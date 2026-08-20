#!/bin/bash
set -euo pipefail

HOME_DIR="${HOME:-$(cd && pwd -P)}"
SOURCE_DIR="${SMART_WAKE_CODE_DIR:-$(cd "$(dirname "$0")" && pwd -P)}"
HELPER="/Library/PrivilegedHelperTools/com.user.smartwake.sleep-guard"
PLIST="/Library/LaunchDaemons/com.user.smartwake.sleep-guard.plist"
LABEL="com.user.smartwake.sleep-guard"

launchctl_cmd() {
    /bin/launchctl "$@"
}

sleep_cmd() {
    /bin/sleep "$1"
}

install_files() {
    /bin/mkdir -p /Library/PrivilegedHelperTools
    /usr/bin/install -o root -g wheel -m 0755 "${SOURCE_DIR}/sleep-guard-root.sh" "$HELPER"
    /usr/bin/install -o root -g wheel -m 0644 "${SOURCE_DIR}/com.user.smartwake.sleep-guard.plist" "$PLIST"
}

clear_provenance() {
    /usr/bin/xattr -d com.apple.provenance "$HELPER" "$PLIST" 2>/dev/null || true
}

service_registered() {
    launchctl_cmd print "system/$LABEL" >/dev/null 2>&1
}

service_running() {
    launchctl_cmd print "system/$LABEL" 2>/dev/null | /usr/bin/grep -q 'state = running'
}

install_sleep_guard() {
    local attempt=0

    install_files

# Files copied from the user's configuration directory can inherit macOS's
# provenance marker. launchd may reject a system service carrying that marker
# even when its ownership and permissions are otherwise correct.
    clear_provenance

    if service_registered; then
        if ! bootout_error=$(launchctl_cmd bootout "system/$LABEL" 2>&1); then
            printf 'Smart Wake helper removal failed: %s\n' "$bootout_error" >&2
            return 1
        fi
    fi

# bootout completes asynchronously. Wait until launchd has fully removed the
# old registration before bootstrapping the replacement, or bootstrap can
# fail with the misleading error 5 (Input/output error).
    while service_registered && [ "$attempt" -lt 20 ]; do
        sleep_cmd 0.25
        attempt=$((attempt + 1))
    done
    if service_registered; then
        printf 'Smart Wake helper removal did not finish within 5 seconds.\n' >&2
        return 1
    fi
    launchctl_cmd bootstrap system "$PLIST"
    launchctl_cmd kickstart -k "system/$LABEL"

    attempt=0
    while [ "$attempt" -lt 20 ]; do
        if service_running; then
            printf 'Smart Wake closed-lid helper installed.\n'
            return 0
        fi
        sleep_cmd 0.25
        attempt=$((attempt + 1))
    done

    printf 'Smart Wake helper was registered but did not reach the running state.\n' >&2
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    install_sleep_guard
fi
