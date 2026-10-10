#!/usr/bin/env bash
# RHEL NetBackup primary server preinstallation
# Usage: curl -fsSL https://raw.githubusercontent.com/zungzanho/tools/refs/heads/main/preinstall-nbu11.sh | bash -

main() {
    set -Eeuo pipefail
    umask 022
    export LANG="en_US.UTF-8"
    export LC_ALL="en_US.UTF-8"

    trap 'rc=$?; printf "[ALERT] Failed: line=%s exit=%s command=%s\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2; exit "$rc"' ERR
    trap 'printf "[ALERT] Execution interrupted.\n" >&2; exit 130' INT
    trap 'printf "[ALERT] Execution terminated.\n" >&2; exit 143' TERM

    die() {
        printf '[ALERT] %s\n' "$*" >&2
        exit 1
    }

    [[ "$EUID" -eq 0 ]] ||
        die "Root privileges are required. Non-root execution is prohibited."

    [[ -r /etc/os-release ]] ||
        die "Cannot read /etc/os-release."

    source /etc/os-release

    case "${ID:-}" in
        rhel|rocky|ol) ;;
        *)
            die "Unsupported distribution: ${ID:-unknown}. Only RHEL, Rocky Linux, and Oracle Linux are allowed."
            ;;
    esac

    case "${VERSION_ID:-}" in
        8|8.*|9|9.*|10|10.*) ;;
        *)
            die "Unsupported version: ${VERSION_ID:-unknown}. Only versions 8, 9, and 10 are allowed."
            ;;
    esac

    printf '[INFO] Operating system: %s\n' \
        "${PRETTY_NAME:-${ID} ${VERSION_ID}}"

    local cmd
    for cmd in dnf getent useradd groupadd usermod id hostname \
               sysctl getenforce setenforce sed cut mktemp chmod \
               chown mv mkdir cat cmp rm flock; do
        command -v "$cmd" >/dev/null ||
            die "Required command is unavailable: $cmd"
    done

    [[ -x /usr/sbin/nologin ]] ||
        die "/usr/sbin/nologin is unavailable."

    [[ -f /etc/selinux/config ]] ||
        die "/etc/selinux/config is unavailable."

    exec 9>/run/nbu-preinstall.lock
    flock -n 9 ||
        die "Another NBU preinstallation process is running."

    local fqdn root_home
    fqdn="$(hostname -f)"
    [[ -n "$fqdn" && "$fqdn" == *.* &&
       "$fqdn" != *[[:space:]]* ]] ||
        die "hostname -f must return a fully qualified hostname."

    root_home="$(getent passwd root | cut -d: -f6)"
    [[ -n "$root_home" && -d "$root_home" ]] ||
        die "Root home directory is unavailable."

    NBU_PREINSTALL_WORKDIR="$(mktemp -d /run/nbu-preinstall.XXXXXX)"
    trap 'rc=$?; trap - ERR; if ! rm -rf -- "$NBU_PREINSTALL_WORKDIR"; then printf "[ALERT] Temporary-directory cleanup failed.\n" >&2; [[ "$rc" -ne 0 ]] || rc=1; fi; exit "$rc"' EXIT

    write_if_changed() {
        local destination="$1" mode="$2" candidate staged rc

        [[ ! -L "$destination" ]] ||
            die "Refusing to replace symbolic link: $destination."
        [[ ! -e "$destination" || -f "$destination" ]] ||
            die "Destination is not a regular file: $destination."

        candidate="$(mktemp "$NBU_PREINSTALL_WORKDIR/content.XXXXXX")"
        cat > "$candidate"

        if [[ -f "$destination" ]]; then
            if cmp -s "$candidate" "$destination"; then
                chmod "$mode" "$destination"
                chown root:root "$destination"
                rm -f -- "$candidate"
                return 0
            else
                rc=$?
                [[ "$rc" -eq 1 ]] ||
                    die "Cannot compare configuration: $destination."
            fi
        fi

        staged="$(mktemp "${destination}.XXXXXX")"
        cat "$candidate" > "$staged"
        chmod "$mode" "$staged"
        chown root:root "$staged"
        mv -fT -- "$staged" "$destination"
        rm -f -- "$candidate"

        printf '[INFO] Updated %s\n' "$destination"
    }

    entry_exists() {
        local rc
        if getent "$1" "$2" >/dev/null; then
            return 0
        else
            rc=$?
            [[ "$rc" -eq 2 ]] && return 1
            die "getent failed for $1/$2 (exit $rc)."
        fi
    }

    ensure_shell() {
        local account="$1" current_shell
        current_shell="$(getent passwd "$account" | cut -d: -f7)"

        if [[ "$current_shell" != /usr/sbin/nologin ]]; then
            usermod -s /usr/sbin/nologin "$account"
        fi
    }

    printf '[INFO] Ensuring required packages are installed...\n'
    dnf install -y \
        libnsl.so.1 libnsl libcrypt.so.1 \
        libXtst libXrender xorg-x11-xinit \
        nginx samba nfs-utils podman

    printf '[INFO] Ensuring service accounts are configured...\n'

    if ! entry_exists group nbwebgrp; then
        groupadd nbwebgrp
    fi

    if ! entry_exists passwd nbsvcusr; then
        useradd -M \
            -c 'NetBackup Services account' \
            -d /usr/openv \
            -s /usr/sbin/nologin nbsvcusr
    fi

    local web_gid service_uid service_gid groups
    web_gid="$(getent group nbwebgrp | cut -d: -f3)"
    service_uid="$(id -u nbsvcusr)"
    service_gid="$(id -g nbsvcusr)"

    [[ "$service_uid" -ne 0 ]] ||
        die "nbsvcusr must not have UID 0."

    [[ "$service_gid" != "$web_gid" ]] ||
        die "nbwebgrp must be a supplementary group, not the primary group of nbsvcusr."

    groups="$(id -G nbsvcusr)"
    case " $groups " in
        *" $web_gid "*) ;;
        *) usermod -aG nbwebgrp nbsvcusr ;;
    esac

    ensure_shell nbsvcusr

    if ! entry_exists passwd nbwebsvc; then
        useradd -M -g nbwebgrp \
            -c 'NetBackup Web Services account' \
            -d /usr/openv/wmc \
            -s /usr/sbin/nologin nbwebsvc
    fi

    local web_uid web_primary_gid
    web_uid="$(id -u nbwebsvc)"

    [[ "$web_uid" -ne 0 && "$web_uid" != "$service_uid" ]] ||
        die "nbwebsvc must have a distinct, nonzero UID."

    web_primary_gid="$(id -g nbwebsvc)"
    if [[ "$web_primary_gid" != "$web_gid" ]]; then
        usermod -g nbwebgrp nbwebsvc
    fi

    ensure_shell nbwebsvc

    printf '[INFO] Ensuring file limits are configured...\n'
    mkdir -p /etc/security/limits.d

    write_if_changed /etc/security/limits.d/99-nbu-preinstall.conf 0644 <<'EOF'
*        soft nofile 8192
*        hard nofile 8192
root     soft nofile 8192
root     hard nofile 8192
nbsvcusr soft nofile 8192
nbsvcusr hard nofile 8192
nbwebsvc soft nofile 8192
nbwebsvc hard nofile 8192
EOF

    local soft_limit
    soft_limit="$(ulimit -Sn)"
    if [[ "$soft_limit" == unlimited || "$soft_limit" -gt 8192 ]]; then
        ulimit -Sn 8192
    fi
    ulimit -Hn 8192
    ulimit -Sn 8192

    printf '[INFO] Ensuring kernel parameters are configured...\n'
    local sysctl_candidate="$NBU_PREINSTALL_WORKDIR/sysctl.conf"

    [[ ! -L /etc/sysctl.conf ]] ||
        die "Refusing to replace symbolic link: /etc/sysctl.conf."

    if [[ -f /etc/sysctl.conf ]]; then
        sed \
            -e '/^[[:space:]]*kernel\.sem[[:space:]]*=/d' \
            -e '/^[[:space:]]*fs\.file-max[[:space:]]*=/d' \
            /etc/sysctl.conf > "$sysctl_candidate"
    else
        : > "$sysctl_candidate"
    fi

    cat >> "$sysctl_candidate" <<'EOF'
kernel.sem = 300 307200 100 1024
fs.file-max = 3245530
EOF

    write_if_changed /etc/sysctl.conf 0644 < "$sysctl_candidate"

    local current_sem current_filemax
    current_sem="$(sysctl -n kernel.sem)"
    current_sem="${current_sem//$'\t'/ }"

    if [[ "$current_sem" != '300 307200 100 1024' ]]; then
        sysctl -w 'kernel.sem=300 307200 100 1024'
    fi

    current_filemax="$(sysctl -n fs.file-max)"
    if [[ "$current_filemax" != 3245530 ]]; then
        sysctl -w 'fs.file-max=3245530'
    fi

    current_sem="$(sysctl -n kernel.sem)"
    current_sem="${current_sem//$'\t'/ }"
    current_filemax="$(sysctl -n fs.file-max)"

    [[ "$current_sem" == '300 307200 100 1024' ]] ||
        die "kernel.sem verification failed."
    [[ "$current_filemax" == 3245530 ]] ||
        die "fs.file-max verification failed."

    printf '[INFO] Ensuring SELinux is configured...\n'
    local selinux_state current_selinux
    local selinux_candidate="$NBU_PREINSTALL_WORKDIR/selinux.config"

    selinux_state="$(getenforce)"
    case "$selinux_state" in
        Enforcing) setenforce 0 ;;
        Permissive|Disabled) ;;
        *) die "Unexpected SELinux state: $selinux_state." ;;
    esac

    sed '/^[[:space:]]*SELINUX[[:space:]]*=/d' \
        /etc/selinux/config > "$selinux_candidate"
    printf 'SELINUX=disabled\n' >> "$selinux_candidate"

    write_if_changed /etc/selinux/config 0644 < "$selinux_candidate"

    current_selinux="$(getenforce)"
    [[ "$current_selinux" == Permissive ||
       "$current_selinux" == Disabled ]] ||
        die "SELinux runtime verification failed."

    printf '[INFO] Ensuring root PATH is configured...\n'
    local profile="${root_home}/.bash_profile"
    local profile_candidate="$NBU_PREINSTALL_WORKDIR/bash_profile"

    [[ ! -L "$profile" ]] ||
        die "Refusing to replace symbolic link: $profile."

    if [[ -f "$profile" ]]; then
        sed \
            '/^# BEGIN NBU PREINSTALL PATH$/,/^# END NBU PREINSTALL PATH$/d' \
            "$profile" > "$profile_candidate"
    else
        : > "$profile_candidate"
    fi

    cat >> "$profile_candidate" <<'EOF'
# BEGIN NBU PREINSTALL PATH
NBU_BIN_PATH="/usr/openv/netbackup/bin/goodies:/usr/openv/netbackup/bin/admincmd:/usr/openv/volmgr/bin:/usr/openv/netbackup/bin:/usr/openv/db/bin:/usr/openv/netbackup/bin/support:/usr/openv/netbackup/bin/goodies/support:/opt/VRTSpbx/bin:/opt/VRTS/bin"
case ":${PATH:-}:" in
    *":${NBU_BIN_PATH}:"*) ;;
    *) PATH="${PATH:+${PATH}:}${NBU_BIN_PATH}" ;;
esac
export PATH
# END NBU PREINSTALL PATH
EOF

    write_if_changed "$profile" 0600 < "$profile_candidate"

    printf '[INFO] Ensuring installation answer file is configured...\n'
    write_if_changed /tmp/NBInstallAnswer.conf 0600 <<EOF
CLIENT_NAME = ${fqdn}
MACHINE_ROLE = PRIMARY
SERVER = ${fqdn}
INSTALL_PATH = /usr/openv
LICENSE = EVALUATION
NB_FIPS_MODE = Disable
SERVICE_USER = nbsvcusr
START_JOB_DAEMONS = yes
ALLOW_LONG_NBDB_MIGRATION_TIME = yes
IGNORE_MISSING_CATALOG_BACKUP = yes
DISASTER_RECOVERY_INSTALL = no
ACCEPT_EULA = yes
INCLUDE_JAVA_GUI_ON_PRIMARY = MATCH
PROCEED_WITH_INSTALL = yes
USE_URANDOM = ENABLE
INSTALL_ITA_DATA_COLLECTOR = no
INCLUDE_NBDIRECTIO = EXCLUDE
EOF

    printf '[SUCCESS] NBU preinstallation completed for %s.\n' "$fqdn"
    printf '[INFO] Answer file: /tmp/NBInstallAnswer.conf\n'
    printf '[INFO] Open a new login shell to load the PATH changes.\n'

    if [[ "$current_selinux" != Disabled ]]; then
        printf '[ALERT] Reboot is required to fully disable SELinux.\n' >&2
    fi
}

# Prevent child processes from consuming the downloaded script.
main "$@" </dev/null
