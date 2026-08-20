#!/bin/bash

HOME_DIR="${HOME:-$(cd && pwd -P)}"
SYNC_DIR="${NOTEBOOKLM_SYNC_DIR:-${HOME_DIR}/.local/state/notebooklm-sync}"
"$SYNC_DIR/sync_all.sh"
echo ""
echo "NotebookLM ingest finished. You can close this window."
