#!/bin/zsh
set -euo pipefail
resource_dir=${0:A:h}
module_bin="$resource_dir/../../../../Modules/mail.assistant/bin"
export PATH="$module_bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
if [[ "${1:-}" == "--permission-status" ]]; then
  mail_root="$HOME/Library/Mail"
  if [[ ! -d "$mail_root" ]]; then
    print '{"mailDataReadable":false,"reason":"mail-not-configured"}'
    exit 2
  fi
  error_file=$(/usr/bin/mktemp -t switchboard-mail-permission)
  trap '/bin/rm -f "$error_file"' EXIT
  index_file=$(/usr/bin/find "$mail_root" -type f -name 'Envelope Index' -print -quit 2>"$error_file" || true)
  if /usr/bin/grep -Eiq 'operation not permitted|permission denied' "$error_file"; then
    print '{"mailDataReadable":false,"reason":"permission-denied"}'
    exit 1
  fi
  if [[ -z "$index_file" ]]; then
    print '{"mailDataReadable":false,"reason":"mail-index-not-found"}'
    exit 2
  fi
  if /usr/bin/python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).open("rb").read(1)' "$index_file" 2>"$error_file"; then
    print '{"mailDataReadable":true}'
    exit 0
  fi
  if /usr/bin/grep -Eiq 'operation not permitted|permission denied|PermissionError' "$error_file"; then
    print '{"mailDataReadable":false,"reason":"permission-denied"}'
    exit 1
  fi
  print '{"mailDataReadable":false,"reason":"mail-read-failed"}'
  exit 2
fi
exec "$module_bin/apple-mail-draft-runner" "$@"
