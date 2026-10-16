#!/usr/bin/env python3
"""Build the manufacturing package for one board revision.

    python hardware/release.py A

Writes hardware/release/rev<R>/ with:
  gerbers/ + s6la8-rev<R>-gerbers.zip   copper, mask, paste, silk, outline, Excellon drill
  s6la8-rev<R>-bom-jlc.csv              Comment, Designator, Footprint, LCSC, MPN, Manufacturer
  s6la8-rev<R>-cpl-jlc.csv              Designator, Mid X, Mid Y, Layer, Rotation
  s6la8-rev<R>.step                     3D model for the enclosure and mechanical checks
  s6la8-rev<R>-schematic.pdf, -assembly.pdf
  s6la8-rev<R>-drc.json, -erc.json      the reports the release was checked with
  fab-notes.txt                         what to select in the fab's order form

It refuses to build if KiCad DRC reports an error or an unconnected item.
"""
import csv
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile

KICAD_CLI = os.environ.get("KICAD_CLI", r"C:\Program Files\KiCad\10.0\bin\kicad-cli.exe")
HERE = os.path.dirname(os.path.abspath(__file__))
PCB = os.path.join(HERE, "eda", "s6la8.kicad_pcb")
SCH = os.path.join(HERE, "eda", "s6la8.kicad_sch")
LAYERS = "F.Cu,In1.Cu,In2.Cu,B.Cu,F.Paste,B.Paste,F.Silkscreen,B.Silkscreen,F.Mask,B.Mask,Edge.Cuts"


def cli(*args):
    r = subprocess.run([KICAD_CLI] + list(args), capture_output=True, text=True)
    if r.returncode not in (0, 5):          # 5: violations found (we read the report ourselves)
        sys.exit("kicad-cli %s failed:\n%s%s" % (args[0:3], r.stdout, r.stderr))
    return r


def main(rev):
    out = os.path.join(HERE, "release", "rev" + rev)
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(os.path.join(out, "gerbers"))
    stem = os.path.join(out, "s6la8-rev" + rev)

    # ---- gate: KiCad is the arbiter
    cli("pcb", "drc", "--format", "json", "--severity-all", "--refill-zones", "--schematic-parity",
        "-o", stem + "-drc.json", PCB)
    drc = json.load(open(stem + "-drc.json"))
    errors = [v for v in drc["violations"] if v["severity"] == "error"]
    if errors or drc["unconnected_items"]:
        sys.exit("DRC: %d errors, %d unconnected - not releasing" % (len(errors), len(drc["unconnected_items"])))
    cli("sch", "erc", "--format", "json", "--severity-all", "-o", stem + "-erc.json", SCH)

    # ---- fabrication
    cli("pcb", "export", "gerbers", "--layers", LAYERS, "--subtract-soldermask", "--no-protel-ext",
        "-o", os.path.join(out, "gerbers") + os.sep, PCB)
    cli("pcb", "export", "drill", "--format", "excellon", "--drill-origin", "absolute",
        "--excellon-units", "mm", "--generate-map", "--map-format", "pdf",
        "-o", os.path.join(out, "gerbers") + os.sep, PCB)
    with zipfile.ZipFile(stem + "-gerbers.zip", "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(os.listdir(os.path.join(out, "gerbers"))):
            z.write(os.path.join(out, "gerbers", f), f)

    # ---- assembly: BOM and placement in JLCPCB's column names
    raw = stem + "-bom-raw.csv"
    cli("sch", "export", "bom", "--fields", "Reference,Value,Footprint,${QUANTITY},${DNP}",
        "--group-by", "Value,Footprint", "--ref-range-delimiter", "", "-o", raw, SCH)
    parts = {(r["value"], r["footprint"]): r for r in csv.DictReader(open(os.path.join(HERE, "parts.csv")))}
    missing = []
    with open(stem + "-bom-jlc.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Comment", "Designator", "Footprint", "LCSC Part #", "MPN", "Manufacturer", "Quantity", "Note"])
        for r in csv.DictReader(open(raw)):
            if r["DNP"]:
                continue
            fp = r["Footprint"].split(":")[-1]
            p = parts.get((r["Value"], fp))
            if p is None and not re.match(r"^[0-9.]+[pnuµm]?[FHk]?\b|^LED|^2\.54mm", r["Value"]):
                p = {"mpn": r["Value"], "manufacturer": "", "lcsc": "", "note": "IC: MPN is the value"}
            if p is None:
                p = {"mpn": "", "manufacturer": "", "lcsc": "", "note": "choose at order"}
                missing.append(r["Reference"])
            w.writerow([r["Value"], r["Reference"], fp, p["lcsc"], p["mpn"], p["manufacturer"], r["QUANTITY"], p["note"]])
    os.remove(raw)

    pos = stem + "-pos-raw.csv"
    cli("pcb", "export", "pos", "--format", "csv", "--units", "mm", "--side", "both",
        "--exclude-dnp", "--use-drill-file-origin", "-o", pos, PCB)
    with open(stem + "-cpl-jlc.csv", "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Designator", "Mid X", "Mid Y", "Layer", "Rotation"])
        for r in csv.DictReader(open(pos)):
            w.writerow([r["Ref"], r["PosX"] + "mm", r["PosY"] + "mm",
                        "Top" if r["Side"] == "top" else "Bottom", r["Rot"]])
    os.remove(pos)

    # ---- documents
    cli("pcb", "export", "step", "--subst-models", "-f", "-o", stem + ".step", PCB)
    cli("sch", "export", "pdf", "-o", stem + "-schematic.pdf", SCH)
    cli("pcb", "export", "pdf", "--layers", "F.Fab,Edge.Cuts,F.Silkscreen", "--mode-single",
        "-o", stem + "-assembly.pdf", PCB)

    with open(os.path.join(out, "fab-notes.txt"), "w") as f:
        f.write(FAB_NOTES)
    print("release %s written to %s" % (rev, out))
    print("DRC: 0 errors, 0 unconnected, %d warnings" % len(drc["violations"]))
    if missing:
        print("parts to choose at order (no MPN in parts.csv):", ", ".join(missing))


FAB_NOTES = """s6la8 - order settings
=====================

PCB
  Layers                4, stackup JLC04161H-7628 (or the fab's equivalent with
                        about 0.21 mm prepreg between the outer and inner layers)
  Thickness             1.6 mm
  Material              FR-4, TG155 or better
  Copper                1 oz outer, 0.5 oz inner
  Surface finish        ENIG (fine-pitch TQFP and SSOP; HASL is not flat enough)
  Solder mask           black, matte if offered
  Silkscreen            white
  Min track / space     0.12 / 0.15 mm;  min via 0.45 mm pad, 0.2 mm drill
  Via covering          tented (or "epoxy filled and capped" if vias in pads are added later)
  Impedance control     yes: USB_D_P / USB_D_N, 90 ohm differential, outer layers,
                        0.26 mm width, 0.15 mm gap (fab may trim the width)
  Board outline         100 x 64 mm, 4x M3 mounting holes
  Panel                 let the fab panelise with rails and fiducials (e.g. 2x2),
                        V-cut or tab routing; keep 0.5 mm from copper to the board edge

Assembly (top side only, plus 5 through-hole headers)
  SMT                   all parts on top
  Through-hole          J1, J2, J3, J5 (pin headers), J4 shell tabs are SMT-legs + THT pegs
  Parts                 see the BOM; parts without an LCSC number are matched by MPN or
                        chosen in the order form. Check every rotation in the fab's
                        placement preview (TQFP-144, SSOP-56, TSOP-II-54, SOT-23 parts).
  Inspection            ask for AOI and X-ray of the TQFP-144 and SSOP-56 on the first batch
  Programming           none: firmware and bitstream are loaded over USB by the driver.
                        The board-authentication tag is written to the EEPROM at your
                        end-of-line test (tools/provision.py).
"""

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "A")
