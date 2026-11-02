---
name: uninstall
description: Remove the clawdline status line from Claude Code's settings, before uninstalling the plugin.
disable-model-invocation: true
allowed-tools: Bash(sh "${CLAUDE_PLUGIN_ROOT}/install.sh" --uninstall*)
---

Remove the clawdline status line for the user. Run exactly this, once:

```bash
sh "${CLAUDE_PLUGIN_ROOT}/install.sh" --uninstall
```

It backs up `settings.json`, removes the `statusLine` entry that points at clawdline (and any hooks an
older script install left there), and deletes the version-independent link. Other settings are kept.

Then tell the user, briefly, whether it worked and where the backup is, and that they can now remove
the plugin itself with `/plugin uninstall clawdline@clawdline`. If the command fails, show its error
output and stop; do not edit `settings.json` by hand.
