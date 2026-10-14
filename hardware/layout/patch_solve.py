"""Grid router for the connections the autorouter left open (needs numpy).

    python layout/patch_solve.py out/patch_in.json out/drc.json out/patch_out.json

Input comes from `patch.py dump` and KiCad's DRC report; output goes to
`patch.py rip` and `patch.py apply`.  Other-net copper on F.Cu and B.Cu is
rasterised at 0.05 mm with clearance and each open connection is searched with
A*.  Pads on a plane net only need to reach a spot where a via fits.

When a pad is boxed in, neighbouring signal nets are moved out of the way:
first only the piece of a net that lies near the pad is cut out and its loose
ends are joined again around the new copper, then, if that fails, a whole net
is lifted and routed again.  A change is kept only if everything reconnects.
"""
import heapq
import itertools
import json
import math
import os
import re
import sys

import numpy as np

GRID = 0.05
TRACK_W, VIA_D, CLR = 0.16, 0.45, 0.152
PLANE_NETS = ("GND", "VCC_3V3")
LAYERS = ("F.Cu", "B.Cu")
LIFT = int(os.environ.get("LIFT", "2"))      # how many nets may be cut at once for a boxed-in pad
VERBOSE = bool(os.environ.get("VERBOSE"))
MARGIN = 7.0                                 # a search may stray this far (mm) from its end points


def key(x, y):
    return (round(x, 3), round(y, 3))


def main(src, drc, out):
    d = json.load(open(src))
    x0, y0, x1, y1 = d["edge"]
    W, H = int((x1 - x0) / GRID) + 1, int((y1 - y0) / GRID) + 1

    def cell(x, y):
        return int(round((x - x0) / GRID)), int(round((y - y0) / GRID))

    def raster(net, grow, win):
        """blocked[layer][y, x] for copper of other nets, inflated by grow.
        Everything outside the window win = (xa, ya, xb, yb) counts as blocked."""
        wa, wb = cell(win[0], win[1]), cell(win[2], win[3])
        m = int(1.0 / GRID)                       # keep off the board edge
        ia, ja = max(wa[0], m), max(wa[1], m)
        ib, jb = min(wb[0], W - m), min(wb[1], H - m)
        blk = {}
        for l in LAYERS:
            blk[l] = np.ones((H, W), dtype=bool)
            blk[l][ja:jb, ia:ib] = False
        pad = grow + 1.0

        def outside(ax, ay, bx, by):
            return max(ax, bx) < win[0] - pad or min(ax, bx) > win[2] + pad or \
                   max(ay, by) < win[1] - pad or min(ay, by) > win[3] + pad

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
            blk[l][j0:j1 + 1, i0:i1 + 1] |= np.hypot(X - (ax + t * dx), Y - (ay + t * dy)) < r

        for (ax, ay, bx, by, pnet, th, layer) in d["pads"]:
            if pnet != net and not outside(ax, ay, bx, by):
                for l in (LAYERS if th else (layer,)):
                    box(l, ax, ay, bx, by)
        for (ax, ay, bx, by, hw, snet, layer) in d["segs"]:
            if snet != net and layer in blk and not outside(ax, ay, bx, by):
                capsule(layer, ax, ay, bx, by, hw)
        for (vx, vy, vr, vnet) in d["vias"]:
            if vnet != net and not outside(vx, vy, vx, vy):
                for l in LAYERS:
                    capsule(l, vx, vy, vx, vy, vr)
        return blk

    reach = [""]                                   # where the last failed search got to

    def route(net, src_pt, dst_pt, lead=0.6):
        """A* from src to dst, or with dst None to the nearest via site at
        least `lead` mm of track away.  Returns (tracks, vias) or None."""
        ends = [src_pt, dst_pt or src_pt]
        win = (min(e[0] for e in ends) - MARGIN, min(e[1] for e in ends) - MARGIN,
               max(e[0] for e in ends) + MARGIN, max(e[1] for e in ends) + MARGIN)
        trk = raster(net, CLR + TRACK_W / 2, win)
        via = raster(net, CLR + VIA_D / 2, win)
        via_free = ~(via["F.Cu"] | via["B.Cu"])
        si, sj = cell(src_pt[0], src_pt[1])
        start = (LAYERS.index(src_pt[2]), sj, si)
        goal = None
        if dst_pt:
            gi, gj = cell(dst_pt[0], dst_pt[1])
            goal = (LAYERS.index(dst_pt[2]), gj, gi)

        def h(n):
            return 0 if goal is None else math.hypot(n[1] - goal[1], n[2] - goal[2])

        best, prev, heap, found, steps = {start: 0.0}, {}, [(h(start), 0.0, start)], None, 0
        while heap and steps < 1500000:
            f, g, n = heapq.heappop(heap)
            if g > best.get(n, 1e18):
                continue
            steps += 1
            l, j, i = n
            if goal is None:
                if g > lead / GRID and via_free[j, i]:
                    found = n
                    break
            elif l == goal[0] and abs(j - goal[1]) <= 1 and abs(i - goal[2]) <= 1:
                found = n
                break
            for dj, di, cost in ((0, 1, 1), (0, -1, 1), (1, 0, 1), (-1, 0, 1),
                                 (1, 1, 1.414), (1, -1, 1.414), (-1, 1, 1.414), (-1, -1, 1.414)):
                jj, ii = j + dj, i + di
                if 0 <= jj < H and 0 <= ii < W and not trk[LAYERS[l]][jj, ii]:
                    m = (l, jj, ii)
                    ng = g + cost
                    if ng < best.get(m, 1e18):
                        best[m] = ng
                        prev[m] = n
                        heapq.heappush(heap, (ng + h(m), ng, m))
            if goal is not None and via_free[j, i] and not trk[LAYERS[1 - l]][j, i]:
                m = (1 - l, j, i)
                ng = g + 40
                if ng < best.get(m, 1e18):
                    best[m] = ng
                    prev[m] = n
                    heapq.heappush(heap, (ng + h(m), ng, m))
        if not found:
            js, is_ = [n[1] for n in best], [n[2] for n in best]
            reach[0] = "%d cells, x %.2f..%.2f, y %.2f..%.2f" % (
                len(best), x0 + min(is_) * GRID, x0 + max(is_) * GRID, y0 + min(js) * GRID, y0 + max(js) * GRID)
            return None
        path = [found]
        while path[-1] in prev:
            path.append(prev[path[-1]])
        path.reverse()
        pts = [[LAYERS[l], x0 + i * GRID, y0 + j * GRID] for (l, j, i) in path]
        pts[0][1:] = src_pt[:2]
        if dst_pt:
            pts[-1][1:] = dst_pt[:2]
        tracks, vias, a = [], [], pts[0]
        for k in range(1, len(pts)):
            b = pts[k]
            if b[0] != a[0]:                       # layer change: via here
                vias.append([a[1], a[2], net])
                a = [b[0], a[1], a[2]]
                continue
            if k < len(pts) - 1 and pts[k + 1][0] == b[0]:
                q, pr = pts[k + 1], pts[k - 1]
                if pr[0] == b[0] and abs((b[1] - pr[1]) * (q[2] - b[2]) - (b[2] - pr[2]) * (q[1] - b[1])) < 1e-9:
                    continue                       # still going straight
            tracks.append([a[1], a[2], b[1], b[2], b[0], net])
            a = b
        if goal is None:
            vias.append([a[1], a[2], net])
        return tracks, vias

    def commit(tracks, vias):
        for (ax, ay, bx, by, layer, net) in tracks:
            d["segs"].append([ax, ay, bx, by, TRACK_W / 2, net, layer])
        for (x, y, net) in vias:
            d["vias"].append([x, y, VIA_D / 2, net])

    def groups(net):
        """Which copper of a net hangs together: returns node(point) -> group id."""
        par = {}

        def find(a):
            par.setdefault(a, a)
            while par[a] != a:
                par[a] = par[par[a]]
                a = par[a]
            return a

        centre = {}
        segs = [s for s in d["segs"] if s[5] == net]
        for s in segs:
            par[find((key(s[0], s[1]), s[6]))] = find((key(s[2], s[3]), s[6]))
        for v in d["vias"]:
            if v[3] == net:
                par[find((key(v[0], v[1]), "F.Cu"))] = find((key(v[0], v[1]), "B.Cu"))
        for n, (ax, ay, bx, by, pnet, th, layer) in enumerate(d["pads"]):
            if pnet != net:
                continue
            centre[key((ax + bx) / 2, (ay + by) / 2)] = ("pad", n)
            for s in segs:
                for x, y in ((s[0], s[1]), (s[2], s[3])):
                    if ax - 0.01 <= x <= bx + 0.01 and ay - 0.01 <= y <= by + 0.01 and (th or layer == s[6]):
                        par[find(("pad", n))] = find((key(x, y), s[6]))
        return lambda pt: find(centre.get(key(pt[0], pt[1]), (key(pt[0], pt[1]), pt[2])))

    def join(net, terms):
        """Reconnect the loose ends of a net: each to the first one, or failing
        that to any other copper of the net that is not part of the same piece."""
        tracks, vias = [], []
        for k in range(1, len(terms)):
            group = groups(net)
            if group(terms[k]) == group(terms[0]):
                continue                           # still joined some other way
            others = [((ax + bx) / 2, (ay + by) / 2, "F.Cu" if th else layer)
                      for (ax, ay, bx, by, pnet, th, layer) in d["pads"] if pnet == net]
            others += [(v[0], v[1], "F.Cu") for v in d["vias"] if v[3] == net]
            others = [o for o in others if group(o) != group(terms[k])]
            others.sort(key=lambda o: math.hypot(o[0] - terms[k][0], o[1] - terms[k][1]))
            for target in [terms[0]] + others[:6]:
                r = route(net, terms[k], target)
                if r:
                    break
            if r is None:
                return None
            commit(*r)
            tracks += r[0]
            vias += r[1]
        return tracks, vias

    def lift(net, c=None, R=None):
        """Take copper of a net off the model: all of it, or what lies within
        R of c.  Returns (segments, vias, terminals to join again)."""
        def near(x, y):
            return c is None or math.hypot(x - c[0], y - c[1]) < R
        rs = [s for s in d["segs"] if s[5] == net and (near(s[0], s[1]) or near(s[2], s[3]))]
        rv = [v for v in d["vias"] if v[3] == net and near(v[0], v[1])]
        ids = set(map(id, rs)) | set(map(id, rv))
        d["segs"] = [s for s in d["segs"] if id(s) not in ids]
        d["vias"] = [v for v in d["vias"] if id(v) not in ids]
        pads = [((ax + bx) / 2, (ay + by) / 2, "F.Cu" if th else layer, (ax, ay, bx, by))
                for (ax, ay, bx, by, pnet, th, layer) in d["pads"] if pnet == net]
        if c is None:
            return rs, rv, [p[:3] for p in pads]
        cut = {}                                   # points where removed copper ended -> its layer
        for s in rs:
            cut[key(s[0], s[1])] = cut[key(s[2], s[3])] = s[6]
        for v in rv:
            cut.setdefault(key(v[0], v[1]), "F.Cu")
        terms = {}
        for s in d["segs"]:
            if s[5] == net:
                for x, y in ((s[0], s[1]), (s[2], s[3])):
                    if key(x, y) in cut:
                        terms.setdefault(key(x, y), (x, y, s[6]))
        for v in d["vias"]:
            if v[3] == net and key(v[0], v[1]) in cut:
                terms.setdefault(key(v[0], v[1]), (v[0], v[1], cut[key(v[0], v[1])]))
        for px, py, pl, (ax, ay, bx, by) in pads:
            if any(ax - 1e-3 <= kx <= bx + 1e-3 and ay - 1e-3 <= ky <= by + 1e-3 for kx, ky in cut):
                terms.setdefault(key(px, py), (px, py, pl))
        return rs, rv, list(terms.values())

    jobs = []
    for item in json.load(open(drc))["unconnected_items"]:
        a, b = item["items"][:2]
        da, db = a["description"], b["description"]
        if da.startswith("Zone") and db.startswith("Zone"):
            continue
        if da.startswith("Zone"):
            a, b, da, db = b, a, db, da
        net = re.search(r"\[([^\]]*)\]", da).group(1)
        la = "B.Cu" if "on B.Cu" in da and not da.startswith("Via") else "F.Cu"
        lb = "B.Cu" if "on B.Cu" in db and not db.startswith("Via") else "F.Cu"
        pa, pb = (a["pos"]["x"], a["pos"]["y"], la), (b["pos"]["x"], b["pos"]["y"], lb)
        if net in PLANE_NETS:
            ends = [(da, pa), (db, pb)]
            if not any(desc.startswith(("Pad", "Zone")) for desc, pt in ends):
                ends = ends[:1]                    # two track stubs: one via joins them through the plane
            if any(desc.startswith("Pad") for desc, pt in ends):
                ends = [e for e in ends if e[0].startswith("Pad")]
            for desc, pt in ends:
                if not desc.startswith(("Via", "Zone")) and (net, pt, None) not in jobs:
                    jobs.append((net, pt, None))
        elif (net, pa, pb) not in jobs:
            jobs.append((net, pa, pb))

    for net, x, y, layer in d.get("islands", []):
        if net in PLANE_NETS and (net, (x, y, layer), None) not in jobs:
            jobs.append((net, (x, y, layer), None))

    result = {"tracks": [], "vias": [], "ripped": [], "rip_segs": [], "rip_vias": [], "failed": []}
    for net, src_pt, dst_pt in jobs:
        r = route(net, src_pt, dst_pt)
        if r:
            commit(*r)
            result["tracks"] += r[0]
            result["vias"] += r[1]
            continue
        boxed = reach[0]
        near = []
        for (ax, ay, bx, by, hw, snet, layer) in d["segs"]:
            if snet in PLANE_NETS or snet == net or snet in near:
                continue
            if min(math.hypot(ax - src_pt[0], ay - src_pt[1]), math.hypot(bx - src_pt[0], by - src_pt[1])) < 1.6:
                near.append(snet)
        tries = [(c, R) for R in (1.5, 3.0) for n in range(1, LIFT + 1) for c in itertools.combinations(near, n)]
        tries += [((v,), None) for v in near]
        done = False
        for victims, R in tries:
            saved = (d["segs"], d["vias"])
            cuts = [lift(v, src_pt if R else None, R) for v in victims]
            lifted = (d["segs"], d["vias"])
            # a via dropped right next to the pad often sits in the cut net's way; try further out too
            for lead in ((0.6,) if dst_pt else (0.6, 1.5, 3.0)):
                d["segs"], d["vias"] = list(lifted[0]), list(lifted[1])
                r = route(net, src_pt, dst_pt, lead)
                rr = []
                if not r:
                    break
                commit(*r)
                for v, (rs, rv, terms) in zip(victims, cuts):
                    rr.append(join(v, terms))
                    if rr[-1] is None:
                        break
                if VERBOSE:
                    print("    %s R=%s lead=%s: pad %s, rejoin %s; ends %s" % (
                        victims, R, lead, bool(r), [x is not None for x in rr],
                        [[(round(t[0], 2), round(t[1], 2), t[2]) for t in c[2]] for c in cuts]))
                if None not in rr:
                    break
            if not (r and None not in rr):
                d["segs"], d["vias"] = saved
                continue
            new = [(r[0], r[1])] + rr
            for v, (rs, rv, terms) in zip(victims, cuts):
                if R is None and v not in result["ripped"]:
                    result["ripped"].append(v)
                for s in rs:                       # copper added earlier in this run is simply dropped again
                    t = [s[0], s[1], s[2], s[3], s[6], s[5]]
                    if t in result["tracks"]:
                        result["tracks"].remove(t)
                    else:
                        result["rip_segs"].append(t)
                for s in rv:
                    t = [s[0], s[1], s[3]]
                    if t in result["vias"]:
                        result["vias"].remove(t)
                    else:
                        result["rip_vias"].append(t)
            for t, v in new:
                result["tracks"] += t
                result["vias"] += v
            print("  %s at (%.2f, %.2f): moved %s (%s)" % (
                net, src_pt[0], src_pt[1], list(victims), "within %.1f mm" % R if R else "whole net"))
            done = True
            break
        if not done:
            result["failed"].append([net, src_pt])
            print("  failed %s at (%.2f, %.2f); reached %s; tried moving %s" % (net, src_pt[0], src_pt[1], boxed, near))
    seen, vias = set(), []
    for x, y, net in result["vias"]:                # routes of one net may share a via
        if key(x, y) not in seen:
            seen.add(key(x, y))
            vias.append([x, y, net])
    result["vias"] = vias
    json.dump(result, open(out, "w"))
    print("routed %d of %d; lifted %s, cut %d segments; failed %s" % (
        len(jobs) - len(result["failed"]), len(jobs), result["ripped"], len(result["rip_segs"]),
        [f[0] for f in result["failed"]]))


if __name__ == "__main__":
    main(*sys.argv[1:4])
