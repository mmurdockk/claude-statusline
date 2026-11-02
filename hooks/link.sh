#!/bin/sh
# SessionStart hook. A plugin cannot set the statusLine itself, and each version
# is installed in its own directory (plugins/cache/<marketplace>/<plugin>/<v>),
# so the statusLine written by /clawdline:setup points at a symlink
# instead, which this hook re-aims at the running version. Updates then just
# work. Silent on purpose: a SessionStart hook's stdout lands in the context.
[ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/statusline.sh" ] || exit 0
d="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/clawdline"
[ "$(readlink "$d/current" 2>/dev/null)" = "$CLAUDE_PLUGIN_ROOT" ] && exit 0
mkdir -p "$d" && ln -sfn "$CLAUDE_PLUGIN_ROOT" "$d/current"
exit 0
