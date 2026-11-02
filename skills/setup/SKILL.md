---
name: setup
description: Point Claude Code's status line at clawdline. Run once after installing the plugin, or again to repair it.
disable-model-invocation: true
allowed-tools: Bash(sh "${CLAUDE_PLUGIN_ROOT}/install.sh" --plugin*)
---

Set up the clawdline status line for the user.

A plugin can ship hooks but cannot set `statusLine` itself, so this step writes it into the user's
settings. Run exactly this, once:

```bash
sh "${CLAUDE_PLUGIN_ROOT}/install.sh" --plugin
```

It backs up `settings.json`, points `statusLine` at a version-independent link to this plugin, removes
any hooks a previous non-plugin install left there (the plugin now provides them), and prints a sample
render.

Then tell the user, briefly:

- whether it worked; if it replaced a different status line, say which one and where the backup is;
- that the new status line shows up on the next refresh, within a second or two;
- if the sample render shows boxes or question marks instead of icons, they need a Nerd Font in their
  terminal, or `"env": { "SL_NERD": "0" }` in their settings;
- that `gh` (GitHub) or `glab` (GitLab), installed and logged in, add the CI status of their PR / MR.

If the command fails, show its error output and stop; do not edit `settings.json` by hand.
