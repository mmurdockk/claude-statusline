#!/usr/bin/env python3
"""Regenerate docs/clawd.gif: the status line through each of Clawd's moods.

    uv run tools/animate.py

Standard library only, plus the same Chrome / ImageMagick / Nerd Font as
tools/screenshot.py. Every frame is a real render: for twelve seconds, at each
tick, tools/demo.sh runs once per state, so each state's frames are
consecutive seconds of the genuine animation (walk cycle, blinks, the z
drifting off). The frames are then laid out on one page, photographed by a
single Chrome run, cut apart and assembled.
"""
import subprocess
import tempfile
import time
from pathlib import Path

from screenshot import CHROME, FONT, ROOT, SGR, TERM_BG, TERM_FG, ansi_to_html

OUT = ROOT / "docs" / "clawd.gif"
SECONDS = 12
FRAME_CSS_H = 124          # one window, in CSS pixels
DELAY = 50                 # per frame, in 1/100 s: twice the real speed

# (state, caption, how many consecutive seconds to keep, epoch to centre on)
STORY = [
    ("idle",   "idle",            6, lambda e: e % 12 == 5),   # the blink
    ("think",  "thinking…",       8, None),
    ("tool",   "running a tool",  8, None),
    ("party",  "just committed!", 8, None),
    ("asleep", "dozing off",      6, None),
]

PAGE = """<!doctype html><meta charset="utf-8">
<style>
  html, body {{ margin: 0; padding: 0; background: transparent; }}
  body {{ display: inline-block; }}
  .win {{ background: rgb{bg}; height: {h}px; overflow: hidden; }}
  .bar {{ height: 30px; background: #1b2028; display: flex; align-items: center;
          padding: 0 14px; gap: 8px; font: 13px -apple-system, "Segoe UI", sans-serif;
          color: #8b949e; }}
  .dot {{ width: 11px; height: 11px; border-radius: 50%; }}
  .title {{ flex: 1; text-align: center; margin-right: 54px; }}
  .title b {{ color: #d77757; font-weight: 600; }}
  .term {{ padding: 16px 22px; font-family: "{font}"; font-size: 15px;
           line-height: 1.17; color: rgb{fg}; }}
  .term div {{ white-space: pre; }}
</style>
{frames}
"""
FRAME = """<div class="win">
  <div class="bar">
    <span class="dot" style="background:#ff5f57"></span>
    <span class="dot" style="background:#febc2e"></span>
    <span class="dot" style="background:#28c840"></span>
    <span class="title">Clawd is <b>{caption}</b></span>
  </div>
  <div class="term">{lines}</div>
</div>"""


def capture():
    """{state: [(epoch, ansi), ...]} over SECONDS consecutive ticks."""
    shots = {s: [] for s, *_ in STORY}
    for _ in range(SECONDS):
        time.sleep(1.05 - time.time() % 1)        # just past the tick
        epoch = int(time.time())
        procs = {s: subprocess.Popen(["sh", str(ROOT / "tools" / "demo.sh"), s],
                                     stdout=subprocess.PIPE, text=True)
                 for s in shots}
        for s, p in procs.items():
            shots[s].append((epoch, p.communicate()[0]))
    return shots


def pick(frames, n, centre):
    start = 0
    if centre:
        hit = next((i for i, (e, _) in enumerate(frames) if centre(e)), n // 2)
        start = min(max(hit - n // 2, 0), len(frames) - n)
    return [ansi for _, ansi in frames[start:start + n]]


def main():
    shots = capture()
    seq = []
    for state, caption, n, centre in STORY:
        seq += [(caption, a) for a in pick(shots[state], n, centre)]

    width = max(len(SGR.sub("", l)) for _, a in seq for l in a.split("\n"))
    frames = "\n".join(
        FRAME.format(caption=c, lines="".join(
            "<div>%s</div>" % ansi_to_html(l) for l in a.split("\n") if l))
        for c, a in seq)
    page = PAGE.format(bg=TERM_BG, fg=TERM_FG, font=FONT, h=FRAME_CSS_H, frames=frames)

    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        (tmp / "anim.html").write_text(page, encoding="utf-8")
        subprocess.run([
            CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
            "--force-device-scale-factor=2", "--default-background-color=00000000",
            "--window-size=%d,%d" % (width * 10 + 100, FRAME_CSS_H * len(seq)),
            "--screenshot=%s" % (tmp / "strip.png"), (tmp / "anim.html").as_uri(),
        ], check=True, capture_output=True)
        # Cut the strip into frames (2x pixels), scale back down for crisp 1x
        # text, then one shared palette so nothing flickers between frames.
        subprocess.run(["magick", str(tmp / "strip.png"), "-trim", "+repage",
                        "-crop", "0x%d" % (FRAME_CSS_H * 2), "+repage",
                        str(tmp / "f-%03d.png")], check=True)
        parts = sorted(tmp.glob("f-*.png"))
        assert len(parts) == len(seq), (len(parts), len(seq))
        subprocess.run(["magick", "-delay", str(DELAY), "-loop", "0",
                        *map(str, parts), "-resize", "50%", "-dither", "None",
                        "+remap", "-layers", "Optimize", str(OUT)], check=True)
    print(OUT, "%d frames" % len(seq))


if __name__ == "__main__":
    main()
