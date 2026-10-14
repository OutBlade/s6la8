"""Close the last open connections the autorouter left behind.

The grid search wants numpy and KiCad's Python has none, so the work is split:

    kicad-python layout/patch.py dump  eda/s6la8.kicad_pcb out/patch_in.json
    python       layout/patch_solve.py out/patch_in.json out/drc.json out/patch_out.json
    kicad-python layout/patch.py rip   eda/s6la8.kicad_pcb out/patch_out.json [out/drc.json]
    kicad-python layout/patch.py apply eda/s6la8.kicad_pcb out/patch_out.json

`rip` removes the copper of nets the solver lifted and rerouted, duplicate
vias, and (given the DRC report) vias drilled too close to another hole of
their own net.  It is a separate run because KiCad's Python bindings
misbehave when items are removed and added in one process.
"""
import json
import re
import sys

TRACK_W, VIA_D, VIA_DRILL = 0.16, 0.45, 0.2


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
    # pour fragments that hang on surface pads only, with no via or through-hole pad to their plane
    data["islands"] = []
    for z in b.Zones():
        for lid in z.GetLayerSet().Seq():
            if not b.GetLayerName(lid) in ("F.Cu", "B.Cu"):
                continue
            polys = z.GetFilledPolysList(lid)
            for k in range(polys.OutlineCount()):
                def inside(pt):
                    return polys.Contains(pt, k)
                tied = any(t.Type() == pcbnew.PCB_VIA_T and t.GetNetname() == z.GetNetname() and inside(t.GetStart())
                           for t in b.GetTracks())
                pads = [p for fp in b.GetFootprints() for p in fp.Pads()
                        if p.GetNetname() == z.GetNetname() and inside(p.GetPosition())]
                tied = tied or any(p.GetAttribute() != pcbnew.PAD_ATTRIB_SMD for p in pads)
                # a track of the net leaving the fragment is taken to end at a via
                tied = tied or any(t.Type() != pcbnew.PCB_VIA_T and t.GetNetname() == z.GetNetname()
                                   and t.GetLayer() == lid and inside(t.GetStart()) != inside(t.GetEnd())
                                   for t in b.GetTracks())
                if pads and not tied:
                    c = pads[0].GetPosition()
                    data["islands"].append([z.GetNetname(), mm(c.x), mm(c.y), b.GetLayerName(lid)])
    json.dump(data, open(out, "w"))
    print("%d pour fragments without a plane connection" % len(data["islands"]))
    print("dumped %d pads, %d segments, %d vias" % (len(data["pads"]), len(data["segs"]), len(data["vias"])))


def rip(pcb, src, drc=None):
    import pcbnew
    b = pcbnew.LoadBoard(pcb)
    nets = set(json.load(open(src)).get("ripped", []))
    b.Zones()                                   # touch zones before removing anything
    victims = [t for t in b.GetTracks() if t.GetNetname() in nets]
    crowded = set()                             # vias drilled too close to another hole of their own net
    for v in json.load(open(drc))["violations"] if drc else []:
        d = [i["description"] for i in v["items"]]
        if v["type"] == "hole_to_hole" and d[0].startswith("Via") and d[1].startswith(("PTH pad", "Via")) \
                and re.findall(r"\[([^\]]*)\]", d[0]) == re.findall(r"\[([^\]]*)\]", d[1]):
            crowded.add((round(v["items"][0]["pos"]["x"], 2), round(v["items"][0]["pos"]["y"], 2)))
    for t in b.GetTracks():
        if t.Type() == pcbnew.PCB_VIA_T and \
                (round(pcbnew.ToMM(t.GetStart().x), 2), round(pcbnew.ToMM(t.GetStart().y), 2)) in crowded:
            victims.append(t)
    seen = set()
    for t in b.GetTracks():                     # one via per spot
        if t.Type() == pcbnew.PCB_VIA_T and t.GetNetname() not in nets:
            key = (t.GetStart().x, t.GetStart().y)
            if key in seen:
                victims.append(t)
            seen.add(key)
    for t in victims:
        b.Remove(t)
    pcbnew.SaveBoard(pcb, b)
    print("removed %d items of %s" % (len(victims), sorted(nets)))


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
    {"dump": dump, "rip": rip, "apply": apply}[sys.argv[1]](*sys.argv[2:])
