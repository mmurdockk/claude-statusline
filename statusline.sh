#!/bin/sh
# Claude Code status line.
#
# Shape of a render, and why it is that shape:
#
#   1. Find the repo with shell builtins. A git process that is going to fail
#      because there is no repo costs the same ~8 ms to start as one that
#      succeeds, so a handful of stat calls up the tree pays for itself.
#   2. Start git in the BACKGROUND, from $PWD. The TUI spawns this script with
#      its working directory already set to the session directory, so git can
#      begin before we have parsed anything.
#   3. Run the jq pass in the foreground. One invocation parses the payload and
#      does every bit of arithmetic -- percentages, gradients, money, durations,
#      timestamps, the gauges themselves -- then emits @sh-quoted assignments we
#      eval. git and jq now overlap, which is where most of the render went.
#   4. Reconcile: if the session directory turned out not to be $PWD, redo the
#      git call synchronously. Then parse its output with `while read`, in the
#      current shell, so no subshell is forked to capture it.
#
# Two processes per render, overlapped, plus a detached rm of git's scratch file
# once the line is out. Everything downstream is shell builtins concatenating
# strings that jq already formatted.
#
# The lines, by what they answer:
#   1. where and what   directory, git, model, what the turn is doing, PR/MR
#   2. this session     account and plan, time, lines changed, version, name
#   3. how much is left context, 5h and 7d quotas, money
#
# What the turn is doing comes from statusline-turn.sh, wired as hooks in
# settings.json: the payload alone cannot tell a long think from an idle session.
#
# Two caches, both keyed on a value rather than a clock, so neither can go
# stale: the HEAD commit time against the branch OID that git status already
# reports, and the account against a twelve-hour stamp (it is read from a 160 KB
# ~/.claude.json that changes about never).
#
# Toggles, export from your profile or set them in settings.json under "env":
#   SL_NERD=0        ASCII fallback, for a terminal without a patched font
#   SL_POWERLINE=0   thin dividers on line 1 instead of filled segments
#   SL_MASCOT=0      no sprite
#   SL_PATH=full     do not abbreviate parent directories
#   SL_ACCOUNT=0     hide the signed-in account; =org adds the organisation
#   SL_FORGE=0       no CI lookup through gh (GitHub) or glab (GitLab); the
#                    PR/MR number still shows, Claude Code provides it
#   SL_TRACK=r,g,b   colour of the empty part of the gauges. It has to sit
#                    ABOVE the terminal background to read as a groove; the
#                    default is tuned for a black terminal.

# Every lower-case payload field used below (dir, up, fbar, pr, ...) is assigned
# by the eval of the jq pass, which shellcheck cannot follow.
# shellcheck disable=SC2154

# Real binaries first. A mise shim re-resolves the toolchain on every exec, which
# cost ~25 ms per jq call -- a third of the render, every second.
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH

: "${SL_NERD:=1}"
: "${SL_POWERLINE:=1}"
: "${SL_MASCOT:=1}"
: "${SL_PATH:=short}"
: "${SL_ACCOUNT:=1}"
: "${SL_FORGE:=1}"
: "${SL_TRACK:=54,61,72}"

GIT_ARGS="status --porcelain=v2 --branch --show-stash --untracked-files=normal"

# Is there a repo at or above $1? Builtins only, no fork.
find_git() {
  _d=$1
  while [ -n "$_d" ] && [ "$_d" != "/" ]; do
    [ -e "$_d/.git" ] && return 0
    _d=${_d%/*}
  done
  [ -e "/.git" ]
}

# ── 1-2. Git, started before anything else so it overlaps the jq pass ─────────
p0=$PWD
# Per render, not per session: a render that runs past the next tick (a big
# repo, Defender) would otherwise have its file truncated under it.
gtmp="${TMPDIR:-/tmp}/statusline-git-$$"
gpid=""
if find_git "$p0"; then
  # shellcheck disable=SC2086
  git --no-optional-locks $GIT_ARGS > "$gtmp" 2>/dev/null &
  gpid=$!
fi

# ── 3. The single jq pass ─────────────────────────────────────────────────────
# The program lives next to this script, in statusline.jq.
eval "$(jq -r --arg home "$HOME" --arg pathmode "$SL_PATH" \
              --arg track "$SL_TRACK" -f "${0%/*}/statusline.jq" 2>/dev/null)"

if [ -z "$model$cwd" ]; then
  [ -n "$gpid" ] && { wait "$gpid"; rm -f "$gtmp"; } >/dev/null 2>&1 &
  exit 0
fi

# ── 4. Collect git, and parse it without forking ──────────────────────────────
gsrc=""
# A directory that has vanished just means no git segment: carry on.
# shellcheck disable=SC2164
[ -n "$cwd" ] && cd -- "$cwd" 2>/dev/null
if [ -n "$gpid" ]; then
  wait "$gpid" 2>/dev/null
  [ "$cwd" = "$p0" ] && gsrc=$gtmp
fi
if [ -z "$gsrc" ] && [ -n "$cwd" ] && find_git "$cwd"; then
  # shellcheck disable=SC2086
  git --no-optional-locks $GIT_ARGS > "$gtmp" 2>/dev/null
  gsrc=$gtmp
fi

branch=""; dirty=""; ahead=""; behind=""; stash=""; oid=""
staged=0; unstaged=0; untrk=0; confl=0; headage=""; hage=""
if [ -n "$gsrc" ] && [ -s "$gsrc" ]; then
  while IFS= read -r ln; do
    case $ln in
      '# branch.oid '*)  oid=${ln#\# branch.oid } ;;
      '# branch.head '*) branch=${ln#\# branch.head } ;;
      '# branch.ab '*)
        ab=${ln#\# branch.ab }
        ahead=${ab%% *};  ahead=${ahead#+}
        behind=${ab##* }; behind=${behind#-}
        [ "$ahead"  = "0" ] && ahead=""
        [ "$behind" = "0" ] && behind=""
        ;;
      '# stash '*) stash=${ln#\# stash }; [ "$stash" = "0" ] && stash="" ;;
      '#'*) ;;
      '?'*)  [ "$untrk" -lt 99 ] && untrk=$((untrk + 1)) ;;
      'u '*) confl=$((confl + 1)) ;;
      1\ *|2\ *)
        xy=${ln#? }; xy=${xy%% *}
        case $xy in [!.]*) staged=$((staged + 1)) ;; esac
        case $xy in ?[!.]) unstaged=$((unstaged + 1)) ;; esac
        ;;
    esac
  done < "$gsrc"
  [ "$staged$unstaged$untrk$confl" != "0000" ] && dirty=1

  # git log -1 was the single most expensive thing in a render, paid every
  # second to answer a question whose answer only changes when you commit. The
  # porcelain output already carries the head OID, so cache the commit time
  # against it: git log now runs only when HEAD has actually moved, and the
  # value is exact rather than merely fresh-ish.
  if [ -n "$oid" ]; then
    hf="${TMPDIR:-/tmp}/statusline-head-$sid"
    hoid=""; ct=""
    [ -f "$hf" ] && read -r hoid ct < "$hf" 2>/dev/null
    if [ "$hoid" != "$oid" ]; then
      ct=$(git --no-optional-locks log -1 --format=%ct 2>/dev/null)
      [ -n "$ct" ] && printf '%s %s\n' "$oid" "$ct" > "$hf" 2>/dev/null
    fi
    if [ -n "$ct" ] && [ -n "$epoch" ]; then
      a=$((epoch - ct)); hage=$a
      if   [ "$a" -ge 31536000 ]; then t=$((a * 10 / 31536000)); headage="$((t / 10)).$((t % 10))y"
      elif [ "$a" -ge 86400 ]; then headage="$((a / 86400))d"
      elif [ "$a" -ge 3600  ]; then headage="$((a / 3600))h"
      elif [ "$a" -ge 60    ]; then headage="$((a / 60))m"
      else                          headage="${a}s"; fi
    fi
  fi
fi

# ── Palette ───────────────────────────────────────────────────────────────────
RESET="\033[0m"; B="\033[1m"; DIM="\033[2m"
FG_MUT="\033[38;2;125;133;144m"
FG_TXT="\033[38;2;201;209;217m"
FG_CYAN="\033[38;2;121;192;255m"
FG_MAG="\033[38;2;210;168;255m"
FG_GRN="\033[38;2;86;211;100m"
FG_AMB="\033[38;2;226;170;60m"
FG_RED="\033[38;2;248;81;73m"
# Highlight: amber ground + near-black ink, for the one field we want to pop.
BG_AMB="\033[48;2;226;170;60m"; FG_INK="\033[38;2;28;30;34m"
BG_RED="\033[48;2;248;81;73m"

# Powerline segment backgrounds. Each keeps a matching foreground escape, used
# to draw the arrow that closes it over the NEXT segment background.
S1B="\033[48;2;46;52;62m";  S1A="\033[38;2;46;52;62m";  S1F="\033[38;2;190;200;212m"
# The git segment carries the tree state in its ground, so it reads from the
# corner of the eye: violet clean, amber dirty, red mid-conflict.
if   [ "$confl" != "0" ]; then
  S2B="\033[48;2;92;32;34m";  S2A="\033[38;2;92;32;34m";  S2F="\033[38;2;255;170;160m"
elif [ -n "$dirty" ]; then
  S2B="\033[48;2;74;56;22m";  S2A="\033[38;2;74;56;22m";  S2F="\033[38;2;240;196;110m"
else
  S2B="\033[48;2;58;42;72m";  S2A="\033[38;2;58;42;72m";  S2F="\033[38;2;210;168;255m"
fi
S3B="\033[48;2;25;56;90m";  S3A="\033[38;2;25;56;90m";  S3F="\033[38;2;121;192;255m"
S4B="\033[48;2;40;45;53m";  S4A="\033[38;2;40;45;53m";  S4F="\033[38;2;150;160;175m"
# Activity, in Clawd's terracotta: it only exists while the turn runs.
S5B="\033[48;2;72;40;30m";  S5A="\033[38;2;72;40;30m";  S5F="\033[38;2;240;160;128m"
if [ "$SL_POWERLINE" != 1 ]; then
  S1B=""; S2B=""; S3B=""; S4B=""; S5B=""
  S1A=""; S2A=""; S3A=""; S4A=""; S5A=""
fi

# ── Glyphs ────────────────────────────────────────────────────────────────────
# Every icon lives in the Powerline (U+E0Ax/E0Bx) or FontAwesome (U+F000-F2FF)
# block. Those two ranges kept their codepoints across the Nerd Font v2 -> v3
# renumbering, unlike Material Design and Octicons, so an older patched font
# renders this identically. The gauge and mascot glyphs are plain Unicode and
# need no patched font at all.
if [ "$SL_NERD" = 1 ]; then
  PLS=""; PLT=""
  I_DIR=""; I_BR=""; I_GH=""; I_GL=""
  I_MOD=""; I_EFF=""; I_THK=""; I_TOK=""
  I_USD=""; I_CLK=""; I_API=""; I_CACHE=""
  I_VER=""; I_AGT=""; I_PR=""; I_WT=""
  I_CLOUD=""; I_HG=""; I_RST=""; I_WARN=""
  I_SESS=""; I_STASH=""; I_UP=""; I_DN=""
  I_ADD=""; I_DEL=""; I_STYLE=""; I_FAST=""
  I_PLAN=""; I_TOOL=""
  # Badge bevels: a half-cell filled in the badge colour over the terminal
  # background, so a coloured field reads as a slanted tab rather than a block.
  BVL=""; BVR=""
else
  PLS=" "; PLT="|"
  I_DIR="in"; I_BR="git"; I_GH="gh"; I_GL="gl"
  I_MOD=""; I_EFF="effort"; I_THK="think"; I_TOK=""
  I_USD="\$"; I_CLK=""; I_API="api"; I_CACHE="cache"
  I_VER="v"; I_AGT="@"; I_PR="PR"; I_WT="wt"
  I_CLOUD="remote"; I_HG=""; I_RST="resets"; I_WARN="!"
  I_SESS=""; I_STASH="stash"; I_UP="^"; I_DN="v"
  I_ADD="+"; I_DEL="-"; I_STYLE="style"; I_FAST=""
  I_PLAN="plan"; I_TOOL="run"
  BVL=""; BVR=""
fi
SEP="${DIM}${FG_MUT} │ ${RESET}"
MID="${DIM} · ${RESET}"

# ── Pending upgrade: running version vs the one the updater last installed ────
newer_than() {  # $1 > $2, field by field over dot-separated versions
  _a=$1; _b=$2
  while [ -n "$_a" ] || [ -n "$_b" ]; do
    case $_a in *.*) _x=${_a%%.*}; _a=${_a#*.} ;; *) _x=$_a; _a="" ;; esac
    case $_b in *.*) _y=${_b%%.*}; _b=${_b#*.} ;; *) _y=$_b; _b="" ;; esac
    _x=${_x%%[!0-9]*}; _y=${_y%%[!0-9]*}   # drop any prerelease suffix
    [ "${_x:-0}" -gt "${_y:-0}" ] && return 0
    [ "${_x:-0}" -lt "${_y:-0}" ] && return 1
  done
  return 1
}
newver=""
if [ -f "$HOME/.claude/.last-update-result.json" ]; then
  read -r _u < "$HOME/.claude/.last-update-result.json"
  t=${_u#*\"version_to\":\"}
  # A failed install writes "version_to":null, so the prefix strip matches
  # nothing and t is still the whole line; only trust a real quoted value.
  if [ "$t" != "$_u" ]; then
    t=${t%%\"*}
    # Strictly newer only: the file outlives the upgrade it records, so after an
    # update that bypassed it version_to is *older* than what we run and a plain
    # "!=" advertised 2.1.269 as ready while 2.1.270 was already running.
    [ -n "$ver" ] && newer_than "$t" "$ver" && newver=$t
  fi
fi

# ── Signed-in account, cached ─────────────────────────────────────────────────
acct=""
if [ "$SL_ACCOUNT" != 0 ] && [ -n "$epoch" ]; then
  af="$HOME/.claude/.statusline-account"
  ats=0
  [ -f "$af" ] && read -r ats acct < "$af" 2>/dev/null
  case $ats in ''|*[!0-9]*) ats=0 ;; esac
  if [ $((epoch - ats)) -ge 43200 ]; then
    acct=$(jq -r '
      .oauthAccount // {}
      | ((.emailAddress // .displayName // "") | split("@")[0])                as $u
      | ((.userRateLimitTier // "") | sub("^default_"; "") | sub("^claude_"; "")) as $t
      | (if   $t == "max_5x"  then "Max 5x"
         elif $t == "max_20x" then "Max 20x"
         elif $t == "pro"     then "Pro"
         elif $t == "free"    then "Free"
         elif $t == ""        then ""
         else ($t | gsub("_"; " ")) end)                                       as $plan
      | ((.organizationType // "") | sub("^claude_"; "")
         | if . == "" then "" else ((.[0:1] | ascii_upcase) + .[1:]) end)      as $otype
      | [$u,
         ([$otype, $plan] | map(select(. != "")) | join(" · ")),
         (.organizationName // "")]
      | join("|") | gsub("\\\\"; "\\\\")' "$HOME/.claude.json" 2>/dev/null)
    [ -n "$acct" ] && printf '%s %s\n' "$epoch" "$acct" > "$af" 2>/dev/null
  fi
fi

# ── Activity ──────────────────────────────────────────────────────────────────
# Two sources. The hooks (statusline-turn.sh) say where the turn is. Without
# them, fall back on total_api_duration_ms: it moves when a request completes,
# so "changed since the previous render" catches activity for free, but a long
# think is one request and goes unseen. Both state files are per session, read
# and written with builtins only. The mascot animates on the result and the
# model name shimmers while anything runs.
#   think   the model is working on its answer
#   busy    a tool is running, or, without hooks, something just happened
#   idle    awake, nothing to do
#   asleep  idle for longer than DOZE_AFTER
DOZE_AFTER=25       # seconds without the model generating before it dozes off
TURN_STALE=600      # Esc fires no hook: a turn this silent, hooks and API alike, is over
state=idle; turn=""; tts=0; ttool=""
if [ -n "$sid" ]; then
  st="${TMPDIR:-/tmp}/statusline-mascot-$sid"
  last=""; since=""
  [ -f "$st" ] && read -r last since < "$st" 2>/dev/null
  if [ "$apims" != "$last" ] || [ -z "$since" ]; then
    since=$epoch
    printf '%s %s\n' "$apims" "$since" > "$st" 2>/dev/null
  fi
  tf="${TMPDIR:-/tmp}/statusline-turn-$sid"
  [ -f "$tf" ] && read -r turn tts ttool < "$tf" 2>/dev/null
  case $tts in ''|*[!0-9]*) turn=""; tts=0 ;; esac
  case $turn in think|tool)
    [ $((epoch - tts)) -ge "$TURN_STALE" ] && [ $((epoch - since)) -ge "$TURN_STALE" ] && turn=idle ;;
  esac
  case $turn in
    think) state=think ;;
    tool)  state=busy ;;
    *)
      quiet=$((epoch - since))
      [ "$turn" = idle ] && [ $((epoch - tts)) -lt "$quiet" ] && quiet=$((epoch - tts))
      if   [ -z "$turn" ] && [ "$quiet" -le 1 ]; then state=busy
      elif [ "$quiet" -ge "$DOZE_AFTER" ];       then state=asleep; fi
      ;;
  esac
fi

# What the turn is doing, for its own segment on line 1: Claude Code's own
# spinner while it thinks, the tool's name while one runs, and how long either
# has been going.
act=""
if [ "$turn" = think ] || [ "$turn" = tool ]; then
  if [ "$state" = think ] || [ "$state" = busy ]; then
    a=$((epoch - tts)); [ "$a" -lt 0 ] && a=0
    if [ "$a" -ge 60 ]; then
      s=$((a % 60)); [ "$s" -lt 10 ] && s="0$s"; el="$((a / 60))m${s}s"
    else
      el="${a}s"
    fi
    if [ "$state" = think ]; then
      case $((epoch % 10)) in
        0) g='·' ;; 1|9) g='✢' ;; 2|8) g='✳' ;; 3|7) g='✶' ;; 4|6) g='✻' ;; *) g='✽' ;;
      esac
      act="${B}${g}${RESET}${S5B}${S5F} ${el}"
    else
      act="${I_TOOL} ${ttool:+${B}${ttool}${RESET}${S5B}${S5F} }${el}"
    fi
  fi
fi

# ── Forge: PR / MR and CI ─────────────────────────────────────────────────────
# Claude Code already hands us the open PR (GitHub) or MR (GitLab) for the
# branch, with its review state, and the origin host. What it does not know is
# CI, so that comes from gh or glab. Both are network round trips, far too slow
# for a render: a detached child refreshes a per-session cache at most once a
# minute and the render only reads what the last refresh left. The child also
# records the PR/MR number, a fallback for Claude Code versions that do not
# send one. An expired token shows as a hint instead of failing silently.
#
# The cache line is "epoch branch state number ci", in GitLab's vocabulary:
# success failed running pending manual canceled skipped, or "-".
forge=""
case $rhost in
  *github*) forge=gh ;;
  *gitlab*) forge=gl ;;
  '')
    # No host from Claude Code (outside a repo, or an older version): the
    # checkout path is free and right for ~/dev/<host>/<owner>/<repo> layouts.
    case $cwd in *github*) forge=gh ;; *gitlab*) forge=gl ;; esac ;;
esac
[ "$prkind" = mr ] && forge=gl

# Checks of the open PR, rolled up the way GitHub's own badge does it.
GH_PR_JQ='
  def norm: if .__typename == "StatusContext" then (.state // "")
            elif .status != "COMPLETED" then (if .status == "IN_PROGRESS" then "RUNNING" else "PENDING" end)
            else (.conclusion // "") end;
  def roll: [.[] | norm] as $s
    | if   ($s | length) == 0 then "-"
      elif any($s[]; IN("FAILURE", "ERROR", "TIMED_OUT", "STARTUP_FAILURE")) then "failed"
      elif any($s[]; . == "RUNNING") then "running"
      elif any($s[]; IN("PENDING", "EXPECTED", "QUEUED", "WAITING", "REQUESTED")) then "pending"
      elif any($s[]; . == "ACTION_REQUIRED") then "manual"
      elif any($s[]; . == "CANCELLED") then "canceled"
      elif all($s[]; IN("SKIPPED", "NEUTRAL", "STALE")) then "skipped"
      else "success" end;
  if .state == "OPEN" then "ok \(.number) \(.statusCheckRollup // [] | roll)" else "none" end'
# No open PR: the latest workflow run on the branch instead.
GH_RUN_JQ='
  .[0] // {} | "ok - " + (
    if   .status == null        then "-"
    elif .status == "completed" then ({success: "success", failure: "failed", timed_out: "failed",
           startup_failure: "failed", cancelled: "canceled", skipped: "skipped", neutral: "skipped",
           action_required: "manual"}[.conclusion // ""] // "-")
    elif .status == "in_progress" then "running"
    else "pending" end)'

forge_refresh() {  # $1 cache file  $2 branch  $3 forge
  if [ "$3" = gh ]; then
    # No argument: gh resolves the current branch's PR itself, forks included.
    _r=$(gh pr view --json number,state,statusCheckRollup 2>&1)
    case $_r in
      '{'*) _o=$(printf '%s' "$_r" | jq -r "$GH_PR_JQ") ;;
      *'no pull requests found'*) _o=none ;;
      *'auth login'*|*'HTTP 401'*|*'Bad credentials'*) _o="auth - -" ;;
      *) _o="err - -" ;;
    esac
    if [ "$_o" = none ]; then
      _o=$(gh run list --branch "$2" --limit 1 --json status,conclusion 2>/dev/null | jq -r "$GH_RUN_JQ")
      [ -n "$_o" ] || _o="err - -"
    fi
  else
    # Encoded, or a "+" in the branch reaches GitLab as a space and a "#" ends the URL.
    _b=$(jq -rn --arg b "$2" '$b | @uri')
    _r=$(glab api "projects/:id/merge_requests?state=opened&source_branch=$_b&per_page=20" 2>&1)
    case $_r in
      *401*|*invalid_token*) _o="auth - -" ;;
      '['*)
        # Forks open MRs from their own same-named branch (a fork "master" into
        # ours), so keep only MRs whose source branch lives in this project.
        _i=$(printf '%s' "$_r" | jq -r '[.[] | select(.source_project_id == .project_id)][0].iid // "-"')
        if [ "$_i" != "-" ]; then
          _p=$(glab api "projects/:id/merge_requests/$_i" 2>/dev/null | jq -r '.head_pipeline.status // "-"')
        else
          _p=$(glab api "projects/:id/pipelines?ref=$_b&per_page=1" 2>/dev/null | jq -r '.[0].status // "-"')
        fi
        _o="ok $_i ${_p:--}" ;;
      *) _o="err - -" ;;
    esac
  fi
  printf '%s %s %s\n' "$epoch" "$2" "$_o" > "$1.tmp" && mv -f "$1.tmp" "$1"
}

cr_num=""; cr_ci=""; cr_auth=""
cli=""; [ "$forge" = gh ] && cli=gh; [ "$forge" = gl ] && cli=glab
if [ "$SL_FORGE" = 1 ] && [ -n "$cli" ] && command -v "$cli" >/dev/null 2>&1 \
   && [ -n "$branch" ] && [ "$branch" != "(detached)" ] && [ -n "$sid" ]; then
  ff="${TMPDIR:-/tmp}/statusline-forge-$sid"
  fts=0; fbr=""; fst=""; fnum=""; fci=""
  [ -f "$ff" ] && read -r fts fbr fst fnum fci < "$ff" 2>/dev/null
  case $fts in ''|*[!0-9]*) fts=0 ;; esac
  if [ "$fbr" != "$branch" ] || [ $((epoch - fts)) -ge 60 ]; then
    # The lock keeps a slow or hung CLI from being joined by one more per second.
    lts=0; [ -f "$ff.lock" ] && read -r lts < "$ff.lock" 2>/dev/null
    case $lts in ''|*[!0-9]*) lts=0 ;; esac
    if [ $((epoch - lts)) -ge 30 ]; then
      printf '%s\n' "$epoch" > "$ff.lock" 2>/dev/null
      forge_refresh "$ff" "$branch" "$forge" > /dev/null 2>&1 &
    fi
  fi
  if [ "$fbr" = "$branch" ]; then
    case $fst in
      auth) cr_auth=1 ;;
      ok)
        [ "$fnum" != "-" ] && cr_num=$fnum
        case $fci in
          success) cr_ci="${FG_GRN}✓" ;;
          failed)  cr_ci="${FG_RED}✗" ;;
          running)
            case $((epoch % 4)) in
              0) cr_ci="${FG_CYAN}◐" ;; 1) cr_ci="${FG_CYAN}◓" ;;
              2) cr_ci="${FG_CYAN}◑" ;; *) cr_ci="${FG_CYAN}◒" ;;
            esac ;;
          pending|created|preparing|waiting_for_resource|scheduled) cr_ci="${FG_AMB}◌" ;;
          manual)  cr_ci="${FG_MAG}▶" ;;
          canceled|skipped) cr_ci="${FG_MUT}⊘" ;;
        esac ;;
    esac
  fi
fi

# Host icon on the branch segment.
case $forge in gh) I_HOST=$I_GH ;; gl) I_HOST=$I_GL ;; *) I_HOST=$I_BR ;; esac

# A percentage at 90 or more alternates onto a red ground, once a second.
hot() { hot=""; [ "${1:-0}" -ge 90 ] && [ $((epoch % 2)) -eq 0 ] && hot="${BG_RED}${FG_INK}"; }

# ── LINE 1: identity, as powerline segments ───────────────────────────────────
l1=""; prevA=""
seg() {  # $1 background  $2 arrow-fg matching that background  $3 content
  if [ "$SL_POWERLINE" = 1 ]; then
    [ -n "$prevA" ] && l1="${l1}${1}${prevA}${PLS}"
    l1="${l1}${1} ${3} "
    prevA=$2
  else
    l1="${l1:+${l1}${SEP}}${3}"
  fi
}

c="${S1F}${I_DIR} ${B}${dir}${RESET}${S1B}${S1F}"
[ "$dirs" != "0" ] && [ -n "$dirs" ] && c="${c} ${DIM}+${dirs}${RESET}${S1B}${S1F}"
seg "$S1B" "$S1A" "$c"

if [ -n "$branch" ]; then
  c="${S2F}${I_HOST} ${B}${branch}${RESET}${S2B}"
  [ -n "$headage" ] && c="${c} ${DIM}${S2F}${I_CLK}${headage}${RESET}${S2B}"
  [ "$staged"   != "0" ] && c="${c} ${FG_GRN}${I_ADD}${staged}${RESET}${S2B}"
  [ "$unstaged" != "0" ] && c="${c} ${FG_AMB}±${unstaged}${RESET}${S2B}"
  [ "$untrk"    != "0" ] && c="${c} ${FG_MUT}?${untrk}${RESET}${S2B}"
  [ "$confl"    != "0" ] && c="${c} ${FG_RED}${I_WARN}${confl}${RESET}${S2B}"
  [ -n "$stash"  ] && c="${c} ${FG_MAG}${I_STASH}${stash}${RESET}${S2B}"
  [ -n "$ahead"  ] && c="${c} ${FG_CYAN}${I_UP}${ahead}${RESET}${S2B}"
  [ -n "$behind" ] && c="${c} ${FG_CYAN}${I_DN}${behind}${RESET}${S2B}"
  [ -z "$dirty" ] && [ -z "$ahead" ] && [ -z "$behind" ] && c="${c} ${FG_GRN}✓${RESET}${S2B}"
  [ -n "$wt" ] && c="${c} ${DIM}${S2F}${PLT} ${I_WT} ${wt}${RESET}${S2B}"
  seg "$S2B" "$S2A" "$c"
fi

mname=$model
case $state in think|busy) [ -n "$model_sh" ] && mname=$model_sh ;; esac
c="${S3F}${I_MOD:+${I_MOD} }${B}${mname}${RESET}${S3B}${S3F}"
[ -n "$big"  ] && c="${c} ${DIM}1M${RESET}${S3B}${S3F}"
[ -n "$fast" ] && c="${c} ${FG_AMB}${I_FAST}fast${RESET}${S3B}${S3F}"
[ -n "$effort" ] && c="${c} ${DIM}${PLT}${RESET}${S3B}${S3F} ${I_EFF} ${effort}"
# Thinking is on almost always, so only its absence is worth a glyph.
[ -z "$think" ] && c="${c} ${DIM}${I_THK}×${RESET}${S3B}${S3F}"
seg "$S3B" "$S3A" "$c"

[ -n "$act" ] && seg "$S5B" "$S5A" "${S5F}${act}"

c=""
[ -n "$agent"  ] && c="${c:+${c} }${FG_MAG}${I_AGT}${agent}${RESET}${S4B}${S4F}"
# PR/MR: Claude Code's number first, the CLI's as a fallback. GitLab writes
# merge requests as !N, GitHub pull requests as #N. A plain "pending" review is
# every open PR's resting state, so only the states that ask something show.
num=$pr; [ -z "$num" ] && num=$cr_num
sig="#"; [ "$forge" = gl ] && sig="!"
case $prstate in
  approved)          rv="${FG_GRN}approved" ;;
  changes_requested) rv="${FG_RED}changes" ;;
  draft)             rv="${DIM}draft" ;;
  *)                 rv="" ;;
esac
if [ -n "$num" ]; then
  c="${c:+${c} }${I_PR} ${sig}${num}${cr_ci:+ ${cr_ci}${RESET}${S4B}${S4F}}${rv:+ ${rv}${RESET}${S4B}${S4F}}"
elif [ -n "$cr_ci" ]; then
  c="${c:+${c} }CI ${cr_ci}${RESET}${S4B}${S4F}"
fi
[ -n "$cr_auth" ] && c="${c:+${c} }${FG_AMB}${cli} auth${RESET}${S4B}${S4F}"
[ -n "$remote" ] && c="${c:+${c} }${FG_AMB}${I_CLOUD}${RESET}${S4B}${S4F}"
[ -n "$style"  ] && c="${c:+${c} }${I_STYLE} ${style}"
[ -n "$vim"    ] && c="${c:+${c} }${DIM}vim${RESET}${S4B}${S4F}:${vim}"
[ -n "$c" ] && seg "$S4B" "$S4A" "${S4F}${c}"
[ "$SL_POWERLINE" = 1 ] && [ -n "$prevA" ] && l1="${l1}${RESET}${prevA}${PLS}${RESET}"

# ── LINE 2: this session ──────────────────────────────────────────────────────
l2=""
if [ -n "$acct" ]; then
  au=${acct%%|*}; _r=${acct#*|}; ap=${_r%%|*}; ao=${_r#*|}
  l2="${FG_MUT}${I_AGT}${RESET} ${FG_TXT}${au}${RESET}"
  [ -n "$ap" ] && l2="${l2} ${FG_MUT}${I_PLAN}${RESET} ${FG_MAG}${ap}${RESET}"
  [ "$SL_ACCOUNT" = org ] && [ -n "$ao" ] && l2="${l2} ${DIM}${ao}${RESET}"
fi
# Wall clock, then how much of it was actually spent waiting on the model.
[ -n "$dur" ] && \
  l2="${l2:+${l2}${SEP}}${DIM}${I_CLK:+${I_CLK} }${dur}${RESET}${apidur:+ ${DIM}${FG_MUT}${I_API}${apidur}${RESET}}"
[ "$add$del" != "00" ] && \
  l2="${l2:+${l2}${SEP}}${FG_GRN}${I_ADD}${add}${RESET} ${FG_RED}${I_DEL}${del}${RESET} ${diffbar}"
# The pending upgrade rides INSIDE the badge: amber text pressed against an
# amber ground read as one smeared field, and the slant wants a single shape.
if [ -n "$ver" ]; then
  c="${I_VER} ${ver}"
  [ -n "$newver" ] && c="${c} ${B}→ ${newver} ready"
  l2="${l2:+${l2}${SEP}}${FG_AMB}${BVL}${BG_AMB}${FG_INK} ${c} ${RESET}${FG_AMB}${BVR}${RESET}"
fi
# Lowest-value field last: the TUI truncates each line, so this drops first.
[ -n "$sess" ] && l2="${l2:+${l2}${MID}}${DIM}${I_SESS:+${I_SESS} }${sess}${RESET}"

# ── LINE 3: what is left, as three gauges side by side, then money ────────────
# pace_of renders used% minus elapsed%: a red triangle up means the window is
# draining faster than it refills, a green one down means you are coasting, a
# dash means you are on budget.
l3=""; pace=""
pace_of() {
  pace=""
  [ -z "$1" ] && return
  if   [ "$1" -ge 8 ];  then pace=" ${FG_RED}▲${1}${RESET}"
  elif [ "$1" -le -8 ]; then pace=" ${FG_GRN}▼${1#-}${RESET}"
  else                       pace=" ${DIM}${FG_MUT}▬${RESET}"; fi
}
if [ -n "$has_ctx" ]; then
  if   [ "$up" -ge 80 ]; then pc="$FG_RED"
  elif [ "$up" -ge 50 ]; then pc="$FG_AMB"
  else                        pc="$FG_GRN"; fi
  hot "$up"
  l3="${FG_MUT}${I_TOK:+${I_TOK} }ctx${RESET} ${ctxbar} ${pc}${B}${hot}${up}%${RESET}${MID}${FG_GRN}${rt_k} free${RESET}"
  # A healthy cache sits in the high nineties; only a drop is news.
  [ -n "$cache" ] && [ "$cache" != "0" ] && [ "$cache" -lt 80 ] && \
    l3="${l3}${MID}${FG_MUT}${I_CACHE}${RESET} ${FG_AMB}${cache}%${RESET}"
fi
if [ -n "$has5" ]; then
  pace_of "$fpace"; hot "$fp"
  l3="${l3:+${l3}${SEP}}${FG_MUT}${I_HG:+${I_HG} }5h${RESET} ${fbar} ${B}${hot}${fp}%${RESET}${pace}"
  [ -n "$f_at" ] && l3="${l3} ${DIM}${I_RST} ${f_at}${RESET}"
fi
if [ -n "$has7" ]; then
  pace_of "$wpace"; hot "$wp"
  l3="${l3:+${l3}${SEP}}${FG_MUT}${I_HG:+${I_HG} }7d${RESET} ${wbar} ${B}${hot}${wp}%${RESET}${pace}"
  [ -n "$w_at" ] && l3="${l3} ${DIM}${I_RST} ${w_at}${RESET}"
fi
# On a subscription this is the API-price equivalent, not a bill: last, so it
# is the first thing the TUI truncates.
if [ -n "$cost" ]; then
  l3="${l3:+${l3}${SEP}}${FG_CYAN}${B}${I_USD}${cost}${RESET}"
  [ -n "$burn" ] && l3="${l3} ${DIM}${FG_MUT}${burn}/h${RESET}"
fi

# ── Mascot ────────────────────────────────────────────────────────────────────
# Clawd, the Claude Code mascot, modelled on the parts Claude Code uses
# for its welcome screen: nine columns by three rows, which is exactly the
# three rows we already print. An anchor glyph is prepended at print time.
# tools/mascot-gen.py generates the frames and asserts the width.
GAP='   '
gap1=$GAP; gap2=$GAP

if [ "$SL_MASCOT" = 1 ]; then
  # The body is the one alarm light for the whole bar: it follows whichever of
  # the three gauges is worst, so a 5h quota about to run out turns the mascot
  # red even while the context window is still wide open.
  sev=${up:-0}
  [ "${fp:-0}" -gt "$sev" ] && sev=$fp
  [ "${wp:-0}" -gt "$sev" ] && sev=$wp
  if   [ "$sev" -ge 80 ]; then MC="248;81;73"
  elif [ "$sev" -ge 50 ]; then MC="226;170;60"
  else                         MC="215;119;87"   # clawd_body, as Claude Code paints it
  fi
  MB="\033[38;2;${MC}m"; MBB="\033[48;2;${MC}m"
  MEF="\033[38;2;0;0;0m"; MEB="\033[48;2;0;0;0m"
  MX="\033[49m"; MZ="\033[0m"

  # think fidgets, hand to the chin: blinks, winks, taps a foot, lets the
  # arm drop; busy walks, idle stands with the occasional blink,
  # asleep shuts its eyes with a z drifting off. A commit younger than 15 s
  # overrides them all with a celebration: arms up, dancing, winking, hopping,
  # with sparkles where the z would be.
  mstate=$state
  [ -n "$hage" ] && [ "$hage" -ge 0 ] && [ "$hage" -lt 15 ] && mstate=party

  case $mstate in
    party)
      SPK=$FG_AMB
      case $((epoch % 4)) in
        0) frame=15 ;;  1) frame=12 ;;  2) frame=16 ;;  *) frame=8 ;;
      esac
      if [ $((epoch % 2)) -eq 0 ]; then gap1="${SPK}✦${MZ} ${SPK}·${MZ}"
      else                              gap1="${SPK}·${MZ} ${SPK}✦${MZ}"; fi
      ;;
    think)
      # Mostly still, one small move every other beat, so it reads as
      # mulling rather than as the walk.
      case $((epoch % 8)) in
        2) frame=21 ;;  4) frame=3 ;;  6) frame=22 ;;  7) frame=0 ;;  *) frame=20 ;;
      esac
      ;;
    busy)
      # Four-beat walk, a step on each foot with the arm swinging, and a hop on
      # the eighth beat so it does not read as a loop.
      case $((epoch % 8)) in
        0|4) frame=1 ;;  2|6) frame=3 ;;  7) frame=8 ;;  *) frame=0 ;;
      esac
      ;;
    asleep)
      frame=10
      # The z drifts one cell right every two seconds. All three variants are
      # exactly as wide as GAP, so nothing shifts.
      case $(((epoch / 2) % 3)) in
        0) gap1="${DIM}z${MZ}  " ;;
        1) gap1=" ${DIM}z${MZ} " ;;
        *) gap1="  ${DIM}z${MZ}" ;;
      esac
      ;;
    *)
      # Awake with nothing to do: stand, and blink once every twelve seconds.
      case $((epoch % 12)) in
        5) frame=5 ;;  *) frame=0 ;;
      esac
      ;;
  esac

  # Past 80% on any gauge, awake, it sweats: a drop forms at the brow, then falls.
  if [ "$sev" -ge 80 ] && { [ "$mstate" = busy ] || [ "$mstate" = idle ] || [ "$mstate" = think ]; }; then
    if [ $((epoch % 2)) -eq 0 ]; then gap1="${FG_CYAN}°${MZ}  "
    else                              gap2="${FG_CYAN}.${MZ}  "; fi
  fi

  # generated by tools/mascot-gen.py -- 12 frames x 3 rows
  case $frame in
    1) m1=" ${MB}▐${MEB}▛${MX}███${MEB}▛${MX}█${MZ} ${MZ}"; m2="${MB}▝▜██████▀${MZ}"; m3=" ${MB}▝▝${MZ}      ${MZ}" ;;
    3) m1=" ${MB}▐${MEB}▛${MX}███${MEB}▛${MX}█▄${MZ}"; m2="${MB}▝▜██████▘${MZ}"; m3="      ${MB}▝▝${MZ} ${MZ}" ;;
    5) m1=" ${MB}▐${MEF}${MBB}▂${MX}${MB}███${MEF}${MBB}▂${MX}${MB}█${MZ} ${MZ}"; m2="${MB}▝▜██████▀${MZ}"; m3=" ${MB}▝▝${MZ}   ${MB}▝▝${MZ} ${MZ}" ;;
    8) m1="${MB}▗▟${MEB}▛${MX}███${MEB}▛${MX}█▄${MZ}"; m2=" ${MB}▜██████▘${MZ}"; m3="         ${MZ}" ;;
    10) m1=" ${MB}▐${MEF}${MBB}▂${MX}${MB}███${MEF}${MBB}▂${MX}${MB}█${MZ} ${MZ}"; m2="${MB}▝▜██████▀${MZ}"; m3=" ${MB}▝▝${MZ}   ${MB}▝▝${MZ} ${MZ}" ;;
    12) m1="${MB}▗▟${MEB}▛${MX}███${MEF}${MBB}▂${MX}${MB}█▄${MZ}"; m2=" ${MB}▜██████▘${MZ}"; m3=" ${MB}▝▝${MZ}   ${MB}▝▝${MZ} ${MZ}" ;;
    15) m1="${MB}▗▟${MEB}▛${MX}███${MEB}▛${MX}█▄${MZ}"; m2=" ${MB}▜██████▘${MZ}"; m3=" ${MB}▝▝${MZ}      ${MZ}" ;;
    16) m1="${MB}▗▟${MEB}▛${MX}███${MEB}▛${MX}█▄${MZ}"; m2=" ${MB}▜██████▘${MZ}"; m3="      ${MB}▝▝${MZ} ${MZ}" ;;
    20) m1=" ${MB}▐${MEB}▛${MX}███${MEB}▛${MX}█▄${MZ}"; m2="${MB}▝▜██████▘${MZ}"; m3=" ${MB}▝▝${MZ}   ${MB}▝▝${MZ} ${MZ}" ;;
    21) m1=" ${MB}▐${MEF}${MBB}▂${MX}${MB}███${MEF}${MBB}▂${MX}${MB}█▄${MZ}"; m2="${MB}▝▜██████▘${MZ}"; m3=" ${MB}▝▝${MZ}   ${MB}▝▝${MZ} ${MZ}" ;;
    22) m1=" ${MB}▐${MEB}▛${MX}███${MEF}${MBB}▂${MX}${MB}█▄${MZ}"; m2="${MB}▝▜██████▘${MZ}"; m3=" ${MB}▝▝${MZ}   ${MB}▝▝${MZ} ${MZ}" ;;
    *) m1=" ${MB}▐${MEB}▛${MX}███${MEB}▛${MX}█${MZ} ${MZ}"; m2="${MB}▝▜██████▀${MZ}"; m3=" ${MB}▝▝${MZ}   ${MB}▝▝${MZ} ${MZ}" ;;   # 0 stand
  esac
fi

# ── Output ────────────────────────────────────────────────────────────────────
# A powerline segment opens with a cell of padding, so line 1's text starts one
# column in. Lines 2 and 3 take the same pad and all three read from one edge.
pad=""; [ "$SL_POWERLINE" = 1 ] && pad=" "
if [ "$SL_MASCOT" = 1 ]; then
  # Always three rows: the sprite needs all of them even when l2 and l3 are
  # empty. Each row opens on U+2800, the blank braille pattern: it draws
  # nothing, yet is not whitespace, so the TUI keeps it and the sprite keeps
  # its indentation.
  A='⠀'
  printf "%b
" "${A}${m1}${gap1}${l1}"
  printf "%b
" "${A}${m2}${gap2}${pad}${l2}"
  printf "%b
" "${A}${m3}${GAP}${pad}${l3}"
else
  # No rail in front here, so the pad has to be a glyph the TUI will not trim.
  [ -n "$pad" ] && pad="⠀"
  printf "%b" "$l1"
  [ -n "$l2" ] && printf "\n%b" "${pad}${l2}"
  [ -n "$l3" ] && printf "\n%b" "${pad}${l3}"
  printf "\n"
fi
[ -n "$gsrc$gpid" ] && rm -f "$gtmp" >/dev/null 2>&1 &
