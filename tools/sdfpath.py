#!/usr/bin/env python3
"""Longest delay from one FPGA pin to another, from nextpnr's SDF.

timing_budget.py takes T54 and T43 from the slowest pin-to-pin
(combinational) path anywhere in the design, which nextpnr reports; that
path can belong to something else entirely and moves with every placement.
This walks the SDF instead: INTERCONNECT delays (wire, driver pin to load
pin) and each cell's IOPATH delays (input pin to output pin), from the
input pad's D_IN_0 to the output pad's D_OUT_0 / OUTPUT_ENABLE, and returns
the slowest route and its steps. Flip-flops only have IOPATHs from their
clock pin, so a route through one only counts as a clock-to-output.

Usage: sdfpath.py FILE.sdf FROM_PIN TO_PIN     (e.g. tc_l burst_o_l)
       or import longest(sdf_text, frm, to)

This file is part of a fork of DifNif; CERN-OHL-S-2.0.
"""

import re
import sys


def _graph(s):
    edges = {}

    def add(a, b, d):
        edges.setdefault(a, []).append((b, d))

    def worst(t):
        # "(r:r:r) (f:f:f)": rise and fall delays; the larger, in ns
        return max(float(x) for x in re.findall(r"[\d.]+", t)) / 1000.0

    # INTERCONNECT a b (min:typ:max) (min:typ:max)
    for a, b, t in re.findall(r"\(INTERCONNECT (\S+) (\S+) ((?:\([\d.:]+\)\s*)+)\)", s):
        add(a, b, worst(t))
    # Cells: (CELL (CELLTYPE "x") (INSTANCE name) (DELAY (ABSOLUTE (IOPATH i o (..)...
    for m in re.finditer(r"\(CELL\s*\(CELLTYPE \"[^\"]*\"\)\s*\(INSTANCE ([^)]*)\)(.*?)\n\s*\)\s*\n(?=\s*\(CELL|\s*\)\s*$)",
                         s, re.S):
        inst, body = m.group(1).strip(), m.group(2)
        for i, o, t in re.findall(r"\(IOPATH (\S+) (\S+) ((?:\([\d.:]+\)\s*)+)\)", body):
            i = re.sub(r"^\((?:posedge|negedge) ", "", i)
            add("%s/%s" % (inst, i), "%s/%s" % (inst, o), worst(t))
    return edges


def longest(s, frm, to):
    """(delay ns, [nodes]) of the slowest route from pad frm's input to pad
    to's output driver, or None"""
    edges = _graph(s)
    src = [n for n in edges if n.startswith(frm + "\\$sb_io/D_IN_0") or n == frm + "\\$sb_io/D_IN_0"]
    sinks = set()
    for a, lst in edges.items():
        for b, _ in lst:
            if b.startswith(to + "\\$sb_io/") and re.search(r"/(D_OUT_0|OUTPUT_ENABLE)$", b):
                sinks.add(b)
    best = {}
    path = {}

    def visit(n, depth=0):
        if n in best:
            return best[n]
        r = (float("-inf"), None)
        if n in sinks:
            r = (0.0, None)
        if depth < 200:
            for b, d in edges.get(n, []):
                v, _ = visit(b, depth + 1)
                if v + d > r[0]:
                    r = (v + d, b)
        best[n] = r
        return r

    out = None
    for n in src:
        v, nxt = visit(n)
        if v > float("-inf") and (out is None or v > out[0]):
            route = [n]
            while route[-1] in best and best[route[-1]][1]:
                route.append(best[route[-1]][1])
            out = (v, route)
    return out


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    r = longest(open(sys.argv[1]).read(), sys.argv[2], sys.argv[3])
    if not r:
        sys.exit("no route from %s to %s" % (sys.argv[2], sys.argv[3]))
    print("%.2f ns" % r[0])
    for n in r[1]:
        print("  " + n)


if __name__ == "__main__":
    main()
