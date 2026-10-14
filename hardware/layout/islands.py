"""Drop unconnected copper islands from every pour and refill (KiCad's Python).

    kicad-python layout/islands.py eda/s6la8.kicad_pcb
"""
import sys

import pcbnew

b = pcbnew.LoadBoard(sys.argv[1])
zones = b.Zones()
for z in zones:
    z.SetIslandRemovalMode(pcbnew.ISLAND_REMOVAL_MODE_ALWAYS)
pcbnew.ZONE_FILLER(b).Fill(zones)
pcbnew.SaveBoard(sys.argv[1], b)
print("island removal set on %d zones" % len(zones))
