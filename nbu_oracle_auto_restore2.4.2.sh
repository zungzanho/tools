#!/usr/bin/env bash
###################################################################################################################################
## Script Name: nbu_oracle_auto_restore.sh
## Author: hozungzan@outlook.com
## Created Date: Dec 28, 2023
## Updated Date: Oct 11, 2026
## Description: Automates Oracle database(11g - 23ai) recovery from NetBackup(9.x\10.x\11.x).
## Notes:
##   - Supports in-place restore and redirected restore.
##   - Supports latest restore and point-in-time recovery (PITR).
##   - Redirected restore can rename redo members and clear redo groups after restore.
## Disclaimer:
##   - Testing and learning use only. Review and validate carefully before any env use.
###################################################################################################################################
# Keep the legacy "sh script.sh"
if [ -z "${BASH_VERSION:-}" ]; then
    exec /usr/bin/env bash "$0" "$@"
fi
set -u
set -o pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="2.4.2"
readonly REQUIRED_GROUP="oinstall"
readonly NBU_BPLIST="/usr/openv/netbackup/bin/bplist"
readonly NBU_LIBOBK="/usr/openv/netbackup/bin/libobk.so64"

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"
export NLS_DATE_FORMAT="MM/DD/YYYY HH24:MI:SS"

# Optional overrides for redirected restore.
datafile_path="${datafile_path:-}"
ora_pfile="${ora_pfile:-}"

SOURCE_CLIENT=""
SID=""
RECOVERY_TIME=""
CNTRLFILE_BAKSET=""
# RECOVERY_TIME is the effective RMAN target. Preserve the original PITR request.
REQUESTED_RECOVERY_TIME=""
CONTROLFILE_TIME=""
ARCHIVE_BACKUP_TIME=""
CONTROLFILE_INDEX=0
CONTROLFILE_PIECES=()
CONTROLFILE_TIMES=()

LOG_DIR="${HOME}/hoyeung_nbora_log"
LOG_FILE=""
LOG_READY=0
TMP_DIR=""

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log_line() {
    local level="$1"
    shift
    local line
    line="[$(timestamp)] [$level] $*"
    printf '%s\n' "$line"
    if [[ "$LOG_READY" -eq 1 ]]; then
        printf '%s\n' "$line" >>"$LOG_FILE"
    fi
}

info() {
    log_line "INFO" "$@"
}

warn() {
    log_line "WARN" "$@"
}

error() {
    log_line "ERROR" "$@"
}

die() {
    error "$@"
    exit 1
}

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}

trap cleanup EXIT

usage() {
    cat <<EOF
Usage:
  sh ${SCRIPT_NAME} -sourceclient <sourceclient_hostname> -sid <database_sid> [-recovertime "MM/DD/YYYY HH24:MI:SS"]

Required parameters:
  -sourceclient    Original backup client hostname
  -sid             Oracle SID to restore

Optional parameters:
  -recovertime     Point-in-time recovery target in "MM/DD/YYYY HH24:MI:SS"
  -h, --help       Show this help message

Optional environment variables for redirected restore:
  datafile_path    Target path for restored datafiles
  ora_pfile        PFILE path to use for STARTUP NOMOUNT

Examples:
  # In-place restore to latest available backup
  sh ${SCRIPT_NAME} -sourceclient dbsrv01 -sid orcl

  # In-place point-in-time recovery
  sh ${SCRIPT_NAME} -sourceclient dbsrv01 -sid orcl -recovertime "12/28/2023 13:40:50"

  # Redirected restore (datafiles restored under a new path)
  datafile_path=/u01/app/oracle/oradata/DB01 sh ${SCRIPT_NAME} -sourceclient dbsrv01 -sid orcl

  # Redirected restore with custom PFILE for STARTUP NOMOUNT
  datafile_path=/u01/app/oracle/oradata/DB01 ora_pfile=/tmp/db01_pfile.ora sh ${SCRIPT_NAME} -sourceclient dbsrv01 -sid orcl
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -sourceclient)
                [[ $# -ge 2 && "$2" != -* ]] || die "Missing value for -sourceclient"
                SOURCE_CLIENT="$2"
                shift 2
                ;;
            -sid)
                [[ $# -ge 2 && "$2" != -* ]] || die "Missing value for -sid"
                SID="$2"
                shift 2
                ;;
            -recovertime)
                [[ $# -ge 2 && "$2" != -* ]] || die "Missing value for -recovertime"
                RECOVERY_TIME="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                usage
                die "Unknown parameter: $1"
                ;;
        esac
    done

    [[ -n "$SOURCE_CLIENT" ]] || die "Missing required parameter: -sourceclient"
    [[ -n "$SID" ]] || die "Missing required parameter: -sid"
    REQUESTED_RECOVERY_TIME="$RECOVERY_TIME"
}

validate_recovery_time() {
    local expected_format

    [[ -n "$RECOVERY_TIME" ]] || return 0

    expected_format='^([0-9]{2})/([0-9]{2})/([0-9]{4}) ([0-9]{2}):([0-9]{2}):([0-9]{2})$'
    [[ "$RECOVERY_TIME" =~ $expected_format ]] || \
        die "Invalid -recovertime value. Expected format: MM/DD/YYYY HH24:MI:SS"

    if date -d "$RECOVERY_TIME" '+%m/%d/%Y %H:%M:%S' >/dev/null 2>&1; then
        return 0
    fi

    if date -j -f '%m/%d/%Y %H:%M:%S' "$RECOVERY_TIME" '+%m/%d/%Y %H:%M:%S' >/dev/null 2>&1; then
        return 0
    fi

    warn "Date format is valid, but semantic date validation was skipped because the local date command does not support it."
}

require_commands() {
    local cmd

    for cmd in "$NBU_BPLIST" rman sqlplus awk sed grep head nl mktemp basename tr sort; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            die "Required command not found: $cmd"
        fi
    done
}

run_bplist_text() {
    "$NBU_BPLIST" "$@" 2>>"$LOG_FILE" | tr -d '\000'
}

init_runtime() {
    local current_user uid gid groups

    if ! id -nG | tr ' ' '\n' | grep -qx "$REQUIRED_GROUP"; then
        die "Current user must belong to the '${REQUIRED_GROUP}' group."
    fi

    current_user="$(id -un)"
    uid="$(id -u)"
    gid="$(id -g)"
    groups="$(id -Gn)"

    mkdir -p "$LOG_DIR" || die "Failed to create log directory: $LOG_DIR"

    LOG_FILE="${LOG_DIR}/${current_user}-$(date +'%Y%m%d%H%M%S').log"
    TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nbu_restore.${SID}.XXXXXX")" || \
        die "Failed to create temporary working directory."

    LOG_READY=1
    export ORACLE_SID="$SID"

    info "Script version: ${SCRIPT_VERSION}"
    info "Current user: ${current_user} (uid=${uid}, gid=${gid})"
    info "Current groups: ${groups}"
    info "ORACLE_SID set to: ${ORACLE_SID}"
    info "Log file: ${LOG_FILE}"
    info "Working directory: ${TMP_DIR}"
}

validate_runtime_inputs() {
    if [[ -n "$ora_pfile" && ! -f "$ora_pfile" ]]; then
        die "Configured ora_pfile does not exist: ${ora_pfile}"
    fi

    if [[ -n "$datafile_path" ]]; then
        # mkdir -p "$datafile_path" || die "Failed to create redirected datafile path: ${datafile_path}"
        [[ -d "$datafile_path" ]] || die "Redirected datafile path is not a directory: ${datafile_path}"
    fi
}

month_to_number() {
    case "$1" in
        Jan) printf '01' ;;
        Feb) printf '02' ;;
        Mar) printf '03' ;;
        Apr) printf '04' ;;
        May) printf '05' ;;
        Jun) printf '06' ;;
        Jul) printf '07' ;;
        Aug) printf '08' ;;
        Sep) printf '09' ;;
        Oct) printf '10' ;;
        Nov) printf '11' ;;
        Dec) printf '12' ;;
        *) return 1 ;;
    esac
}

parse_bplist_time() {
    local line="$1"
    local month day year_or_time year time_part month_num

    month="$(awk '{print $5}' <<<"$line")"
    day="$(awk '{print $6}' <<<"$line")"
    year_or_time="$(awk '{print $7}' <<<"$line")"
    month_num="$(month_to_number "$month")" || return 1

    if [[ "$year_or_time" =~ ^[0-9]{4}$ ]]; then
        year="$year_or_time"
        time_part="$(awk '{print $8}' <<<"$line")"
    else
        year="$(date '+%Y')"
        time_part="$year_or_time"
    fi

    printf '%s/%02d/%s %s\n' "$month_num" "$((10#$day))" "$year" "$time_part"
}

# A lexical key compares these fixed-format timestamps without date arithmetic.
time_key() {
    local value="$1"
    printf '%s%s%s%s\n' "${value:6:4}" "${value:0:2}" "${value:3:2}" "${value:11:8}"
}

select_controlfile() {
    CNTRLFILE_BAKSET="${CONTROLFILE_PIECES[$CONTROLFILE_INDEX]}"
    CONTROLFILE_TIME="${CONTROLFILE_TIMES[$CONTROLFILE_INDEX]}"
    info "Selected control file: ${CNTRLFILE_BAKSET}"
    info "Control file NetBackup timestamp: ${CONTROLFILE_TIME}"
}

find_control_file() {
    local listing line backup_time piece i target_key
    local inventory="${TMP_DIR}/controlfiles.tsv"
    local sorted_inventory="${TMP_DIR}/controlfiles.sorted.tsv"

    # Read the full list before selecting so later retries use one stable inventory.
    listing="$(run_bplist_text -t 4 -C "$SOURCE_CLIENT" -Listseconds -R -l '/c*trl*')" ||
        die "Failed to list NetBackup control file backups."
    [[ -n "$listing" ]] || die "No control file backups were found in NetBackup."
    : >"$inventory"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        backup_time="$(parse_bplist_time "$line")" || die "Cannot parse control file backup timestamp: $line"
        [[ "$backup_time" =~ ^[0-9]{2}/[0-9]{2}/[0-9]{4}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] ||
            die "Control file listing lacks a full timestamp: $line"
        piece="$(awk '{print $NF}' <<<"$line")"
        printf '%s\t%s\t%s\n' "$(time_key "$backup_time")" "$backup_time" "$piece" >>"$inventory"
    done <<<"$listing"
    sort -u "$inventory" >"$sorted_inventory" || die "Failed to sort control file backups."
    CONTROLFILE_PIECES=()
    CONTROLFILE_TIMES=()
    while IFS=$'\t' read -r target_key backup_time piece; do
        CONTROLFILE_TIMES+=("$backup_time")
        CONTROLFILE_PIECES+=("$piece")
    done <"$sorted_inventory"
    [[ ${#CONTROLFILE_PIECES[@]} -gt 0 ]] || die "No usable control file entries were found."

    # Latest: newest control file. PITR: earliest control file at/after the target.
    # Reject a target newer than the inventory before changing the instance.
    CONTROLFILE_INDEX=$((${#CONTROLFILE_PIECES[@]} - 1))
    if [[ -n "$REQUESTED_RECOVERY_TIME" ]]; then
        target_key="$(time_key "$REQUESTED_RECOVERY_TIME")"
        if [[ "$target_key" < "$(time_key "${CONTROLFILE_TIMES[0]}")" ]]; then
            error "Requested recovery time ${REQUESTED_RECOVERY_TIME} is earlier than the oldest control file backup timestamp ${CONTROLFILE_TIMES[0]}. Please specify a recovery time within the available control file backup range."
            info "Oldest control file backup: ${CONTROLFILE_PIECES[0]}"
            info "Available control file backup range: ${CONTROLFILE_TIMES[0]} to ${CONTROLFILE_TIMES[$CONTROLFILE_INDEX]}"
            info "Recovery has not started; the Oracle instance has not been changed."
            exit 1
        fi
        if [[ "$target_key" > "$(time_key "${CONTROLFILE_TIMES[$CONTROLFILE_INDEX]}")" ]]; then
            error "Requested recovery time ${REQUESTED_RECOVERY_TIME} is later than the newest control file backup timestamp ${CONTROLFILE_TIMES[$CONTROLFILE_INDEX]}. Please specify an earlier recovery time."
            info "Newest control file backup: ${CONTROLFILE_PIECES[$CONTROLFILE_INDEX]}"
            info "Recovery has not started; the Oracle instance has not been changed."
            exit 1
        fi
        for ((i=0; i<${#CONTROLFILE_PIECES[@]}; i++)); do
            if [[ "$(time_key "${CONTROLFILE_TIMES[$i]}")" < "$target_key" ]]; then
                continue
            fi
            CONTROLFILE_INDEX=$i
            break
        done
    fi
    select_controlfile
}

mount_database() {
    run_rman_script "mount_controlfile" <<'EOF'
ALTER DATABASE MOUNT;
EXIT;
EOF
}

# Parse only archive rows inside AVAILABLE SBT backup sets. Do not use backup
# completion times or TAG timestamps. RMAN output is kept in the main log.
parse_archive_backup_list() {
    awk -v mode="${2:-time}" '
    function key(d, t) { return substr(d,7,4) substr(d,1,2) substr(d,4,2) t }
    function flush( i, thread, k) {
        if (device == "SBT_TAPE" && pieces > 0 && !unavailable) {
            for (i=1; i<=rows; i++) {
                thread=threads[i]; k=keys[i]
                if (!(thread in latest) || k > latest[thread]) {
                    latest[thread]=k; times[thread]=dates[i]
                    evidence[thread]=set_line "\n" piece_lines "\n" archive_lines[i]
                }
            }
        }
        rows=0; pieces=0; unavailable=0; piece_lines=""
    }
    /^[[:space:]]*[0-9]+[[:space:]]+/ && ($3 == "SBT_TAPE" || $3 == "DISK") {
        flush(); device=$3; set_line=$0; next
    }
    /BP Key:/ {
        pieces++
        piece_lines=piece_lines $0 "\n"
        if ($0 !~ /Status:[[:space:]]+AVAILABLE([[:space:]]|$)/) unavailable=1
        next
    }
    /Handle:/ { piece_lines=piece_lines $0 "\n"; next }
    NF == 8 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ &&
    $3 ~ /^[0-9]+$/ && $6 ~ /^[0-9]+$/ &&
    $7 ~ /^[0-9][0-9]\/[0-9][0-9]\/[0-9][0-9][0-9][0-9]$/ &&
    $8 ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ {
        rows++; threads[rows]=$1; keys[rows]=key($7,$8); dates[rows]=$7 " " $8; archive_lines[rows]=$0
        next
    }
    END {
        flush()
        for (thread in latest) {
            if (boundary == "" || latest[thread] < boundary) {
                boundary=latest[thread]; result=times[thread]
            }
        }
        if (mode == "summary") {
            print "LIST BACKUP OF ARCHIVELOG ALL — key records"
            for (thread in latest) {
                print "Thread " thread " latest available archive backup:"
                print "BS Key / Size / Device Type / Elapsed Time / Completion Time"
                print "Thrd / Seq / Low SCN / Low Time / Next SCN / Next Time"
                print evidence[thread]
            }
            if (result == "") print "No matching AVAILABLE SBT archive backup records."
        } else {
            if (result == "") print "UNKNOWN"; else print result
        }
    }' "$1"
}

inspect_archive_backups() {
    local list_file="${TMP_DIR}/archive_backups.list" result
    local command_file="${TMP_DIR}/list_archive_backups.rcv"
    cat >"$command_file" <<'EOF'
LIST BACKUP OF ARCHIVELOG ALL;
EXIT;
EOF
    if ! rman target / nocatalog @"$command_file" >"$list_file" 2>&1; then
        cat "$list_file" >>"$LOG_FILE"
        error "Failed to list archive backups from the mounted control file."
        return 1
    fi
    # Some RMAN diagnostics can be printed even when the process returns zero.
    if grep -Eq '^[[:space:]]*(RMAN-|ORA-)[0-9]+:' "$list_file"; then
        cat "$list_file" >>"$LOG_FILE"
        error "RMAN reported an error while listing archive backups."
        return 1
    fi
    result="$(parse_archive_backup_list "$list_file")" || return 1
    if [[ "$result" != UNKNOWN && ! "$result" =~ ^[0-9]{2}/[0-9]{2}/[0-9]{4}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
        error "Unexpected archive backup list result."
        return 1
    fi
    parse_archive_backup_list "$list_file" summary >>"$LOG_FILE" || return 1
    ARCHIVE_BACKUP_TIME="$result"
    info "Recorded available archive backup boundary (Next Time): ${ARCHIVE_BACKUP_TIME}"
    return 0
}

confirm_latest_target() {
    local answer=""
    if [[ "$ARCHIVE_BACKUP_TIME" != UNKNOWN ]]; then
        printf 'Recover to %s, the recorded archive backup boundary? [y/N]: ' "$ARCHIVE_BACKUP_TIME"
        read -r answer || answer=""
        case "$answer" in
            y|Y|yes|YES|Yes)
                RECOVERY_TIME="$ARCHIVE_BACKUP_TIME"
                info "Accepted recovery time: ${RECOVERY_TIME}"
                return 0
                ;;
        esac
        info "Archive backup boundary was not accepted."
    else
        warn "The control file does not contain enough available archive backup records to determine a time."
    fi
    RECOVERY_TIME=""
    warn "During RECOVER, you may need to manually add archived log files for recovery to succeed. Please contact Oracle Technical Support for assistance."
    info "Continuing the original latest recovery without SET UNTIL TIME."
}

stop_uncovered_recovery() {
    error "The current backup records cannot support recovery to ${REQUESTED_RECOVERY_TIME}. Please adjust the recovery time."
    info "Source client: ${SOURCE_CLIENT}; target SID: ${SID}"
    info "Last restored control file: ${CNTRLFILE_BAKSET}"
    info "Control file NetBackup timestamp: ${CONTROLFILE_TIME}"
    info "Recorded archive backup boundary: ${ARCHIVE_BACKUP_TIME}"
    startup_database || die "Could not return to NOMOUNT. Check the actual instance state; the last successful state was MOUNT."
    info "Instance is NOMOUNT using ${ora_pfile:-the default parameter file}."
    info "The control file above was last restored and inspected in MOUNT; a NOMOUNT instance does not mount a control file. No database datafiles have been restored by this run."
    exit 1
}

prepare_controlfile_and_target() {
    while :; do
        log_selected_backup_details
        startup_database || die "Failed to start the Oracle instance in NOMOUNT."
        restore_controlfile || die "Failed to restore the control file."
        mount_database || die "Failed to mount the restored control file."
        inspect_archive_backups || die "Failed to inspect archive backup coverage. See ${LOG_FILE}"

        if [[ -z "$REQUESTED_RECOVERY_TIME" ]]; then
            confirm_latest_target
            return 0
        fi
        # Equality is sufficient: do not change the user's PITR target.
        if [[ "$ARCHIVE_BACKUP_TIME" != UNKNOWN ]]; then
            if [[ ! "$(time_key "$ARCHIVE_BACKUP_TIME")" < "$(time_key "$REQUESTED_RECOVERY_TIME")" ]]; then
                info "Archive backup boundary covers requested time: ${REQUESTED_RECOVERY_TIME}"
                return 0
            fi
        fi
        if (( CONTROLFILE_INDEX + 1 >= ${#CONTROLFILE_PIECES[@]} )); then
            stop_uncovered_recovery
        fi
        warn "Requested time is not covered; trying the next newer control file backup."
        CONTROLFILE_INDEX=$((CONTROLFILE_INDEX + 1))
        select_controlfile
    done
}

log_selected_backup_details() {
    {
        printf '\n[%s] [INFO] Selected control file backup details for %s\n' "$(timestamp)" "$CNTRLFILE_BAKSET"
        run_bplist_text -t 4 -C "$SOURCE_CLIENT" -Listseconds -R -l "$CNTRLFILE_BAKSET"
        printf '\n'
    } >>"$LOG_FILE" 2>&1
}

build_until_clause() {
    if [[ -n "$RECOVERY_TIME" ]]; then
        printf '    SET UNTIL TIME "TO_DATE('\''%s'\'', '\''MM/DD/YYYY HH24:MI:SS'\'')";\n' "$RECOVERY_TIME"
    fi
}

run_rman_script() {
    local name="$1"
    local script_file="${TMP_DIR}/${name}.rcv"

    cat >"$script_file"

    if ! rman target / nocatalog @"$script_file" >>"$LOG_FILE" 2>&1; then
        error "RMAN step failed: ${name}. See ${LOG_FILE}"
        return 1
    fi

    return 0
}

startup_database() {
    local startup_clause

    if [[ -n "$ora_pfile" ]]; then
        info "Starting instance in NOMOUNT using custom PFILE: ${ora_pfile}"
        startup_clause="STARTUP FORCE NOMOUNT PFILE='${ora_pfile}';"
    else
        info "Starting instance in NOMOUNT using default parameter file."
        startup_clause="STARTUP FORCE NOMOUNT;"
    fi

    run_rman_script "startup_nomount" <<EOF
${startup_clause}
EXIT;
EOF
}

restore_controlfile() {
    info "Restoring control file from backup piece: ${CNTRLFILE_BAKSET}"
    run_rman_script "restore_controlfile" <<EOF
RUN {
    ALLOCATE CHANNEL ch00 TYPE 'SBT_TAPE' PARMS 'SBT_LIBRARY=${NBU_LIBOBK}';
    SEND 'NB_ORA_CLIENT=${SOURCE_CLIENT}';
    RESTORE PRIMARY CONTROLFILE FROM '${CNTRLFILE_BAKSET}';
    RELEASE CHANNEL ch00;
}
EXIT;
EOF
}

restore_database_in_place() {
    info "Restoring database in-place."

    run_rman_script "restore_database_in_place" <<EOF
RUN {
    ALLOCATE CHANNEL ch00 TYPE SBT_TAPE PARMS 'SBT_LIBRARY=${NBU_LIBOBK}';
    ALLOCATE CHANNEL ch01 TYPE SBT_TAPE PARMS 'SBT_LIBRARY=${NBU_LIBOBK}';
    ALLOCATE CHANNEL ch02 TYPE SBT_TAPE PARMS 'SBT_LIBRARY=${NBU_LIBOBK}';
    ALLOCATE CHANNEL ch03 TYPE SBT_TAPE PARMS 'SBT_LIBRARY=${NBU_LIBOBK}';
    SEND 'NB_ORA_CLIENT=${SOURCE_CLIENT}';
$(build_until_clause)
    RESTORE DATABASE;
    RELEASE CHANNEL ch00;
    RELEASE CHANNEL ch01;
    RELEASE CHANNEL ch02;
    RELEASE CHANNEL ch03;
}
EXIT;
EOF
}

restore_database_redirected() {
    info "Restoring database to redirected path: ${datafile_path}"

    run_rman_script "restore_database_redirected" <<EOF
RUN {
    ALLOCATE CHANNEL ch00 TYPE SBT_TAPE PARMS 'SBT_LIBRARY=${NBU_LIBOBK}';
    ALLOCATE CHANNEL ch01 TYPE SBT_TAPE PARMS 'SBT_LIBRARY=${NBU_LIBOBK}';
    ALLOCATE CHANNEL ch02 TYPE SBT_TAPE PARMS 'SBT_LIBRARY=${NBU_LIBOBK}';
    ALLOCATE CHANNEL ch03 TYPE SBT_TAPE PARMS 'SBT_LIBRARY=${NBU_LIBOBK}';
    SEND 'NB_ORA_CLIENT=${SOURCE_CLIENT}';
$(build_until_clause)
    SET NEWNAME FOR DATABASE TO '${datafile_path}/%N%f.dbf';
    RESTORE DATABASE;
    RELEASE CHANNEL ch00;
    RELEASE CHANNEL ch01;
    RELEASE CHANNEL ch02;
    RELEASE CHANNEL ch03;
}
SWITCH DATABASE TO COPY;
EXIT;
EOF
}

update_redolog_path() {
    local redo_list_file="${TMP_DIR}/redo_logs_list.txt"
    local redo_clean_file="${TMP_DIR}/redo_logs_list.clean"
    local group_list_file="${TMP_DIR}/logfile_groups.sql"
    local batch_sql_file="${TMP_DIR}/rename_redo_batch.sql"
    local redo_member new_member_path

    info "Updating redo log paths under redirected restore path."

    if ! sqlplus -S / as sysdba >"$redo_list_file" 2>>"$LOG_FILE" <<'EOF'
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET PAGESIZE 0
SET FEEDBACK OFF
SET HEADING OFF
SET VERIFY OFF
SET ECHO OFF
SET TRIMSPOOL ON
SELECT member FROM v$logfile;
EXIT;
EOF
    then
        error "Failed to query current redo log members."
        return 1
    fi

    awk 'NF {print $0}' "$redo_list_file" >"$redo_clean_file"
    [[ -s "$redo_clean_file" ]] || {
        warn "No redo log members were returned from v\$logfile. Skipping redo rename step."
        return 0
    }

    if ! sqlplus -S / as sysdba >"$group_list_file" 2>>"$LOG_FILE" <<'EOF'
WHENEVER SQLERROR EXIT SQL.SQLCODE
SET PAGESIZE 0
SET FEEDBACK OFF
SET HEADING OFF
SET VERIFY OFF
SET ECHO OFF
SET TRIMSPOOL ON
SELECT 'ALTER DATABASE CLEAR LOGFILE GROUP ' || GROUP# || ';' FROM v$log;
EXIT;
EOF
    then
        error "Failed to query redo log groups."
        return 1
    fi

    {
        printf 'WHENEVER SQLERROR EXIT SQL.SQLCODE\n'
        printf 'CONNECT / AS SYSDBA\n'
        while IFS= read -r redo_member; do
            new_member_path="${datafile_path}/$(basename "$redo_member")"
            printf "ALTER DATABASE RENAME FILE '%s' TO '%s';\n" "$redo_member" "$new_member_path"
        done <"$redo_clean_file"
        awk 'NF {print $0}' "$group_list_file"
        printf 'EXIT;\n'
    } >"$batch_sql_file"

    if ! sqlplus -S /nolog @"$batch_sql_file" >>"$LOG_FILE" 2>&1; then
        error "Redo log path update failed. Review ${LOG_FILE}"
        return 1
    fi

    info "Redo log path update completed."
}

recover_database() {
    info "Recovering database; the instance will remain MOUNTED."

    run_rman_script "recover_database" <<EOF
RUN {
    ALLOCATE CHANNEL ch00 TYPE SBT_TAPE PARMS 'SBT_LIBRARY=${NBU_LIBOBK}';
    ALLOCATE CHANNEL ch01 TYPE SBT_TAPE PARMS 'SBT_LIBRARY=${NBU_LIBOBK}';
    SEND 'NB_ORA_CLIENT=${SOURCE_CLIENT}';
$(build_until_clause)
    RECOVER DATABASE;
    RELEASE CHANNEL ch00;
    RELEASE CHANNEL ch01;
}
EXIT;
EOF
}

report_recovery_success() {
    if [[ -n "$RECOVERY_TIME" ]]; then
        info "Database recovery completed successfully to target time: ${RECOVERY_TIME}"
    else
        info "Database recovery completed successfully without an explicit time target."
        info "An exact recovered timestamp is not determined by this run; see the RMAN recovery log."
    fi
    info "Database remains MOUNTED. To open it for use, connect as SYSDBA and run:"
    info "   sqlplus / as sysdba"
    info "   ALTER DATABASE OPEN RESETLOGS;"
}

pause_before_restore() {
    info "Selected control file backup: ${CNTRLFILE_BAKSET}"
    if [[ -n "$RECOVERY_TIME" ]]; then
        info "Recovery target time: ${RECOVERY_TIME}"
    else
        info "Recovery target time: latest available backup state"
    fi

    info "A 30-second safety delay starts now. Press Ctrl+C to abort."
    sleep 30
}

main() {
    parse_args "$@"
    validate_recovery_time
    require_commands
    init_runtime
    validate_runtime_inputs

    if [[ -n "$datafile_path" ]]; then
        info "Redirected restore enabled. Datafiles will be restored under: ${datafile_path}"
    else
        info "In-place restore enabled. Original datafile paths will be reused."
    fi

    find_control_file
    pause_before_restore
    prepare_controlfile_and_target

    if [[ -n "$datafile_path" ]]; then
        restore_database_redirected || die "Failed to restore the database to the redirected path."
        if ! update_redolog_path; then
            warn "Redo log path update failed. Recovery will continue, but redo members may still reference the old path."
        fi
    else
        restore_database_in_place || die "Failed to restore the database."
    fi

    recover_database || die "Failed to recover the database."
    report_recovery_success
}

main "$@"
