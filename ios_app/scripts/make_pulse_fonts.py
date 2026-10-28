# Run: uv run --with fonttools python scripts/make_pulse_fonts.py JarvisWidget/Fonts
"""Pulse-ring fonts for the voice Live Activity: font k draws ring band k of a ripple
for EVEN digits and nothing for odd ones, so a Text(timerInterval:) in it shows its
ring one second and hides it the next. Eight timers staggered by 1/8 s make a pulse
spread out from the orb and fade, the only motion a Live Activity allows.

Only the seconds digit may draw: a contextual rule (calt) turns any digit followed by
another digit or the colon into a blank of no width, and the colon has none either,
so "0:07" is one cell wide and shows the 7's ring — wherever the system lays the
timer out (a widget's timer text sits in a box sized for its widest value)."""
import math, sys
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.t2CharStringPen import T2CharStringPen
from fontTools.feaLib.builder import addOpenTypeFeaturesFromString

UPM = 1000
CX = CY = 500
BANDS = 8
R0, R1 = 300, 478          # the ripple runs from just outside the orb to inside the cell

def circle(pen, r, clockwise):
    k = 0.5522847498 * r
    pts = [(CX + r, CY), (CX, CY + r), (CX - r, CY), (CX, CY - r)]
    if clockwise:
        pts = [pts[0], pts[3], pts[2], pts[1]]
    pen.moveTo(pts[0])
    for i in range(4):
        a, b = pts[i], pts[(i + 1) % 4]
        # control points along the tangents
        ax, ay = a[0] - CX, a[1] - CY
        bx, by = b[0] - CX, b[1] - CY
        s = 1 if not clockwise else -1
        c1 = (a[0] - s * ay / r * k, a[1] + s * ax / r * k)
        c2 = (b[0] + s * by / r * k, b[1] - s * bx / r * k)
        pen.curveTo(c1, c2, b)
    pen.closePath()

def build(k, out):
    width = (R1 - R0) / BANDS
    r_in = R0 + k * width - 6          # a hair of overlap so bands join
    r_out = R0 + (k + 1) * width + 6
    names = [".notdef", "space", "colon", "blank"] + [f"d{i}" for i in range(10)]
    cmap = {ord(" "): "space", ord(":"): "colon"}
    cmap.update({ord(str(i)): f"d{i}" for i in range(10)})
    fb = FontBuilder(UPM, isTTF=False)
    fb.setupGlyphOrder(names)
    fb.setupCharacterMap(cmap)
    charstrings, metrics = {}, {}
    for n in names:
        pen = T2CharStringPen(UPM, None)
        if n.startswith("d") and int(n[1:]) % 2 == 0:
            circle(pen, r_out, clockwise=False)
            circle(pen, r_in, clockwise=True)
        charstrings[n] = pen.getCharString()
        metrics[n] = (UPM if n.startswith("d") else 0, 0)
    family = f"JCPulse{k}"
    fb.setupCFF(family, {"FullName": family}, charstrings, {})
    fb.setupHorizontalMetrics(metrics)
    fb.setupHorizontalHeader(ascent=UPM, descent=0)
    fb.setupNameTable({"familyName": family, "styleName": "Regular", "psName": family})
    fb.setupOS2(sTypoAscender=UPM, sTypoDescender=0, usWinAscent=UPM, usWinDescent=0)
    fb.setupPost()
    digits = " ".join(f"d{i}" for i in range(10))
    addOpenTypeFeaturesFromString(fb.font, f"""
        languagesystem DFLT dflt;
        languagesystem latn dflt;
        @digits = [{digits}];
        @next = [{digits} colon];
        feature calt {{
            sub @digits' @next by blank;
        }} calt;
    """)
    fb.save(out)

if __name__ == "__main__":
    outdir = sys.argv[1]
    for k in range(BANDS):
        build(k, f"{outdir}/JCPulse{k}.otf")
    print("built", BANDS)
