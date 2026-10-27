"""The animated 'Setting up a port' diagram in the README (docs/assets/repos.svg) - its source.

Run `python3 docs/assets/repos.py` to regenerate repos.svg after editing; `--check` verifies the
committed SVG is current (tools/tests runs it). It shares flow.py's look and building blocks: plain SVG
+ SMIL animation on one looping clock, no scripts and no web fonts (GitHub shows README images through
<img>).

Storyboard (19.5 s loop), told by a terminal on the left: `git clone ... port-foo` makes port-foo/, a
copy of Chisel; `chisel-init` turns it into your workbench repo (new-instance.sh), imports the original
code into source/foo/ (import-source.sh), creates your product repo and clones it as foo-c/ BESIDE
port-foo/, not inside it (new-product.sh), and chooses the models; the first `/port-sprint-start`
commits and pushes the setup. On the right, the repositories on GitHub and the folders on your disk
appear as each step makes them.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from flow import DARK as P, MONO, Clock, card, t  # noqa: E402

W, H = 1000, 424
L = 19.5
C = Clock(L)
RESET = 18.4
GHOST = 0.22
KEEP = 'xml:space="preserve"'           # terminal and tree text keep their spaces (indents, tree art)

# ---------- layout -----------------------------------------------------------------------------------
TX, TY, TW, TH = 28, 24, 452, 330   # terminal panel
LINE0, LH = 80, 23                  # first terminal line, line height
RX = 500                            # right column
GW, GH = 230, 62                    # GitHub cards
G1, G2 = 56, 128                    # GitHub card rows (top)
TREE_Y, TL = 246, 21                # first tree line, tree line height
NOTE_X = RX + 172                   # tree notes column
# Each step's time: when its terminal line appears and what it makes appears.
T_CLONE, T_CD, T_INIT = 0.6, 2.6, 3.4
T_FLIP, T_SRC, T_PROD, T_MODELS = 4.4, 6.4, 8.4, 10.4
T_OC, T_START, T_PUSH = 11.8, 12.8, 13.8


def glow(x, y, w, h, col, t_on, t_off=RESET, rx=10):
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{col}" fill-opacity="0.07" '
            f'stroke="{col}" stroke-width="1.6" filter="url(#glow)" opacity="0">{C.fade(t_on, t_off)}</rect>')


def appear(inner, t_on):
    """Shown as a ghost until t_on, then in full, back to a ghost at the reset."""
    return (f'<g opacity="{GHOST}">{C.anim("opacity", [(0, GHOST), (t_on, GHOST), (t_on + 0.3, 1), (RESET, 1), (RESET + 0.4, GHOST)])}'
            f'{inner}</g>')


def shown(inner, t_on, t_off=RESET):
    return f'<g opacity="0">{C.fade(t_on, t_off)}{inner}</g>'


def badge(x, y, text, col, t_on):
    w = 16 + 6.6 * len(text)
    return shown(f'<rect x="{x - w}" y="{y - 11}" width="{w:.0f}" height="20" rx="10" fill="{P["bg"]}" stroke="{col}"/>'
                 + t(x - w / 2, y + 3, text, 11, col, 700, "middle"), t_on)


def build():
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" '
         f'aria-label="Setting up a port: git clone Chisel as port-foo, then python3 tools/chisel-init.py turns '
         f'it into your workbench repo, imports the original code into source/foo/, creates your product repo '
         f'and clones it as foo-c/ beside port-foo/, not inside it, and chooses the models; the first '
         f'/port-sprint-start commits and pushes the setup">']
    o.append(f"""<defs>
<filter id="glow" x="-60%" y="-60%" width="220%" height="220%"><feGaussianBlur stdDeviation="3" result="b"/>
<feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
<pattern id="dots" width="22" height="22" patternUnits="userSpaceOnUse"><circle cx="1" cy="1" r="1" fill="#21262d"/></pattern>
</defs>""")
    o.append(f'<rect x="0.5" y="0.5" width="{W - 1}" height="{H - 1}" rx="16" fill="{P["bg"]}" stroke="{P["border"]}"/>')
    o.append(f'<rect x="1" y="1" width="{W - 2}" height="{H - 2}" rx="16" fill="url(#dots)"/>')

    # ---- the terminal
    o.append(f'<rect x="{TX}" y="{TY}" width="{TW}" height="{TH}" rx="12" fill="#010409" stroke="{P["border"]}"/>')
    for i, col in enumerate(("#f85149", "#d29922", "#3fb950")):
        o.append(f'<circle cx="{TX + 18 + 14 * i}" cy="{TY + 18}" r="4.5" fill="{col}" opacity="0.7"/>')
    o.append(t(TX + TW / 2, TY + 22, "terminal  ·  ~/work/", 11, P["faint"], 600, "middle"))
    o.append(f'<line x1="{TX}" y1="{TY + 34}" x2="{TX + TW}" y2="{TY + 34}" stroke="{P["border"]}"/>')
    lines = [  # (time, text, colour, weight, script it runs)
        (T_CLONE, "$ git clone https://github.com/ecmwf/chisel.git port-foo", P["text"], 600, ""),
        (T_CD, "$ cd port-foo", P["text"], 600, ""),
        (T_INIT, "$ python3 tools/chisel-init.py", P["text"], 600, ""),
        (T_FLIP, "  ✓ your workbench repo: you/port-foo", P["blue"], 500, "new-instance.sh"),
        (T_SRC, "  ✓ the original code → source/foo/", P["muted"], 500, "import-source.sh"),
        (T_PROD, "  ✓ your product repo: you/foo-c", P["green"], 500, "new-product.sh"),
        (T_PROD, "    cloned as ../foo-c/, beside port-foo/", P["green"], 500, ""),
        (T_MODELS, "  ✓ a model for each agent", P["muted"], 500, ""),
        (T_OC, "$ opencode", P["text"], 600, ""),
        (T_START, "> /port-sprint-start", P["orange"], 600, ""),
        (T_PUSH, "  ✓ commits and pushes the setup to you/port-foo", P["blue"], 500, ""),
    ]
    for k, (tm, text, col, wt, script) in enumerate(lines):
        y = LINE0 + k * LH
        inner = t(TX + 16, y, text, 12, col, wt, family=MONO, extra=KEEP)
        if script:
            inner += t(TX + TW - 14, y, script, 11, P["faint"], 400, "end", family=MONO)
        o.append(shown(inner, tm))
    # a blinking cursor below the last line shown
    at = {0: LINE0 - 12}
    for k, (tm, *_r) in enumerate(lines):
        at[tm] = LINE0 + (k + 1) * LH - 12      # lines shown together: the cursor goes below the last
    cur_y = sorted(at.items())
    o.append(f'<rect x="{TX + 16}" y="{LINE0 - 12}" width="7" height="14" fill="{P["muted"]}">'
             f'{C.step("y", cur_y + [(RESET + 0.4, LINE0 - 12)])}'
             f'{C.step("opacity", [(i * 0.5, (i + 1) % 2) for i in range(int(L * 2))])}</rect>')

    # ---- the repositories on GitHub
    o.append(t(RX, 44, "ON GITHUB", 10.5, P["faint"], 700, ls="0.1em"))
    o.append(card(RX, G1, GW, GH, "CHISEL", P["purple"], "ecmwf/chisel", "the method you clone"))
    o.append(card(RX + GW + 12, G1, GW, GH, "THE ORIGINAL CODE", P["grey"], "org/foo", "the program you port"))
    o.append(appear(card(RX, G2, GW, GH, "YOUR WORKBENCH", P["blue"], "you/port-foo", "the port's record"), T_FLIP))
    o.append(appear(card(RX + GW + 12, G2, GW, GH, "YOUR PRODUCT", P["green"], "you/foo-c", "the translated code"), T_PROD))
    o.append(glow(RX, G2, GW, GH, P["blue"], T_FLIP, T_FLIP + 1.4))
    o.append(glow(RX + GW + 12, G1, GW, GH, P["grey"], T_SRC, T_SRC + 1.4))
    o.append(glow(RX + GW + 12, G2, GW, GH, P["green"], T_PROD, T_PROD + 1.6))
    o.append(glow(RX, G2, GW, GH, P["blue"], T_PUSH, T_PUSH + 1.6))
    o.append(badge(RX + GW - 12, G2 + 35, "✓ setup pushed", P["blue"], T_PUSH))

    # ---- the folders on your disk
    o.append(t(RX, TREE_Y - 32, "ON YOUR DISK", 10.5, P["faint"], 700, ls="0.1em"))
    o.append(f'<rect x="{RX}" y="{TREE_Y - 22}" width="{2 * GW + 12}" height="{7 * TL + 20}" rx="10" '
             f'fill="{P["card"]}" stroke="{P["border"]}"/>')

    def row(k, tree, col, note, note_col, t_on, weight=600):
        y = TREE_Y + k * TL
        s = t(RX + 16, y, tree, 12.5, col, weight, family=MONO, extra=KEEP)
        if note:
            s += t(NOTE_X, y, note, 11.5, note_col)
        return s if t_on is None else shown(s, t_on)

    o.append(row(0, "~/work/", P["muted"], "", None, None))
    o.append(shown(t(RX + 16, TREE_Y + TL, "├── port-foo/", 12.5, P["text"], 700, family=MONO, extra=KEEP), T_CLONE + 0.8))
    o.append(shown(t(NOTE_X, TREE_Y + TL, "a copy of Chisel · origin ecmwf/chisel", 11.5, P["purple"]),
                   T_CLONE + 0.8, T_FLIP))
    o.append(shown(t(NOTE_X, TREE_Y + TL, "your workbench · origin you/port-foo", 11.5, P["blue"]), T_FLIP))
    o.append(row(2, "│   ├── source/foo/", P["muted"], "the original code, pinned", P["muted"], T_SRC))
    o.append(row(3, "│   ├── port/", P["muted"], "charter · progress · lessons", P["muted"], T_CLONE + 0.8))
    o.append(row(4, "│   └── tools/", P["muted"], "Chisel's checks and scripts", P["muted"], T_CLONE + 0.8))
    o.append(row(5, "└── foo-c/", P["green"], "your product · origin you/foo-c", P["green"], T_PROD, 700))
    o.append(row(6, "", P["green"], "beside port-foo/, not inside it", P["muted"], T_PROD))
    o.append(glow(RX + 6, TREE_Y + TL - 15, 2 * GW, TL, P["blue"], T_FLIP, T_FLIP + 1.4, rx=6))
    o.append(glow(RX + 6, TREE_Y + 2 * TL - 15, 2 * GW, TL, P["grey"], T_SRC, T_SRC + 1.4, rx=6))
    o.append(glow(RX + 6, TREE_Y + 5 * TL - 15, 2 * GW, 2 * TL, P["green"], T_PROD, T_PROD + 1.6, rx=6))

    # ---- joining a port
    o.append(t(TX, H - 16, "Joining a port someone started? Run the same chisel-init from any clone of Chisel and choose "
               "“join”: it clones their workbench and product side by side.", 11.5, P["muted"]))
    o.append("</svg>")
    return "\n".join(o)


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    target = os.path.join(here, "repos.svg")
    svg = build() + "\n"
    if sys.argv[1:] == ["--check"]:
        if open(target, encoding="utf-8").read() != svg:
            sys.exit("repos.svg is stale - regenerate it: python3 docs/assets/repos.py")
        print("repos.svg is current")
    else:
        open(target, "w", encoding="utf-8").write(svg)
        print("wrote", target)
