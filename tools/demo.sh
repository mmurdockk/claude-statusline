#!/bin/sh
# Render the status line once, with made-up data, in a throwaway sandbox: a
# fake $HOME, a small git repo with a dirty tree, an open pull request and a
# canned CI answer. Nothing outside a temp directory is read or written.
#
#   tools/demo.sh [STATE]     what Clawd is up to (default: tool)
#
#   tool    a tool is running: Clawd walks
#   think   the model is thinking: Clawd ponders
#   idle    nothing to do: Clawd stands, and blinks now and then
#   asleep  idle for a while: Clawd dozes off
#   party   a commit just landed: Clawd dances
#
# Used by install.sh as a smoke test, by tools/test.sh, and to produce the
# images in docs/.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
SH=/bin/sh; [ -x /bin/dash ] && SH=/bin/dash
turn=${1:-tool}

# Version-manager shims (mise, asdf) look their config up under $HOME, which is
# about to be fake: put the real binaries' directories first while it is not.
for b in jq git; do
  p=$(mise which "$b" 2>/dev/null || command -v "$b") && PATH="${p%/*}:$PATH"
done
export PATH

box=$(mktemp -d "${TMPDIR:-/tmp}/clawdline-demo.XXXXXX")
trap 'rm -rf "$box"' EXIT
export HOME="$box/home" TMPDIR="$box/tmp"
mkdir -p "$HOME/.claude" "$TMPDIR"

now=$(date +%s)
sid=00000000-0000-4000-8000-000000000042
branch=feat/statusline
repo="$HOME/dev/github.com/my-org/my-app"

# The signed-in account and a pending Claude Code upgrade.
printf '%s\n' '{"oauthAccount":{"emailAddress":"jane.doe@example.com","userRateLimitTier":"default_claude_max_5x","organizationType":"claude_enterprise"}}' \
  > "$HOME/.claude.json"
printf '%s\n' '{"version_to":"2.1.320"}' > "$HOME/.claude/.last-update-result.json"

# A repo with a commit from two hours ago (a few seconds, for the party), then
# a bit of everything.
ago=7200; [ "$turn" = party ] && ago=3
mkdir -p "$repo"
(
  cd "$repo"
  g() { git -c user.name=demo -c user.email=demo@example.com -c init.defaultBranch=main "$@"; }
  g init -q
  printf 'a\n' > app.py; printf 'b\n' > auth.py; printf 'c\n' > README.md
  g add . && GIT_COMMITTER_DATE="@$((now - ago))" g commit -q -m init --date "@$((now - ago))"
  g checkout -q -b "$branch"
  printf 'x\n' >> app.py; g add app.py
  printf 'y\n' >> auth.py; printf 'z\n' >> README.md
  : > notes.md
)

# What the hooks and the background CI refresh would have left behind.
case $turn in
  tool)   printf 'tool %s Bash\n' $((now - 14)) ;;
  think)  printf 'think %s\n'     $((now - 8)) ;;
  asleep) printf 'idle %s\n'      $((now - 60)) ;;
  *)      printf 'idle %s\n'      $((now - 5)) ;;
esac > "$TMPDIR/statusline-turn-$sid"
# Asleep means no API activity for a while either: the last change of the API
# time (the payload's 1510000 ms) was a minute ago.
[ "$turn" = asleep ] && printf '1510000 %s\n' $((now - 60)) > "$TMPDIR/statusline-mascot-$sid"
printf '%s %s ok 42 running\n' "$now" "$branch" > "$TMPDIR/statusline-forge-$sid"
printf '%s\n' "$now" > "$TMPDIR/statusline-forge-$sid.lock"

payload=$(jq -nc --arg cwd "$repo" --arg sid "$sid" --argjson now "$now" '{
  session_id: $sid, cwd: $cwd, session_name: "Refactor the auth flow",
  model: {id: "claude-opus-5-5", display_name: "Opus 5.5"},
  workspace: {current_dir: $cwd, project_dir: $cwd, added_dirs: [],
             repo: {host: "github.com", owner: "my-org", name: "my-app"}},
  pr: {number: 42, url: "https://github.com/my-org/my-app/pull/42", review_state: "approved"},
  version: "2.1.318", output_style: {name: "default"},
  cost: {total_cost_usd: 4.82, total_duration_ms: 4380000, total_api_duration_ms: 1510000,
         total_lines_added: 342, total_lines_removed: 87},
  context_window: {context_window_size: 200000,
                   current_usage: {input_tokens: 2, cache_creation_input_tokens: 1800,
                                   cache_read_input_tokens: 90200}},
  fast_mode: false, effort: {level: "high"}, thinking: {enabled: true},
  rate_limits: {five_hour: {used_percentage: 38, resets_at: ($now + 7500)},
                seven_day: {used_percentage: 44, resets_at: ($now + 190000)}}
}')

cd "$repo"
printf '%s' "$payload" | "$SH" "$ROOT/statusline.sh"
