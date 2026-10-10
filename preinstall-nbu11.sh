#!/usr/bin/env bash
# RHEL NetBackup primary server preinstallation
# Usage: curl -fsSL https://raw.githubusercontent.com/zungzanho/tools/refs/heads/main/preinstall-nbu11.sh | bash -

main() {
    set -Eeuo pipefail
    umask 022
    export LANG="en_US.UTF-8"
    export LC_ALL="en_US.UTF-8"

    trap 'rc=$?; printf "[ALERT] Line %s failed (exit %s): %s\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2; exit "$rc"' ERR

    if [[ "$EUID" -ne 0 ]]; then
        echo '[ALERT] This script must be run as root.' >&2
        exit 1
    fi

    source /etc/os-release
    case "${ID:-}:${VERSION_ID:-}" in
        rhel:8|rhel:8.*|rhel:9|rhel:9.*|rhel:10|rhel:10.*|\
        rocky:8|rocky:8.*|rocky:9|rocky:9.*|rocky:10|rocky:10.*|\
        ol:8|ol:8.*|ol:9|ol:9.*|ol:10|ol:10.*)
            ;;
        *)
            echo '[ALERT] Only RHEL, Rocky Linux, and Oracle Linux 8/9/10 are supported.' >&2
            exit 1
            ;;
    esac

    fqdn="$(hostname -f)"
    if [[ "$fqdn" != *.* || "$fqdn" == *[[:space:]]* ]]; then
        echo '[ALERT] hostname -f must return a fully qualified hostname.' >&2
        exit 1
    fi

    packages=(
        libnsl.so.1 libnsl libcrypt.so.1
        libXtst libXrender xorg-x11-xinit
        nginx samba nfs-utils podman
    )

    echo '[INFO] Checking and installing required packages...'
    dnf_log="$(mktemp /tmp/nbu-dnf.XXXXXX)"

    if dnf install -y "${packages[@]}" >"$dnf_log" 2>&1; then
        rm -f "$dnf_log"
        echo '[SUCCESS] All requested packages are installed.'
    else
        rc=$?
        echo "[ALERT] Package installation failed (exit $rc)." >&2
        cat "$dnf_log" >&2
        echo "[INFO] Installation log: $dnf_log" >&2
        exit "$rc"
    fi

    exists() {
        local rc
        if getent "$1" "$2" >/dev/null; then
            return 0
        else
            rc=$?
            [[ "$rc" -eq 2 ]] && return 1
            echo "[ALERT] getent failed for $1/$2 (exit $rc)." >&2
            exit "$rc"
        fi
    }

    exists passwd nbsvcusr ||
        useradd -M -c 'NetBackup Services account' \
            -d /usr/openv/ -s /usr/sbin/nologin nbsvcusr

    exists group nbwebgrp || groupadd nbwebgrp

    if [[ "$(id -gn nbsvcusr)" == nbwebgrp ]]; then
        echo '[ALERT] nbwebgrp must not be the primary group of nbsvcusr.' >&2
        exit 1
    fi

    usermod -aG nbwebgrp -s /usr/sbin/nologin nbsvcusr

    exists passwd nbwebsvc ||
        useradd -M -g nbwebgrp -c 'NetBackup Web Services account' \
            -d /usr/openv/wmc -s /usr/sbin/nologin nbwebsvc

    if [[ "$(id -u nbsvcusr)" -eq 0 ||
          "$(id -u nbwebsvc)" -eq 0 ||
          "$(id -u nbsvcusr)" == "$(id -u nbwebsvc)" ]]; then
        echo '[ALERT] Service accounts must have distinct, nonzero UIDs.' >&2
        exit 1
    fi

    usermod -g nbwebgrp -s /usr/sbin/nologin nbwebsvc
    echo '[SUCCESS] Service accounts are configured.'

    sed -i \
        '/^[[:space:]]*\*[[:space:]]\+\(soft\|hard\)[[:space:]]\+nofile[[:space:]]/d;
         /^[[:space:]]*root[[:space:]]\+\(soft\|hard\)[[:space:]]\+nofile[[:space:]]/d' \
        /etc/security/limits.conf

    cat >> /etc/security/limits.conf <<'EOF'
* soft nofile 8192
* hard nofile 8192
root soft nofile 8192
root hard nofile 8192
EOF

    touch /etc/sysctl.conf
    sed -i \
        '/^[[:space:]]*kernel\.sem[[:space:]]*=/d;
         /^[[:space:]]*fs\.file-max[[:space:]]*=/d' \
        /etc/sysctl.conf

    cat >> /etc/sysctl.conf <<'EOF'
kernel.sem = 300 307200 100 1024
fs.file-max = 3245530
EOF

    sysctl -p /etc/sysctl.conf >/dev/null
    echo '[SUCCESS] File limits and kernel parameters are configured.'

    case "$(getenforce)" in
        Enforcing) setenforce 0 ;;
        Permissive|Disabled) ;;
        *)
            echo '[ALERT] Unexpected SELinux state.' >&2
            exit 1
            ;;
    esac

    sed -i '/^[[:space:]]*SELINUX[[:space:]]*=/d' /etc/selinux/config
    echo 'SELINUX=disabled' >> /etc/selinux/config
    echo '[SUCCESS] SELinux configuration is updated.'

    root_home="$(getent passwd root | cut -d: -f6)"
    [[ -n "$root_home" && -d "$root_home" ]] || {
        echo '[ALERT] Root home directory is unavailable.' >&2
        exit 1
    }

    touch "$root_home/.bash_profile"
    sed -i \
        '/^# BEGIN NBU PATH$/,/^# END NBU PATH$/d' \
        "$root_home/.bash_profile"

    cat >> "$root_home/.bash_profile" <<'EOF'
# BEGIN NBU PATH
NBU_BIN_PATH="/usr/openv/netbackup/bin/goodies:/usr/openv/netbackup/bin/admincmd:/usr/openv/volmgr/bin:/usr/openv/netbackup/bin:/usr/openv/db/bin:/usr/openv/netbackup/bin/support:/usr/openv/netbackup/bin/goodies/support:/opt/VRTSpbx/bin:/opt/VRTS/bin"
case ":${PATH:-}:" in
    *":$NBU_BIN_PATH:"*) ;;
    *) PATH="${PATH:+$PATH:}$NBU_BIN_PATH" ;;
esac
export PATH
# END NBU PATH
EOF

    echo '[SUCCESS] Root NetBackup PATH is configured.'

    if [[ -L /tmp/NBInstallAnswer.conf ||
          -e /tmp/NBInstallAnswer.conf && ! -f /tmp/NBInstallAnswer.conf ]]; then
        echo '[ALERT] Answer-file destination must be a regular file, not a symbolic link.' >&2
        exit 1
    fi

    umask 077
    cat > /tmp/NBInstallAnswer.conf <<EOF
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

    chmod 0600 /tmp/NBInstallAnswer.conf
    echo '[SUCCESS] Answer file: /tmp/NBInstallAnswer.conf'

    if [[ "$(getenforce)" != Disabled ]]; then
        echo '[ALERT] Reboot is required to fully disable SELinux.' >&2
    fi

    echo '[SUCCESS] NBU preinstallation completed.'
}

# Prevent commands from consuming the downloaded script.
main "$@" </dev/null
