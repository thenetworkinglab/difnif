#!/usr/bin/env python3
"""Fail if yosys tied a bidirectional (inout) top-level pin to a constant.

yosys turns an inout bit whose only driver is a constant 1'bz into a constant
0, and nextpnr then drives that pin low. The processor build's Teensy data
lines did this (they fought the Teensy's serial output), and simulation can't
show it: there the pins really are undriven. Run on the synthesized JSON
before place and route, as the Makefile does.

Usage: check_inouts.py build/<board>/difnif_top.json

This file is part of a fork of DifNif; CERN-OHL-S-2.0.
"""

import json
import sys


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    netlist = json.load(open(sys.argv[1]))
    bad = []
    for name, mod in netlist["modules"].items():
        if mod.get("attributes", {}).get("top") is None:
            continue
        for port, p in mod["ports"].items():
            if p["direction"] != "inout":
                continue
            for i, b in enumerate(p["bits"]):
                if isinstance(b, str):      # "0", "1", "x" or "z": a constant
                    bad.append(f"{port}[{i}] = {b}")
    if bad:
        print("check_inouts: inout pins tied to a constant (they'd be driven):")
        for b in bad:
            print("  " + b)
        print("Use an SB_IO pad with OUTPUT_ENABLE 0 for pins that only listen.")
        sys.exit(1)


if __name__ == "__main__":
    main()
