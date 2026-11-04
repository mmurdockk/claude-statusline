#!/usr/bin/env python3
"""Regenerate docs/screenshot.png from tools/demo.sh.

    uv run tools/screenshot.py [idle|tool|think]     (default: idle)

Standard library only. Turns the demo's ANSI output into HTML laid out on a
character grid, then has headless Chrome photograph it on a transparent page,
so the window and its shadow sit well on both light and dark READMEs.
Needs Google Chrome, a Nerd Font installed (Hack Nerd Font Mono by default,
override with SB_FONT), and ImageMagick to trim the margins.
"""
import html
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "screenshot.png"
FONT = os.environ.get("SB_FONT", "Hack Nerd Font Mono")
CHROME = os.environ.get(
    "CHROME", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")

TERM_BG = (13, 17, 23)
TERM_FG = (201, 209, 217)
SGR = re.compile(r"\x1b\[([0-9;]*)m")


def mix(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def cells(line):
    """One (char, fg, bg, bold, dim) per visible character of an ANSI line, so
    a render can be sliced by terminal column."""
    fg = bg = None
    bold = dim = False
    out, pos = [], 0

    def emit(text):
        out.extend((ch, fg, bg, bold, dim) for ch in text)

    for m in SGR.finditer(line):
        emit(line[pos:m.start()])
        pos = m.end()
        codes = [int(c) if c else 0 for c in m.group(1).split(";")]
        i = 0
        while i < len(codes):
            c = codes[i]
            if c == 0:
                fg = bg = None; bold = dim = False
            elif c == 1:
                bold = True
            elif c == 2:
                dim = True
            elif c == 22:
                bold = dim = False
            elif c == 39:
                fg = None
            elif c == 49:
                bg = None
            elif c in (38, 48) and i + 4 < len(codes) and codes[i + 1] == 2:
                rgb = tuple(codes[i + 2:i + 5])
                if c == 38:
                    fg = rgb
                else:
                    bg = rgb
                i += 4
            i += 1
    emit(line[pos:])
    return out


def cells_to_html(cs):
    out = []
    for (ch, fg, bg, bold, dim) in cs:
        f = fg or TERM_FG
        if dim:  # a terminal dims the ink, not the ground
            f = mix(f, bg or TERM_BG, 0.45)
        style = "color:rgb(%d,%d,%d)" % f
        if bg:
            style += ";background:rgb(%d,%d,%d)" % bg
        if bold:
            style += ";font-weight:bold"
        span = '<span style="%s">' % style
        if out and out[-1][0] == span:
            out[-1][1].append(ch)
        else:
            out.append((span, [ch]))
    return "".join("%s%s</span>" % (s, html.escape("".join(t))) for s, t in out)


def ansi_to_html(line):
    return cells_to_html(cells(line))


PAGE = """<!doctype html><meta charset="utf-8">
<style>
  html, body {{ margin: 0; background: transparent; }}
  body {{ padding: 48px; display: inline-block; }}
  .win {{ background: rgb{bg}; border-radius: 12px; overflow: hidden;
          box-shadow: 0 0 0 1px rgba(255,255,255,.08), 0 22px 48px rgba(0,0,0,.45); }}
  .bar {{ height: 34px; background: #1b2028; display: flex; align-items: center;
          padding: 0 14px; gap: 8px; font: 13px -apple-system, "Segoe UI", sans-serif;
          color: #8b949e; }}
  .dot {{ width: 12px; height: 12px; border-radius: 50%; }}
  .title {{ flex: 1; text-align: center; margin-right: 60px; }}
  .term {{ padding: 18px 22px 20px; font-family: "{font}"; font-size: 15px;
           line-height: 1.17; color: rgb{fg}; }}
  .term div {{ white-space: pre; }}
  .muted {{ color: #6e7681; }}
  .rule {{ color: #30363d; }}
</style>
<div class="win">
  <div class="bar">
    <span class="dot" style="background:#ff5f57"></span>
    <span class="dot" style="background:#febc2e"></span>
    <span class="dot" style="background:#28c840"></span>
    <span class="title">claude — ~/dev/github.com/my-org/my-app</span>
  </div>
  <div class="term">
    <div class="rule">{rule}</div>
    <div><span style="color:#d77757">&gt;</span> <span class="muted">Try "add a retry to the token refresh"</span></div>
    <div class="rule">{rule}</div>
    <div> </div>
{lines}
  </div>
</div>
"""


def main():
    for need in (CHROME, "magick"):
        if not shutil.which(need) and not Path(need).exists():
            sys.exit("missing: %s" % need)

    state = sys.argv[1] if len(sys.argv) > 1 else "idle"
    ansi = subprocess.run(["sh", str(ROOT / "tools" / "demo.sh"), state],
                          check=True, capture_output=True, text=True).stdout
    lines = [l for l in ansi.split("\n") if l]
    width = max(len(SGR.sub("", l)) for l in lines)
    body = "\n".join("    <div>%s</div>" % ansi_to_html(l) for l in lines)
    page = PAGE.format(bg=TERM_BG, fg=TERM_FG, font=FONT, rule="─" * width,
                       lines=body)

    with tempfile.TemporaryDirectory() as tmp:
        src, raw = Path(tmp) / "shot.html", Path(tmp) / "raw.png"
        src.write_text(page, encoding="utf-8")
        subprocess.run([
            CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars",
            "--force-device-scale-factor=2", "--default-background-color=00000000",
            "--window-size=%d,600" % (width * 10 + 200),
            "--screenshot=%s" % raw, src.as_uri(),
        ], check=True, capture_output=True)
        OUT.parent.mkdir(exist_ok=True)
        # Trim to the shadow, then give it back an even margin.
        subprocess.run(["magick", str(raw), "-trim", "+repage",
                        "-bordercolor", "none", "-border", "24", str(OUT)],
                       check=True)
    print(OUT)


if __name__ == "__main__":
    main()
