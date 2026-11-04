#!/usr/bin/env python3
"""Regenerate the two promotional images, from real renders of tools/demo.sh:

    uv run tools/showcase.py

docs/showcase.gif        1080x1080, for social posts read on a phone: Clawd big,
                         his mood as a caption, and line 1 of the bar wrapped
                         onto two rows so it stays legible.
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
MODEL_BG = (25, 56, 90)    # the model segment: line 1 wraps just before it

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
"""

SQUARE = """<div class="bg" style="width:540px;height:540px;padding:26px 24px">
  <div class="brand" style="font-size:19px">claw<i>d</i>line</div>
  <div style="display:flex;justify-content:center;margin-top:46px">
    <pre class="clawd" style="font-size:64px">{clawd}</pre>
  </div>
  <div style="text-align:center;font-size:21px;margin-top:22px">Clawd is <b class="t">{caption}</b></div>
  <div class="term" style="font-size:15.5px;margin-top:40px;display:flex;flex-direction:column;align-items:center;gap:8px"><div>{row_a}</div><div>{row_b}</div></div>
  <div class="muted" style="position:absolute;bottom:20px;left:0;right:0;text-align:center;font-size:13px">
    github.com/mmurdockk/clawdline · Claude Code plugin · GitHub &amp; GitLab
  </div>
</div>"""

PREVIEW = """<div class="bg" style="width:1280px;height:640px;padding:0 72px;display:flex;flex-direction:column;justify-content:center">
  <div style="display:flex;align-items:center;gap:64px">
    <pre class="clawd" style="font-size:74px">{clawd}</pre>
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
  <!-- no whitespace between the rows: .term is white-space: pre -->
  <div class="term" style="font-size:14px;margin-top:56px;padding:18px 22px;background:#0d1117;
       border-radius:10px;box-shadow:0 0 0 1px rgba(255,255,255,.08)"><div>{l1}</div><div>{l2}</div><div>{l3}</div></div>
</div>"""


def split(ansi):
    """Demo output -> (Clawd's 3 rows incl. the z / sparkles gap, line 1, 2, 3)."""
    rows = [cells(l) for l in ansi.split("\n") if l]
    clawd = [r[1:13] for r in rows]           # column 0 is the anchor glyph
    return clawd, rows[0][13:], rows[1][14:], rows[2][14:]


def wrap(line1):
    """Line 1 as two rows: directory and branch, then model onwards. The arrow
    joining them closes row A instead, and row B starts on its own padding."""
    i = next(k for k, c in enumerate(line1) if c[2] == MODEL_BG)
    close = [("", line1[i][1], None, False, False)]
    return line1[:i] + close, line1[i + 1:]


def clawd_html(rows):
    return "\n".join(cells_to_html(r) for r in rows)


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

        # Social preview: Clawd standing, the bar mid-tool with a PR and CI.
        clawd = split(shots["idle"][0][1])[0]
        _, l1, l2, l3 = split(shots["tool"][0][1])
        shoot(PREVIEW.format(clawd=clawd_html(clawd), l1=cells_to_html(l1),
                             l2=cells_to_html(l2), l3=cells_to_html(l3)),
              1280, 640, tmp / "preview.png")
        subprocess.run(["magick", str(tmp / "preview.png"), "-resize", "1280x640!", str(PNG)], check=True)

        # Square GIF: one page per frame, stacked, shot once, cut apart.
        seq = []
        for state, caption, n, centre in STORY:
            seq += [(caption, a) for a in pick(shots[state], n, centre)]
        pages = []
        for caption, ansi in seq:
            clawd, l1, _, _ = split(ansi)
            a, b = wrap(l1)
            pages.append(SQUARE.format(clawd=clawd_html(clawd), caption=caption,
                                       row_a=cells_to_html(a), row_b=cells_to_html(b)))
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
