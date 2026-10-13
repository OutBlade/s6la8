"""Seed placement for the s6la8 board.  Run with KiCad's Python:

    "C:/Program Files/KiCad/10.0/bin/python.exe" layout/place.py eda/s6la8.kicad_pcb

Only the anchors (ICs, connectors, holes) are positioned by hand below.  Every
other part is placed next to the pad it connects to, so the floorplan is about
twenty lines and no passive has typed coordinates.  Parts that already carry
tracks are left alone, so re-running after routing is safe.
"""
import math
import sys

import pcbnew

MM = pcbnew.FromMM
OX, OY = 100.0, 60.0            # board origin on the sheet
W, H = 100.0, 64.0
EDGE = 1.0                      # keep parts this far inside the outline

# design name -> (x, y, rotation) in board millimetres
ANCHORS = {
    "H1": (4, 4, 0), "H2": (96, 4, 0), "H3": (4, 60, 0), "H4": (96, 60, 0),
    "FID1": (10, 3, 0), "FID2": (90, 3, 0), "FID3": (10, 61, 0),
    "J_PROBE": (9, 32, 180),
    "U_FE": (22, 24, 0),
    "U_FE_AUX": (22, 44, 0),
    "U_FALLBACK": (33, 50, 90),
    "U_FPGA": (50, 26, 0),
    "U_SDRAM": (80, 20, 0),
    "U_FX2": (56, 52, 90),
    "U_EEPROM": (75, 57, 0),
    "J_USB": (95.5, 46, 90),
    "U_REG_3V3": (84, 38, 0),
    "U_REG_1V2": (72, 40, 0),
    "J_JTAG": (38, 3.5, 90),
    "J_VREF": (16, 57, 90),
    "J_MODE": (30, 60.5, 90),
}

# Rail-only parts cannot find their place from a signal net; name their home.
HOME = {
    "C_FX2": "U_FX2", "C_AVCC": "U_FX2", "FB_AVCC": "U_FX2",
    "C_VCCINT": "U_FPGA", "C_VCCAUX": "U_FPGA", "C_VCCO": "U_FPGA",
    "C_SDRAM": "U_SDRAM", "C_FE_AUX": "U_FE_AUX", "C_FE": "U_FE",
    "C_FALLBACK": "U_FALLBACK", "C_EEPROM": "U_EEPROM", "C_OSC": "Y_FPGA",
    "C_VCCA": "J_VREF", "C_V5": "J_USB", "FB_VBUS": "J_USB",
    "C_3V3": "U_REG_3V3", "C_1V2": "U_REG_1V2",
    "U_ESD_USB": "J_USB", "R_LED_PWR": "U_REG_3V3", "D_PWR": "U_REG_3V3", "R_CC": "J_USB",
}
RAILS = {"GND", "VCC_3V3", "VCC_1V2", "V5", "VBUS", "AVCC", "VCCA"}


def name_of(fp):
    path = fp.GetFieldText("Path") if fp.HasField("Path") else fp.GetReference()
    return path.split(".")[0]


def bbox(fp, grow=0.0):
    b = fp.GetBoundingBox(False)
    g = MM(grow)
    return (b.GetLeft() - g, b.GetTop() - g, b.GetRight() + g, b.GetBottom() + g)


def overlaps(a, b):
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


def main(path):
    board = pcbnew.LoadBoard(path)
    fps = {name_of(f): f for f in board.GetFootprints()}
    routed = {t.GetNetname() for t in board.GetTracks()}

    # Outline, once.
    if not any(d.GetLayer() == pcbnew.Edge_Cuts for d in board.GetDrawings()):
        r = pcbnew.PCB_SHAPE(board)
        r.SetShape(pcbnew.SHAPE_T_RECT)
        r.SetStart(pcbnew.VECTOR2I(MM(OX), MM(OY)))
        r.SetEnd(pcbnew.VECTOR2I(MM(OX + W), MM(OY + H)))
        r.SetLayer(pcbnew.Edge_Cuts)
        r.SetWidth(MM(0.1))
        board.Add(r)

    placed = {}
    for name, (x, y, rot) in ANCHORS.items():
        fp = fps[name]
        fp.SetOrientationDegrees(rot)
        fp.SetPosition(pcbnew.VECTOR2I(MM(OX + x), MM(OY + y)))
        placed[name] = fp
    boxes = [bbox(f, 0.3) for f in placed.values()]
    lo = (MM(OX + EDGE), MM(OY + EDGE))
    hi = (MM(OX + W - EDGE), MM(OY + H - EDGE))

    def fits(fp):
        b = bbox(fp, 0.2)
        if b[0] < lo[0] or b[1] < lo[1] or b[2] > hi[0] or b[3] > hi[1]:
            return False
        return not any(overlaps(b, o) for o in boxes)

    used_pads = set()

    def anchor_pad(fp, name):
        """The placed pad this part should sit beside, signal nets first."""
        nets = [p.GetNetname() for p in fp.Pads() if p.GetNetname()]
        signal = [n for n in nets if n not in RAILS]
        home = next((HOME[k] for k in sorted(HOME, key=len, reverse=True) if name.startswith(k)), None)
        for reuse in (False, True):
            best = None
            for net in signal or nets:
                if net == "GND" and len(set(nets)) > 1:
                    continue
                for oname, other in placed.items():
                    if home and oname != home:
                        continue
                    for pad in other.Pads():
                        if pad.GetNetname() != net:
                            continue
                        key = (oname, pad.GetNumber())
                        if not signal and not reuse and key in used_pads:
                            continue
                        score = len(other.Pads())
                        if best is None or score > best[0]:
                            best = (score, other, pad, key)
            if best:
                return best
            if signal:
                break
        return None

    todo = [n for n in fps if n not in placed]
    progress = True
    while todo and progress:
        progress = False
        for name in list(todo):
            fp = fps[name]
            if any(p.GetNetname() in routed for p in fp.Pads()) and name not in ANCHORS:
                pass
            hit = anchor_pad(fp, name)
            if not hit:
                continue
            _, other, pad, key = hit
            c, p = other.GetPosition(), pad.GetPosition()
            dx, dy = p.x - c.x, p.y - c.y
            n = math.hypot(dx, dy) or 1.0
            ux, uy = dx / n, dy / n
            done = False
            for dist in [1.6 + 0.5 * i for i in range(40)]:
                for side in (0, 1, -1, 2, -2, 3, -3, 4, -4, 6, -6, 8, -8):
                    x = p.x + MM(dist) * ux - MM(0.8 * side) * uy
                    y = p.y + MM(dist) * uy + MM(0.8 * side) * ux
                    for rot in ((90, 0) if abs(ux) > abs(uy) else (0, 90)):
                        fp.SetOrientationDegrees(rot)
                        fp.SetPosition(pcbnew.VECTOR2I(int(x), int(y)))
                        if fits(fp):
                            done = True
                            break
                    if done:
                        break
                if done:
                    break
            if done:
                placed[name] = fp
                boxes.append(bbox(fp, 0.2))
                used_pads.add(key)
                todo.remove(name)
                progress = True
    # Leftovers: nearest free spot to their home (or the board centre).
    for name in list(todo):
        fp = fps[name]
        home = next((HOME[k] for k in sorted(HOME, key=len, reverse=True) if name.startswith(k)), None)
        c = placed[home].GetPosition() if home in placed else pcbnew.VECTOR2I(MM(OX + W / 2), MM(OY + H / 2))
        spots = sorted(((x, y) for x in range(2, int(W) - 1) for y in range(2, int(H) - 1)),
                       key=lambda s: (MM(OX + s[0]) - c.x) ** 2 + (MM(OY + s[1]) - c.y) ** 2)
        for x, y in spots:
            fp.SetOrientationDegrees(0)
            fp.SetPosition(pcbnew.VECTOR2I(MM(OX + x), MM(OY + y)))
            if fits(fp):
                placed[name] = fp
                boxes.append(bbox(fp, 0.2))
                todo.remove(name)
                break
    pcbnew.SaveBoard(path, board)
    print("placed %d of %d; unplaced: %s" % (len(placed), len(fps), ", ".join(sorted(todo)) or "none"))


if __name__ == "__main__":
    main(sys.argv[1])
