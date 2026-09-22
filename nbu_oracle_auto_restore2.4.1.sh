#!/usr/bin/env bash

###################################################################################################################################
## Script Name: nbu_oracle_auto_restore.sh
## Author: hozungzan@outlook.com
## Created Date: Dec 28, 2023
## Updated Date: May 26, 2026
## Description: Automates Oracle database(11g - 23ai) recovery from NetBackup(9.x\10.x\11.x).
## Notes:
##   - Supports in-place restore and redirected restore.
##   - Supports latest restore and point-in-time recovery (PITR).
##   - Redirected restore can rename redo members and clear redo groups after restore.
## Disclaimer:
##   - Testing and learning use only. Review and validate carefully before any production use.
###################################################################################################################################

set -u
set -o pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="2.4.1"
readonly REQUIRED_GROUP="oinstall"
readonly NBU_BPLIST="/usr/openv/netbackup/bin/bplist"
readonly NBU_LIBOBK="/usr/openv/netbackup/bin/libobk.so64"

export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

# Optional overrides for redirected restore.
datafile_path="${datafile_path:-}"
ora_pfile="${ora_pfile:-}"

SOURCE_CLIENT=""
SID=""
RECOVERY_TIME=""
CNTRLFILE_BAKSET=""

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

    for cmd in "$NBU_BPLIST" rman sqlplus awk sed grep head nl mktemp basename tr; do
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

show_recent_backup_selection() {
    local backup_list backup_count choice selected_line

    backup_list="$(run_bplist_text -t 4 -C "$SOURCE_CLIENT" -Listseconds -R -l '/c*trl*' | head -n 8)"
    [[ -n "$backup_list" ]] || die "No control file backups were found in NetBackup."
    backup_count="$(printf '%s\n' "$backup_list" | awk 'END {print NR}')"

    printf '\n'
    warn "No control file backup newer than the requested recovery time was found."
    printf '%s\n' "Please select a backup from the recent list below:"
    printf '%s\n' "$backup_list" | nl -v 1 -w 2 -s '. '
    printf '\n'
    printf '%s' "Enter your choice [1-${backup_count}], or press Enter to use default (1): "
    read -r choice

    if [[ -z "$choice" ]]; then
        choice=1
    elif ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > backup_count )); then
        warn "Invalid selection '${choice}'. Using default (1)."
        choice=1
    fi

    selected_line="$(printf '%s\n' "$backup_list" | sed -n "${choice}p")"
    [[ -n "$selected_line" ]] || die "Failed to read the selected backup entry."

    CNTRLFILE_BAKSET="$(awk '{print $NF}' <<<"$selected_line")"
    RECOVERY_TIME="$(parse_bplist_time "$selected_line")" || \
        die "Failed to derive RECOVERY_TIME from the selected backup."

    info "Selected control file backup: ${CNTRLFILE_BAKSET}"
    info "Adjusted recovery time to selected backup timestamp: ${RECOVERY_TIME}"
}

find_control_file() {
    local valid_check

    if [[ -n "$RECOVERY_TIME" ]]; then
        info "Searching for a control file backup newer than recovery time: ${RECOVERY_TIME}"

        valid_check="$(run_bplist_text -t 4 -C "$SOURCE_CLIENT" -e "$RECOVERY_TIME" -R -l '/c*trl*' || true)"
        [[ -n "$valid_check" ]] || \
            die "No control file backup exists at or before ${RECOVERY_TIME}. The requested time is likely older than the backup catalog."

        CNTRLFILE_BAKSET="$(run_bplist_text -t 4 -C "$SOURCE_CLIENT" -s "$RECOVERY_TIME" -Listseconds -R -l '/c*trl*' | awk 'NF {last=$NF} END {print last}')"
        if [[ -z "$CNTRLFILE_BAKSET" ]]; then
            show_recent_backup_selection
        fi
    else
        info "Searching for the most recent control file backup."
        CNTRLFILE_BAKSET="$(run_bplist_text -t 4 -C "$SOURCE_CLIENT" -Listseconds -R -l '/c*trl*' | awk 'NR==1 {print $NF; exit}')"
    fi

    [[ -n "$CNTRLFILE_BAKSET" ]] || die "Failed to determine the control file backup to restore."
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
ALTER DATABASE MOUNT;
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
ALTER DATABASE MOUNT;
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

recover_and_open_database() {
    info "Recovering database and opening RESETLOGS."

    run_rman_script "recover_and_open_database" <<EOF
RUN {
    ALLOCATE CHANNEL ch00 TYPE SBT_TAPE PARMS 'SBT_LIBRARY=${NBU_LIBOBK}';
    ALLOCATE CHANNEL ch01 TYPE SBT_TAPE PARMS 'SBT_LIBRARY=${NBU_LIBOBK}';
    SEND 'NB_ORA_CLIENT=${SOURCE_CLIENT}';
$(build_until_clause)
    RECOVER DATABASE;
    ALTER DATABASE OPEN RESETLOGS;
    RELEASE CHANNEL ch00;
    RELEASE CHANNEL ch01;
}
EXIT;
EOF
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
    log_selected_backup_details
    pause_before_restore

    startup_database || die "Failed to start the Oracle instance in NOMOUNT."
    restore_controlfile || die "Failed to restore the control file."

    if [[ -n "$datafile_path" ]]; then
        restore_database_redirected || die "Failed to restore the database to the redirected path."
        if ! update_redolog_path; then
            warn "Redo log path update failed. Recovery will continue, but redo members may still reference the old path."
        fi
    else
        restore_database_in_place || die "Failed to restore the database."
    fi

    recover_and_open_database || die "Failed to recover and open the database."
    info "Database recovery completed successfully."
}

main "$@"
