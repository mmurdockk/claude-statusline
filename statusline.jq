# Claude Code status line -- the single jq pass. statusline.sh runs this
# with jq -f: read from a file it compiles in half the time it takes as an
# argument, and the shell no longer has to parse 10 KB of quoted text.
# Emits one shell assignment per line, @sh-quoted, for the script to eval.

def cl: if . == null then 0 elif . < 0 then 0 elif . > 100 then 100 else . end;
def q($k; $v): "\($k)=\(($v // "") | tostring | @sh)";
# For free text bound for printf %b: a lone backslash would be read as an
# escape, and a "\c" in a session name cut the whole line short. Doubled, it
# prints as itself. Our own colour codes are raw ESC bytes, so they pass through.
def qe($k; $v): q($k; ($v // "") | tostring | gsub("\\\\"; "\\\\"));
def money: (. * 100 | round) as $c | ($c % 100) as $f
  | "\(($c / 100) | floor).\(if $f < 10 then "0" else "" end)\($f)";
def dur: (. / 1000 | floor) as $s
  | if   $s >= 3600 then "\(($s / 3600) | floor)h\((($s % 3600) / 60) | floor)m"
    elif $s >= 60   then "\(($s / 60) | floor)m"
    else "\($s)s" end;
def kfmt: if   . >= 1000000 then "\(((. / 100000) | floor) / 10)M"
          elif . >= 1000    then "\((. / 1000) | floor)k"
          else tostring end;
def clock: if . == null then "" else (strflocaltime("%-I:%M%p") | ascii_downcase) end;
def stamp: if . == null then "" else (strflocaltime("%b %-d, %-I:%M%p") | ascii_downcase) end;

# ── Colour ────────────────────────────────────────────────────────────────────
# Green/amber/red, because the gauges are alarms.
def _lerp($a; $b; $t): ($a + (($b - $a) * $t)) | round;
def _fg($c): "\u001b[38;2;\($c[0]);\($c[1]);\($c[2])m";
def _hue($t):
    if $t < 0.5
    then (($t * 2) as $u         | [_lerp(76;226;$u),  _lerp(201;170;$u), _lerp(122;60;$u)])
    else ((($t - 0.5) * 2) as $u | [_lerp(226;248;$u), _lerp(170;81;$u),  _lerp(60;73;$u)])
    end;
def _trk:  ($track     | split(",") | map(tonumber));

# ── Gauges ────────────────────────────────────────────────────────────────────
# A rule, never a block: light stroke for the track, heavy stroke for the fill,
# a half-cell at the leading edge. No caps, no background. Hue follows POSITION,
# so the track is green at the left and red at the right and filling it walks
# you into the red -- the bar answers "how close to the wall" without the number.
def bar($pct; $w):
  ((($pct | cl) / 100) * $w * 2 | floor) as $lv
  | (($lv / 2) | floor)                  as $full
  | ($lv % 2)                            as $half
  | ([ range(0; $w) as $i
       | (if $w > 1 then ($i / ($w - 1)) else 0 end) as $t
       | if   $i < $full                   then _fg(_hue($t)) + "━"
         elif ($i == $full and $half == 1) then _fg(_hue($t)) + "╸"
         else                                   _fg(_trk)     + "─"
         end
     ] | join("")) + "\u001b[0m";

# A highlight three cells wide sweeping across $s, two cells per tick, so a
# string that is generating looks lit from inside. The shell decides whether to
# use it; this only prepares the frame for the current second.
def shimmer($s; $base; $t):
  ($s | explode | map([.] | implode)) as $ch | ($ch | length) as $n
  | ((($t * 2) % ($n + 6)) - 3) as $p
  | [ range(0; $n) as $k | ($k - $p | if . < 0 then -. else . end) as $d
      | _fg(if $d == 0 then [240,250,255] elif $d == 1 then [180,222,255] else $base end)
        + $ch[$k] ] | join("");

# Five cells split green:red in the ratio of lines added to lines removed.
def diffbar($a; $d):
  if ($a + $d) == 0 then ""
  else ((($a / ($a + $d)) * 5) | round) as $g
    | _fg([86,211,100]) + ("▰" * $g) + _fg([248,81,73]) + ("▰" * (5 - $g)) + "\u001b[0m"
  end;

# ── Path abbreviation ─────────────────────────────────────────────────────────
# Everything but the last two components collapses to its initial, fish-style:
# ~/dev/gitlab.com/acme/platform/tooling/repo -> ~/d/g/a/p/tooling/repo
def shortp($home; $mode):
  (if . == $home then "~"
   elif startswith($home + "/") then "~" + .[($home | length):]
   else . end) as $p
  | if $mode != "short" then $p
    else ($p | split("/")) as $s | ($s | length) as $n
      | if $n <= 3 then $p
        else (([ $s[0:$n-2] | .[] | if (. == "" or . == "~") then . else .[0:1] end ]
               + $s[$n-2:]) | join("/"))
        end
    end;

. as $i
| ($i.context_window // {}) as $cw
| ($i.cost           // {}) as $co
# A window whose reset time has passed is a fresh window: the payload keeps the
# old figures until the next API call, which showed a spent quota as still spent.
| (($i.rate_limits // {})
   | with_entries(if (.value.resets_at // (now + 1)) <= now
                  then .value = {used_percentage: 0} else . end)) as $rl
| ($cw.context_window_size // 0)  as $csz
| ($cw.current_usage // {})       as $cu
| (if $cw.current_usage
   then (($cu.input_tokens // 0) + ($cu.cache_creation_input_tokens // 0)
         + ($cu.cache_read_input_tokens // 0))
   else ($cw.total_input_tokens // 0) end)  as $ut
# Derive the percentage from the very tokens we print, so gauge, percentage and
# count can never disagree. Fall back to the CLI value when there is no usage.
| (if ($cw.current_usage and $csz > 0)
   then (($ut / $csz * 100) | round | cl)
   else (($cw.used_percentage | cl) | round) end)  as $up
| ([$csz - $ut, 0] | max)                          as $rt
| (($rl.five_hour.used_percentage | cl) | round)   as $fp
| (($rl.seven_day.used_percentage | cl) | round)   as $wp
# Pace: how far into the window we already are. used% - elapsed% > 0 means the
# quota is draining faster than it refills, which is the number to steer on.
| (if $rl.five_hour.resets_at
   then (((18000 - ($rl.five_hour.resets_at - now)) / 18000 * 100) | cl | round)
   else null end)                                  as $fel
| (if $rl.seven_day.resets_at
   then (((604800 - ($rl.seven_day.resets_at - now)) / 604800 * 100) | cl | round)
   else null end)                                  as $wel
| (($co.total_duration_ms // 0) / 3600000)         as $hrs
| [
    q("cwd";     ($i.workspace.current_dir // $i.cwd)),
    qe("dir";    (($i.workspace.current_dir // $i.cwd) | shortp($home; $pathmode))),
    q("dirs";    (($i.workspace.added_dirs // []) | length)),
    # Parsed by Claude Code from the origin remote: tells GitHub from GitLab.
    q("rhost";   ($i.workspace.repo.host // "")),
    qe("wt";     ($i.worktree.name // $i.workspace.git_worktree)),
    qe("sess";   $i.session_name),
    q("sid";     $i.session_id),
    q("epoch";   (now | floor)),

    qe("model";  $i.model.display_name),
    qe("model_sh"; shimmer($i.model.display_name // ""; [121,192,255]; now | floor)),
    q("big";     (if $csz > 200000 then "1" else "" end)),
    q("fast";    (if $i.fast_mode then "1" else "" end)),
    qe("effort"; $i.effort.level),
    q("think";   (if $i.thinking.enabled == false then "" else "1" end)),
    qe("style";  (($i.output_style.name // "default") | if . == "default" then "" else . end)),
    qe("vim";    $i.vim.mode),
    qe("agent";  $i.agent.name),
    q("remote";  (if $i.remote then "1" else "" end)),
    # The open PR, or MR when kind is "mr": Claude Code looks it up itself.
    q("pr";      $i.pr.number),
    q("prkind";  $i.pr.kind),
    qe("prstate"; $i.pr.review_state),
    q("ver";     $i.version),

    q("has_ctx"; (if $csz > 0 then "1" else "" end)),
    q("up";      $up),
    q("rt_k";    ($rt | kfmt)),
    q("ctxbar";  bar($up; 12)),
    # Cache hit ratio: how much of the window we re-read instead of re-sending.
    # Low here after a long session means something keeps busting the prefix and
    # every turn is paying full input price.
    q("cache";   (if $ut > 0 then ((($cu.cache_read_input_tokens // 0) / $ut * 100) | round) else "" end)),

    q("cost";    (($co.total_cost_usd // 0) | if . > 0 then money else "" end)),
    q("burn";    (if $hrs > 0.05 then ((($co.total_cost_usd // 0) / $hrs) | money) else "" end)),
    q("add";     ($co.total_lines_added   // 0)),
    q("del";     ($co.total_lines_removed // 0)),
    q("diffbar"; diffbar($co.total_lines_added // 0; $co.total_lines_removed // 0)),
    q("dur";     (($co.total_duration_ms // 0) | if . >= 1000 then dur else "" end)),
    q("apidur";  (($co.total_api_duration_ms // 0) | if . >= 1000 then dur else "" end)),
    q("apims";   ($co.total_api_duration_ms // 0)),

    q("has5";    (if $rl.five_hour then "1" else "" end)),
    q("fp";      $fp),
    q("fbar";    bar($fp; 10)),
    q("fpace";   (if $fel == null then "" else ($fp - $fel) end)),
    q("f_at";    ($rl.five_hour.resets_at | clock)),

    q("has7";    (if $rl.seven_day then "1" else "" end)),
    q("wp";      $wp),
    q("wbar";    bar($wp; 10)),
    q("wpace";   (if $wel == null then "" else ($wp - $wel) end)),
    q("w_at";    ($rl.seven_day.resets_at | stamp))
  ] | join("\n")
