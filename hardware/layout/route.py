"""Autoroute the s6la8 board with Freerouting.  Run with KiCad's Python:

    "C:/Program Files/KiCad/10.0/bin/python.exe" layout/route.py eda/s6la8.kicad_pcb [passes]

In1.Cu is a solid GND plane and In2.Cu a solid 3.3 V plane; both are handed to
the router as power layers so it never runs signals through them.

Known limit: the Freerouting build used here only succeeds on a board with no
existing tracks.  With locked or kept wiring it hits an internal
NullPointerException and writes an empty session file, so plane vias cannot
be placed first and protected, and a completion-only pass does not work.  The recipe (power
layers, rules file, single-threaded optimiser) comes from an earlier board.
"""
import os
import re
import subprocess
import sys

import pcbnew

FREEROUTING = os.environ.get(
    "FREEROUTING",
    r"C:\Users\Semi\Desktop\2.Semester\Vibe\ub60a\work_freerouting\freerouting\freerouting.exe")
PLANES = {"In1.Cu": "GND", "In2.Cu": "VCC_3V3"}

RULES = """(rules PCB s6la8
  (layer_rule F.Cu
    (active on)
    (preferred_direction horizontal)
    (preferred_direction_trace_cost 1.0)
    (against_preferred_direction_trace_cost 2.0)
  )
  (layer_rule B.Cu
    (active on)
    (preferred_direction vertical)
    (preferred_direction_trace_cost 1.0)
    (against_preferred_direction_trace_cost 2.0)
  )
  (autoroute_settings
    (fanout off)
    (autoroute on)
    (postroute on)
    (vias on)
    (via_costs 20)
    (plane_via_costs 3)
    (start_ripup_costs 50)
  )
)
"""


def add_plane(board, layer_name, net_name):
    layer = board.GetLayerID(layer_name)
    for z in board.Zones():
        if z.GetFirstLayer() == layer and z.GetNetname() == net_name:
            return
    box = board.GetBoardEdgesBoundingBox()
    zone = pcbnew.ZONE(board)
    zone.SetLayer(layer)
    zone.SetNet(board.FindNet(net_name))
    zone.SetPadConnection(pcbnew.ZONE_CONNECTION_FULL)
    zone.SetLocalClearance(pcbnew.FromMM(0.2))
    outline = zone.Outline()
    outline.NewOutline()
    for x, y in ((box.GetLeft(), box.GetTop()), (box.GetRight(), box.GetTop()),
                 (box.GetRight(), box.GetBottom()), (box.GetLeft(), box.GetBottom())):
        outline.Append(x, y)
    board.Add(zone)


def main(path, passes="20", keep=""):
    work = os.path.join(os.path.dirname(os.path.abspath(path)), "..", "out", "route")
    os.makedirs(work, exist_ok=True)
    dsn, ses = os.path.join(work, "s6la8.dsn"), os.path.join(work, "s6la8.ses")

    board = pcbnew.LoadBoard(path)
    for layer, net in PLANES.items():
        add_plane(board, layer, net)
    if keep:
        # Completion pass: keep all routing, drop the outer pours so the
        # router sees free space, and let it close what is still open.
        for z in list(board.Zones()):
            if board.GetLayerName(z.GetFirstLayer()) not in PLANES:
                board.Remove(z)
    else:
        for t in list(board.GetTracks()):
            if not t.IsLocked():
                board.Remove(t)
    pcbnew.SaveBoard(path, board)
    if not pcbnew.ExportSpecctraDSN(board, dsn):
        raise SystemExit("Specctra export failed")

    text = open(dsn, encoding="utf-8", errors="replace").read()
    for layer in PLANES:
        text = re.sub(r"(\(layer\s+%s\s*\n\s*\(type\s+)signal(\s*\))" % re.escape(layer), r"\1power\2", text)
    open(dsn, "w", encoding="utf-8").write(text)
    rules = os.path.splitext(dsn)[0] + ".rules"
    open(rules, "w", encoding="utf-8").write(RULES)
    if os.path.exists(ses):
        os.remove(ses)

    if os.environ.get("FREEROUTING_CLI"):
        # Freerouting 2.5 jar on Java 25, run in the dev container (the jar
        # goes in .tools/freerouting; its native CLI build crashes on start).
        # Tried on this board: 175 connections left open after 15 passes,
        # against 17 with the older desktop build, so it is not the default.
        repo = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(path)), "..", ".."))
        cmd = ["docker", "run", "--rm", "-v", repo + ":/work", "-w", "/work/hardware/out/route", "s6la8-dev",
               "java", "-Djava.awt.headless=true", "-jar", "/work/.tools/freerouting/freerouting.jar", "-de", "s6la8.dsn", "-do", "s6la8.ses",
               "-mp", passes, "-dr", "s6la8.rules", "-mt", "1"]
    else:
        cmd = [FREEROUTING, "-de", dsn, "-do", ses, "-mp", passes, "-dr", rules, "-mt", "1"]
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=7200)
    open(os.path.join(work, "freerouting.log"), "w", encoding="utf-8").write((r.stdout or "") + (r.stderr or ""))
    if not os.path.exists(ses):
        raise SystemExit("Freerouting produced no session file")

    board = pcbnew.LoadBoard(path)
    if not pcbnew.ImportSpecctraSES(board, ses):
        raise SystemExit("Specctra session import failed")
    pcbnew.ZONE_FILLER(board).Fill(board.Zones())
    pcbnew.SaveBoard(path, board)
    print("routed: %d track segments and vias" % len(board.GetTracks()))


if __name__ == "__main__":
    main(*sys.argv[1:4])
