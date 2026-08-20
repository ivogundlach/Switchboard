#!/bin/zsh
set -euo pipefail
resource_dir=${0:A:h}
module_bin="$resource_dir/../../../../Modules/mail.assistant/bin"
export PATH="$module_bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
exec "$module_bin/apple-mail-draft-runner" "$@"
