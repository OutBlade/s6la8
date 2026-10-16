"""Collision check between the populated board and the printed case.

    kicad-cli pcb export stl -f -o case/build/board.stl hardware/eda/s6la8.kicad_pcb
    openscad -D 'part="tray"' -o case/build/tray.stl case/s6la8_case.scad
    openscad -D 'part="lid_in_place"' -o case/build/lid_in_place.stl case/s6la8_case.scad
    python case/check.py

Every vertex and triangle centre of the board model is tested against the
two case solids; anything inside one of them is a collision.  The board's own
mounting-hole pads are expected to touch the bosses that clamp them.
"""
import os
import sys

import numpy as np
import trimesh

here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "build")
board = trimesh.load(os.path.join(here, "board.stl"))
pts = np.vstack([board.vertices, board.triangles_center])
holes = np.array([[104, -64], [196, -64], [104, -120], [196, -120]])
near_hole = np.min(np.hypot(pts[:, None, 0] - holes[:, 0], pts[:, None, 1] - holes[:, 1]), axis=1) < 3.3
pts = pts[~near_hole]

bad = 0
for name in ("tray", "lid_in_place"):
    case = trimesh.load(os.path.join(here, name + ".stl"))
    assert case.is_watertight, name + " is not watertight"
    hit = pts[case.contains(pts)]
    if len(hit):                                   # faces that merely touch (within 0.05 mm) do not count
        d = trimesh.proximity.signed_distance(case, hit)
        hit = hit[d > 0.05]
    print("%-13s %6d board points inside the case%s" % (
        name, len(hit), "" if not len(hit) else ", e.g. at x %.1f..%.1f  y %.1f..%.1f  z %.1f..%.1f" % (
            hit[:, 0].min(), hit[:, 0].max(), hit[:, 1].min(), hit[:, 1].max(), hit[:, 2].min(), hit[:, 2].max())))
    bad += len(hit)
sys.exit(1 if bad else 0)
