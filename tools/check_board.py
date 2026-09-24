#!/usr/bin/env python3
"""
Static connectivity check for the DifNif 72-pin (form factor) board.

Exports the KiCad netlist and checks it against:
  * the published DBA-ESDI 2x36 connector pinout (dba_esdi_72pin.csv)
  * the FPGA pin constraints (verilog/difnif.pcf) and top-level port
    directions (verilog/difnif_top.v), tracing each MCA signal from the
    FPGA pin through the level shifters to the edge connector
  * the 74LVC4245A supply-pin requirements (Nexperia datasheet: pin 1 is
    VCC(A), the 5 V side; pins 23/24 are VCC(B), the 3 V side, abs max 4.6 V).
    The pin-compatible SN74LVC8T245 allows 1.65-5.5 V on either side.
  * nets that have only one connection (floating inputs)

KiCad's own ERC misses most of these because the level-shifter pins are
"bidirectional", so a net with one of them on it is not flagged.

Usage:
  tools/check_board.py                      # check pcb_formfactor
  tools/check_board.py --netlist foo.xml    # use an existing kicadxml netlist

Exit status is 1 if any ERROR is found.

This file is part of a fork of DifNif; CERN-OHL-S-2.0.
"""

import argparse
import csv
import os
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MAC_KICAD_CLI = "/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli"

# Rail names used in the schematics
RAIL_5V = {"+5V", "+5VD"}
RAIL_3V3 = {"+3V3"}
GND = {"GND"}

# Dual-supply octal transceivers sharing the 24-pin 4245 pinout
XCVR_4245 = {"74LVC4245", "74LVC8T245"}

# FPGA top-level port -> connector signal it should carry.
# None means "not present on the 72-pin connector".
PORT_SIGNAL = {
    "chreset": "CHRESET",
    "chreset_l": None,          # 700C-only; not on the 72-pin connector
    "cmd_l": "-CMD",
    "s0_w_l": "-S0",
    "s1_r_l": "-S1",
    "m_io_l": "M/-IO",
    "cd_setup_l": "-CD SETUP",
    "addr_sel_in_l": None,      # 700C-only; 72-pin decodes A15..A4 instead
    "sbhe_l": "-SBHE",
    "cd_ds16_l": "-CD DS 16",
    "cd_chrdy_l": "CD CHRDY",
    "irq14_l": "-IRQ 14",
    "arb_gnt_l": "ARB/-GNT",
    "tc_l": "-TC",
    "burst_l": "-BURST",
    "preempt_l": "-PREEMPT",
    "burst_o_l": "-BURST",
    "preempt_o_l": "-PREEMPT",
}
for i in range(16):
    PORT_SIGNAL["bus_a[%d]" % i] = "A %02d" % i
    PORT_SIGNAL["bus_d[%d]" % i] = "D %02d" % i
for i in range(4):
    PORT_SIGNAL["arb[%d]" % i] = "ARB %02d" % i
    PORT_SIGNAL["arb_o[%d]" % i] = "ARB %02d" % i

# Ports whose name polarity intentionally differs from the bus signal.
POLARITY_OK = {
    # Driven through an open-drain buffer: port low pulls CD CHRDY low
    # (not ready). Active-high ready on the bus, active-low "wait" in logic.
    "cd_chrdy_l",
}

# Single-connection nets that are expected
IGNORE_SINGLE = re.compile(r"^/TN\d+$")  # unused Teensy pins


class Finding:
    def __init__(self):
        self.items = []

    def add(self, level, section, msg):
        self.items.append((level, section, msg))

    def count(self, level):
        return sum(1 for i in self.items if i[0] == level)


def find_kicad_cli():
    for c in (os.environ.get("KICAD_CLI"), shutil.which("kicad-cli"), MAC_KICAD_CLI):
        if c and os.path.exists(c):
            return c
    sys.exit("kicad-cli not found; set KICAD_CLI or pass --netlist")


def export_netlist(sch, out):
    cli = find_kicad_cli()
    r = subprocess.run([cli, "sch", "export", "netlist", "--format", "kicadxml",
                        "-o", out, sch], capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(out):
        sys.exit("netlist export failed:\n" + r.stdout + r.stderr)


class Netlist:
    def __init__(self, path):
        root = ET.parse(path).getroot()
        self.value = {c.get("ref"): c.findtext("value") for c in root.iter("comp")}
        self.nets = {}      # net name -> [(ref, pin)]
        self.pin_net = {}   # (ref, pin) -> net name
        for n in root.iter("net"):
            name = n.get("name")
            nodes = [(x.get("ref"), x.get("pin")) for x in n.iter("node")]
            self.nets[name] = nodes
            for node in nodes:
                self.pin_net[node] = name

    def net(self, ref, pin):
        return self.pin_net.get((ref, str(pin)))

    def refs_with_value(self, value):
        return sorted(r for r, v in self.value.items() if v == value)


def norm(name):
    """Canonical signal key: '/DifNifBus/~{CD_DS16}_5V' -> '-CDDS16'."""
    if name is None:
        return None
    s = re.sub(r"^/(DifNifBus/|DifNifPower/|SDCard/)?", "", name)
    s = s.replace("{slash}", "/")
    s = re.sub(r"~\{([^}]*)\}", r"-\1", s)
    s = re.sub(r"_5V$", "", s)
    s = s.upper().replace("–", "-").replace("_", "").replace(" ", "")
    s = re.sub(r"(?<=[A-Z])0+(?=\d)", "", s)
    return s


# Board label -> spec name, where they differ only in naming
ALIASES = {"CDCHRDY": "CHRDY"}


def base(key):
    """Signal identity without polarity."""
    if not key:
        return key
    key = key.replace("-", "")
    return ALIASES.get(key, key)


def active_low(key):
    """True/False for active-low, None if the name encodes two states (M/-IO)."""
    if "/" in key:
        return None
    return key.startswith("-")


def load_pinout(path):
    rows = []
    with open(path) as f:
        for row in csv.DictReader(line for line in f if not line.startswith("#")):
            rows.append(row)
    return rows


def load_pcf(path):
    ports = {}
    with open(path) as f:
        for line in f:
            m = re.match(r"\s*set_io\s+(\S+)\s+(\d+)", line)
            if m:
                ports[m.group(1)] = m.group(2)
    return ports


def load_port_dirs(path):
    dirs = {}
    with open(path) as f:
        for line in f:
            m = re.match(r"\s*(input|output|inout)\s*(\[\d+:\d+\])?\s*([A-Za-z_]\w*)", line)
            if m:
                dirs[m.group(3)] = m.group(1)
    return dirs


# Level shifter pin pairings: FPGA-side pin -> connector-side pin.
# 74LVC4245: pins 3..10 pair with 21..14.
def pair_4245(pin):
    p = int(pin)
    if 3 <= p <= 10:
        return str(24 - p)
    if 14 <= p <= 21:
        return str(24 - p)
    return None


# 74LCX07 open-drain hex buffer: input -> output
LCX07 = {"1": "2", "3": "4", "5": "6", "9": "8", "11": "10", "13": "12"}
# 74VHCT125 quad tri-state buffer: (OE, A, Y)
VHCT125 = [("1", "2", "3"), ("4", "5", "6"), ("10", "9", "8"), ("13", "12", "11")]


def trace_to_connector(nl, fpga_net, conn="J1"):
    """Follow an FPGA-side net through one buffer to the connector.
    Returns (connector_pin or None, description of the path)."""
    for ref, pin in nl.nets.get(fpga_net, []):
        val = nl.value.get(ref, "")
        other = None
        if val in XCVR_4245:
            other = pair_4245(pin)
        elif val == "74LCX07" and pin in LCX07:
            other = LCX07[pin]
        elif val in ("74VHCT125", "74LS125"):
            for oe, a, y in VHCT125:
                if pin in (oe, a):
                    other = y
        if other is None:
            continue
        far = nl.net(ref, other)
        path = "%s pin %s -> %s pin %s (%s)" % (ref, pin, ref, other, far)
        conn_pins = [p for r, p in nl.nets.get(far, []) if r == conn]
        if conn_pins:
            return conn_pins[0], path
        return None, path + " -- goes nowhere else"
    return None, "no buffer on this net"


def check_connector(nl, pinout, f):
    sec = "connector"
    for row in pinout:
        pin, d, sig = row["pin"], row["dir"], row["signal"]
        net = nl.net("J1", pin)
        unconnected = net is None or net.startswith("unconnected-")
        if d == "PWR":
            rail = {"GND": GND, "+5V": RAIL_5V}.get(sig)
            if rail and net not in rail:
                f.add("ERROR", sec, "%s should be %s, board has %s" % (pin, sig, net))
            elif sig == "+12V" and not unconnected:
                f.add("WARN", sec, "%s is +12V on the host, board connects %s" % (pin, net))
            continue
        if unconnected:
            if sig.startswith("RESERVED"):
                f.add("INFO", sec, "%s (%s) not connected -- fine" % (pin, sig))
            elif d == "I":
                f.add("WARN", sec, "%s %s is a card output the host may expect; "
                      "board leaves it undriven" % (pin, sig))
            else:
                f.add("WARN", sec, "%s %s is not connected on the board" % (pin, sig))
            continue
        want, got = norm(sig), norm(net)
        if base(want) != base(got):
            f.add("ERROR", sec, "%s should be %s, board net is %s" % (pin, sig, net))
        elif active_low(want) is not None and active_low(got) is not None \
                and active_low(want) != active_low(got):
            # Labels are only names; fpga-trace checks what the logic sees.
            f.add("INFO", sec, "%s is %s but the board labels it %s"
                  % (pin, sig, net))


def check_fpga_trace(nl, pinout, pcf, dirs, f):
    sec = "fpga-trace"
    by_signal = {base(norm(r["signal"])): r for r in pinout}
    by_pin = {r["pin"]: r for r in pinout}
    for port, sig in sorted(PORT_SIGNAL.items()):
        if port not in pcf:
            f.add("WARN", sec, "%s has no pin in difnif.pcf" % port)
            continue
        fpin = pcf[port]
        fnet = nl.net("U1", fpin)
        pdir = dirs.get(re.sub(r"\[.*", "", port), "?")
        if fnet is None or fnet.startswith("unconnected-"):
            if sig:
                f.add("ERROR", sec, "%s (FPGA pin %s) is not connected on the board" % (port, fpin))
            continue
        cpin, path = trace_to_connector(nl, fnet)
        if sig is None:
            if cpin:
                f.add("WARN", sec, "%s (FPGA pin %s) is 700C-only but reaches J1 %s (%s)"
                      % (port, fpin, cpin, by_pin[cpin]["signal"]))
            elif pdir == "input":
                f.add("INFO", sec, "%s (FPGA pin %s) has no source on this board: %s"
                      % (port, fpin, path))
            continue
        if cpin is None:
            f.add("ERROR", sec, "%s (FPGA pin %s, net %s) should carry %s but is not "
                  "connected to the edge connector: %s" % (port, fpin, fnet, sig, path))
            continue
        row = by_pin[cpin]
        if base(norm(row["signal"])) != base(norm(sig)):
            f.add("ERROR", sec, "%s should carry %s (J1 %s) but reaches J1 %s = %s"
                  % (port, sig, by_signal[base(norm(sig))]["pin"], cpin, row["signal"]))
            continue
        # Direction: FPGA input <- host output, FPGA output -> host input.
        # Shared open-collector lines (ARB, -BURST, -PREEMPT) are driven by
        # an output port and read back by an input port, which is fine.
        shared = pdir == "input" and any(
            s == sig and dirs.get(re.sub(r"\[.*", "", p)) == "output"
            for p, s in PORT_SIGNAL.items())
        if not shared and ((pdir == "input" and row["dir"] == "I")
                           or (pdir == "output" and row["dir"] == "O")):
            f.add("ERROR", sec, "%s is an FPGA %s but %s is host direction %s"
                  % (port, pdir, row["signal"], row["dir"]))
        want_low = active_low(norm(sig))
        if want_low is not None and port not in POLARITY_OK \
                and want_low != re.sub(r"\[.*", "", port).endswith("_l"):
            f.add("ERROR", sec, "%s polarity does not match %s" % (port, sig))
    # Signals on the connector that no FPGA port uses
    used = {base(norm(s)) for s in PORT_SIGNAL.values() if s}
    for row in pinout:
        if row["dir"] != "PWR" and base(norm(row["signal"])) not in used \
                and not row["signal"].startswith("RESERVED"):
            f.add("WARN", sec, "no FPGA port handles %s (J1 %s)" % (row["signal"], row["pin"]))


def check_4245_supplies(nl, f):
    sec = "4245-supply"
    for ref in nl.refs_with_value("74LVC4245"):
        vcca = nl.net(ref, 1)
        vccb = {nl.net(ref, 23), nl.net(ref, 24)}
        if vcca not in RAIL_5V or not vccb <= RAIL_3V3:
            f.add("ERROR", sec, "%s: VCC(A) pin 1 = %s, VCC(B) pins 23/24 = %s. "
                  "Datasheet wants VCC(A) = 5 V side, VCC(B) = 3 V side "
                  "(VCC(B) abs max 4.6 V). SN74LVC8T245PW is a drop-in fix"
                  % (ref, vcca, "/".join(sorted(vccb))))


def check_single_nets(nl, f):
    sec = "floating"
    for name, nodes in sorted(nl.nets.items()):
        if len(nodes) != 1 or name.startswith("unconnected-") or IGNORE_SINGLE.match(name):
            continue
        ref, pin = nodes[0]
        f.add("ERROR" if nl.value.get(ref) in XCVR_4245 else "WARN", sec,
              "net %s has only one connection (%s pin %s, %s)"
              % (name, ref, pin, nl.value.get(ref)))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--sch", default=os.path.join(REPO, "pcb_formfactor", "DifNif.kicad_sch"))
    ap.add_argument("--netlist", help="use this kicadxml netlist instead of exporting")
    ap.add_argument("--pinout", default=os.path.join(REPO, "tools", "dba_esdi_72pin.csv"))
    ap.add_argument("--pcf", default=os.path.join(REPO, "verilog", "difnif.pcf"))
    ap.add_argument("--top", default=os.path.join(REPO, "verilog", "difnif_top.v"))
    args = ap.parse_args()

    with tempfile.TemporaryDirectory() as tmp:
        path = args.netlist
        if not path:
            path = os.path.join(tmp, "netlist.xml")
            export_netlist(args.sch, path)
        nl = Netlist(path)

    pinout = load_pinout(args.pinout)
    f = Finding()
    check_connector(nl, pinout, f)
    check_fpga_trace(nl, pinout, load_pcf(args.pcf), load_port_dirs(args.top), f)
    check_4245_supplies(nl, f)
    check_single_nets(nl, f)

    for level in ("ERROR", "WARN", "INFO"):
        for lv, sec, msg in f.items:
            if lv == level:
                print("%-5s [%s] %s" % (lv, sec, msg))
    print("\n%d errors, %d warnings, %d notes"
          % (f.count("ERROR"), f.count("WARN"), f.count("INFO")))
    return 1 if f.count("ERROR") else 0


if __name__ == "__main__":
    sys.exit(main())
