#!/usr/bin/env python3
"""Regenerate the two promotional images, from real renders of tools/demo.sh:

    uv run tools/showcase.py

docs/showcase.gif        1080x1080, for social posts read on a phone: the real
                         bar, Clawd in it, zoomed in on its left end so it
                         stays legible, then the rest of line 1 (model, what
                         Claude is doing, the PR and its CI) further along.
docs/social-preview.png  1280x640, for GitHub (Settings > Social preview).

Same requirements as tools/animate.py, whose capture it reuses.
"""
import subprocess
import tempfile
from pathlib import Path

from animate import DELAY, STORY, capture, pick
from screenshot import CHROME, FONT, ROOT, cells, cells_to_html

GIF = ROOT / "docs" / "showcase.gif"
PNG = ROOT / "docs" / "social-preview.png"
MODEL_BG = (25, 56, 90)    # the model segment: "further along" starts there
ZOOM_COLS = 41             # columns of the real bar the square shows, Clawd included
ADVANCE = 0.602            # Hack's advance width, in em

CSS = """
  html, body {{ margin: 0; padding: 0; background: transparent; }}
  body {{ display: inline-block; }}
  .bg {{ background: radial-gradient(ellipse at 50% 30%, #2a1e1a 0%, #141820 55%, #0d1117 100%);
         color: #c9d1d9; font-family: -apple-system, "Segoe UI", sans-serif; overflow: hidden;
         position: relative; box-sizing: border-box; }}
  pre {{ margin: 0; font-family: "{font}"; line-height: 1.17; }}
  .clawd {{ color: #d77757; }}
  .term {{ white-space: pre; font-family: "{font}"; line-height: 1.17; }}
  .brand {{ font-family: "{font}"; font-weight: bold; color: #e6edf3; }}
  .brand i {{ color: #d77757; font-style: normal; }}
  .muted {{ color: #8b949e; }}
  b.t {{ color: #d77757; }}
  .win {{ background: #0d1117; border-radius: 10px; overflow: hidden;
          box-shadow: 0 0 0 1px rgba(255,255,255,.09), 0 14px 34px rgba(0,0,0,.45); }}
  .bar {{ height: 24px; background: #1b2028; display: flex; align-items: center; gap: 6px;
          padding: 0 11px; font-size: 11px; color: #8b949e; }}
  .dot {{ width: 9px; height: 9px; border-radius: 50%; }}
  .fade {{ -webkit-mask-image: linear-gradient(to right, #000 82%, transparent); }}
"""

DOTS = ('<span class="dot" style="background:#ff5f57"></span>'
        '<span class="dot" style="background:#febc2e"></span>'
        '<span class="dot" style="background:#28c840"></span>')

# Rows are joined with no whitespace in between: .term is white-space: pre.
SQUARE = """<div class="bg" style="width:540px;height:540px;padding:24px;display:flex;flex-direction:column">
  <div class="brand" style="font-size:19px">claw<i>d</i>line</div>
  <div style="flex:1;display:flex;flex-direction:column;justify-content:center">
    <div style="text-align:center;font-size:26px">Clawd is <b class="t">{caption}</b></div>
    <div class="muted" style="text-align:center;font-size:14px;margin-top:6px">right in your Claude Code status bar</div>
    <div class="win" style="margin-top:28px">
      <div class="bar">{dots}<span style="flex:1;text-align:center;margin-right:40px">claude</span></div>
      <div class="term fade" style="font-size:18.5px;padding:18px 16px 20px">{zoom}</div>
    </div>
    <div class="muted" style="text-align:center;font-size:13.5px;margin-top:28px">… and further along the same bar</div>
    <div class="term" style="font-size:16px;margin-top:10px;text-align:center">{rest}</div>
  </div>
  <div class="muted" style="text-align:center;font-size:13px">github.com/mmurdockk/clawdline · Claude Code plugin · GitHub &amp; GitLab</div>
</div>"""

PREVIEW = """<div class="bg" style="width:1280px;height:640px;padding:0 72px;display:flex;flex-direction:column;justify-content:center">
  <div style="display:flex;align-items:center;gap:64px">
    <pre class="clawd" style="font-size:66px">{clawd}</pre>
    <div>
      <div class="brand" style="font-size:76px;line-height:1">claw<i>d</i>line</div>
      <div style="font-size:30px;margin-top:14px;color:#e6edf3">The status bar Claude Code deserves.</div>
      <div style="font-size:22px;margin-top:26px;line-height:1.6">
        🦀 <b>Clawd, animated</b> <span class="muted">thinks, walks, dances, dozes off</span><br>
        🔀 <b>GitHub &amp; GitLab</b> <span class="muted">PR / MR with live CI status</span><br>
        📊 <b>Quotas with pace</b> <span class="muted">context, 5h and 7d, cost</span>
      </div>
    </div>
  </div>
  <div class="term" style="font-size:{size}px;margin-top:48px;padding:16px 20px;background:#0d1117;
       border-radius:10px;box-shadow:0 0 0 1px rgba(255,255,255,.08)">{rows}</div>
</div>"""


def rows_of(ansi):
    """Demo output -> its 3 rows as cells, minus the invisible anchor in column 0."""
    return [cells(l)[1:] for l in ansi.split("\n") if l]


def clawd_of(rows):
    return [r[:12] for r in rows]             # the sprite and its z / sparkles gap


def rest_of_line1(rows):
    """Line 1 from the model segment on, its joining arrow dropped."""
    line1 = rows[0]
    i = next(k for k, c in enumerate(line1) if c[2] == MODEL_BG)
    return line1[i + 1:]


def html_rows(rows):
    return "".join("<div>%s</div>" % cells_to_html(r) for r in rows)


def shoot(html, width, height, out):
    page = "<!doctype html><meta charset='utf-8'><style>%s</style>%s" % (CSS.format(font=FONT), html)
    tmp = Path(tempfile.mkdtemp())
    (tmp / "p.html").write_text(page, encoding="utf-8")
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                    "--force-device-scale-factor=2", "--default-background-color=00000000",
                    "--window-size=%d,%d" % (width, height), "--screenshot=%s" % out,
                    (tmp / "p.html").as_uri()], check=True, capture_output=True)


def main():
    shots = capture()
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)

        # Social preview: Clawd standing, big, and in the bar it lives in.
        idle = rows_of(shots["idle"][0][1])
        bar = rows_of(shots["tool"][0][1])
        bar = [c[:12] + r[12:] for c, r in zip(clawd_of(idle), bar)]
        size = min(14, round(1092 / (max(len(r) for r in bar) * ADVANCE), 1))
        shoot(PREVIEW.format(clawd="\n".join(cells_to_html(r) for r in clawd_of(idle)),
                             size=size, rows=html_rows(bar)),
              1280, 640, tmp / "preview.png")
        subprocess.run(["magick", str(tmp / "preview.png"), "-resize", "1280x640!", str(PNG)], check=True)

        # Square GIF: one page per frame, stacked, shot once, cut apart.
        seq = []
        for state, caption, n, centre in STORY:
            seq += [(caption, a) for a in pick(shots[state], n, centre)]
        pages = []
        for caption, ansi in seq:
            rows = rows_of(ansi)
            pages.append(SQUARE.format(caption=caption, dots=DOTS,
                                       zoom=html_rows([r[:ZOOM_COLS] for r in rows]),
                                       rest=cells_to_html(rest_of_line1(rows))))
        shoot("".join(pages), 540, 540 * len(seq), tmp / "strip.png")
        subprocess.run(["magick", str(tmp / "strip.png"), "-crop", "1080x1080", "+repage",
                        str(tmp / "f-%03d.png")], check=True)
        parts = sorted(tmp.glob("f-*.png"))
        assert len(parts) == len(seq), (len(parts), len(seq))
        subprocess.run(["magick", "-delay", str(DELAY), "-loop", "0", *map(str, parts),
                        "-dither", "None", "+remap", "-layers", "Optimize", str(GIF)], check=True)
    print(GIF, "%d frames" % len(seq))
    print(PNG)


if __name__ == "__main__":
    main()
