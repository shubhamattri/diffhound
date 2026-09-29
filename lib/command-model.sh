#!/bin/bash
# The same funded API backend as reviews; never the personal Claude CLI.
set -euo pipefail
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
unset CLAUDE_CODE_OAUTH_TOKEN CLAUDECODE
source "$LIB_DIR/platform.sh"
source "$LIB_DIR/parser.sh"
source "$LIB_DIR/cost.sh"
source "$LIB_DIR/api.sh"
command_dir=$(mktemp -d -t dh-command-model.XXXXXX)
trap 'rm -rf "$command_dir"' EXIT
cat > "$command_dir/input"
jq -er .system "$command_dir/input" > "$command_dir/system"
jq -er .context "$command_dir/input" > "$command_dir/context"
DIFFHOUND_STAGE=command DIFFHOUND_STOP_REASON_FILE="$command_dir/stop" \
  _call_api_system "${DIFFHOUND_COMMAND_MODEL:-claude-sonnet-5}" 8192 180 "$command_dir/system" \
  < "$command_dir/context" > "$command_dir/output"
[ "$(cat "$command_dir/stop")" != max_tokens ] || exit 1
cat "$command_dir/output"
