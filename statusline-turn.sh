#!/bin/sh
# Hook half of the status line's activity signal.
#
# total_api_duration_ms only moves when a request COMPLETES, so a long think,
# which is one long request, looks exactly like an idle session: the mascot
# dozed off while the model was working hardest. The hooks know better. They
# record where the turn is, per session, for statusline.sh to read:
#
#   think  UserPromptSubmit, PostToolUse, PostToolUseFailure
#   tool   PreToolUse (with the tool's name)
#   idle   Stop, StopFailure
#
# Esc fires no hook at all; the status line drops a turn that has been silent
# for ten minutes. Subagent tool calls are ignored: they would flip the main
# thread's state behind its back, and a background agent would leave it at
# "think" long after Stop.
#
# Runs before and after every tool call, so builtins only, bar one date.

state=$1
j=""
while IFS= read -r l || [ -n "$l" ]; do j="$j$l"; done

case $j in *'"agent_id"'*) exit 0 ;; esac

# $1 key; sets v to its string value, or empty. Tolerates a space after the colon.
field() {
  v=${j#*\"$1\"}
  [ "$v" = "$j" ] && { v=""; return; }
  v=${v#:}; v=${v# }; v=${v#\"}; v=${v%%\"*}
}

field session_id; sid=$v
case $sid in ''|*[!0-9a-f-]*) exit 0 ;; esac

tool=""
if [ "$state" = tool ]; then
  field tool_name; tool=${v##*__}    # mcp__gitlab__get_issue -> get_issue
  case $tool in *[!A-Za-z0-9_.:-]*) tool="" ;; esac
fi

printf '%s %s %s\n' "$state" "$(date +%s)" "$tool" \
  > "${TMPDIR:-/tmp}/statusline-turn-$sid" 2>/dev/null
exit 0
