"""The animated 'How a port flows' diagram in the README (docs/assets/flow.svg) - its source.

Run `python3 docs/assets/flow.py` to regenerate flow.svg after editing; `--check` verifies the committed
SVG is current (tools/tests runs it). The SVG is plain SVG + SMIL animation: no scripts and no web fonts,
because GitHub shows README images through <img>, where neither is available. Every animation shares one
looping clock (Clock below), so the storyboard - written in seconds - stays in sync forever.

Storyboard (15 s loop): the foundations light up; Ptah-Orchestrator fans three units out to parallel
Kha-Workers; two pass the R1 proof, one fails - its lesson flies into the workbench memory and it loops
back for rework; all three pass an independent review; Seshat-Integrator integrates them into the
product; the milestone is tagged.
"""
import math
import os
import sys
from xml.sax.saxutils import escape

SANS = "-apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif"
MONO = "ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Consolas, 'Liberation Mono', 'DejaVu Sans Mono', monospace"

# GitHub Primer colours, so the diagram reads as native in either theme.
DARK = dict(bg="#0d1117", card="#161b22", card2="#1c2128", border="#30363d", text="#e6edf3",
            muted="#8b949e", faint="#6e7681", grey="#8b949e", purple="#bc8cff", blue="#58a6ff",
            orange="#f0883e", green="#3fb950", red="#f85149", cyan="#39c5cf", yellow="#d29922")


def t(x, y, s, size=13, fill="#fff", weight=400, anchor="start", family=SANS, ls=None, extra=""):
    lsp = f' letter-spacing="{ls}"' if ls is not None else ""
    return (f'<text x="{x:g}" y="{y:g}" font-family="{family}" font-size="{size}" font-weight="{weight}" '
            f'fill="{fill}" text-anchor="{anchor}"{lsp} {extra}>{escape(s)}</text>')


class Clock:
    """SMIL animations on one looping clock: every element repeats with the same period, so a
    storyboard written in seconds stays in sync forever."""

    def __init__(self, period):
        self.L = float(period)

    def _norm(self, keys):
        keys = sorted(keys, key=lambda k: k[0])
        if keys[0][0] > 0:
            keys = [(0.0, keys[0][1])] + keys
        if keys[-1][0] < self.L:
            keys = keys + [(self.L, keys[-1][1])]
        times = ";".join(f"{min(max(k[0] / self.L, 0), 1):.5f}" for k in keys)
        vals = ";".join(str(k[1]) for k in keys)
        return times, vals

    def anim(self, attr, keys, mode="linear"):
        times, vals = self._norm(keys)
        return (f'<animate attributeName="{attr}" dur="{self.L:g}s" repeatCount="indefinite" '
                f'calcMode="{mode}" keyTimes="{times}" values="{vals}"/>')

    def step(self, attr, keys):
        """Discrete switches: value i holds from its time until the next key."""
        keys = sorted(keys, key=lambda k: k[0])
        if keys[0][0] > 0:
            keys = [(0.0, keys[0][1])] + keys
        times = ";".join(f"{k[0] / self.L:.5f}" for k in keys)
        vals = ";".join(str(k[1]) for k in keys)
        return (f'<animate attributeName="{attr}" dur="{self.L:g}s" repeatCount="indefinite" '
                f'calcMode="discrete" keyTimes="{times}" values="{vals}"/>')

    def scale(self, keys):
        times, vals = self._norm(keys)
        return (f'<animateTransform attributeName="transform" type="scale" dur="{self.L:g}s" '
                f'repeatCount="indefinite" calcMode="linear" keyTimes="{times}" values="{vals}"/>')

    def motion(self, path_d, keys):
        """Move along path_d; keys = [(time, fraction-of-length)]."""
        keys = sorted(keys, key=lambda k: k[0])
        if keys[0][0] > 0:
            keys = [(0.0, keys[0][1])] + keys
        if keys[-1][0] < self.L:
            keys = keys + [(self.L, keys[-1][1])]
        times = ";".join(f"{k[0] / self.L:.5f}" for k in keys)
        pts = ";".join(f"{k[1]:.5f}" for k in keys)
        return (f'<animateMotion dur="{self.L:g}s" repeatCount="indefinite" calcMode="linear" '
                f'path="{path_d}" keyPoints="{pts}" keyTimes="{times}"/>')

    def fade(self, t_on, t_off=None, dur=0.25, lo=0, hi=1, attr="opacity"):
        """Off until t_on, fade to hi, hold until t_off (default: the loop's reset), fade back."""
        t_off = self.L - 0.6 if t_off is None else t_off
        return self.anim(attr, [(0, lo), (t_on, lo), (t_on + dur, hi), (t_off, hi), (t_off + dur, lo)])


P = DARK
W, H = 1000, 470
L = 15.0
C = Clock(L)
RESET = 14.1          # state fades back to neutral here
LANES = [138, 251, 364]
UNITS = ["grid_mod", "solver", "io_mod"]

# ---------- geometry helpers -----------------------------------------------------------------------
def cubic_len(p0, p1, p2, p3, n=200):
    def pt(u):
        a = (1 - u) ** 3; b = 3 * (1 - u) ** 2 * u; c = 3 * (1 - u) * u ** 2; d = u ** 3
        return (a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0], a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1])
    s, prev = 0.0, pt(0)
    for i in range(1, n + 1):
        cur = pt(i / n); s += math.dist(prev, cur); prev = cur
    return s


class Route:
    """A path built from segments, remembering the cumulative length at every waypoint so motion can
    be keyed by named stops."""

    def __init__(self, start):
        self.d = [f"M{start[0]:g} {start[1]:g}"]
        self.cur = start
        self.len = 0.0
        self.stops = {"start": 0.0}

    def line(self, p, name=None):
        self.len += math.dist(self.cur, p); self.d.append(f"L{p[0]:g} {p[1]:g}"); self.cur = p
        if name: self.stops[name] = self.len
        return self

    def curve(self, c1, c2, p, name=None):
        self.len += cubic_len(self.cur, c1, c2, p)
        self.d.append(f"C{c1[0]:g} {c1[1]:g} {c2[0]:g} {c2[1]:g} {p[0]:g} {p[1]:g}"); self.cur = p
        if name: self.stops[name] = self.len
        return self

    def path(self):
        return " ".join(self.d)

    def f(self, name):
        return self.stops[name] / self.len


# ---------- primitives ------------------------------------------------------------------------------
def card(x, y, w, h, kicker, kcol, title, sub, mono_sub=False):
    o = [f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{P["card"]}" stroke="{P["border"]}"/>']
    if kicker:
        o.append(t(x + 14, y + 20, kicker, 10.5, kcol, 700, ls="0.1em"))
        o.append(t(x + 14, y + 39, title, 14, P["text"], 600))
        o.append(t(x + 14, y + 55, sub, 11.5, P["muted"], 400, family=MONO if mono_sub else SANS))
    else:
        o.append(t(x + w / 2, y + 24, title, 14, P["text"], 600, "middle"))
        o.append(t(x + w / 2, y + 41, sub, 11.5, P["muted"], 400, "middle", family=MONO if mono_sub else SANS))
    return "\n".join(o)


def glow_rect(x, y, w, h, col, t_on, t_off=RESET, rx=10):
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{col}" fill-opacity="0.07" '
            f'stroke="{col}" stroke-width="1.6" filter="url(#glow)" opacity="0">{C.fade(t_on, t_off)}</rect>')


def badge(cx, cy, col, t_on, glyph="✓", t_off=RESET):
    return (f'<g opacity="0">{C.fade(t_on, t_off, 0.2)}<circle cx="{cx}" cy="{cy}" r="9" fill="{col}"/>'
            + t(cx, cy + 4, glyph, 11, P["bg"], 800, "middle") + "</g>")


def arrow(d, col=None, dash=None, width=1.4, marker=True, extra=""):
    col = col or P["faint"]
    da = f' stroke-dasharray="{dash}"' if dash else ""
    mk = ' marker-end="url(#tip)"' if marker else ""
    return f'<path d="{d}" fill="none" stroke="{col}" stroke-width="{width}"{da}{mk} {extra}/>'


def token(route, keys, vis, fills, r=5.5):
    """A glowing dot moving along route: keys=[(time, stop-name)], vis=[(time, opacity)] (discrete),
    fills=[(time, colour)] (discrete)."""
    mk = [(tm, route.f(nm)) for tm, nm in keys]
    return (f'<g opacity="0">{C.step("opacity", vis)}'
            f'<circle r="{r}" fill="{fills[0][1]}" filter="url(#glow)">{C.step("fill", fills)}</circle>'
            f'{C.motion(route.path(), mk)}</g>')


# ---------- layout -----------------------------------------------------------------------------------
LX, LW = 28, 180                     # left column
PX0, PX1 = 236, 760                  # phase-2 panel
RX, RW = 790, 182                    # right column
PTAH = (312, 251)                    # Ptah-Orchestrator card centre
PW = 140                             # its width
WK0, WK1 = 410, 520                  # worker box x-range
PROOF = 566                           # proof centre x
RV0, RV1 = 614, 724                  # review box x-range
SESH = (RX, 251)


def build():
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" '
         f'aria-label="How a port flows: chisel-init, scoping and tooling, then parallel translation where '
         f'each unit passes an R1 proof and an independent review, with failures recorded as lessons and '
         f'reworked, then integration into the product repo and a milestone tag">']
    o.append(f"""<defs>
<filter id="glow" x="-60%" y="-60%" width="220%" height="220%"><feGaussianBlur stdDeviation="3" result="b"/>
<feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
<pattern id="dots" width="22" height="22" patternUnits="userSpaceOnUse"><circle cx="1" cy="1" r="1" fill="#21262d"/></pattern>
<marker id="tip" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
<path d="M1 1 L8 5 L1 9" fill="none" stroke="{P['faint']}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></marker>
<marker id="tipred" viewBox="0 0 10 10" refX="8" refY="5" markerWidth="6" markerHeight="6" orient="auto-start-reverse">
<path d="M1 1 L8 5 L1 9" fill="none" stroke="{P['red']}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></marker>
</defs>""")
    o.append(f'<rect x="0.5" y="0.5" width="{W - 1}" height="{H - 1}" rx="16" fill="{P["bg"]}" stroke="{P["border"]}"/>')
    o.append(f'<rect x="1" y="1" width="{W - 2}" height="{H - 2}" rx="16" fill="url(#dots)"/>')

    # ---- left column: foundations + workbench memory
    nodes = [(36, "SETUP", P["grey"], "chisel-init", "workbench + product wired"),
             (128, "PHASE 0", P["purple"], "Scoping", "charter · config · ref run"),
             (220, "PHASE 1", P["blue"], "Tooling", "proofs seen red → green")]
    for (y, k, col, ti, su) in nodes:
        o.append(card(LX, y, LW, 62, k, col, ti, su))
    cxl = LX + LW / 2
    o.append(arrow(f"M{cxl} 98 L{cxl} 126"))
    o.append(arrow(f"M{cxl} 190 L{cxl} 218"))
    # memory box
    o.append(f'<rect x="{LX}" y="318" width="{LW}" height="122" rx="10" fill="none" stroke="{P["border"]}" stroke-dasharray="4 4"/>')
    o.append(t(LX + 14, 340, "WORKBENCH MEMORY", 10.5, P["faint"], 700, ls="0.1em"))
    o.append(t(LX + 14, 362, "port/ — every sprint", 12.5, P["text"], 600))
    for j, ln in enumerate(["charter · TRACE", "LESSONS · handoffs", "evidence packs"]):
        o.append(t(LX + 14, 382 + j * 17, ln, 11.5, P["muted"], 400, family=MONO))

    # ---- phase-2 panel
    o.append(f'<rect x="{PX0}" y="24" width="{PX1 - PX0}" height="422" rx="12" fill="#10151c" stroke="{P["border"]}"/>')
    o.append(t(PX0 + 20, 50, "PHASE 2 · TRANSLATION", 10.5, P["orange"], 700, ls="0.1em"))
    o.append(t(PX1 - 18, 50, "one Kha-Worker per ready unit, in parallel", 11.5, P["muted"], 400, "end"))
    # P1 -> Ptah-Orchestrator
    o.append(arrow(f"M{LX + LW} 251 L{PTAH[0] - PW / 2 - 2} 251"))
    # Ptah-Orchestrator
    o.append(card(PTAH[0] - PW / 2, PTAH[1] - 27, PW, 54, None, None, "Ptah-Orchestrator", "dispatch"))
    o.append(f'<g transform="translate({PTAH[0]} {PTAH[1]})"><g>{C.scale([(0, 1), (3.45, 1), (3.6, 1.05), (3.85, 1)])}'
             f'<rect x="{-PW / 2}" y="-27" width="{PW}" height="54" rx="10" fill="none" stroke="{P["orange"]}" '
             f'stroke-width="1.6" filter="url(#glow)" opacity="0">'
             f'{C.anim("opacity", [(0, 0), (3.4, 0), (3.55, 1), (4.3, 1), (4.6, 0)])}</rect></g></g>')

    for i, (y, unit) in enumerate(zip(LANES, UNITS)):
        # fan-out
        o.append(arrow(f"M{PTAH[0] + PW / 2} {PTAH[1]} C{PTAH[0] + PW / 2 + 20} {PTAH[1]} {WK0 - 26} {y} {WK0 - 2} {y}"))
        # worker
        o.append(card(WK0, y - 27, WK1 - WK0, 54, None, None, "Kha-Worker", unit, mono_sub=True))
        o.append(f'<rect x="{WK0 + 12}" y="{y + 18}" width="{WK1 - WK0 - 24}" height="3" rx="1.5" fill="#21262d"/>')
        # rework arc (faint for every lane: the loop always exists)
        o.append(arrow(f"M{PROOF} {y - 22} C{PROOF} {y - 52} {(WK0 + WK1) / 2} {y - 56} {(WK0 + WK1) / 2} {y - 29}",
                       dash="3 4"))
        if i == 0:
            o.append(t((PROOF + (WK0 + WK1) / 2) / 2 + 6, y - 56, "findings → rework", 10.5, P["faint"], 400, "middle"))
        # worker -> proof -> review
        o.append(arrow(f"M{WK1} {y} L{PROOF - 24} {y}"))
        o.append(f'<path d="M{PROOF} {y - 22} L{PROOF + 22} {y} L{PROOF} {y + 22} L{PROOF - 22} {y} Z" fill="{P["card"]}" stroke="{P["border"]}"/>')
        o.append(t(PROOF, y + 4, "R1", 11, P["muted"], 700, "middle"))
        o.append(arrow(f"M{PROOF + 22} {y} L{RV0 - 2} {y}"))
        o.append(card(RV0, y - 27, RV1 - RV0, 54, None, None, "port-review", "independent"))
        # converge to Seshat-Integrator
        o.append(arrow(f"M{RV1} {y} C{RV1 + 50} {y} {SESH[0] - 50} {SESH[1]} {SESH[0] - 2} {SESH[1]}"))

    # ---- right column
    o.append(t(RX + 4, 46, "●", 11, P["orange"]) + t(RX + 20, 46, "unit in progress", 11.5, P["muted"]))
    o.append(t(RX + 4, 66, "●", 11, P["green"]) + t(RX + 20, 66, "proof / review passed", 11.5, P["muted"]))
    o.append(t(RX + 4, 86, "●", 11, P["red"]) + t(RX + 20, 86, "finding → lesson → rework", 11.5, P["muted"]))
    o.append(card(RX, 220, RW, 62, "INTEGRATE", P["cyan"], "Seshat-Integrator", "guarded land, in order"))
    o.append(arrow(f"M{RX + RW / 2} 282 L{RX + RW / 2} 308"))
    o.append(card(RX, 310, RW, 62, "PRODUCT REPO", P["green"], "main", "builds · runs · self-tests"))
    o.append(arrow(f"M{RX + RW / 2} 372 L{RX + RW / 2} 398"))
    tagx, tagy = RX + RW / 2, 418
    o.append(f'<rect x="{RX}" y="400" width="{RW}" height="36" rx="18" fill="{P["card"]}" stroke="{P["border"]}"/>')
    o.append(t(tagx, 423, "finalize.sh → git tag", 12, P["muted"], 600, "middle", family=MONO))

    # ================= animation =================
    # foundations
    for (y, k, col, *_r), t_on in zip(nodes, (0.4, 1.4, 2.4)):
        o.append(glow_rect(LX, y, LW, 62, col, t_on))
        o.append(badge(LX + LW - 16, y + 16, col, t_on + 0.1))
    found = Route((cxl, 98)).line((cxl, 128), "p0").line((cxl, 190), "p0out").line((cxl, 220), "p1") \
        .line((cxl, 251), "p1mid").line((PTAH[0], 251), "ptah")
    o.append(token(found, [(0.8, "start"), (1.4, "p0"), (1.8, "p0"), (1.8, "p0out"), (2.4, "p1"), (2.8, "p1"),
                           (2.8, "p1mid"), (3.45, "ptah")],
                   [(0, 0), (0.8, 1), (1.4, 0), (1.8, 1), (2.4, 0), (2.8, 1), (3.45, 0)],
                   [(0, P["purple"]), (1.8, P["blue"]), (2.8, P["orange"])]))

    # per-lane timing: (work done, proof result time, review done) ; lane 1 (solver) fails first
    plan = {0: dict(done=5.6), 1: dict(done=5.9), 2: dict(done=5.3)}
    for i, y in enumerate(LANES):
        r = Route(PTAH).line((PTAH[0] + PW / 2, PTAH[1])) \
            .curve((PTAH[0] + PW / 2 + 20, PTAH[1]), (WK0 - 26, y), (WK0, y), "wk_in") \
            .line(((WK0 + WK1) / 2, y), "wk_mid").line((WK1, y), "wk_out").line((PROOF, y), "proof") \
            .line((RV0, y), "rv_in").line((RV1, y), "rv_out") \
            .curve((RV1 + 50, y), (SESH[0] - 50, SESH[1]), SESH, "sesh")
        done = plan[i]["done"]
        o.append(glow_rect(WK0, y - 27, WK1 - WK0, 54, P["orange"], 4.2, done, rx=10))
        if i != 1:
            g_pass = done + 0.3
            rv_in = g_pass + 0.4
            rv_done = rv_in + 0.5
            keys = [(3.6, "start"), (4.2, "wk_in"), (4.25, "wk_mid"), (done - 0.05, "wk_mid"), (done, "wk_out"),
                    (g_pass, "proof"), (g_pass + 0.15, "proof"), (rv_in, "rv_in"), (rv_done, "rv_out"),
                    (9.8, "rv_out"), (10.6, "sesh")]
            vis = [(0, 0), (3.6, 1), (4.25, 0), (done, 1), (rv_in, 0), (rv_done, 1), (10.6, 0)]
            fills = [(0, P["orange"]), (rv_done, P["green"])]
            bar = [(0, 0), (4.2, 0), (done, 1), (RESET, 1), (RESET + 0.3, 0)]
            o.append(proof_state(y, P["green"], g_pass))
        else:
            g_fail = done + 0.3                 # 6.2
            back0, back1 = g_fail + 0.2, g_fail + 1.0   # rework arc travel
            redo = back1 + 1.0                  # 8.2
            g_pass = redo + 0.3                 # 8.5
            rv_in = g_pass + 0.4
            rv_done = rv_in + 0.5               # 9.4
            keys = [(3.6, "start"), (4.2, "wk_in"), (4.25, "wk_mid"), (done - 0.05, "wk_mid"), (done, "wk_out"),
                    (g_fail, "proof"), (back0, "proof"), (back0 + 0.05, "wk_mid"), (redo - 0.05, "wk_mid"),
                    (redo, "wk_out"), (g_pass, "proof"), (g_pass + 0.15, "proof"), (rv_in, "rv_in"),
                    (rv_done, "rv_out"), (9.8, "rv_out"), (10.6, "sesh")]
            vis = [(0, 0), (3.6, 1), (4.25, 0), (done, 1), (back0, 0), (redo, 1), (rv_in, 0), (rv_done, 1), (10.6, 0)]
            fills = [(0, P["orange"]), (g_fail, P["red"]), (redo, P["orange"]), (rv_done, P["green"])]
            bar = [(0, 0), (4.2, 0), (done, 1), (back1, 1), (back1 + 0.05, 0), (redo, 1), (RESET, 1), (RESET + 0.3, 0)]
            o.append(proof_state(y, P["red"], g_fail, g_pass))
            o.append(proof_state(y, P["green"], g_pass))
            # rework arc lights up and a red token rides it back to the worker
            arc = Route((PROOF, y - 22)).curve((PROOF, y - 52), ((WK0 + WK1) / 2, y - 56), ((WK0 + WK1) / 2, y - 29), "end")
            o.append(f'<path d="{arc.path()}" fill="none" stroke="{P["red"]}" stroke-width="1.8" marker-end="url(#tipred)" '
                     f'opacity="0">{C.anim("opacity", [(0, 0), (g_fail, 0), (g_fail + 0.15, 1), (back1 + 0.3, 1), (back1 + 0.8, 0)])}</path>')
            o.append(token(arc, [(back0, "start"), (back1, "end")], [(0, 0), (back0, 1), (back1, 0)], [(0, P["red"])]))
            o.append(glow_rect(WK0, y - 27, WK1 - WK0, 54, P["orange"], back1, redo, rx=10))
            # the lesson flies to workbench memory
            les = Route((PROOF - 10, y - 30)).curve((420, 150), (230, 290), (LX + LW / 2, 330), "mem")
            o.append(f'<g opacity="0">{C.step("opacity", [(0, 0), (g_fail + 0.1, 1), (g_fail + 1.0, 0)])}'
                     f'<g><rect x="-34" y="-10" width="68" height="20" rx="10" fill="{P["red"]}" fill-opacity="0.18" stroke="{P["red"]}"/>'
                     + t(0, 4, "+1 lesson", 10.5, P["red"], 700, "middle", family=MONO) +
                     f'{C.motion(les.path(), [(g_fail + 0.1, 0), (g_fail + 1.0, 1)])}</g></g>')
            o.append(glow_rect(LX, 318, LW, 122, P["red"], g_fail + 1.0, g_fail + 1.8))
            o.append(f'<g opacity="0">{C.fade(g_fail + 1.0)}<rect x="{LX + LW - 60}" y="405" width="48" height="18" rx="9" '
                     f'fill="{P["red"]}" fill-opacity="0.16" stroke="{P["red"]}" stroke-opacity="0.6"/>'
                     + t(LX + LW - 36, 417.5, "L-0001", 10, P["red"], 700, "middle", family=MONO) + "</g>")
        # progress bar, review glow + clean badge
        o.append(f'<rect x="{WK0 + 12}" y="{y + 18}" width="0" height="3" rx="1.5" fill="{P["orange"]}">'
                 f'{C.anim("width", [(tm, v * (WK1 - WK0 - 24)) for tm, v in bar])}'
                 f'{C.step("fill", [(0, P["orange"]), (g_pass, P["green"]), (RESET + 0.3, P["orange"])])}</rect>')
        o.append(glow_rect(RV0, y - 27, RV1 - RV0, 54, P["green"], rv_in, rv_done, rx=10))
        o.append(badge(RV1 - 14, y - 27, P["green"], rv_done))
        o.append(token(r, keys, vis, fills))

    # integrate -> product -> tag
    o.append(glow_rect(RX, 220, RW, 62, P["cyan"], 10.6))
    o.append(badge(RX + RW - 16, 236, P["cyan"], 10.7))
    down = Route((RX + RW / 2, 282)).line((RX + RW / 2, 310), "prod").line((RX + RW / 2, 372), "prod_out") \
        .line((RX + RW / 2, 400), "tag")
    o.append(token(down, [(10.8, "start"), (11.2, "prod"), (11.5, "prod"), (11.5, "prod_out"), (11.9, "tag")],
                   [(0, 0), (10.8, 1), (11.2, 0), (11.5, 1), (11.9, 0)], [(0, P["green"])]))
    o.append(glow_rect(RX, 310, RW, 62, P["green"], 11.2))
    o.append(badge(RX + RW - 16, 326, P["green"], 11.3))
    o.append(f'<g transform="translate({tagx} {tagy})"><g opacity="0">{C.fade(11.9, RESET, 0.15)}'
             f'{C.scale([(0, 0.85), (11.9, 0.85), (12.1, 1.08), (12.3, 1)])}'
             f'<rect x="{-RW / 2}" y="-18" width="{RW}" height="36" rx="18" fill="{P["bg"]}"/>'
             f'<rect x="{-RW / 2}" y="-18" width="{RW}" height="36" rx="18" fill="{P["green"]}" fill-opacity="0.18" '
             f'stroke="{P["green"]}" stroke-width="1.6" filter="url(#glow)"/>'
             + t(0, 5, "✓ tag phase2-accepted", 12, P["green"], 700, "middle", family=MONO) + "</g></g>")
    o.append("</svg>")
    return "\n".join(o)


def proof_state(y, col, t_on, t_off=RESET):
    return (f'<g opacity="0">{C.fade(t_on, t_off, 0.15)}'
            f'<path d="M{PROOF} {y - 22} L{PROOF + 22} {y} L{PROOF} {y + 22} L{PROOF - 22} {y} Z" fill="{col}" '
            f'fill-opacity="0.18" stroke="{col}" stroke-width="1.6" filter="url(#glow)"/>'
            + t(PROOF, y + 4, "R1", 11, col, 800, "middle") + "</g>")


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    target = os.path.join(here, "flow.svg")
    svg = build() + "\n"
    if sys.argv[1:] == ["--check"]:
        if open(target, encoding="utf-8").read() != svg:
            sys.exit("flow.svg is stale - regenerate it: python3 docs/assets/flow.py")
        print("flow.svg is current")
    else:
        open(target, "w", encoding="utf-8").write(svg)
        print("wrote", target)
