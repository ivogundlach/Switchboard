#!/bin/bash
set -u

HOME_DIR="${HOME:-$(cd && pwd -P)}"
STATE_DIR="${SMART_WAKE_STATE_DIR:-${HOME_DIR}/.config/smart-wake/state}"
LEASE_FILE="${STATE_DIR}/sleep-guard-lease"
LID_TRIGGER_GRACE_FILE="${STATE_DIR}/lid-trigger-grace-until"
POLL_SECONDS=1
LID_TRIGGER_GRACE_SECONDS=120
PMSET_FAILURE_LOG_INTERVAL=60
sleep_disabled=unknown
last_pmset_failure_at=0
clamshell_was_closed=false
lid_trigger_grace_until=""

log_guard() {
    /usr/bin/logger -t smart-wake-sleep-guard "$*"
}

apply_sleep_setting() {
    /usr/bin/pmset -a disablesleep "$1" >/dev/null 2>&1
}

read_sleep_setting() {
    local value
    value=$(/usr/bin/pmset -g 2>/dev/null |
        /usr/bin/awk '$1 == "SleepDisabled" { print $2; exit }')
    case "$value" in
        1) printf 'true\n' ;;
        0) printf 'false\n' ;;
        *) return 1 ;;
    esac
}

log_pmset_failure() {
    local desired="$1"
    local now
    now=$(now_epoch)
    if [ "$last_pmset_failure_at" -eq 0 ] ||
        [ "$((now - last_pmset_failure_at))" -ge "$PMSET_FAILURE_LOG_INTERVAL" ]; then
        log_guard "Failed to set closed-lid sleep protection to ${desired}; will retry"
        last_pmset_failure_at="$now"
    fi
}

set_sleep_disabled() {
    local desired="$1"
    local value=0
    local observed=""

    [ "$desired" = true ] && value=1
    observed=$(read_sleep_setting 2>/dev/null || true)
    if [ "$observed" = true ] || [ "$observed" = false ]; then
        sleep_disabled="$observed"
    fi
    [ "$sleep_disabled" = "$desired" ] && return 0

    if apply_sleep_setting "$value" && [ "$(read_sleep_setting 2>/dev/null || true)" = "$desired" ]; then
        sleep_disabled="$desired"
        last_pmset_failure_at=0
        if [ "$desired" = true ]; then
            log_guard "Enabled closed-lid sleep protection"
        else
            log_guard "Disabled closed-lid sleep protection"
        fi
        return 0
    fi

    log_pmset_failure "$desired"
    return 1
}

restore_sleep() {
    local attempt=1
    local restored=false

    while [ "$attempt" -le 3 ]; do
        if apply_sleep_setting 0 && [ "$(read_sleep_setting 2>/dev/null || true)" = false ]; then
            restored=true
            sleep_disabled=false
            break
        fi
        attempt=$((attempt + 1))
        /bin/sleep 0.25
    done
    /bin/rm -f "$LID_TRIGGER_GRACE_FILE"
    if [ "$restored" = true ]; then
        log_guard "Restored normal sleep behavior"
    else
        log_guard "Failed to restore normal sleep behavior after three attempts"
    fi
}

now_epoch() {
    /bin/date +%s
}

clamshell_closed() {
    /usr/sbin/ioreg -r -n IOPMrootDomain -d 1 2>/dev/null |
        /usr/bin/grep -q '"AppleClamshellState" = Yes'
}

write_lid_trigger_grace() {
    local temporary="${LID_TRIGGER_GRACE_FILE}.tmp.$$"
    /bin/mkdir -p "$STATE_DIR"
    /usr/bin/printf '%s\n' "$lid_trigger_grace_until" > "$temporary"
    /bin/mv -f "$temporary" "$LID_TRIGGER_GRACE_FILE"
}

clear_lid_trigger_grace() {
    lid_trigger_grace_until=""
    /bin/rm -f "$LID_TRIGGER_GRACE_FILE"
}

lease_active() {
    local now="$1"
    local lease_until=""

    if [ -f "$LEASE_FILE" ]; then
        # Smart Wake replaces this file atomically. It can disappear between
        # the existence check and the read without representing a failure.
        lease_until=$(/usr/bin/tr -dc '0-9' 2>/dev/null < "$LEASE_FILE" || true)
    fi
    [ -n "$lease_until" ] && [ "$lease_until" -gt "$now" ] 2>/dev/null
}

sleep_guard_cycle() {
    local now="$1"
    local closed=false
    local keep_awake=false

    if clamshell_closed; then
        closed=true
    fi

    if [ "$closed" = true ] && [ "$clamshell_was_closed" = false ]; then
        lid_trigger_grace_until=$((now + LID_TRIGGER_GRACE_SECONDS))
        write_lid_trigger_grace
        log_guard "Started two-minute trigger-discovery grace after lid closure"
    elif [ "$closed" = false ]; then
        clear_lid_trigger_grace
    elif [ -n "$lid_trigger_grace_until" ] &&
        [ "$lid_trigger_grace_until" -le "$now" ] 2>/dev/null; then
        clear_lid_trigger_grace
        log_guard "Trigger-discovery grace expired"
    fi
    clamshell_was_closed="$closed"

    if lease_active "$now"; then
        keep_awake=true
    elif [ "$closed" = true ] && [ -n "$lid_trigger_grace_until" ] &&
        [ "$lid_trigger_grace_until" -gt "$now" ] 2>/dev/null; then
        keep_awake=true
    fi

    set_sleep_disabled "$keep_awake" || true
}

main() {
    trap 'restore_sleep' EXIT
    trap 'exit 0' HUP INT TERM

    # The first cycle always writes the desired state because the in-memory
    # state begins as unknown. Failed writes remain unknown and retry.
    /bin/rm -f "$LID_TRIGGER_GRACE_FILE"

    while true; do
        sleep_guard_cycle "$(now_epoch)"
        /bin/sleep "$POLL_SECONDS"
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
