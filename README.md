# claude-statusline

A three-line status bar for [Claude Code](https://docs.claude.com/en/docs/claude-code) that answers,
at a glance: **where am I, what is Claude doing, and how much do I have left?**
It also knows about your pull request: the open **GitHub PR or GitLab MR** for your branch, its review state
and its **live CI status**, right next to the model.
And it has Clawd, the Claude Code mascot, walking, thinking, dozing off and partying next to it.

![claude-statusline: Clawd idle, thinking, running a tool, celebrating a commit and dozing off](docs/clawd.gif)

## Install in 30 seconds

```bash
curl -fsSL https://raw.githubusercontent.com/mmurdockk/claude-statusline/main/install.sh | sh
```

**Or with plain git**, if you'd rather read the script before running it:

```bash
git clone https://github.com/mmurdockk/claude-statusline.git ~/.claude/claude-statusline && ~/.claude/claude-statusline/install.sh
```

Then open a new Claude Code session. That's it.

Both commands end up in the same place. The script clones the repo into `~/.claude/claude-statusline`, adds the status line and
five small hooks to `~/.claude/settings.json` (backing that file up first), checks your prerequisites and prints a
sample render so you can check your font right away. You can run it again whenever you like, because it never adds anything twice.

> **Even lazier:** paste this into Claude Code:
> *"Clone https://github.com/mmurdockk/claude-statusline.git into ~/.claude/claude-statusline and run its install.sh"*

### Prerequisites

| What | Why | How |
|---|---|---|
| macOS, Linux or WSL | it's a POSIX shell script | Windows Git Bash should work too, but nobody has tested it |
| `jq` ≥ 1.6 | does all the parsing and maths in one pass | `brew install jq` / `apt install jq` |
| `git` | branch and working-tree segment | you have it |
| A [Nerd Font](https://www.nerdfonts.com/) in your terminal | icons and powerline arrows | `brew install --cask font-hack-nerd-font`, then pick *Hack Nerd Font Mono* in your terminal settings |
| `gh` and/or `glab` *(optional)* | CI status of your GitHub PR / GitLab MR | `brew install gh && gh auth login`, `brew install glab && glab auth login` |

No Nerd Font? Set `SL_NERD=0` (see [Configuration](#configuration)) to get a plain-ASCII version.

### Update / uninstall

```bash
git -C ~/.claude/claude-statusline pull            # update: the scripts run straight from the clone
~/.claude/claude-statusline/install.sh --uninstall # removes the status line and hooks, keeps your other settings
```

## What you're looking at

![claude-statusline, full size](docs/screenshot.png)

**Line 1: where and what**

| Segment | Shows |
|---|---|
| 📁 directory | current dir, parents abbreviated fish-style (`~/d/g/my-squad/my-app`), `+N` if you added dirs |
| 🌿 git | branch, age of the last commit, `+staged ±modified ?untracked`, conflicts, stash, `↑ahead ↓behind`, `✓` when clean. The segment turns **violet** when clean, **amber** when dirty and **red** during a conflict |
| 🤖 model | model name (it shimmers while Claude is working), `1M` context, `fast` mode, effort level, `think×` when thinking is off |
| ⚙️ activity | only shown during a turn: the spinner while Claude thinks, or the tool currently running (`Bash 14s`) |
| 🔀 extras | GitHub PR `#42` or GitLab MR `!42`, with its CI status (`✓ ✗ ◐ ◌ ▶ ⊘`) and review state (`approved`, `changes`, `draft`); sub-agent, output style, vim mode |

**Line 2: this session**: signed-in account and plan, wall-clock time vs. time spent waiting on the API, lines
added/removed (with a little ratio bar), Claude Code version (with `→ x.y.z ready` when an update is waiting) and the session name.

**Line 3: how much is left**

- **ctx**: context window used, as a gauge plus how many tokens are still free. A cache hit ratio appears only when it drops below 80 %,
  which usually means something keeps busting the prompt cache.
- **5h / 7d**: your rate-limit windows, with **pace**: `▲12` (red) means you are burning the quota 12 points faster
  than the window refills, `▼20` (green) means you're coasting, `▬` means you're on budget. Then the reset time.
- **$**: API-price equivalent of the session and the hourly burn rate. On a subscription it isn't a bill.

Every gauge turns red as it fills, and any figure at 90 % or above blinks.

### Clawd

| Clawd is… | when |
|---|---|
| walking 🚶 | a tool is running |
| hand on chin, blinking 🤔 | the model is thinking |
| standing, blinking now and then | idle |
| asleep, `z` drifting off 💤 | idle for more than 25 s |
| dancing, with sparkles ✨ | you committed less than 15 s ago |
| sweating 💦 | any gauge is above 80 % |

His colour is the bar's single warning light: terracotta while everything is fine, amber once any gauge passes 50 %, and red past 80 %.

## Configuration

Everything is optional. Set these in `~/.claude/settings.json` under `env` (or export them from your shell profile):

```json
{
  "env": { "SL_NERD": "0", "SL_ACCOUNT": "org" }
}
```

| Variable | Default | Effect |
|---|---|---|
| `SL_NERD` | `1` | `0` = ASCII fallback, for terminals without a Nerd Font |
| `SL_POWERLINE` | `1` | `0` = thin `│` dividers instead of filled arrow segments |
| `SL_MASCOT` | `1` | `0` = no Clawd |
| `SL_PATH` | `short` | `full` = don't abbreviate parent directories |
| `SL_ACCOUNT` | `1` | `0` = hide the account, `org` = also show the organisation |
| `SL_FORGE` | `1` | `0` = no CI lookup through `gh` / `glab`. The PR/MR number still shows, since Claude Code provides it |
| `SL_TRACK` | `54,61,72` | RGB of the empty part of the gauges. It's tuned for a dark terminal, so pick something darker than your background on a light theme |

If you use vim mode, the bar already shows it, so you can hide Claude Code's own indicator by adding
`"hideVimModeIndicator": true` inside the `statusLine` block of your settings. The installer keeps that setting.

## How it works

```
Claude Code ──JSON on stdin, every second──▶ statusline.sh ──▶ 3 lines of ANSI
     │                                           ▲
     └─ hooks ─▶ statusline-turn.sh ─▶ $TMPDIR/statusline-turn-<session>
        (prompt, pre/post tool, stop)            "think | tool Bash | idle"
```

- **`statusline.sh`** is the renderer. It runs every second, so it is built to be cheap. It starts `git status` in the
  background while a **single** `jq` pass (`statusline.jq`) parses the payload and does all the maths, and everything else is
  shell builtins. That works out to two overlapped processes per render. The age of HEAD is cached against the commit OID,
  and the account against a 12-hour stamp.
- **`statusline-turn.sh`** is the hook half. On its own, the payload can't tell a long think from an idle session,
  so the hooks write down where the turn is (thinking, which tool is running, done). Sub-agent tool calls are ignored.
- **PRs, MRs and CI.** Claude Code already sends the open PR (GitHub) or MR (GitLab) for your branch, with its review
  state and the `origin` host, so the number costs nothing. CI status is the one thing it doesn't know: a detached background
  job asks `gh` (checks of the open PR, or the branch's latest workflow run) or `glab` (the MR's head pipeline, or the
  branch's latest pipeline), at most once a minute, and the render only ever reads the cached result. The CLI is picked
  from the `origin` host, and skipped if it isn't installed. If your token has expired, you'll see `gh auth` / `glab auth` in amber.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Boxes / `?` instead of icons | Your terminal isn't using a Nerd Font. Install one and select it, or set `SL_NERD=0` |
| Nothing shows at all | Run `~/.claude/claude-statusline/tools/demo.sh`. If that works, check `statusLine` in `~/.claude/settings.json` and restart Claude Code |
| `jq: error` / blank line | `jq --version` must be ≥ 1.6. With mise or asdf, make sure a real `jq` is installed (e.g. `brew install jq`) |
| Clawd's rows look misaligned | Use the *Mono* variant of your Nerd Font (e.g. *Hack Nerd Font Mono*), not the proportional one |
| Gauges look washed out on a light theme | Set `SL_TRACK` to a colour slightly darker than your background |
| No PR/MR number | Claude Code shows it only while a PR/MR is *open* for the current branch; older Claude Code versions need `gh` / `glab` installed |
| No CI status | `gh auth status` / `glab auth status`, and the `origin` remote must point to GitHub or a GitLab host (with `gitlab` in its name) |

## Contributing

Issues and pull requests are welcome. CI runs `tools/test.sh` on Linux and macOS for every push and pull request.

- `tools/demo.sh [tool|think|idle|asleep|party]` renders the bar once with fake data in a throwaway sandbox.
- `tools/test.sh` runs the test suite: shellcheck, every demo state, and install / reinstall / uninstall against a scratch config.
- `uv run tools/screenshot.py [STATE]` regenerates `docs/screenshot.png`, and `uv run tools/animate.py` regenerates
  `docs/clawd.gif` from twelve seconds of real renders (both need Chrome, ImageMagick and Hack Nerd Font).
- `python3 tools/mascot-gen.py` regenerates Clawd's frames; paste its output over the `case $frame` block in `statusline.sh`.
- Releases: bump nothing, just push a tag (`git tag v1.2.0 && git push origin v1.2.0`). The release workflow re-runs
  the tests and publishes a GitHub release with generated notes and a tarball.
- Keep the renderer POSIX `sh` (it runs under `dash`) and avoid adding processes to the render path, since it runs every second.

Made by Adrien Gooris. Feedback and ideas are welcome in the issues. Released under the [MIT licence](LICENSE).
