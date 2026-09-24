#!/usr/bin/env python3
"""
Timing budget for the DifNif 72-pin board against IBM's Micro Channel timing.

Builds the FPGA design with yosys and nextpnr (same flags as verilog/Makefile),
then combines:
  * nextpnr's worst delay for each class of path (pin to pin, pin to a
    -CMD-clocked flip-flop, flip-flop to pin, ...), taken from its JSON
    report. Using the worst path of a class for every path in that class is
    pessimistic, which is the safe direction.
  * the clock-network delay from pin to flip-flop for -CMD and ARB/-GNT,
    from the SDF file nextpnr writes
  * an allowance for the FPGA's I/O pad buffers, which nextpnr's report
    leaves out (sized from Lattice's HX pin-to-pin figures)
  * worst-case delays of the other chips on the board, from their datasheets
and prints the margin left for each requirement in IBM Figure 2-34 (I/O
cycle), 2-40/2-41 (DMA) and 2-46 (arbitration). A negative margin fails.

Usage:
  tools/timing_budget.py              # default build (POS bypassed)
  tools/timing_budget.py --pos        # build with -DMCA_USE_POS

Needs yosys and nextpnr-ice40 on PATH (oss-cad-suite). Exit status is 1 if
any margin is negative.

This file is part of a fork of DifNif; CERN-OHL-S-2.0.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERILOG = os.path.join(REPO, "verilog")

# ----------------------------------------------------------------------------
# Board chips, worst case (ns). Rev P2 uses SN74LVC8T245 with VCCA = 3.3 V,
# VCCB = 5 V (TI datasheet, section 5.9). Rev P1's 74LVC4245A are wired with
# their supplies swapped (finding 2), so their real delays are unspecified;
# its in-spec figures (Nexperia table 7) are similar or smaller.
# ----------------------------------------------------------------------------
BOARD = {
    "xcvr_in":    (0.6, 7.0),   # bus to FPGA (8T245 B->A max 6.0; 4245 max 6.5 at 125 C)
    "xcvr_out":   (0.5, 7.0),   # FPGA to bus (8T245 A->B max 4.4; 4245 max 6.7)
    "xcvr_on":    15.0,         # DIR change until bus side drives (A disable 8.2 + B enable 6.8)
    "xcvr_off":   10.0,         # DIR change until bus side releases (8T245 6.3; 4245 OE->B 10)
    "vhct125":    10.0,         # -CD DS16 / -CD SFDBK / IRQ buffer (SN74AHCT125 50 pF: tpd 8.5, en 8, dis 10)
    "lcx07":      7.0,          # ARB/-PREEMPT open drain (SN74LVC07A 3.3 V: 3.6; doubled, ST part not checked)
}

# nextpnr's report leaves out the FPGA's input and output pad buffers. Lattice
# gives 7.3 ns pin-to-pin through one LUT for HX parts (FPGA-DS-02029 table
# 4.26); nextpnr's own estimate for such a path is about 4-5 ns.
PAD_IN = 1.5
PAD_OUT = 1.5
# Flip-flop hold requirement inside the fabric: Lattice's PIO input-register
# hold with a global clock is 2.38 ns; use that as a generous bound.
T_HOLD_FF = 2.4

# IBM timing (ns), Figure 2-34 unless noted
IBM = {
    "T2":   55,     # status active to -CMD active (min)
    "T9":   30,     # address hold from -CMD active (min)
    "T10":  30,     # status hold from -CMD active (min)
    "T13":  55,     # -CD DS 16 valid from address valid (max)
    "T14":  60,     # -CD SFDBK valid from address valid (max)
    "T15":  85,     # -CMD active from address valid (min)
    "T16":  90,     # -CMD pulse width (min)
    "T17":  0,      # write data setup to -CMD active (min)
    "T18":  30,     # write data hold from -CMD inactive (min)
    "T20":  60,     # read data valid from -CMD active (max)
    "T22":  40,     # read data tri-state from -CMD inactive (max)
    "T41":  30,     # ARB/-GNT high from end of transfer (min, Figure 2-46)
    "T42":  50,     # -PREEMPT inactive from ARB/-GNT low (max, Figure 2-46)
    "T45":  50,     # arbitration driver turn-on from ARB/-GNT high (max)
    "T47":  50,     # driver turn-on/off from another ARB line (T45A/T47, max)
}


def build(tmp, pos):
    sources = [os.path.join(VERILOG, f) for f in ("difnif_top.v", "mcabus.v", "teensy.v")]
    define = "-DMCA_USE_POS " if pos else ""
    json_path = os.path.join(tmp, "difnif.json")
    run(["yosys", "-q", "-p",
         "read_verilog %s%s; synth_ice40 -top difnif_top -json %s"
         % (define, " ".join(sources), json_path)])
    report = os.path.join(tmp, "report.json")
    sdf = os.path.join(tmp, "difnif.sdf")
    run(["nextpnr-ice40", "--hx8k", "--package", "tq144:4k", "-q",
         "--pcf", os.path.join(VERILOG, "difnif.pcf"), "--json", json_path,
         "--asc", os.path.join(tmp, "difnif.asc"), "--report", report, "--sdf", sdf])
    return report, sdf


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        sys.exit("%s failed:\n%s%s" % (cmd[0], r.stdout[-2000:], r.stderr[-2000:]))


def path_classes(report):
    """Worst delay (ns) for each (from, to) clock-event pair."""
    worst = {}
    for cp in json.load(open(report))["critical_paths"]:
        key = (norm_event(cp["from"]), norm_event(cp["to"]))
        worst[key] = max(worst.get(key, 0.0), sum(s["delay"] for s in cp["path"]))
    return worst


def norm_event(e):
    # "negedge cmd_l$SB_IO_IN_$glb_clk" -> "negedge cmd_l"
    m = re.match(r"(posedge|negedge) (\w+)", e)
    return "%s %s" % m.groups() if m else e


def clock_insertion(sdf, clock):
    """Pin-buffer output to flip-flop clock pin, worst case, in ns."""
    s = open(sdf).read()
    esc = re.escape(clock)
    to_gb = [int(m) for m in re.findall(
        r"INTERCONNECT %s\\\$sb_io/D_IN_0 \\\$gbuf_%s\S*/USER_SIGNAL_TO_GLOBAL_BUFFER \((\d+):" % (esc, esc), s)]
    gb = [int(m) for m in re.findall(
        r'\(INSTANCE \\\$gbuf_%s\S*\)\s*\(DELAY\s*\(ABSOLUTE\s*\(IOPATH \S+ \S+ \((\d+):' % esc, s)]
    to_ff = [int(m) for m in re.findall(
        r"INTERCONNECT \\\$gbuf_%s\S*/GLOBAL_BUFFER_OUTPUT \S+/CLK \((\d+):" % esc, s)]
    if not gb or not to_ff:
        sys.exit("couldn't find the %s clock network in the SDF" % clock)
    # A dedicated global input pin has no fabric hop to the buffer
    return (max(to_gb) if to_gb else 0) / 1000 + max(gb) / 1000 + max(to_ff) / 1000


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--pos", action="store_true", help="build with -DMCA_USE_POS")
    args = ap.parse_args()

    with tempfile.TemporaryDirectory() as tmp:
        report, sdf = build(tmp, args.pos)
        w = path_classes(report)
        ins_cmd = clock_insertion(sdf, "cmd_l")
        ins_gnt = clock_insertion(sdf, "arb_gnt_l")

    missing = set()

    def d(frm, to):
        if (frm, to) not in w:
            missing.add((frm, to))
            return 0.0
        return w[(frm, to)]

    xin_min, xin_max = BOARD["xcvr_in"]
    xout_max = BOARD["xcvr_out"][1]
    # Clock edge at a flip-flop, relative to the edge at the connector
    clk_cmd_max = xin_max + PAD_IN + ins_cmd
    clk_gnt_max = xin_max + PAD_IN + ins_gnt
    clk_gnt_min = xin_min + PAD_IN
    comb = d("<async>", "<async>")

    rows = []

    def row(req, what, limit, used, kind="max"):
        margin = (limit - used) if kind == "max" else (used - limit)
        rows.append((req, what, limit, used, margin, kind))

    # Decoded outputs from the unlatched address (combinational)
    row("T13", "-CD DS 16 from address", IBM["T13"],
        xin_max + PAD_IN + comb + PAD_OUT + BOARD["vhct125"])
    row("T14", "-CD SFDBK from address", IBM["T14"],
        xin_max + PAD_IN + comb + PAD_OUT + BOARD["vhct125"])

    # Falling-edge latch: status is the latest input (T2 before -CMD)
    arrive = -IBM["T2"] + xin_max + PAD_IN + d("<async>", "negedge cmd_l")
    row("T2/T15", "address/status setup at -CMD falling", 0,
        -arrive + 0, kind="min")
    # ... and must not change before the flip-flops have sampled it
    change = min(IBM["T9"], IBM["T10"]) + xin_min
    row("T9/T10", "address/status hold after -CMD falling", T_HOLD_FF,
        change - clk_cmd_max, kind="min")

    # Rising-edge write capture (finding 9 fix)
    data_ready = IBM["T17"] * -1 + xin_max + PAD_IN + d("<async>", "posedge cmd_l")
    row("T16/T17", "write data setup at -CMD rising", 0,
        IBM["T16"] - data_ready, kind="min")
    row("T18", "write data hold after -CMD rising", T_HOLD_FF,
        IBM["T18"] + xin_min - clk_cmd_max, kind="min")
    row("T16", "falling-edge latches to rising-edge logic", 0,
        IBM["T16"] - d("negedge cmd_l", "posedge cmd_l"), kind="min")

    # Read data
    via_dir = xin_max + PAD_IN + comb + PAD_OUT + BOARD["xcvr_on"]
    via_mux = clk_cmd_max + d("negedge cmd_l", "<async>") + PAD_OUT + xout_max
    row("T20", "read data valid from -CMD falling", IBM["T20"], max(via_dir, via_mux))
    row("T22", "read data released after -CMD rising", IBM["T22"],
        xin_max + PAD_IN + comb + PAD_OUT + BOARD["xcvr_off"])

    # Arbitration and DMA
    row("T42", "-PREEMPT released after ARB/-GNT low", IBM["T42"],
        clk_gnt_max + d("negedge arb_gnt_l", "<async>") + PAD_OUT + BOARD["lcx07"])
    row("T45", "ARB drivers on after ARB/-GNT high", IBM["T45"],
        clk_gnt_max + d("posedge arb_gnt_l", "<async>") + PAD_OUT + BOARD["lcx07"])
    row("T45A/T47", "ARB driver follows another ARB line", IBM["T47"],
        xin_max + PAD_IN + comb + PAD_OUT + BOARD["lcx07"])
    # Finding 12: request must drop before the next arbitration latches it
    req_drop = clk_cmd_max + d("posedge cmd_l", "posedge arb_gnt_l")
    row("T41", "DMA request dropped before next ARB/-GNT", 0,
        IBM["T41"] + clk_gnt_min - req_drop, kind="min")

    print("FPGA path classes used (nextpnr, worst path of each class):")
    for (f, t), v in sorted(w.items()):
        print("  %-22s -> %-22s %6.2f ns" % (f, t, v))
    print("Clock network, pin buffer to flip-flops: -CMD %.2f ns, ARB/-GNT %.2f ns"
          % (ins_cmd, ins_gnt))
    print("Allowances: FPGA pad in %.1f ns, pad out %.1f ns, flip-flop hold %.1f ns\n"
          % (PAD_IN, PAD_OUT, T_HOLD_FF))

    print("%-9s %-42s %8s %8s %8s" % ("IBM", "requirement", "limit", "budget", "margin"))
    bad = 0
    for req, what, limit, used, margin, kind in rows:
        if kind == "max":
            lim, use = "%.1f" % limit, "%.1f" % used
        else:
            lim, use = ">= %.1f" % limit, "%.1f" % used
        flag = "" if margin >= 0 else "  FAIL"
        bad += margin < 0
        print("%-9s %-42s %8s %8s %7.1f%s" % (req, what, lim, use, margin, flag))
    for f, t in sorted(missing):
        print("ERROR: nextpnr reported no %s -> %s paths; that row used 0 ns" % (f, t))
        bad += 1
    print("\nFor 'max' rows the budget is the worst-case delay; for '>=' rows it is the")
    print("time available, which must be at least the limit. Margins are in ns.")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
