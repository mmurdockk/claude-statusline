#!/bin/sh
# Wire clawdline into Claude Code: the status line, plus the six hooks that
# tell it what the current turn is doing. Everything runs from this checkout,
# so `git pull` is the whole update story.
#
#   ./install.sh               install, or repair; safe to run again
#   ./install.sh --plugin      status line only, for the clawdline plugin, which
#                              ships the hooks itself (run by /clawdline:setup)
#   ./install.sh --uninstall   take out everything this script put in
#
# settings.json is backed up next to itself before every change.
#
# Piped in rather than run from a checkout (curl ... | sh),
# it first clones the repo into ~/.claude/clawdline (or pulls it), then runs
# itself from there. CLAWDLINE_DIR and CLAWDLINE_REPO override the defaults.
set -eu

CONF="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CONF/settings.json"

say()  { printf '\033[38;2;121;192;255m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[38;2;86;211;100m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[38;2;226;170;60m!\033[0m %s\n' "$*"; }
die()  { printf '\033[38;2;248;81;73m✗\033[0m %s\n' "$*" >&2; exit 1; }

DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P) || DIR=""
if [ ! -f "$DIR/statusline.sh" ]; then
  command -v git >/dev/null 2>&1 || die "git is required"
  dest=${CLAWDLINE_DIR:-$CONF/clawdline}
  if [ -d "$dest/.git" ]; then
    say "updating $dest"
    git -C "$dest" pull -q --ff-only || die "could not update $dest"
  else
    say "cloning into $dest"
    git clone -q "${CLAWDLINE_REPO:-https://github.com/mmurdockk/clawdline.git}" "$dest" \
      || die "could not clone the repo (network? git credentials?)"
  fi
  exec /bin/sh "$dest/install.sh" "$@"
fi

mode=install
case "${1:-}" in
  ""|--install) ;;
  --plugin) mode=plugin ;;
  --uninstall|uninstall) mode=uninstall ;;
  -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "unknown option: $1 (try --help)" ;;
esac

# ── Prerequisites ─────────────────────────────────────────────────────────────
command -v jq >/dev/null 2>&1 || die "jq is required: brew install jq  (or apt/dnf install jq)"
jq -n 'now | strflocaltime("%H")' >/dev/null 2>&1 || die "jq is too old, 1.6 or newer is required"
case $DIR in *"'"*) die "the checkout path must not contain a single quote: $DIR" ;; esac

# dash starts in a third of the time bash does, and this runs every second.
SH=/bin/sh; [ -x /bin/dash ] && SH=/bin/dash

mkdir -p "$CONF"
[ -f "$SETTINGS" ] || printf '{}\n' > "$SETTINGS"
jq empty "$SETTINGS" 2>/dev/null || die "$SETTINGS is not valid JSON, fix it first"

backup="$SETTINGS.bak-$(date +%Y%m%d-%H%M%S)"
cp "$SETTINGS" "$backup"

# Any hook entry that calls statusline-turn.sh is ours, wherever it lives: that
# also clears out an older copy, so the hooks never fire twice.
STRIP='
  def strip: map(.hooks |= map(select((.command // "") | contains("statusline-turn.sh") | not)))
             | map(select(.hooks | length > 0));
  def clean: if .hooks then
               .hooks |= (with_entries(.value |= strip) | with_entries(select(.value | length > 0)))
               | (if .hooks == {} then del(.hooks) else . end)
             else . end;
'

tmp="$SETTINGS.tmp.$$"
trap 'rm -f "$tmp"' EXIT

# The plugin lives in a directory per version, so its status line goes through
# a symlink that the plugin's SessionStart hook keeps aimed at the current one.
LINKDIR="$CONF/plugins/clawdline"
SL="$DIR/statusline.sh"
if [ "$mode" = plugin ]; then
  mkdir -p "$LINKDIR" && ln -sfn "$DIR" "$LINKDIR/current"
  SL="$LINKDIR/current/statusline.sh"
  case $SL in *"'"*) die "the config path must not contain a single quote: $SL" ;; esac
fi

if [ "$mode" = uninstall ]; then
  jq "$STRIP"'
    clean
    | if ((.statusLine.command // "") | contains("statusline.sh")) then del(.statusLine) else . end
  ' "$SETTINGS" > "$tmp"
  mv "$tmp" "$SETTINGS"
  if [ -L "$LINKDIR/current" ]; then rm -f "$LINKDIR/current"; rmdir "$LINKDIR" 2>/dev/null || :; fi
  ok "status line and hooks removed from $SETTINGS"
  say "backup of the previous file: $backup"
  say "restart Claude Code (or open a new session) to see the change"
  exit 0
fi

prev=$(jq -r '.statusLine.command // ""' "$SETTINGS")
case $prev in
  ""|*statusline.sh*) ;;
  *) warn "replacing your current status line: $prev" ;;
esac

# In plugin mode the hooks come with the plugin: this only clears out the ones
# an earlier script install left in settings.json, so nothing fires twice.
addhooks=true; [ "$mode" = plugin ] && addhooks=false
jq --arg sl "$SH '$SL'" --argjson addhooks "$addhooks" \
   --arg turn "$SH '$DIR/statusline-turn.sh'" "$STRIP"'
  def hook($ev; $state; $tools):
    if $addhooks | not then . else
    .hooks[$ev] = ((.hooks[$ev] // [])
      + [ (if $tools then {matcher: "*"} else {} end)
          + {hooks: [{type: "command", command: "\($turn) \($state)", timeout: 5}]} ]) end;
  clean
  | .statusLine = ((.statusLine // {}) + {type: "command", command: $sl, refreshInterval: 1})
  | if $addhooks then .hooks //= {} else . end
  | hook("UserPromptSubmit";   "think"; false)
  | hook("PreToolUse";         "tool";  true)
  | hook("PostToolUse";        "think"; true)
  | hook("PostToolUseFailure"; "think"; true)
  | hook("Stop";               "idle";  false)
  | hook("StopFailure";        "idle";  false)
' "$SETTINGS" > "$tmp"
mv "$tmp" "$SETTINGS"

ok "status line installed in $SETTINGS"
say "backup of the previous file: $backup"

# ── Nice-to-haves, checked rather than required ───────────────────────────────
command -v git  >/dev/null 2>&1 || warn "git not found: the branch segment will stay empty"
command -v gh >/dev/null 2>&1 || command -v glab >/dev/null 2>&1 \
  || say "optional: install gh (GitHub) and/or glab (GitLab) to see the CI status of your PRs / MRs"

printf '\n'
say "here is what it looks like with sample data:"
printf '\n'
"$SH" "$DIR/tools/demo.sh" || warn "the demo render failed, the status line itself may still work"
printf '\n'
say "icons look like boxes or question marks? Install a Nerd Font (see README) or"
say "add  \"env\": { \"SL_NERD\": \"0\" }  to $SETTINGS"
if [ "$mode" = plugin ]; then
  say "it shows up within a second or two in this session"
else
  say "open a new Claude Code session to see it live"
fi
