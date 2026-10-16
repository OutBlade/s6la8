# Making 100 units

Researched October 2026. Prices move; treat every number here as an estimate
to check against a live quote, not as a quote.

## Recommendation

1. **Build 5 prototypes first** (JLCPCB PCBA, same files as production). Bring
   them up and run the tests in "Before the 100" below. Do not order 100 boards
   from an unvalidated design: one wrong footprint or pin would scrap the batch.
2. **Order the 100 from JLCPCB, fully assembled, panelised by the fab**,
   with the FPGA and FX2 checked for genuine sourcing (see "Parts"). For this
   board JLCPCB is the cheapest complete route: board, stencil, parts (through
   LCSC, its sister company) and assembly in one order, with an instant quote.
3. **Get a second quote from PCBWay** with the same zip, BOM and CPL. Its
   quotes are reviewed by a person (1 to 2 working days) and it can source
   parts that LCSC lacks; it tends to cost more for simple boards.
4. **Print the enclosures yourself** (or through a print service) and do the
   final test, provisioning and boxing in house. That last step is also what
   makes clones fail (see `README.md`, "Copy protection").

## Files to upload

`python hardware/release.py A` writes `hardware/release/revA/`:

| File | Use |
|---|---|
| `s6la8-revA-gerbers.zip` | PCB order (Gerber X2 + Excellon) |
| `s6la8-revA-bom-jlc.csv` | assembly BOM (LCSC numbers where known, MPN otherwise) |
| `s6la8-revA-cpl-jlc.csv` | pick-and-place |
| `fab-notes.txt` | the options to choose in the order form |

In the order form: 4 layers, 1.6 mm, JLC04161H-7628 stackup, **ENIG**,
**impedance control** (USB pair 90 ohm), black mask, tented vias, top-side
assembly, "panel by JLCPCB" (e.g. 2x2 with rails and fiducials). Check each
part's rotation in the placement preview before paying; the TQFP-144, SSOP-56,
TSOP-II-54 and SOT-23 packages are the usual suspects.

## Rough cost per unit at 100 pieces

| Item | Estimate | Notes |
|---|---|---|
| FPGA XC6SLX9-2TQG144C | $5 to $35 | LCSC listed about $5.36 at 120+; authorised distributors (Mouser, Newark) $29 to $35. The low price may be grey-market stock; see below |
| FX2LP CY7C68013A-56PVXC | about $8 | LCSC about $7.90 at 104+ |
| SDRAM, logic, ESD, bucks, EEPROM, clocks, USB-C | about $8 | |
| Passives, LEDs, headers | about $1.50 | mostly JLC "basic" parts (no extra loading fee) |
| 4-layer PCB, ENIG, impedance control | $2 to $4 | per board at 100 |
| Assembly | $3 to $5 | setup fee per side, stencil, about $0.0016 per solder joint, $3 per "extended" part type per order, hand-soldered headers |
| **Board total** | **about $30 (LCSC FPGA) to $60 (authorised FPGA)** | before shipping and import |
| Enclosure, printed in PETG | $2 to $4 | about 60 g filament; 4 heat-set inserts, 4 screws, 4 feet about $1 |

Shipping DHL/FedEx for 100 boards: roughly $40 to $80.

## Import into Germany / the EU

- The EU's EUR 150 customs-duty exemption ended on **1 July 2026**. Low-value
  consumer parcels now pay a flat EUR 3 per item line until the 2028 reform;
  business imports pay the normal tariff rate for the goods' customs code.
- **Import VAT (19 %) applies from the first euro**, on goods plus shipping
  plus duty. As a VAT-registered business you can reclaim it.
- Look up the duty for your goods code in TARIC (assembled measuring
  instrument modules are usually 0 to a few percent); the courier clears customs
  and bills you.

## Selling them in Germany

This applies once you sell to the public, even small quantities. Check with
the IHK or a compliance service before the first sale.

- **CE marking**: EMC Directive 2014/30/EU (and RoHS 2011/65/EU). For a
  USB-powered 5 V device the Low Voltage Directive does not apply. You write
  the EU declaration of conformity yourself, backed by a technical file; an
  EMC pre-scan at a test lab (a few hundred euros) is strongly advised.
- **WEEE / ElektroG**: register with **stiftung ear** before offering the
  product (takes several weeks), print the WEEE number on invoices and
  listings, report quantities. Marketplaces such as eBay remove listings
  without it.
- **Packaging (VerpackG)**: register the packaging in LUCID and join a
  take-back scheme.
- **USB IDs**: replace the pid.codes test ID `1209:0001` with your own PID
  (free from pid.codes for open hardware) before selling.
- Product safety (GPSR): name and address on the product or packaging,
  instructions in German.

## Parts: watch the FPGA

XC6SLX9 is a mature part, and much of the cheap stock in the market is
recovered or remarked. For a product:

- buy the FPGA (and ideally the FX2) from an authorised distributor and
  consign them to the assembler, **or** order from LCSC/JLC and inspect the
  first boards (DNA readout works, JTAG IDCODE correct, configuration
  succeeds).
- The authentication scheme uses the FPGA's Device DNA, so a remarked part
  still works; it only has to be a real Spartan-6.

## Before the 100

Not done yet, in this order:

1. ISE build with no timing errors (`gateware/ise/README-docker.md`).
2. Five prototypes: rails, current draw, USB high-speed enumeration, FPGA
   configuration, DNA readout and provisioning, fallback mode with stock
   sigrok, 10 minutes of streaming the test pattern without errors, a
   32 M-sample SDRAM capture of the test pattern at 100 MS/s without a
   sequence break (if it fails, adjust CLKOUT1_PHASE in clkgen.v), a
   triggered capture of a known signal at 1.8 V, 3.3 V and 5 V.
3. Fit check of the printed case on a real board (`case/`).
4. EMC pre-scan with the case.
5. Fix whatever these turn up, then freeze rev A (or rev B) and order.

## End-of-line test per unit (about 2 minutes)

1. Plug in. Driver loads firmware and bitstream; DONE LED on.
2. Fit the MODE jumper, run `python tools/provision.py` with the product key:
   it reads the DNA, writes the tag to the EEPROM (see `tools/eol.py`).
3. Remove the jumper, re-plug: authentication passes, test-pattern capture
   passes, probe loopback with a test fixture passes.
4. Close the case, label with serial number (= DNA), box.

Sources: JLCPCB assembly pricing and FAQ (jlcpcb.com/help), LCSC product pages
C27408 and C26717, NextPCB and lead-pcb.com service comparisons, Avalara, DHL
and UPS on the EU de-minimis change, stiftung ear guidance via eBay and
compliance-service summaries.
