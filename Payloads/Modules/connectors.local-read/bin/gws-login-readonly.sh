#!/usr/bin/env bash
set -euo pipefail

CLIENT_CONFIG="${GWS_CLIENT_SECRET_FILE:-$HOME/.config/gws/oauth-client-config}"

if [[ ! -f "$CLIENT_CONFIG" ]]; then
  echo "Missing: $CLIENT_CONFIG" >&2
  echo "Download the Desktop OAuth client JSON from Google Cloud Console and save it there." >&2
  exit 1
fi

exec gws auth login --readonly --services gmail,drive,docs,sheets,calendar,keep,people,tasks
