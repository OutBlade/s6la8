"""Tie surface-mount power pads to the inner planes.  Run with KiCad's Python:

    "C:/Program Files/KiCad/10.0/bin/python.exe" layout/fanout.py eda/s6la8.kicad_pcb

The autorouter leaves many GND and 3.3 V pads without a via.  For every pad on
a plane net that has no track yet, this drops a via within reach and joins it
with a short stub, checking clearance against all other copper first.
"""
import math
import sys

import pcbnew

PLANE_NETS = ("GND", "VCC_3V3")
import os
# A second pass with FANOUT_SMALL=1 uses the smallest via the rules allow for
# pads the first pass could not reach.
if os.environ.get("FANOUT_SMALL"):
    VIA_D, VIA_DRILL, STUB_W, CLR = 0.45, 0.2, 0.16, 0.155
else:
    VIA_D, VIA_DRILL, STUB_W, CLR = 0.6, 0.3, 0.25, 0.16
mm = pcbnew.ToMM
MM = pcbnew.FromMM


def seg_dist(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def main(path):
    board = pcbnew.LoadBoard(path)
    edge = board.GetBoardEdgesBoundingBox()
    ex0, ey0, ex1, ey1 = mm(edge.GetLeft()), mm(edge.GetTop()), mm(edge.GetRight()), mm(edge.GetBottom())

    pads = []      # (x0, y0, x1, y1, net, through)
    for fp in board.GetFootprints():
        for p in fp.Pads():
            b = p.GetBoundingBox()
            pads.append((mm(b.GetLeft()), mm(b.GetTop()), mm(b.GetRight()), mm(b.GetBottom()),
                         p.GetNetname(), p.GetAttribute() != pcbnew.PAD_ATTRIB_SMD))
    segs, vias = [], []     # (ax, ay, bx, by, halfwidth, net, layer), (x, y, r, net)
    touched = set()
    for t in board.GetTracks():
        s, e = t.GetStart(), t.GetEnd()
        if t.Type() == pcbnew.PCB_VIA_T:
            vias.append((mm(s.x), mm(s.y), mm(t.GetWidth(pcbnew.F_Cu)) / 2, t.GetNetname()))
        else:
            segs.append((mm(s.x), mm(s.y), mm(e.x), mm(e.y), mm(t.GetWidth()) / 2, t.GetNetname(), t.GetLayer()))

    def via_ok(x, y, net, extra=0.0):
        r = VIA_D / 2 + CLR + extra
        if x - r < ex0 + 0.3 or y - r < ey0 + 0.3 or x + r > ex1 - 0.3 or y + r > ey1 - 0.3:
            return False
        for (x0, y0, x1, y1, pnet, _) in pads:
            if pnet == net:
                continue
            dx = max(x0 - x, 0, x - x1)
            dy = max(y0 - y, 0, y - y1)
            if math.hypot(dx, dy) < r:
                return False
        for (ax, ay, bx, by, hw, snet, _) in segs:
            if snet != net and seg_dist(x, y, ax, ay, bx, by) < r + hw:
                return False
        for (vx, vy, vr, vnet) in vias:
            if math.hypot(x - vx, y - vy) < VIA_D / 2 + vr + CLR + 0.1 + extra:
                return False
        return True

    def stub_ok(ax, ay, bx, by, net, layer):
        r = STUB_W / 2 + CLR
        for (x0, y0, x1, y1, pnet, through) in pads:
            if pnet == net:
                continue
            for k in range(13):                 # distance to the pad rectangle
                t = k / 12.0
                x, y = ax + t * (bx - ax), ay + t * (by - ay)
                if math.hypot(max(x0 - x, 0, x - x1), max(y0 - y, 0, y - y1)) < r:
                    return False
        for (sx, sy, tx, ty, hw, snet, slayer) in segs:
            if snet == net or slayer != layer:
                continue
            for k in range(9):
                t = k / 8.0
                if seg_dist(ax + t * (bx - ax), ay + t * (by - ay), sx, sy, tx, ty) < r + hw:
                    return False
        for (vx, vy, vr, vnet) in vias:
            if vnet != net and seg_dist(vx, vy, ax, ay, bx, by) < r + vr:
                return False
        return True

    done = failed = 0
    for fp in board.GetFootprints():
        for p in fp.Pads():
            net = p.GetNetname()
            if net not in PLANE_NETS or p.GetAttribute() != pcbnew.PAD_ATTRIB_SMD:
                continue
            c = p.GetPosition()
            px, py = mm(c.x), mm(c.y)
            layer = fp.GetLayer()
            # Skip pads that already have a plane via close by.
            if any(n == net and math.hypot(px - vx, py - vy) < 1.3 for (vx, vy, _, n) in vias):
                continue
            placed = False
            for dist in (0.75, 0.9, 1.1, 1.3, 1.6, 2.0, 2.5, 3.0, 3.6, 4.2, 5.0, 6.0):
                for k in range(48):
                    a = 2 * math.pi * k / 48
                    x, y = px + dist * math.cos(a), py + dist * math.sin(a)
                    if via_ok(x, y, net) and stub_ok(px, py, x, y, net, layer):
                        t = pcbnew.PCB_TRACK(board)
                        t.SetStart(c)
                        t.SetEnd(pcbnew.VECTOR2I(MM(x), MM(y)))
                        t.SetWidth(MM(STUB_W))
                        t.SetLayer(layer)
                        t.SetNet(p.GetNet())
                        board.Add(t)
                        v = pcbnew.PCB_VIA(board)
                        v.SetPosition(pcbnew.VECTOR2I(MM(x), MM(y)))
                        v.SetWidth(pcbnew.F_Cu, MM(VIA_D))
                        v.SetDrill(MM(VIA_DRILL))
                        v.SetNet(p.GetNet())
                        board.Add(v)
                        segs.append((px, py, x, y, STUB_W / 2, net, layer))
                        vias.append((x, y, VIA_D / 2, net))
                        placed = True
                        break
                if placed:
                    break
            done += placed
            failed += not placed
    # Stitch the outer ground pours to the plane on a coarse grid.
    stitched = 0
    if os.environ.get("FANOUT_STITCH"):
        gnd = board.FindNet("GND")
        y = ey0 + 2.0
        while y < ey1 - 1.5:
            x = ex0 + 2.0
            while x < ex1 - 1.5:
                if via_ok(x, y, "GND", extra=0.3):
                    v = pcbnew.PCB_VIA(board)
                    v.SetPosition(pcbnew.VECTOR2I(MM(x), MM(y)))
                    v.SetWidth(pcbnew.F_Cu, MM(VIA_D))
                    v.SetDrill(MM(VIA_DRILL))
                    v.SetNet(gnd)
                    board.Add(v)
                    vias.append((x, y, VIA_D / 2, "GND"))
                    stitched += 1
                x += 4.0
            y += 4.0
        for z in board.Zones():
            if z.GetNetname() == "GND" and board.GetLayerName(z.GetFirstLayer()) in ("F.Cu", "B.Cu"):
                z.SetPadConnection(pcbnew.ZONE_CONNECTION_FULL)
        print("stitching vias added: %d" % stitched)
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    pcbnew.SaveBoard(path, board)
    print("plane vias added: %d, pads without room: %d" % (done, failed))


if __name__ == "__main__":
    main(sys.argv[1])
