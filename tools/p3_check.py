#!/usr/bin/env python3
"""Check Rev P3's schematic (pcb_p3/) against what it should connect.

    python3 tools/p3_check.py

Exports both boards' netlists with kicad-cli, then checks:
- every Rev P2 net the change shouldn't touch is unchanged in Rev P3;
- every new connection (docs/rev-p3-design.md) is there.
Parts are found by value and pin name (RP2040:GPIO8), or by reference
for Rev P2's (U1.33).

This file is part of a fork of DifNif; CERN-OHL-S-2.0.
"""

import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KICAD_CLI = os.environ.get('KICAD_CLI', '/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli')


def netlist(sch):
    out = os.path.join(tempfile.mkdtemp(), 'n.net')
    subprocess.run([KICAD_CLI, 'sch', 'export', 'netlist', '--format', 'kicadsexpr', '-o', out,
                    sch], check=True, capture_output=True)
    s = open(out).read()
    nets = {}
    for chunk in s.split('(net (code ')[1:]:
        name = re.match(r'"\d+"\) \(name "([^"]*)"\)', chunk).group(1)
        nets[name] = re.findall(
            r'\(node \(ref "([^"]*)"\) \(pin "([^"]*)"\)(?: \(pinfunction "([^"]*)"\))?', chunk)
    vals = dict(re.findall(r'\(comp \(ref "([^"]*)"\)\s*\(value "([^"]*)"\)', s))
    return nets, vals


class Board:
    def __init__(self, sch):
        self.nets, self.vals = netlist(sch)
        self.of = {}
        for name, nodes in self.nets.items():
            for r, p, f in nodes:
                self.of[(r, p)] = name
        self.errors = 0

    def pins(self, ep):
        """'U1.25', 'VALUE.pin' or 'VALUE:PINFUNCTION' -> [(ref, pin)]"""
        if ':' in ep:
            val, fn = ep.split(':', 1)
            refs = [r for r, v in self.vals.items() if v == val]
            assert len(refs) == 1, (ep, refs)
            out = [(r, p) for name, nodes in self.nets.items() for r, p, f in nodes
                   if r == refs[0] and f == fn]
        else:
            r, p = ep.rsplit('.', 1)
            if r not in self.vals:      # a value, not a reference
                refs = [x for x, v in self.vals.items() if v == r]
                assert len(refs) == 1, (ep, refs)
                r = refs[0]
            out = [(r, p)] if (r, p) in self.of else []
        assert out, f'no such pin {ep}'
        return out

    def net(self, ep):
        names = {self.of[x] for x in self.pins(ep)}
        assert len(names) == 1, (ep, names)
        return names.pop()

    def fail(self, msg):
        print('FAIL', msg)
        self.errors += 1

    def same(self, *eps):
        n = {ep: self.net(ep) for ep in eps}
        if len(set(n.values())) != 1:
            self.fail('not one net: ' + ', '.join(f'{e} ({v})' for e, v in n.items()))

    def apart(self, a, b):
        if self.net(a) == self.net(b):
            self.fail(f'{a} and {b} are joined ({self.net(a)})')

    def via(self, value, a, b):
        """a two-pin part of this value joins a's net to b's"""
        na, nb = self.net(a), self.net(b)
        for r, v in self.vals.items():
            if v == value and {self.of.get((r, '1')), self.of.get((r, '2'))} == {na, nb}:
                return r
        self.fail(f'no {value} between {a} ({na}) and {b} ({nb})')

    def alone(self, ep):
        nodes = self.nets[self.net(ep)]
        if len(nodes) != 1:
            self.fail(f'{ep} should be unused: {nodes}')


SWITCH = {'4': ('2', '3'), '7': ('5', '6'), '9': ('11', '10'), '12': ('14', '13')}  # A: (B1, B2)


def check_switch(b, card, fpga, rp):
    """card pin -> a 74CBTLV3257 channel: B1 to the FPGA, B2 to the RP2040"""
    a = [(r, p) for r, p, f in b.nets[b.net(card)] if b.vals.get(r) == '74CBTLV3257']
    if len(a) != 1 or a[0][1] not in SWITCH:
        return b.fail(f'{card}: switch channels {a}')
    r, p = a[0]
    b1, b2 = SWITCH[p]
    b.same(f'{r}.{b1}', fpga)
    b.same(f'{r}.{b2}', rp)
    b.same(f'{r}.1', 'RP2040:GPIO11')


def main():
    p2 = Board(os.path.join(ROOT, 'pcb_formfactor', 'DifNif.kicad_sch'))
    b = Board(os.path.join(ROOT, 'pcb_p3', 'DifNif.kicad_sch'))

    # Rev P2's nets, unchanged unless the change is meant to touch them
    gone = {'U13', 'R23'}
    changed = {'U7.2', 'U1.135', 'J3.1', 'J3.2', 'J3.3', 'J3.5', 'J3.7', 'J3.8', 'J3.9'}
    grow = {'+3V3', 'GND', '+5VD', '+5V'}
    unchanged = 0
    for name, nodes in p2.nets.items():
        keep = {(r, p) for r, p, f in nodes if r not in gone}
        if not keep or any(f'{r}.{p}' in changed for r, p in keep):
            continue
        if any(r == 'U13' for r, p, f in nodes) or name == 'Net-(U1D-IOT_219)':
            continue                    # the Teensy's FPGA pins: checked below
        names = {b.of.get(x) for x in keep}
        if len(names) != 1 or None in names:
            b.fail(f'P2 net {name} split: {names}')
            continue
        now = {(r, p) for r, p, f in b.nets[names.pop()]}
        if name in grow:
            if not keep <= now:
                b.fail(f'P2 net {name} lost {keep - now}')
        elif now != keep and name not in ('/SD_CLK', '/SD_CMD', '/SD_D0', '/SD_D1', '/SD_D2',
                                           '/SD_D3', '/SPI_SCK', '/SPI_COPI', '/SPI_CIPO',
                                           '/SPI_~{CS}', '/CDONE', '/~{CRESET}', '/DATA_DIR'):
            b.fail(f'P2 net {name} changed: +{now - keep} -{keep - now}')
        unchanged += 1
    for r in b.vals:
        if r in gone:
            b.fail(f'{r} still there')

    # FPGA <-> RP2040
    b.same('U1.26', 'RP2040:GPIO0')         # UART0 TX -> uart_rx
    b.same('U1.25', 'RP2040:GPIO1')         # uart_tx -> UART0 RX
    b.via('33', 'U1.70', 'RP2040:GPIO2')    # config flash SCK
    b.same('U1.70', 'U2.6')
    b.via('33', 'U1.67', 'RP2040:GPIO3')    # COPI
    b.same('U1.67', 'U2.5')
    b.same('U1.68', 'RP2040:GPIO4', 'U2.2')  # CIPO
    b.via('33', 'U1.71', 'RP2040:GPIO5')    # CS
    b.same('U1.71', 'U2.1')
    b.same('U1.66', 'RP2040:GPIO6', 'U3.2', 'J2.4')    # CRESET
    b.same('U1.65', 'RP2040:GPIO7', 'J2.2')            # CDONE
    b.same('U1.33', 'RP2040:GPIO8')         # sd_req
    b.same('U1.34', 'RP2040:GPIO9')         # sd_rel
    b.same('U1.31', 'RP2040:GPIO10')        # pfail
    b.via('10K', 'RP2040:GPIO11', 'U1.5')   # switch select, pulled to the FPGA side
    b.same('RP2040:GPIO12', 'J3.9', 'U1.3')  # card detect
    # the SD card through the switches
    for card, fpga, gp in (('J3.5', 'U1.1', 16), ('J3.3', 'U1.2', 17), ('J3.7', 'U1.7', 18),
                           ('J3.8', 'U1.4', 19), ('J3.1', 'U1.9', 20), ('J3.2', 'U1.8', 21)):
        check_switch(b, card, fpga, f'RP2040:GPIO{gp}')
        b.apart(card, fpga)
    for card in ('J3.3', 'J3.7', 'J3.8', 'J3.1'):
        b.via('47K', card, 'U1.6')          # pull-ups stay on the card side (U1.6 is +3V3)
    for r, v in b.vals.items():
        if v == '74CBTLV3257':
            b.same(f'{r}.16', 'U1.6')
            b.same(f'{r}.8', f'{r}.15', 'U1.5')       # GND, ~OE on

    # U7 on its own direction line
    b.same('U7.2', 'U1.135')
    b.same('U6.2', 'U1.130', 'R7.1', 'J4.12')
    b.apart('U6.2', 'U7.2')

    # PSRAM and test points
    b.same('U1.18', 'APS6404L-3SQR-SN:~{CE}')
    b.via('10K', 'U1.18', 'U1.6')
    b.same('U1.17', 'APS6404L-3SQR-SN:SCLK')
    b.same('U1.21', 'APS6404L-3SQR-SN:SI/SIO0')
    b.same('U1.23', 'APS6404L-3SQR-SN:SO/SIO1')
    b.same('U1.28', 'APS6404L-3SQR-SN:SIO2')
    b.same('U1.29', 'APS6404L-3SQR-SN:SIO3')
    b.same('APS6404L-3SQR-SN:VDD', 'U1.6')
    b.same('APS6404L-3SQR-SN:VSS', 'U1.5')
    tps = sorted(r for r, v in b.vals.items() if v == 'TP')
    for r, pin in zip(tps, ('32', '11', '12', '16')):
        b.same(f'{r}.1', f'U1.{pin}')
    for pin in ('10', '15', '19', '20', '22', '24', '136', '137', '138', '139',
                '141', '142', '143', '144'):
        b.alone(f'U1.{pin}')

    # the RP2040's own parts
    for fn in ('IOVDD', 'USB_VDD', 'ADC_AVDD', 'VREG_IN'):
        b.same(f'RP2040:{fn}', 'U1.6')
    b.same('RP2040:DVDD', 'RP2040:VREG_VOUT')
    b.same('RP2040:GND', 'RP2040:TESTEN', 'U1.5')
    for fn, ffn in (('QSPI_SS', '~{CS}'), ('QSPI_SCLK', 'CLK'), ('QSPI_SD0', 'DI/IO_{0}'),
                    ('QSPI_SD1', 'DO/IO_{1}'), ('QSPI_SD2', '~{WP}/IO_{2}'),
                    ('QSPI_SD3', '~{HOLD}/~{RESET}/IO_{3}')):
        b.same(f'RP2040:{fn}', f'W25Q16JVSS:{ffn}')
    b.same('W25Q16JVSS:VCC', 'U1.6')
    b.same('W25Q16JVSS:GND', 'U1.5')
    sw = b.via('1K', 'RP2040:QSPI_SS', 'BOOTSEL.1')
    b.same('BOOTSEL.2', 'U1.5')
    b.same('RP2040:XIN', '12MHz.1')
    b.via('1K', 'RP2040:XOUT', '12MHz.3')
    b.via('15pF', '12MHz.1', 'U1.5')
    b.via('15pF', '12MHz.3', 'U1.5')
    b.same('12MHz.2', '12MHz.4', 'U1.5')
    b.via('10K', 'RP2040:RUN', 'U1.6')
    for pin, fn in (('2', 'SWCLK'), ('4', 'SWD'), ('5', 'RUN')):
        b.same(f'SWD (not fitted).{pin}', f'RP2040:{fn}')
    led = b.via('330', 'RP2040:GPIO25', 'GRN:A')
    b.same('GRN:K', 'U1.5')
    b.same('D3.2', 'J1.a7')                 # the edge's +5V (D3's anode)
    b.via('10K', 'RP2040:GPIO26_ADC0', 'D3.2')
    b.via('15K', 'RP2040:GPIO26_ADC0', 'U1.5')
    b.via('10K', 'RP2040:GPIO22', 'USB_C.A4')  # VBUS detect
    b.via('15K', 'RP2040:GPIO22', 'U1.5')
    # USB and power
    b.via('27', 'RP2040:USB_DP', 'USB_C.A6')
    b.via('27', 'RP2040:USB_DM', 'USB_C.A7')
    b.same('USB_C.A6', 'USB_C.B6', 'USBLC6-2SC6.1', 'USBLC6-2SC6.6')
    b.same('USB_C.A7', 'USB_C.B7', 'USBLC6-2SC6.3', 'USBLC6-2SC6.4')
    b.via('5.1K', 'USB_C.A5', 'U1.5')
    b.via('5.1K', 'USB_C.B5', 'U1.5')
    b.same('USB_C.A4', 'USBLC6-2SC6.5', 'LM66100:VIN')
    b.same('LM66100:VOUT', 'D3.1', 'U4.1', 'U5.1')      # +5VD
    b.same('LM66100:~{CE}', 'LM66100:GND', 'USB_C.A1', 'USB_C.S1', 'U1.5')
    b.apart('USB_C.A4', 'D3.2')             # VBUS never meets the PS/2's +5V
    b.apart('USB_C.A4', 'D3.1')

    # the FPGA build's pins (verilog/difnif_p3.pcf) are all wired, and the
    # Teensy's old pins it doesn't use are not
    pcf = {}
    for line in open(os.path.join(ROOT, 'verilog', 'difnif_p3.pcf')):
        w = line.split()
        if w[:1] == ['set_io']:
            w = [x for x in w[1:] if not x.startswith('-')]
            pcf[w[1]] = w[0]
    for pin, sig in sorted(pcf.items(), key=lambda x: int(x[0])):
        if sig == 'addr_sel_in_l':
            continue    # unconnected on the 72-pin boards: FULLADDR (R22) decodes on the card
        if len(b.nets[b.net(f'U1.{pin}')]) < 2:
            b.fail(f'pcf {sig} on pin {pin}, which goes nowhere')
    teensy = {p for name, n in p2.nets.items() if name.startswith('/TN') or 'IOT_219' in name
              for r, p, f in n if r == 'U1'}
    for pin in teensy - set(pcf):
        b.alone(f'U1.{pin}')

    print(f'{unchanged} Rev P2 nets checked unchanged; {len(pcf)} pcf pins wired; '
          + ('all P3 connections present' if not b.errors else f'{b.errors} FAILED'))
    return 1 if b.errors else 0


if __name__ == '__main__':
    sys.exit(main())
