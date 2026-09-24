#!/usr/bin/env python3
"""
Assembly files for the DifNif 72-pin board (Rev P2): BOM and placement.

Writes, next to the Gerber zip in pcb_formfactor/fab/:
  DifNifFormFactor-RevP2-BOM.csv        grouped parts list with manufacturer
                                        part numbers
  DifNifFormFactor-RevP2-positions.csv  placement (centroid) file for the
                                        surface-mount parts

Part numbers come from the schematic's Mouser order codes: the digits before
the first dash are Mouser's manufacturer prefix, the rest is (almost) the
manufacturer part number. Parts without a Mouser code get the generic
description below. Anything that needs a human check says so in "Notes".

Surface-mount parts are for the assembler. Through-hole parts (the Teensy
socket strips and pin headers) are listed as "customer" to fit by hand; the
edge-connector fingers (J1) and mounting holes are not parts and are left out.

Usage: tools/make_assembly.py     (needs KiCad's kicad-cli)

This file is part of a fork of DifNif; CERN-OHL-S-2.0.
"""

import csv
import os
import re
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BOARD_DIR = os.path.join(REPO, "pcb_formfactor")
FAB = os.path.join(BOARD_DIR, "fab")
PREFIX = "DifNifFormFactor-RevP2"
KICAD_CLI = os.environ.get("KICAD_CLI", "/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli")

MOUSER_MFR = {
    "187": "Samsung Electro-Mechanics",
    "520": "ECS Inc.",
    "579": "Microchip Technology",
    "595": "Texas Instruments",
    "603": "Yageo",
    "621": "Diodes Incorporated",
    "757": "Toshiba",
    "771": "Nexperia",
    "798": "Hirose",
    "810": "TDK",
    "842": "Lattice Semiconductor",
}

# Where Mouser's code isn't exactly the manufacturer part number
MPN_FIX = {
    "798-DM3AT-SF-PEJM540": ("DM3AT-SF-PEJM5(40)", "Check: Mouser code ends in 40, Hirose's packaging variant"),
    "757-74LCX07FTAE": ("74LCX07FT", "Check: Mouser code adds a packaging suffix (AE)"),
    "579-26VF080A-104I/SN": ("SST26VF080A-104I/SN", ""),
    "520-ECS-2333-100-BNT": ("ECS-2333-100-BN-TR", "Check: 10 MHz 3.3 V oscillator, 3.2 x 2.5 mm; Mouser code drops the -TR punctuation"),
}

# Parts the schematic gives no order code for
GENERIC = {
    "0.1uF": ("Samsung Electro-Mechanics", "CL10B104KB8NNNC",
              "Any 0.1 uF X7R 0603 rated 16 V or more is fine"),
    "LED0": ("", "", "Any 0603 LED (e.g. green); 470 ohm from 3.3 V"),
    "LED1": ("", "", "Any 0603 LED (e.g. green); 470 ohm from 3.3 V"),
}

DESCRIPTION = {
    "U1": "FPGA, iCE40 HX4K, TQFP-144",
    "U2": "SPI flash 8 Mbit, SOIC-8 (FPGA configuration)",
    "U3": "Reset supervisor 2.93 V, SOT-23",
    "U4": "LDO 3.3 V, SOT-223",
    "U5": "LDO 1.2 V, SOT-223",
    "U6": "Dual-supply octal transceiver, TSSOP-24",
    "U11": "Hex open-drain buffer, TSSOP-14",
    "U12": "Quad tri-state buffer, TSSOP-14",
    "D1": "LED, 0603",
    "D3": "Schottky diode 1 A 100 V, SOD-123F",
    "J3": "microSD socket",
    "X1": "Oscillator 10 MHz",
}

# Hand-fitted through-hole parts
THT = {
    "J2": ("2x4 pin header, 2.54 mm", "FPGA flash programming header"),
    "J4": ("2x10 pin header, 2.54 mm", "Logic analyzer header (HP pod)"),
    "U13": ("2x 1x24 female socket strips, 2.54 mm, rows 15.24 mm apart", "Socket for the Teensy 4.1 (Teensy fitted separately)"),
}
NOT_PARTS = re.compile(r"^(J1|H\d+)$")   # edge fingers, mounting holes


def run(args):
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode:
        sys.exit("%s failed:\n%s%s" % (" ".join(args[:3]), r.stdout, r.stderr))


def refkey(ref):
    m = re.match(r"([A-Z]+)(\d+)", ref)
    return (m.group(1), int(m.group(2)))


def main():
    with tempfile.TemporaryDirectory() as tmp:
        net = os.path.join(tmp, "netlist.xml")
        run([KICAD_CLI, "sch", "export", "netlist", "--format", "kicadxml", "-o", net,
             os.path.join(BOARD_DIR, "DifNif.kicad_sch")])
        pos = os.path.join(tmp, "pos.csv")
        run([KICAD_CLI, "pcb", "export", "pos", "--format", "csv", "--units", "mm",
             "--side", "both", "--smd-only", "--exclude-dnp", "-o", pos,
             os.path.join(BOARD_DIR, "DifNif.kicad_pcb")])
        comps = {}
        for c in ET.parse(net).getroot().iter("comp"):
            f = {x.get("name"): (x.text or "") for x in c.iter("field")}
            comps[c.get("ref")] = (c.findtext("value"), (c.findtext("footprint") or "").split(":")[-1], f.get("Mouser", ""))
        placed = list(csv.DictReader(open(pos)))

    smd_refs = {row["Ref"] for row in placed}

    # ---- BOM, grouped by part ----
    groups = {}
    for ref, (value, fp, mouser) in comps.items():
        if NOT_PARTS.match(ref):
            continue
        if ref in THT:
            desc, note = THT[ref]
            key = ("THT", ref)
            groups[key] = {"refs": [ref], "mfr": "", "mpn": "", "value": value, "fp": fp,
                           "desc": desc, "type": "THT", "by": "Customer", "notes": note, "mouser": ""}
            continue
        if ref not in smd_refs:
            sys.exit("%s is not in the placement file: check its footprint type" % ref)
        notes = ""
        if mouser:
            prefix, _, rest = mouser.partition("-")
            mfr = MOUSER_MFR.get(prefix, "")
            mpn, notes = MPN_FIX.get(mouser, (rest, ""))
            if not mfr:
                notes = ("Check: unknown Mouser prefix %s. " % prefix) + notes
        elif value in GENERIC:
            mfr, mpn, notes = GENERIC[value]
        else:
            sys.exit("%s (%s) has no part number and no generic entry" % (ref, value))
        # Generic parts group by what they are, not the schematic's label
        group_value = "LED" if value in ("LED0", "LED1") else value
        key = ("SMD", mfr, mpn, group_value, fp)
        g = groups.setdefault(key, {"refs": [], "mfr": mfr, "mpn": mpn, "value": group_value, "fp": fp,
                                    "desc": "", "type": "SMD", "by": "Assembler", "notes": notes,
                                    "mouser": mouser})
        g["refs"].append(ref)

    rows = []
    for g in groups.values():
        g["refs"].sort(key=refkey)
        first = g["refs"][0]
        if not g["desc"]:
            g["desc"] = DESCRIPTION.get(first) or DESCRIPTION.get(
                {"U7": "U6", "U8": "U6", "U9": "U6", "U10": "U6", "U14": "U6"}.get(first, ""), "")
            if not g["desc"]:
                kind = {"C": "Capacitor", "R": "Resistor", "D": "LED"}.get(refkey(first)[0], "")
                size = "0805" if "2012" in g["fp"] else "0603" if "1608" in g["fp"] else ""
                g["desc"] = ("%s %s %s" % (kind, g["value"], size)).strip()
        rows.append(g)
    rows.sort(key=lambda g: (g["type"] != "SMD", refkey(g["refs"][0])))

    bom = os.path.join(FAB, PREFIX + "-BOM.csv")
    with open(bom, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["Item", "Qty", "Designators", "Manufacturer", "Manufacturer Part Number",
                    "Description", "Value", "Footprint", "Type", "Fitted by", "Mouser", "Notes"])
        for i, g in enumerate(rows, 1):
            w.writerow([i, len(g["refs"]), " ".join(g["refs"]), g["mfr"], g["mpn"], g["desc"],
                        g["value"], g["fp"], g["type"], g["by"], g["mouser"], g["notes"]])

    # ---- Placement, in the column names assembly houses expect ----
    place = os.path.join(FAB, PREFIX + "-positions.csv")
    with open(place, "w", newline="") as fh:
        w = csv.writer(fh)
        w.writerow(["Designator", "Mid X", "Mid Y", "Layer", "Rotation", "Value", "Package"])
        for row in sorted(placed, key=lambda r: refkey(r["Ref"])):
            w.writerow([row["Ref"], "%.4fmm" % float(row["PosX"]), "%.4fmm" % float(row["PosY"]),
                        "Top" if row["Side"] == "top" else "Bottom", row["Rot"], row["Val"], row["Package"]])

    n_smd = sum(len(g["refs"]) for g in rows if g["type"] == "SMD")
    print("BOM: %d lines, %d SMD parts, %d hand-fitted" % (len(rows), n_smd, len(THT)))
    print("Placement: %d parts" % len(placed))
    print("Wrote", os.path.relpath(bom, REPO), "and", os.path.relpath(place, REPO))
    checks = [g for g in rows if g["notes"].startswith("Check")]
    for g in checks:
        print("  check:", g["mpn"], "-", g["notes"])


if __name__ == "__main__":
    main()
