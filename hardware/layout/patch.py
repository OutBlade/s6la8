"""Close the last open connections the autorouter left behind.

Three steps, because the grid search wants numpy and KiCad's Python has none:

    kicad-python layout/patch.py dump  eda/s6la8.kicad_pcb out/patch_in.json
    python       layout/patch.py solve out/patch_in.json out/drc.json out/patch_out.json
    kicad-python layout/patch.py apply eda/s6la8.kicad_pcb out/patch_out.json

`solve` reads KiCad's DRC report for the unconnected items, rasterises all
other-net copper on F.Cu and B.Cu at 0.05 mm with clearance, and runs A* for
each connection.  Pads on a plane net only need to reach a spot where a via
fits; signal nets are routed end to end and may change layer.
"""
import heapq
import json
import math
import re
import sys

GRID = 0.05
TRACK_W, VIA_D, VIA_DRILL, CLR = 0.16, 0.45, 0.2, 0.152
PLANE_NETS = ("GND", "VCC_3V3")
LAYERS = ("F.Cu", "B.Cu")


def dump(pcb, out):
    import pcbnew
    mm = pcbnew.ToMM
    b = pcbnew.LoadBoard(pcb)
    e = b.GetBoardEdgesBoundingBox()
    data = {"edge": [mm(e.GetLeft()), mm(e.GetTop()), mm(e.GetRight()), mm(e.GetBottom())],
            "pads": [], "segs": [], "vias": []}
    for fp in b.GetFootprints():
        for p in fp.Pads():
            bb = p.GetBoundingBox()
            th = p.GetAttribute() != pcbnew.PAD_ATTRIB_SMD
            data["pads"].append([mm(bb.GetLeft()), mm(bb.GetTop()), mm(bb.GetRight()), mm(bb.GetBottom()),
                                 p.GetNetname(), th, b.GetLayerName(fp.GetLayer())])
    for t in b.GetTracks():
        s, en = t.GetStart(), t.GetEnd()
        if t.Type() == pcbnew.PCB_VIA_T:
            data["vias"].append([mm(s.x), mm(s.y), mm(t.GetWidth(pcbnew.F_Cu)) / 2, t.GetNetname()])
        else:
            data["segs"].append([mm(s.x), mm(s.y), mm(en.x), mm(en.y), mm(t.GetWidth()) / 2,
                                 t.GetNetname(), b.GetLayerName(t.GetLayer())])
    json.dump(data, open(out, "w"))
    print("dumped %d pads, %d segments, %d vias" % (len(data["pads"]), len(data["segs"]), len(data["vias"])))


def solve(src, drc, out):
    import numpy as np
    d = json.load(open(src))
    x0, y0, x1, y1 = d["edge"]
    W, H = int((x1 - x0) / GRID) + 1, int((y1 - y0) / GRID) + 1

    def cell(x, y):
        return int(round((x - x0) / GRID)), int(round((y - y0) / GRID))

    def raster(net, grow):
        """blocked[layer][y, x] for copper of other nets, inflated by grow."""
        blk = {l: np.zeros((H, W), dtype=bool) for l in LAYERS}
        m = int(1.0 / GRID)
        for l in LAYERS:                          # keep off the board edge
            blk[l][:m, :] = blk[l][-m:, :] = True
            blk[l][:, :m] = blk[l][:, -m:] = True

        def box(l, ax, ay, bx, by):
            i0, j0 = cell(ax - grow, ay - grow)
            i1, j1 = cell(bx + grow, by + grow)
            blk[l][max(j0, 0):min(j1 + 1, H), max(i0, 0):min(i1 + 1, W)] = True

        def capsule(l, ax, ay, bx, by, r):
            r += grow
            i0, j0 = cell(min(ax, bx) - r, min(ay, by) - r)
            i1, j1 = cell(max(ax, bx) + r, max(ay, by) + r)
            i0, j0, i1, j1 = max(i0, 0), max(j0, 0), min(i1, W - 1), min(j1, H - 1)
            if i1 < i0 or j1 < j0:
                return
            xs = x0 + np.arange(i0, i1 + 1) * GRID
            ys = y0 + np.arange(j0, j1 + 1) * GRID
            X, Y = np.meshgrid(xs, ys)
            dx, dy = bx - ax, by - ay
            L2 = dx * dx + dy * dy
            t = np.zeros_like(X) if L2 == 0 else np.clip(((X - ax) * dx + (Y - ay) * dy) / L2, 0, 1)
            dist = np.hypot(X - (ax + t * dx), Y - (ay + t * dy))
            blk[l][j0:j1 + 1, i0:i1 + 1] |= dist < r

        for (ax, ay, bx, by, pnet, th, layer) in d["pads"]:
            if pnet == net:
                continue
            for l in (LAYERS if th else (layer,)):
                box(l, ax, ay, bx, by)
        for (ax, ay, bx, by, hw, snet, layer) in d["segs"]:
            if snet != net and layer in blk:
                capsule(layer, ax, ay, bx, by, hw)
        for (vx, vy, vr, vnet) in d["vias"]:
            if vnet != net:
                for l in LAYERS:
                    capsule(l, vx, vy, vx, vy, vr)
        return blk

    report = json.load(open(drc))
    jobs = []
    for item in report["unconnected_items"]:
        a, b = item["items"][:2]
        da, db = a["description"], b["description"]
        if da.startswith("Zone") or db.startswith("Zone"):
            continue
        net = re.search(r"\[([^\]]*)\]", da).group(1)
        pa, pb = a["pos"], b["pos"]
        la = "B.Cu" if "on B.Cu" in da and not da.startswith("Via") else "F.Cu"
        lb = "B.Cu" if "on B.Cu" in db and not db.startswith("Via") else "F.Cu"
        if net in PLANE_NETS:
            for desc, p, l in ((da, pa, la), (db, pb, lb)):
                if desc.startswith("Pad"):
                    jobs.append((net, (p["x"], p["y"], l), None))
        else:
            jobs.append((net, (pa["x"], pa["y"], la), (pb["x"], pb["y"], lb)))

    result = {"tracks": [], "vias": [], "failed": []}
    cache = {}
    seen = set()
    for net, src_pt, dst_pt in jobs:
        if (net, src_pt, dst_pt) in seen:
            continue
        seen.add((net, src_pt, dst_pt))
        if net not in cache:
            cache[net] = (raster(net, CLR + TRACK_W / 2), raster(net, CLR + VIA_D / 2))
        trk, via = cache[net]
        via_free = ~(via["F.Cu"] | via["B.Cu"])
        si, sj = cell(src_pt[0], src_pt[1])
        start = (LAYERS.index(src_pt[2]), sj, si)
        goal = None
        if dst_pt:
            gi, gj = cell(dst_pt[0], dst_pt[1])
            goal = (LAYERS.index(dst_pt[2]), gj, gi)

        def h(n):
            return 0 if goal is None else math.hypot(n[1] - goal[1], n[2] - goal[2])

        best = {start: 0.0}
        prev = {}
        heap = [(h(start), 0.0, start)]
        found = None
        steps = 0
        while heap and steps < 3000000:
            f, g, n = heapq.heappop(heap)
            if g > best.get(n, 1e18):
                continue
            steps += 1
            l, j, i = n
            if goal is None:
                if g > 0.6 / GRID and via_free[j, i]:      # clear of the pad itself
                    found = n
                    break
            elif n == goal or (abs(j - goal[1]) <= 1 and abs(i - goal[2]) <= 1 and l == goal[0]):
                found = n
                break
            for dj, di, cost in ((0, 1, 1), (0, -1, 1), (1, 0, 1), (-1, 0, 1),
                                 (1, 1, 1.414), (1, -1, 1.414), (-1, 1, 1.414), (-1, -1, 1.414)):
                jj, ii = j + dj, i + di
                if 0 <= jj < H and 0 <= ii < W and not trk[LAYERS[l]][jj, ii]:
                    m = (l, jj, ii)
                    ng = g + cost
                    if ng < best.get(m, 1e18):
                        best[m] = ng; prev[m] = n
                        heapq.heappush(heap, (ng + h(m), ng, m))
            if goal is not None and via_free[j, i]:
                m = (1 - l, j, i)
                ng = g + 40
                if not trk[LAYERS[1 - l]][j, i] and ng < best.get(m, 1e18):
                    best[m] = ng; prev[m] = n
                    heapq.heappush(heap, (ng + h(m), ng, m))
        if not found:
            result["failed"].append([net, src_pt])
            print("  failed %s at (%.2f, %.2f): start blocked=%s, cells searched=%d" % (net, src_pt[0], src_pt[1], bool(trk[src_pt[2]][sj, si]), steps))
            continue
        path = [found]
        while path[-1] in prev:
            path.append(prev[path[-1]])
        path.reverse()
        pts = [(LAYERS[l], x0 + i * GRID, y0 + j * GRID) for (l, j, i) in path]
        pts[0] = (pts[0][0], src_pt[0], src_pt[1])
        if dst_pt:
            pts[-1] = (pts[-1][0], dst_pt[0], dst_pt[1])
        # merge collinear steps
        run = [pts[0]]
        for k in range(1, len(pts)):
            a, b = run[-1], pts[k]
            if a[0] != b[0]:
                result["vias"].append([a[1], a[2], net])
                d["vias"].append([a[1], a[2], VIA_D / 2, net])
                run = [(b[0], a[1], a[2])]
                continue
            if k + 1 < len(pts) and pts[k + 1][0] == b[0] and len(run) >= 1:
                p, q = pts[k - 1], pts[k + 1]
                if abs((b[1] - p[1]) * (q[2] - b[2]) - (b[2] - p[2]) * (q[1] - b[1])) < 1e-9 and p[0] == b[0]:
                    continue
            result["tracks"].append([a[1], a[2], b[1], b[2], b[0], net])
            d["segs"].append([a[1], a[2], b[1], b[2], TRACK_W / 2, net, b[0]])
            run = [b]
        if goal is None:
            x, y = run[-1][1], run[-1][2]
            result["vias"].append([x, y, net])
            d["vias"].append([x, y, VIA_D / 2, net])
    json.dump(result, open(out, "w"))
    print("routed %d of %d; %d track segments, %d vias; failed: %s" % (
        len(seen) - len(result["failed"]), len(seen), len(result["tracks"]), len(result["vias"]),
        [f[0] for f in result["failed"]]))


def apply(pcb, src):
    import pcbnew
    MM = pcbnew.FromMM
    b = pcbnew.LoadBoard(pcb)
    r = json.load(open(src))
    for (ax, ay, bx, by, layer, net) in r["tracks"]:
        t = pcbnew.PCB_TRACK(b)
        t.SetStart(pcbnew.VECTOR2I(MM(ax), MM(ay)))
        t.SetEnd(pcbnew.VECTOR2I(MM(bx), MM(by)))
        t.SetWidth(MM(TRACK_W)); t.SetLayer(b.GetLayerID(layer)); t.SetNet(b.FindNet(net))
        b.Add(t)
    for (x, y, net) in r["vias"]:
        v = pcbnew.PCB_VIA(b)
        v.SetPosition(pcbnew.VECTOR2I(MM(x), MM(y)))
        v.SetWidth(pcbnew.F_Cu, MM(VIA_D)); v.SetDrill(MM(VIA_DRILL)); v.SetNet(b.FindNet(net))
        b.Add(v)
    pcbnew.ZONE_FILLER(b).Fill(b.Zones())
    pcbnew.SaveBoard(pcb, b)
    print("applied %d tracks, %d vias" % (len(r["tracks"]), len(r["vias"])))


if __name__ == "__main__":
    {"dump": dump, "solve": solve, "apply": apply}[sys.argv[1]](*sys.argv[2:])
