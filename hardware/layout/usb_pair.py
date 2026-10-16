"""Route the USB 2.0 pair as a coupled 90-ohm pair (KiCad's Python).

    kicad-python layout/usb_pair.py eda/s6la8.kicad_pcb

0.26 mm tracks with a 0.15 mm gap on the outer layers of JLCPCB's
JLC04161H-7628 stackup (0.21 mm prepreg to the plane, er 4.4) give about
90 ohm differential (Hammerstad-Jensen plus the IPC-2141 coupling term).
Order with impedance control so the fab trims the width.  The pair runs on
F.Cu over the GND plane from the ESD clamp U6 to x = 163 mm and then on B.Cu
over the 3.3 V plane to the vias at FX2 pins 15 and 16; the short stubs at
the connector, the clamp and the FX2 pads are left as routed.
"""
import subprocess
import sys

import pcbnew

MM, mm = pcbnew.FromMM, pcbnew.ToMM
W = 0.26
if sys.argv[2:] != ["add"]:
    b = pcbnew.LoadBoard(sys.argv[1])
    b.Zones()                                    # touch zones before removing anything
    remove_old = True
else:
    remove_old = False

# the long run and the bottom-layer diagonals of the old route
if remove_old:
    for t in list(b.GetTracks()):
        if t.GetNetname() not in ("USB_D_P", "USB_D_N"):
            continue
        xs = (mm(t.GetStart().x), mm(t.GetEnd().x))
        if t.Type() == pcbnew.PCB_VIA_T:
            if 162 < xs[0] < 163.5:
                b.Remove(t)
        elif b.GetLayerName(t.GetLayer()) == "B.Cu" or (max(xs) > 180 and min(xs) < 170):
            b.Remove(t)
    pcbnew.SaveBoard(sys.argv[1], b)
    # KiCad's bindings misbehave when items are removed and added in one process
    sys.exit(subprocess.call([sys.executable, __file__, sys.argv[1], "add"]))

b = pcbnew.LoadBoard(sys.argv[1])


def trk(net, pts, layer):
    for (ax, ay), (bx, by) in zip(pts, pts[1:]):
        t = pcbnew.PCB_TRACK(b)
        t.SetStart(pcbnew.VECTOR2I(MM(ax), MM(ay)))
        t.SetEnd(pcbnew.VECTOR2I(MM(bx), MM(by)))
        t.SetWidth(MM(W))
        t.SetLayer(b.GetLayerID(layer))
        t.SetNet(b.FindNet(net))
        b.Add(t)


def via(net, x, y):
    v = pcbnew.PCB_VIA(b)
    v.SetPosition(pcbnew.VECTOR2I(MM(x), MM(y)))
    v.SetWidth(pcbnew.F_Cu, MM(0.45))
    v.SetDrill(MM(0.2))
    v.SetNet(b.FindNet(net))
    b.Add(v)


# top layer: P at y 110.90, N at y 111.31 (pitch 0.41); split round U6 pin 2
trk("USB_D_P", [(186.92, 110.37), (185.93, 110.37), (185.40, 110.90), (162.66, 110.90)], "F.Cu")
trk("USB_D_N", [(186.92, 112.27), (186.26, 112.27), (185.30, 111.31), (163.50, 111.31), (163.10, 112.00)], "F.Cu")
via("USB_D_P", 162.66, 110.90)
via("USB_D_N", 163.10, 112.00)
# bottom layer: diagonals x+y = 274.02 (P) and 274.60 (N), pitch 0.41
trk("USB_D_P", [(162.66, 110.90), (162.66, 111.36), (156.32, 117.70)], "B.Cu")
trk("USB_D_N", [(163.10, 112.00), (162.60, 112.00), (156.91, 117.69), (157.08, 117.69)], "B.Cu")
pcbnew.ZONE_FILLER(b).Fill(b.Zones())
pcbnew.SaveBoard(sys.argv[1], b)
print("USB pair routed")
