"""The animated 'Three repos, two folders' diagram in the README (docs/assets/repos.svg) - its source.

Run `python3 docs/assets/repos.py` to regenerate repos.svg after editing; `--check` verifies the
committed SVG is current (tools/tests runs it). It shares flow.py's look and building blocks: plain SVG
+ SMIL animation on one looping clock, no scripts and no web fonts (GitHub shows README images through
<img>).

Storyboard (16 s loop): you clone Chisel under your port's name; chisel-init turns the clone into your
own workbench repo, keeping Chisel as `upstream`; it imports the original code, pinned, into source/;
it creates the product repo and checks it out beside the workbench; then reviewed code lands in the
product, /port-sync-with-base brings Chisel's updates in and /port-contribute-to-base sends
improvements back.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from flow import DARK as P, MONO, SANS, Clock, Route, arrow, card, t  # noqa: E402

W, H = 1000, 442
L = 16.0
C = Clock(L)
RESET = 15.3
GHOST = 0.22

# ---------- layout -----------------------------------------------------------------------------------
CW, CY, CH = 190, 64, 62            # GitHub cards: width, top, height
SRC, BASE, WB, PROD = 28, 244, 554, 770
DY, DH = 266, 96                    # disk row: top, height
PF0, PF1 = BASE, WB + CW            # port-foo/ folder, under the base and the workbench
PD0, PD1 = PROD, PROD + CW          # foo-c/ folder, under the product
CHIP_Y = DY + 58
CAP_Y = 384                         # caption bar top
MID = (CY + CH + DY) / 2 + 2           # link labels, between the rows


def cx(x):
    return x + CW / 2


def glow(x, y, w, h, col, t_on, t_off=RESET, rx=10):
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{col}" fill-opacity="0.07" '
            f'stroke="{col}" stroke-width="1.6" filter="url(#glow)" opacity="0">{C.fade(t_on, t_off)}</rect>')


def appear(inner, t_on):
    """A group shown as a ghost until t_on, then in full, back to a ghost at the reset."""
    return (f'<g opacity="{GHOST}">{C.anim("opacity", [(0, GHOST), (t_on, GHOST), (t_on + 0.3, 1), (RESET, 1), (RESET + 0.4, GHOST)])}'
            f'{inner}</g>')


def shown(inner, t_on, t_off=RESET):
    return f'<g opacity="0">{C.fade(t_on, t_off)}{inner}</g>'


def token(route, t0, t1, col, r=5.5):
    """A glowing dot along route from t0 to t1, hidden otherwise."""
    vis = (f'<animate attributeName="opacity" dur="{L:g}s" repeatCount="indefinite" calcMode="discrete" '
           f'keyTimes="0;{t0 / L:.5f};{t1 / L:.5f}" values="0;1;0"/>')
    keys = [(0, 0), (t0, 0), (t1, 1)]
    return (f'<g opacity="0">{vis}<circle r="{r}" fill="{col}" filter="url(#glow)"/>'
            f'{C.motion(route.path(), keys)}</g>')


def chip(x, y, label, note, col):
    w = 9 + 7.1 * len(label)
    return (f'<rect x="{x}" y="{y}" width="{w:.0f}" height="22" rx="6" fill="#0d1117" stroke="{P["border"]}"/>'
            + t(x + 8, y + 15, label, 11.5, col, 700, family=MONO)
            + t(x + w + 6, y + 15, note, 11, P["muted"])), w


def build():
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" '
         f'aria-label="Three repositories, two folders: you clone Chisel as your port\'s folder; chisel-init '
         f'turns it into your own workbench repository, keeping Chisel as upstream, imports the original '
         f'code into source/ and creates a separate product repository checked out beside it">']
    o.append(f"""<defs>
<filter id="glow" x="-60%" y="-60%" width="220%" height="220%"><feGaussianBlur stdDeviation="3" result="b"/>
<feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
<pattern id="dots" width="22" height="22" patternUnits="userSpaceOnUse"><circle cx="1" cy="1" r="1" fill="#21262d"/></pattern>
<marker id="tip" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
<path d="M1 1 L8 5 L1 9" fill="none" stroke="{P['faint']}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></marker>
</defs>""")
    o.append(f'<rect x="0.5" y="0.5" width="{W - 1}" height="{H - 1}" rx="16" fill="{P["bg"]}" stroke="{P["border"]}"/>')
    o.append(f'<rect x="1" y="1" width="{W - 2}" height="{H - 2}" rx="16" fill="url(#dots)"/>')

    # ---- row labels
    o.append(t(28, 44, "ON GITHUB", 10.5, P["faint"], 700, ls="0.1em"))
    o.append(t(28, DY - 14, "ON YOUR DISK", 10.5, P["faint"], 700, ls="0.1em"))

    # ---- GitHub row
    o.append(card(SRC, CY, CW, CH, "THE ORIGINAL CODE", P["grey"], "its own repository", "imported once, pinned"))
    o.append(card(BASE, CY, CW, CH, "CHISEL  ·  THE BASE", P["purple"], "ecmwf/chisel", "agents · commands · checks"))
    o.append(appear(card(WB, CY, CW, CH, "YOUR WORKBENCH", P["blue"], "you/port-foo", "the port's record"), 4.2))
    o.append(appear(card(PROD, CY, CW, CH, "YOUR PRODUCT", P["green"], "you/foo-c", "the translated code only"), 8.6))

    # ---- disk row
    pf = (f'<rect x="{PF0}" y="{DY}" width="{PF1 - PF0}" height="{DH}" rx="10" fill="{P["card"]}" stroke="{P["border"]}"/>'
          + t(PF0 + 14, DY + 24, "port-foo/", 14, P["text"], 700, family=MONO)
          + t(PF0 + 104, DY + 24, "the workbench  ·  open opencode here", 11.5, P["muted"]))
    x = PF0 + 14
    chips = []
    for label, note, col in (("source/", "pinned", P["grey"]), ("port/", "charter · progress · lessons", P["blue"]),
                             ("tools/", "checks", P["purple"])):
        s, w = chip(x, CHIP_Y, label, note, col)
        chips.append((x, w))
        pf += s
        x += w + 6 + 5.3 * len(note) + 24
    o.append(appear(pf, 1.6))
    pd = (f'<rect x="{PD0}" y="{DY}" width="{PD1 - PD0}" height="{DH}" rx="10" fill="{P["card"]}" stroke="{P["border"]}"/>'
          + t(PD0 + 14, DY + 24, "foo-c/", 14, P["text"], 700, family=MONO)
          + t(PD0 + 14, DY + 43, "the product, beside it", 11.5, P["muted"]))
    s, _ = chip(PD0 + 14, CHIP_Y, "src/ tests/", "", P["green"])
    pd += s
    o.append(appear(pd, 9.8))

    # ---- links between the rows
    base_down = Route((cx(BASE), CY + CH)).line((cx(BASE), DY - 2), "end")
    o.append(arrow(base_down.path()))
    o.append(shown(t(cx(BASE) + 8, MID, "git clone", 11.5, P["muted"], 600, family=MONO), 0.6, 3.6))
    o.append(shown(t(cx(BASE) + 8, MID, "upstream", 11.5, P["purple"], 600, family=MONO), 3.8)
             + shown(t(cx(BASE) + 8, MID + 16, "updates come from here", 10.5, P["faint"]), 3.8))
    wb_up = Route((cx(WB), DY)).line((cx(WB), CY + CH + 2), "end")
    o.append(appear(arrow(f"M{cx(WB)} {DY - 2} L{cx(WB)} {CY + CH + 2}", extra='marker-start="url(#tip)"'), 4.2))
    o.append(shown(t(cx(WB) + 8, MID, "origin", 11.5, P["blue"], 600, family=MONO), 4.2))
    o.append(shown(t(cx(WB) + 8, MID + 16, "your repo", 10.5, P["faint"]), 4.2))
    pr_down = Route((cx(PROD), CY + CH)).line((cx(PROD), DY - 2), "end")
    o.append(appear(arrow(f"M{cx(PROD)} {CY + CH + 2} L{cx(PROD)} {DY - 2}", extra='marker-start="url(#tip)"'), 9.0))
    o.append(shown(t(cx(PROD) + 8, MID, "origin", 11.5, P["green"], 600, family=MONO), 9.8))
    o.append(shown(t(cx(PROD) + 8, MID + 16, "its own repo", 10.5, P["faint"]), 9.8))
    sx = SRC + CW - 24
    src_in = Route((sx, CY + CH)).curve((sx, CHIP_Y + 11), (PF0 - 30, CHIP_Y + 11), (PF0 - 2, CHIP_Y + 11), "end")
    o.append(arrow(src_in.path(), dash="3 4"))
    o.append(shown(t(sx + 10, CY + CH + 26, "imported", 11.5, P["muted"], 600, family=MONO)
                   + t(sx + 10, CY + CH + 42, "into source/", 11.5, P["muted"], 600, family=MONO), 6.2))
    land = Route((PF1, DY + DH / 2)).line((PD0 - 2, DY + DH / 2), "end")
    o.append(appear(arrow(land.path()), 9.8))

    # ---- sync and contribute, between the base and the workbench
    g0, g1, gm = BASE + CW, WB, (BASE + CW + WB) / 2
    sync = Route((g0 + 2, CY + 22)).line((g1 - 2, CY + 22), "end")
    back = Route((g1 - 2, CY + 44)).line((g0 + 2, CY + 44), "end")
    o.append(shown(arrow(sync.path(), dash="3 4") + arrow(back.path(), dash="3 4")
                   + t(gm, CY + 14, "sync", 11, P["purple"], 600, "middle", family=MONO)
                   + t(gm, CY + 60, "contribute", 11, P["cyan"], 600, "middle", family=MONO),
                   10.8))

    # ---- motion
    o.append(token(base_down, 0.8, 1.6, P["purple"]))
    o.append(glow(PF0, DY, PF1 - PF0, DH, P["blue"], 1.6, 3.0))
    o.append(token(wb_up, 3.4, 4.2, P["blue"]))
    o.append(glow(WB, CY, CW, CH, P["blue"], 4.2, 5.6))
    o.append(token(src_in, 6.2, 7.2, P["grey"]))
    cx0, cw0 = chips[0]
    o.append(glow(cx0 - 3, CHIP_Y - 3, cw0 + 6, 28, P["grey"], 7.2, 8.4, rx=8))
    o.append(glow(PROD, CY, CW, CH, P["green"], 8.6, 9.6))
    o.append(token(pr_down, 9.0, 9.8, P["green"]))
    o.append(glow(PD0, DY, PD1 - PD0, DH, P["green"], 9.8, 10.8))
    o.append(token(land, 11.0, 11.6, P["green"]))
    o.append(token(Route((cx(PROD), DY)).line((cx(PROD), CY + CH + 2), "end"), 11.7, 12.3, P["green"]))
    o.append(token(sync, 12.6, 13.4, P["purple"]))
    o.append(token(back, 13.7, 14.5, P["cyan"]))

    # ---- caption bar: one line per step
    o.append(f'<rect x="28" y="{CAP_Y}" width="{W - 56}" height="40" rx="10" fill="{P["card"]}" stroke="{P["border"]}"/>')
    steps = [
        (0.3, 3.2, "1", "git clone https://github.com/ecmwf/chisel.git port-foo", True),
        (3.2, 5.8, "2", "chisel-init turns the clone into your workbench repo; Chisel stays as upstream", False),
        (5.8, 8.4, "3", "it imports the original code into source/, pinned to one commit", False),
        (8.4, 10.8, "4", "it creates your product repo and checks it out beside the workbench", False),
        (10.8, RESET, "→", "then: reviewed code lands in foo-c/ · /port-sync-with-base brings Chisel's updates · /port-contribute-to-base sends improvements back", False),
    ]
    for t_on, t_off, n, text, mono in steps:
        o.append(f'<g opacity="0">{C.fade(t_on, t_off - 0.25, 0.2)}'
                 f'<circle cx="52" cy="{CAP_Y + 20}" r="10" fill="{P["orange"]}"/>'
                 + t(52, CAP_Y + 24.5, n, 11.5, P["bg"], 800, "middle")
                 + t(72, CAP_Y + 25, text, 12.5, P["text"], 500, family=MONO if mono else SANS) + "</g>")
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
