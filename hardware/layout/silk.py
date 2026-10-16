"""Production silkscreen (KiCad's Python).  Safe to run again after `pcb layout`.

    kicad-python layout/silk.py eda/s6la8.kicad_pcb

Reference designators go to the Fab layers (they stay in the assembly
drawing); the board is too dense for them on silk.  The horizontal probe
header's outline is trimmed at the board edge, and the labels a user needs
are added: channel numbers, jumper functions, JTAG, name, revision and logo.
"""
import sys

import pcbnew

MM = pcbnew.FromMM
b = pcbnew.LoadBoard(sys.argv[1])

for fp in b.GetFootprints():
    ref = fp.Reference()
    if ref.GetLayer() == pcbnew.F_SilkS:
        ref.SetLayer(pcbnew.F_Fab)
    elif ref.GetLayer() == pcbnew.B_SilkS:
        ref.SetLayer(pcbnew.B_Fab)

j3 = b.FindFootprintByReference("J3")
for g in list(j3.GraphicalItems()):
    if g.GetLayer() == pcbnew.F_SilkS and not isinstance(g, pcbnew.PCB_TEXT) \
            and pcbnew.ToMM(g.GetBoundingBox().GetLeft()) < 100.3:
        j3.Remove(g)

for t in list(b.GetDrawings()):                 # drop labels from an earlier run
    if isinstance(t, pcbnew.PCB_TEXT) and t.GetLayer() == pcbnew.F_SilkS:
        b.Remove(t)


def text(s, x, y, size=1.0, bold=False, left=False):
    t = pcbnew.PCB_TEXT(b)
    t.SetText(s)
    t.SetLayer(pcbnew.F_SilkS)
    t.SetPosition(pcbnew.VECTOR2I(MM(x), MM(y)))
    t.SetTextSize(pcbnew.VECTOR2I(MM(size), MM(size)))
    t.SetTextThickness(MM(size * (0.2 if bold else 0.15)))
    t.SetBold(bold)
    if left:
        t.SetHorizJustify(pcbnew.GR_TEXT_H_ALIGN_LEFT)
    b.Add(t)


for y, s in [(92.0, "0"), (89.46, "1"), (86.92, "2"), (84.38, "3"), (81.84, "4"), (79.3, "5"),
             (74.22, "7"), (71.68, "VR"), (69.14, "CK/TR")]:
    text(s, 111.0, y, 0.8, left=True)
text("6", 110.5, 76.76, 0.7, left=True)        # U3's outline is close
text("BLADE", 176.5, 110.0, 2.5, bold=True)
text("s6la8 rev A", 179.0, 63.0, 1.5, bold=True)
text("JTAG", 133.0, 63.5)
text("TGT  VREF  3V3", 118.5, 114.9, 0.8)
text("MODE", 131.3, 118.4, 0.8)

pcbnew.SaveBoard(sys.argv[1], b)
print("silkscreen done")
