#!/bin/bash

HOME_DIR="${HOME:-$(cd && pwd -P)}"
SYNC_DIR="${NOTEBOOKLM_SYNC_DIR:-${HOME_DIR}/.local/state/notebooklm-sync}"
exec "$SYNC_DIR/sync_all.sh"
