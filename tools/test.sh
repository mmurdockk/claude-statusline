#!/bin/sh
# The test suite, for CI and for you: tools/test.sh
#
# Syntax and shellcheck, a render of every demo state and toggle, the turn
# hook, and install / reinstall / uninstall against a scratch config. Nothing
# outside a temp directory is touched. Exits non-zero on the first failure
# report, after running everything.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
SH=/bin/sh; [ -x /bin/dash ] && SH=/bin/dash
E=$(printf '\033')
fails=0
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
ko()   { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fails=$((fails + 1)); }
skip() { printf '  \033[33mskip\033[0m  %s\n' "$*"; }
plain() { sed "s/$E\[[0-9;]*m//g"; }
has()  { case $1 in *"$2"*) return 0 ;; esac; return 1; }

tmp=$(mktemp -d "${TMPDIR:-/tmp}/claude-statusline-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
SCRIPTS="statusline.sh statusline-turn.sh install.sh tools/demo.sh tools/test.sh"

echo "syntax"
for f in $SCRIPTS; do
  if "$SH" -n "$ROOT/$f"; then ok "$f"; else ko "$f"; fi
done
if jq -n --arg home x --arg pathmode short --arg track 1,2,3 -f "$ROOT/statusline.jq" \
     2>&1 | grep -q 'compile error'; then ko "statusline.jq"; else ok "statusline.jq"; fi

echo "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  # shellcheck disable=SC2086
  if (cd "$ROOT" && shellcheck -s sh -S warning $SCRIPTS); then ok "no warnings"; else ko "warnings above"; fi
else
  skip "shellcheck not installed"
fi

echo "renders"
render() {  # $1 label  $2 state  $3... strings the plain output must contain
  _l=$1; _s=$2; shift 2
  _o=$("$SH" "$ROOT/tools/demo.sh" "$_s" 2>"$tmp/err") || { ko "$_l: demo exited non-zero: $(cat "$tmp/err")"; return; }
  [ -s "$tmp/err" ] && { ko "$_l: stderr: $(cat "$tmp/err")"; return; }
  _n=$(printf '%s\n' "$_o" | wc -l | tr -d ' ')
  [ "$_n" = 3 ] || { ko "$_l: expected 3 lines, got $_n"; return; }
  _p=$(printf '%s\n' "$_o" | plain)
  for _want in "$@"; do
    has "$_p" "$_want" || { ko "$_l: missing \"$_want\""; return; }
  done
  ok "$_l"
}
render "tool"   tool   feat/statusline "#42" approved Bash "46%" "107k free" "38%" "44%" jane.doe "Refactor the auth flow"
render "think"  think  "#42" "Opus 5.5"
render "idle"   idle   "#42" "4.82"
render "asleep" asleep "z"
render "party"  party  "3s" "✦"
SL_NERD=0      render "SL_NERD=0"      tool "gh feat/statusline" "PR #42"
SL_POWERLINE=0 render "SL_POWERLINE=0" tool "│"
SL_PATH=full   render "SL_PATH=full"   tool "dev/github.com/my-org/my-app"
_o=$(SL_MASCOT=0 "$SH" "$ROOT/tools/demo.sh" tool | plain)
if has "$_o" "▛"; then ko "SL_MASCOT=0: sprite still drawn"; else ok "SL_MASCOT=0"; fi
_o=$(SL_ACCOUNT=0 "$SH" "$ROOT/tools/demo.sh" tool | plain)
if has "$_o" "jane.doe"; then ko "SL_ACCOUNT=0: account still shown"; else ok "SL_ACCOUNT=0 hides the account"; fi
_o=$(printf '' | "$SH" "$ROOT/statusline.sh")
if [ -z "$_o" ]; then ok "empty payload prints nothing"; else ko "empty payload printed: $_o"; fi

echo "turn hook"
mkdir -p "$tmp/turn"
printf '{"session_id":"abc-123","tool_name":"mcp__gitlab__get_issue"}' \
  | TMPDIR="$tmp/turn" "$SH" "$ROOT/statusline-turn.sh" tool
read -r st _ tool < "$tmp/turn/statusline-turn-abc-123" 2>/dev/null || st=""
if [ "$st $tool" = "tool get_issue" ]; then ok "records the tool, MCP prefix stripped"; else ko "got: $st $tool"; fi
printf '{"session_id":"abc-123","agent_id":"x"}' | TMPDIR="$tmp/turn" "$SH" "$ROOT/statusline-turn.sh" idle
read -r st _ < "$tmp/turn/statusline-turn-abc-123"
if [ "$st" = tool ]; then ok "ignores sub-agent events"; else ko "sub-agent event overwrote the state: $st"; fi
printf '{"session_id":"../../etc"}' | TMPDIR="$tmp/turn" "$SH" "$ROOT/statusline-turn.sh" idle
if [ -z "$(find "$tmp" -name 'statusline-turn-..*')" ]; then ok "rejects a hostile session id"; else ko "wrote a file for a hostile session id"; fi

echo "installer"
conf="$tmp/conf"; mkdir -p "$conf"
printf '%s\n' '{"model":"opus","statusLine":{"type":"command","command":"old","hideVimModeIndicator":true},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}' \
  > "$conf/settings.json"
CLAUDE_CONFIG_DIR="$conf" "$SH" "$ROOT/install.sh" >/dev/null 2>&1 || ko "install exited non-zero"
s=$(cat "$conf/settings.json")
check() {  # $1 label  $2 jq filter that must be true
  if printf '%s' "$s" | jq -e "$2" >/dev/null 2>&1; then ok "$1"; else ko "$1"; fi
}
check "status line points at this checkout" ".statusLine.command | endswith(\"$ROOT/statusline.sh'\")"
check "keeps the other statusLine keys"     '.statusLine.hideVimModeIndicator == true and .statusLine.refreshInterval == 1'
check "keeps unrelated settings"            '.model == "opus"'
check "adds the six hooks"                  '[.hooks[][] | .hooks[].command | select(contains("statusline-turn.sh"))] | length == 6'
check "keeps unrelated hooks"               '[.hooks.Stop[].hooks[].command] | index("say done") != null'
cp "$conf/settings.json" "$tmp/first.json"
CLAUDE_CONFIG_DIR="$conf" "$SH" "$ROOT/install.sh" >/dev/null 2>&1
if [ "$(jq -S . "$tmp/first.json")" = "$(jq -S . "$conf/settings.json")" ]; then ok "reinstall changes nothing"; else ko "reinstall changed settings.json"; fi
CLAUDE_CONFIG_DIR="$conf" "$SH" "$ROOT/install.sh" --uninstall >/dev/null 2>&1 || ko "uninstall exited non-zero"
s=$(cat "$conf/settings.json")
check "uninstall removes the status line"   '.statusLine == null'
check "uninstall removes only its hooks"    '(.hooks | keys) == ["Stop"] and ([.hooks.Stop[].hooks[].command] == ["say done"])'
check "uninstall keeps unrelated settings"  '.model == "opus"'
if [ "$(find "$conf" -name 'settings.json.bak-*' | wc -l | tr -d ' ')" -ge 1 ]; then ok "backs settings.json up"; else ko "no backup written"; fi

echo
if [ "$fails" -eq 0 ]; then echo "all good"; else echo "$fails failure(s)"; exit 1; fi
