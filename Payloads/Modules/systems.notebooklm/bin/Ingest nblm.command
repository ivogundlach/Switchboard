#!/bin/bash
set -euo pipefail

NAME="notebooklm-ingest"
VERSION="1.0.0"
CODE_DIR="${NOTEBOOKLM_CODE_DIR:-$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)}"

usage() {
    cat <<'EOF'
Usage: Ingest nblm.command [--help|--version|--self-test] [sync options]

Run the bundled NotebookLM sync wrapper. State and logs stay in
NOTEBOOKLM_SYNC_DIR; bundled code is always loaded beside this script.
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
    /bin/bash -n "${CODE_DIR}/sync_all.sh"
    printf 'NotebookLM ingest self-test passed\n'
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

"${CODE_DIR}/sync_all.sh" "$@"
echo ""
echo "NotebookLM ingest finished. You can close this window."
