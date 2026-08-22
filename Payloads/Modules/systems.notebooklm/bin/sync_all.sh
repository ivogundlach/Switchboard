#!/bin/bash
set -u

NAME="notebooklm-sync"
VERSION="1.0.0"
CODE_DIR="${NOTEBOOKLM_CODE_DIR:-$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)}"

usage() {
    cat <<'EOF'
Usage: sync_all.sh [--help|--version|--self-test] [sync options]

Synchronize NotebookLM into local files. State and logs stay in
NOTEBOOKLM_SYNC_DIR; the sync program is loaded from this bundled directory.
EOF
}

self_test() {
    local required
    for required in sync_all.sh notebooklm_sync.py; do
        [ -f "${CODE_DIR}/${required}" ] || {
            printf 'missing bundled file: %s\n' "${CODE_DIR}/${required}" >&2
            return 1
        }
    done
    if ! /bin/bash -n "${CODE_DIR}/sync_all.sh"; then
        return 1
    fi
    if ! /usr/bin/python3 - "${CODE_DIR}/notebooklm_sync.py" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
compile(path.read_text(), str(path), "exec")
PY
    then
        return 1
    fi
    printf 'NotebookLM sync self-test passed\n'
}

case "${1:-}" in
    --help|-h)
        usage
        exit 0
        ;;
    --version|-V)
        printf '%s %s\n' "$NAME" "$VERSION"
        exit 0
        ;;
    --self-test)
        self_test
        exit $?
        ;;
esac

NOTEBOOKLM_SYNC_ARGS=("$@")

if [[ "${NOTEBOOKLM_POWER_SOURCE:-}" == "battery" ]] ||
   { [[ "${NOTEBOOKLM_POWER_SOURCE:-}" != "ac" ]] &&
     ! /usr/bin/pmset -g batt 2>/dev/null | /usr/bin/grep -q "AC Power"; }; then
    exit 0
fi

# Define paths
HOME_DIR="${HOME:-$(cd && pwd -P)}"
NOTES_DIR="${NOTEBOOKLM_NOTES_DIR:-${HOME_DIR}/Files}"
SYNC_DIR="${NOTEBOOKLM_SYNC_DIR:-${HOME_DIR}/.local/state/notebooklm-sync}"
LOG_FILE="$SYNC_DIR/sync_automation.log"
NOTEBOOKLM_BIN="${NOTEBOOKLM_BIN:-$(command -v notebooklm 2>/dev/null || printf '%s' notebooklm)}"

mkdir -p "$SYNC_DIR"

# Add a timestamp to the log
echo "=== Sync Started: $(date) ===" >> "$LOG_FILE"

# Network-validated auth gate. Two traps to avoid:
#   1. Bare `auth check` only proves the cookie file PARSES (it passed even
#      while auth was dead for 9 days in June 2026). `--test` does a real
#      token-fetch.
#   2. In notebooklm-py 0.7.2 `auth check --test` EXITS 0 even when auth is
#      broken — so we must parse the JSON "status" field, not the exit code.
auth_ok() {
    "$NOTEBOOKLM_BIN" auth check --test --json 2>/dev/null \
        | grep -qE '"status"[[:space:]]*:[[:space:]]*"ok"'
}

# Is the Mac actually online and able to reach Google? A failed token-fetch
# says NOTHING about auth when the machine is simply offline: DNS/connection
# errors (e.g. "[Errno 8] nodename nor servname provided") surfaced as false
# "auth expired" alarms on 2026-06-21. We only notify "re-authenticate" when
# the network is UP but auth still fails — a genuine credential problem, not an
# outage. Any HTTP response (even 3xx/4xx) proves reachability, so no -f.
network_up() {
    /usr/bin/curl -sS -o /dev/null --max-time 8 https://notebooklm.google.com >/dev/null 2>&1
}

if ! auth_ok; then
    echo "Auth stale; attempting in-place refresh..." >> "$LOG_FILE"
    "$NOTEBOOKLM_BIN" auth refresh --quiet >> "$LOG_FILE" 2>&1
fi

if auth_ok; then
    echo "Running NotebookLM Sync..." >> "$LOG_FILE"
    if [ "$#" -gt 0 ]; then
        NOTEBOOKLM_BIN="$NOTEBOOKLM_BIN" NOTEBOOKLM_CODE_DIR="$CODE_DIR" /usr/bin/python3 "$CODE_DIR/notebooklm_sync.py" "${NOTEBOOKLM_SYNC_ARGS[@]}" >> "$LOG_FILE" 2>&1
    else
        NOTEBOOKLM_BIN="$NOTEBOOKLM_BIN" NOTEBOOKLM_CODE_DIR="$CODE_DIR" /usr/bin/python3 "$CODE_DIR/notebooklm_sync.py" >> "$LOG_FILE" 2>&1
    fi
elif ! network_up; then
    # Machine is offline — NOT an auth problem. Skip quietly; the next hourly
    # run retries. Deliberately no notification.
    echo "--- Network unavailable; sync SKIPPED (will retry next run). No auth action needed." >> "$LOG_FILE"
else
    # Network is up but auth still fails => genuine credential expiry. Loud +
    # actionable instead of silently looping a doomed sync.
    echo "!!! AUTH EXPIRED — NotebookLM sync SKIPPED. Re-authenticate with: notebooklm login" >> "$LOG_FILE"
    /usr/bin/osascript -e 'display notification "Run: notebooklm login" with title "NotebookLM sync: auth expired"' >/dev/null 2>&1 || true
fi

echo "=== Sync Completed: $(date) ===" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"
