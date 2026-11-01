"""Draw the Radiant icon: a goal DAG as glowing lines on a dark tile (512 x 512)."""
import sys

BG_TOP, BG_BOT = "#0e1b33", "#081022"
LINE = "#5ad1ff"
DONE = "#7cf0c8"
CORE = "#fff4c2"

# Nodes of a small goal DAG, left to right: (x, y, state)
N = {
    "a": (120, 196, "done"), "b": (120, 316, "done"),
    "c": (236, 150, "done"), "d": (236, 256, "core"), "e": (236, 362, "todo"),
    "f": (356, 200, "todo"), "g": (356, 312, "todo"),
    "h": (440, 256, "todo"),
}
E = [("a", "c"), ("a", "d"), ("b", "d"), ("b", "e"), ("c", "f"), ("d", "f"),
     ("d", "g"), ("e", "g"), ("f", "h"), ("g", "h")]


def art():
    out = []
    for u, v in E:
        (x1, y1, s1), (x2, y2, _) = N[u], N[v]
        mx = (x1 + x2) / 2
        lit = s1 in ("done", "core")
        out.append(f'<path d="M{x1},{y1} C{mx},{y1} {mx},{y2} {x2},{y2}" fill="none" '
                   f'stroke="{DONE if lit else LINE}" stroke-opacity="{0.95 if lit else 0.45}" '
                   f'stroke-width="9" stroke-linecap="round"/>')
    for x, y, s in N.values():
        if s == "core":
            out.append(f'<circle cx="{x}" cy="{y}" r="34" fill="url(#halo)"/>'
                       f'<circle cx="{x}" cy="{y}" r="22" fill="{CORE}"/>')
        elif s == "done":
            out.append(f'<circle cx="{x}" cy="{y}" r="19" fill="{DONE}"/>')
        else:
            out.append(f'<circle cx="{x}" cy="{y}" r="16" fill="{BG_BOT}" stroke="{LINE}" stroke-width="7"/>')
    return "".join(out)


def svg(tile=True):
    defs = ('<defs>'
            f'<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{BG_TOP}"/>'
            f'<stop offset="1" stop-color="{BG_BOT}"/></linearGradient>'
            f'<radialGradient id="halo"><stop offset="0" stop-color="{CORE}" stop-opacity="0.9"/>'
            f'<stop offset="0.45" stop-color="#ffd27a" stop-opacity="0.35"/>'
            f'<stop offset="1" stop-color="#ffd27a" stop-opacity="0"/></radialGradient>'
            '<filter id="glow" x="-20%" y="-20%" width="140%" height="140%">'
            '<feGaussianBlur stdDeviation="6" result="b"/>'
            '<feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge></filter>'
            '</defs>')
    body = f'<g filter="url(#glow)">{art()}</g>'
    if tile:
        return ('<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">'
                + defs + '<rect x="8" y="8" width="496" height="496" rx="112" fill="url(#bg)"/>'
                + body + '<rect x="8" y="8" width="496" height="496" rx="112" fill="none" '
                'stroke="#24365a" stroke-width="5"/></svg>\n')
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">'
            + defs + body + '</svg>\n')


if __name__ == "__main__":
    out = sys.argv[1]
    open(f"{out}/radiant-tile.svg", "w").write(svg(True))
    open(f"{out}/radiant.svg", "w").write(svg(False))
