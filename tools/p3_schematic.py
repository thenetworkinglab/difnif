#!/usr/bin/env python3
"""Build Rev P3's schematic (pcb_p3/) from Rev P2's (pcb_formfactor/).

    python3 tools/p3_schematic.py            # writes pcb_p3/

Rev P2's sheets are edited, not redrawn, so the bus side stays exactly as
it was: the Teensy goes, its FPGA pins are renamed or marked unused, U7
gets its own direction line, the SD card goes through two bus switches,
and two new sheets hold the RP2040 and USB (USB.kicad_sch) and the PSRAM
and test points (PSRAM.kicad_sch). New parts are wired with short stubs
and labels; tidy them in KiCad as you like. The files stay in Rev P2's
format (KiCad 6), which KiCad 9 opens and re-saves in its own.

Check the result with KiCad's own netlist export (tools/p3_check.py).
See docs/rev-p3-design.md for what connects where and why.

This file is part of a fork of DifNif; CERN-OHL-S-2.0.
"""

import copy
import json
import math
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kisexp as K      # noqa: E402
import kisch as S       # noqa: E402
from kisexp import Str  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'pcb_formfactor')
DST = os.path.join(ROOT, 'pcb_p3')
KLIB = os.environ.get('KICAD9_SYMBOL_DIR',
                      '/Applications/KiCad/KiCad.app/Contents/SharedSupport/symbols')

R0603 = 'Resistor_SMD:R_0603_1608Metric'
C0603 = 'Capacitor_SMD:C_0603_1608Metric'
C0805 = 'Capacitor_SMD:C_0805_2012Metric'

# The Teensy's FPGA pins (by their Rev P2 labels) on Rev P3; see
# verilog/difnif_p3.pcf. Labels not listed here are unused pins.
TN_RENAME = {
    'TN16': 'FPGA_TX',    # 25 uart_tx -> RP2040 GPIO1
    'TN17': 'FPGA_RX',    # 26 uart_rx <- RP2040 GPIO0
    'TN22': 'SD_REQ',     # 33
    'TN23': 'SD_REL',     # 34
    'TN20': 'PFAIL',      # 31
    'TN40': 'PS_CLK',     # 17
    'TN41': 'PS_~{CS}',   # 18
    'TN14': 'PS_D0',      # 21
    'TN15': 'PS_D1',      # 23
    'TN18': 'PS_D2',      # 28
    'TN19': 'PS_D3',      # 29
    'TN21': 'TP1',        # 32 tp[0]
    'TN38': 'TP2',        # 11 tp[1]
    'TN27': 'TP3',        # 12 tp[2]
    'TN39': 'TP4',        # 16 tp[3]
}
# top-sheet labels the RP2040 also needs
TOP_GLOBAL = ['SPI_SCK', 'SPI_COPI', 'SPI_CIPO', 'SPI_~{CS}', 'CDONE', '~{CRESET}']

POWER = {'GND', '+3V3', '+5V', '+5VD', 'VBUS', '+1V1'}


def num(v):
    s = f'{float(v):.4f}'.rstrip('0').rstrip('.')
    return '0' if s in ('-0', '') else s


def font():
    return ['font', ['size', '1.27', '1.27']]


# ---------------------------------------------------------------- library

_libs = {}


def _lib(name):
    if name not in _libs:
        t = K.parse(open(os.path.join(KLIB, name + '.kicad_sym')).read())
        _libs[name] = {s[1]: s for s in K.find(t, 'symbol')}
    return _libs[name]


def _flatten(lib, name):
    s = copy.deepcopy(_lib(lib)[name])
    ext = K.first(s, 'extends')
    if not ext:
        return s
    base = _flatten(lib, ext[1])
    pname = base[1]
    base[1] = Str(name)
    for sub in K.find(base, 'symbol'):
        sub[1] = Str(name + sub[1][len(pname):])
    props = {p[1]: p for p in K.find(base, 'property')}
    for p in K.find(s, 'property'):
        if p[1] in props:
            props[p[1]][:] = p
        else:
            i = max(base.index(x) for x in K.find(base, 'property'))
            base.insert(i + 1, p)
    return base


def _sanitize(node):
    """KiCad 9 library syntax -> the KiCad 6 syntax of Rev P2's files"""
    out = []
    for x in node:
        if isinstance(x, list):
            if x == ['hide', 'yes']:
                out.append('hide')
                continue
            if x == ['hide', 'no']:
                continue
            out.append(_sanitize(x))
        else:
            out.append(x)
    return out


def lib_symbol(lib_id):
    lib, name = lib_id.split(':')
    s = _sanitize(_flatten(lib, name))
    s[1] = Str(lib_id)
    fixed = {'Reference': 0, 'Value': 1, 'Footprint': 2, 'Datasheet': 3}
    n = 4
    for p in K.find(s, 'property'):
        if K.first(p, 'id'):
            continue
        if p[1] in fixed:
            i = fixed[p[1]]
        else:
            i, n = n, n + 1
        p.insert(3, ['id', str(i)])
    return s


# ------------------------------------------------------------------ sheet

DIRS = {(1, 0): '0', (-1, 0): '180', (0, -1): '90', (0, 1): '270'}


class Sheet:
    pwr = [200]         # next #PWR number, shared by all sheets

    def __init__(self, tree, path, insts):
        self.t = tree
        self.path = path        # '' for the root sheet, '/<sheet uuid>' below it
        self.insts = insts      # the root's symbol_instances list
        self.libs = S.lib_symbols(tree)

    def add(self, node):
        for i, x in enumerate(self.t):
            if isinstance(x, list) and x[0] in ('sheet_instances', 'symbol_instances'):
                self.t.insert(i, node)
                return node
        self.t.append(node)
        return node

    def need_lib(self, lib_id):
        if lib_id not in self.libs:
            node = lib_symbol(lib_id)
            K.first(self.t, 'lib_symbols').append(node)
            self.libs[lib_id] = node
        return self.libs[lib_id]

    # -- symbols
    def place(self, lib_id, ref, value, x, y, rot=0, unit=1, fp='', mpn=None, fields=None):
        """fields: (dx, dy) for the reference and the value, instead of the library's"""
        lib = self.need_lib(lib_id)
        u = S.uid()
        sym = ['symbol', ['lib_id', Str(lib_id)], ['at', num(x), num(y), str(rot)],
               ['unit', str(unit)], ['in_bom', 'yes'], ['on_board', 'yes'], ['uuid', u]]
        for name, val in (('Reference', ref), ('Value', value), ('Footprint', fp),
                          ('Datasheet', None)):
            lp = next(p for p in K.find(lib, 'property') if p[1] == name)
            p = copy.deepcopy(lp)
            if val is not None:
                p[2] = Str(val)
            at = K.first(p, 'at')
            if name in ('Reference', 'Value') and fields:
                dx, dy = fields[0 if name == 'Reference' else 1]
                px, py = float(x) + dx, float(y) + dy
                eff = K.first(p, 'effects')
                eff[:] = [e for e in eff if not (isinstance(e, list) and e[0] == 'justify')]
                eff.append(['justify', 'left'])
            elif name in ('Reference', 'Value'):
                px, py = S.transform(sym, float(at[1]), float(at[2]))
            else:
                px, py = float(x), float(y)
            at[1:] = [num(px), num(py), '0']
            if name in ('Footprint', 'Datasheet'):
                eff = K.first(p, 'effects')
                if 'hide' not in eff:
                    eff.append('hide')
            sym.append(p)
        if mpn:
            sym.append(['property', Str('MPN'), Str(mpn), ['id', '4'],
                        ['at', num(x), num(y), '0'], ['effects', font(), 'hide']])
        for n, *_ in S.lib_pins(lib, unit):
            sym.append(['pin', Str(n), ['uuid', S.uid()]])
        self.insts.append(['path', Str(self.path + '/' + u), ['reference', Str(ref)],
                           ['unit', str(unit)], ['value', Str(value)],
                           ['footprint', Str(fp)]])
        return self.add(sym)

    def pin(self, sym, number):
        """(end point, outward unit vector) of a placed symbol's pin"""
        lib = self.libs[K.first(sym, 'lib_id')[1]]
        unit = int(K.first(sym, 'unit')[1])
        for n, nm, px, py, ang in S.lib_pins(lib, unit, angles=True):
            if n == str(number):
                a = math.radians(ang)
                dx, dy = -round(math.cos(a)), -round(math.sin(a))  # outward, library axes
                p = S.transform(sym, px, py)
                q = S.transform(sym, px + dx, py + dy)
                return p, (round(q[0] - p[0]), round(q[1] - p[1]))
        raise KeyError(f'{S.ref(sym)} has no pin {number}')

    def pin_by_name(self, lib_id, name):
        lib = self.need_lib(lib_id)
        return [n for n, nm, *_ in S.lib_pins(lib, 1) if nm == name]

    # -- connections
    def wire(self, a, b):
        return self.add(['wire', ['pts', ['xy', num(a[0]), num(a[1])], ['xy', num(b[0]), num(b[1])]],
                         ['stroke', ['width', '0'], ['type', 'default'], ['color', '0', '0', '0', '0']],
                         ['uuid', S.uid()]])

    def junction(self, p):
        return self.add(['junction', ['at', num(p[0]), num(p[1])], ['diameter', '0'],
                         ['color', '0', '0', '0', '0'], ['uuid', S.uid()]])

    def nc(self, p):
        return self.add(['no_connect', ['at', num(p[0]), num(p[1])], ['uuid', S.uid()]])

    def label(self, p, d, name, kind='local', shape='bidirectional'):
        ang = DIRS[d]
        side = 'left' if ang in ('0', '90') else 'right'
        at = ['at', num(p[0]), num(p[1]), ang]
        if kind == 'local':
            return self.add(['label', Str(name), at, ['effects', font(), ['justify', side, 'bottom']],
                             ['uuid', S.uid()]])
        if kind == 'hier':
            return self.add(['hierarchical_label', Str(name), ['shape', shape], at,
                             ['effects', font(), ['justify', side]], ['uuid', S.uid()]])
        return self.add(['global_label', Str(name), ['shape', shape], at, ['fields_autoplaced'],
                         ['effects', font(), ['justify', side]], ['uuid', S.uid()],
                         ['property', Str('Intersheet References'), Str('${INTERSHEET_REFS}'),
                          ['id', '0'], ['at', num(p[0]), num(p[1]), '0'],
                          ['effects', font(), ['justify', side], 'hide']]])

    def power(self, p, d, name):
        if name == 'GND':
            rot = {(0, 1): 0, (1, 0): 90, (0, -1): 180, (-1, 0): 270}[d]
        elif name == 'PWR_FLAG':
            rot = 0
        else:
            rot = {(0, -1): 0, (-1, 0): 90, (0, 1): 180, (1, 0): 270}[d]
        ref = f'#PWR{Sheet.pwr[0]:04d}' if name != 'PWR_FLAG' else f'#FLG{Sheet.pwr[0]:04d}'
        Sheet.pwr[0] += 1
        return self.place('power:' + name, ref, name, p[0], p[1], rot)

    def net_at(self, p, d, net):
        """put a net (power name, 'NC', 'g:NAME', 'h:NAME[:shape]', or a
        local label name) at a point, facing d"""
        if net in POWER or net == 'PWR_FLAG':
            self.power(p, d, net)
        elif net.startswith('g:'):
            self.label(p, d, net[2:], 'global')
        elif net.startswith('h:'):
            name, _, shape = net[2:].partition(':')
            self.label(p, d, name, 'hier', shape or 'bidirectional')
        else:
            self.label(p, d, net)

    def connect(self, sym, number, net, stub=2.54):
        p, d = self.pin(sym, number)
        if net == 'NC':
            self.nc(p)
            return
        q = (p[0] + d[0] * stub, p[1] + d[1] * stub)
        self.wire(p, q)
        self.net_at(q, d, net)

    def connect_all(self, sym, nets):
        for n, net in nets.items():
            if isinstance(net, tuple):
                self.connect(sym, n, net[0], net[1])
            else:
                self.connect(sym, n, net)

    def join(self, sym, numbers, net, stub=5.08):
        """several pins in a row on one net: stubs, a wire along their ends,
        and the net at the first"""
        ends = []
        for n in numbers:
            p, d = self.pin(sym, n)
            q = (p[0] + d[0] * stub, p[1] + d[1] * stub)
            self.wire(p, q)
            ends.append(q)
        for a, b in zip(ends, ends[1:]):
            self.wire(a, b)
        for q in ends[1:-1]:
            self.junction(q)
        self.net_at(ends[0], d, net)

    def two(self, lib_id, ref, value, x, y, n1, n2, fp, mpn=None, rot=0):
        """a two-pin part, upright: pin 1 at the top"""
        s = self.place(lib_id, ref, value, x, y, rot, fp=fp, mpn=mpn)
        pins = [n for n, *_ in S.lib_pins(self.libs[lib_id], 1)]
        top, bot = sorted(pins, key=lambda n: self.pin(s, n)[0][1])
        self.connect(s, top, n1)
        self.connect(s, bot, n2)
        return s


def R(sh, ref, value, x, y, n1, n2, mpn=None):
    return sh.two('Device:R_Small_US', ref, value, x, y, n1, n2, R0603, mpn)


def C(sh, ref, value, x, y, n1='+3V3', n2='GND', fp=C0603):
    return sh.two('Device:C_Small', ref, value, x, y, n1, n2, fp)


class Refs:
    def __init__(self, start):
        self.n = dict(start)

    def __call__(self, prefix):
        self.n[prefix] += 1
        return f'{prefix}{self.n[prefix]}'


# ----------------------------------------------------------------- sheets

def new_sheet(paper='A3'):
    return ['kicad_sch', ['version', '20211123'], ['generator', 'eeschema'],
            ['uuid', S.uid()], ['paper', Str(paper)], ['lib_symbols']]


def free_rect(sheet, x, y, w, h, margin=5):
    for pt in all_points(sheet):
        if x - margin <= pt[0] <= x + w + margin and y - margin <= pt[1] <= y + h + margin:
            return False
    return True


def all_points(sheet):
    pts = []
    for w in K.find(sheet, 'wire'):
        pts += [(float(p[1]), float(p[2])) for p in K.find(K.first(w, 'pts'), 'xy')]
    for kind in ('label', 'global_label', 'hierarchical_label', 'junction', 'no_connect',
                 'symbol', 'text'):
        for n in K.find(sheet, kind):
            at = K.first(n, 'at')
            pts.append((float(at[1]), float(at[2])))
    for s in K.find(sheet, 'sheet'):
        at, sz = K.first(s, 'at'), K.first(s, 'size')
        x, y, w, h = float(at[1]), float(at[2]), float(sz[1]), float(sz[2])
        pts += [(x, y), (x + w, y + h), (x + w, y), (x, y + h)]
    return pts


def sheet_symbol(top, like, name, file, x, y, w=25.4, h=10.16):
    s = copy.deepcopy(like)
    s[:] = [i for i in s if not (isinstance(i, list) and i[0] == 'pin')]
    u = S.uid()
    K.first(s, 'at')[1:] = [num(x), num(y)]
    K.first(s, 'size')[1:] = [num(w), num(h)]
    K.first(s, 'uuid')[1] = u
    for p in K.find(s, 'property'):
        at = K.first(p, 'at')
        if p[1] == 'Sheet name':
            p[2] = Str(name)
            at[1:3] = [num(x), num(y - 0.7116)]
        else:
            p[2] = Str(file)
            at[1:3] = [num(x), num(y + h + 0.5846)]
    for i, item in enumerate(top):
        if isinstance(item, list) and item[0] == 'sheet_instances':
            top.insert(i, s)
            break
    return u


def edit_top(top, insts):
    sh = Sheet(top, '', insts)
    syms = K.find(top, 'symbol')
    gone = [s for s in syms if S.ref(s) in ('U13', 'R23')]
    gone_ids = {id(s) for s in gone}
    removed_uuids = {K.first(s, 'uuid')[1] for s in gone}
    dead = list(gone)
    for g in S.groups(top):
        if not any(id(s) in gone_ids for s, n, p in g['pins']):
            continue
        dead += g['wires'] + g['labels'] + g['junctions'] + g['noconnects']
        for s, n, p in g['pins']:
            if id(s) in gone_ids:
                continue
            if S.ref(s).startswith('#'):
                dead.append(s)
                removed_uuids.add(K.first(s, 'uuid')[1])
            else:
                sh.nc(p)            # FPGA pin 141, which went to R23
    S.remove(top, dead)
    ls = K.first(top, 'lib_symbols')
    S.remove(ls, [x for x in K.find(ls, 'symbol') if x[1] == 'logic:Teensy4_1'])

    # the Teensy's FPGA pins: renamed, or unused
    dead = []
    for g in S.groups(top):
        names = [l[1] for l in g['labels'] if l[0] == 'label']
        tn = [n for n in names if n.startswith('TN')]
        if not tn:
            continue
        assert len(names) == 1, names
        lab = g['labels'][0]
        if tn[0] in TN_RENAME:
            to_global(lab, TN_RENAME[tn[0]])
        else:
            dead += g['wires'] + g['labels']
            for s, n, p in g['pins']:
                sh.nc(p)
    S.remove(top, dead)
    for lab in K.find(top, 'label'):
        if lab[1] in TOP_GLOBAL:
            to_global(lab, lab[1])

    # U7's own direction line, and pins 136-139 unused
    u1 = {}
    for s in K.find(top, 'symbol'):
        if S.ref(s) == 'U1':
            for n in S.symbol_pins(top, s):
                u1[n] = s
    sh.connect(u1['135'], '135', 'g:DATA_DIR_HI')
    for n in ('136', '137', '138', '139'):
        sh.nc(sh.pin(u1[n], n)[0])
    return sh, removed_uuids


def to_global(lab, name):
    at = K.first(lab, 'at')
    side = 'left' if at[3] in ('0', '90') else 'right'
    lab[:] = ['global_label', Str(name), ['shape', 'bidirectional'], at, ['fields_autoplaced'],
              ['effects', font(), ['justify', side]], K.first(lab, 'uuid'),
              ['property', Str('Intersheet References'), Str('${INTERSHEET_REFS}'), ['id', '0'],
               ['at', at[1], at[2], '0'], ['effects', font(), ['justify', side], 'hide']]]


def edit_bus(bus, path, insts):
    """U6 keeps DATA_DIR; U7 moves to DATA_DIR_HI"""
    sh = Sheet(bus, path, insts)
    g = next(g for g in S.groups(bus) if any(l[1] == 'DATA_DIR' for l in g['labels']))
    pins = {S.ref(s): p for s, n, p in g['pins']}
    u6, u7 = pins['U6'], pins['U7']
    keep = []
    for w in g['wires']:
        pts = [(S.r(x[1]), S.r(x[2])) for x in K.find(K.first(w, 'pts'), 'xy')]
        if u6 in pts or u7 in pts or pins['R7'] in pts:
            keep.append(w)
    hl = next(l for l in g['labels'] if l[1] == 'DATA_DIR')
    hp = (S.r(K.first(hl, 'at')[1]), S.r(K.first(hl, 'at')[2]))
    for w in g['wires']:
        pts = [(S.r(x[1]), S.r(x[2])) for x in K.find(K.first(w, 'pts'), 'xy')]
        if hp in pts:
            keep.append(w)
    S.remove(bus, [w for w in g['wires'] if w not in keep] + g['junctions'])
    stub = {}
    for w in keep:
        pts = [(S.r(x[1]), S.r(x[2])) for x in K.find(K.first(w, 'pts'), 'xy')]
        for pin in (u6, u7):
            if pin in pts:
                stub[pin] = pts[1] if pts[0] == pin else pts[0]
    sh.label(stub[u6], (-1, 0), 'DATA_DIR')
    sh.label(stub[u7], (-1, 0), 'DATA_DIR_HI', 'global')


def edit_sd(sd, path, insts, ref):
    """the card goes through two bus switches: B1 to the FPGA (the sheet's
    pins, as before), B2 to the RP2040"""
    sh = Sheet(sd, path, insts)
    lines = ['CLK', 'CMD', 'D0', 'D1', 'D2', 'D3']
    shapes = {}
    for hl in K.find(sd, 'hierarchical_label'):
        name = hl[1]
        if name.startswith('SD_') and name[3:] in lines:
            shapes[name] = K.first(hl, 'shape')[1]
            at = K.first(hl, 'at')
            side = 'left' if at[3] in ('0', '90') else 'right'
            hl[:] = ['label', Str('CARD_' + name[3:]), at,
                     ['effects', font(), ['justify', side, 'bottom']], K.first(hl, 'uuid')]
    # card detect to the RP2040 too: tap the long wire of SD_SWITCH
    g = next(g for g in S.groups(sd) if any(l[1] == 'SD_SWITCH' for l in g['labels']))
    w = max(g['wires'], key=lambda w: abs(float(K.first(w, 'pts')[1][1]) - float(K.first(w, 'pts')[2][1])))  # longest along X
    a, b = K.first(w, 'pts')[1], K.first(w, 'pts')[2]
    assert a[2] == b[2]
    mid = (S.r(round((float(a[1]) + float(b[1])) / 2 / 2.54) * 2.54), S.r(a[2]))
    sh.label(mid, (0, 1), 'SD_CD', 'global')

    chans = [lines[:4], lines[4:] + [None, None]]
    units = [(1, '4', '2', '3'), (2, '7', '5', '6'), (3, '9', '11', '10'), (4, '12', '14', '13')]
    ys = [134.62, 147.32, 160.02, 172.72]
    for chip, x in zip(chans, (40.64, 101.6)):
        r = ref('U')
        for (unit, a_, b1, b2), line, y in zip(units, chip, ys):
            s = sh.place('74xx:74CBTLV3257', r, '74CBTLV3257', x, y, 0, unit,
                         'Package_SO:TSSOP-16_4.4x5mm_P0.65mm', 'SN74CBTLV3257PWR',
                         fields=((-3.81, -7.62), (-3.81, -5.08)))
            if line is None:
                for n in (a_, b1, b2):
                    sh.connect(s, n, 'NC')
                continue
            sh.connect(s, a_, 'CARD_' + line)
            sh.connect(s, b1, 'h:SD_%s:%s' % (line, shapes['SD_' + line]))
            sh.connect(s, b2, 'g:RP_SD_' + line)
        y5 = 140.97 if x < 60 else 170.18
        s = sh.place('74xx:74CBTLV3257', r, '74CBTLV3257', 160.02, y5, 0, 5,
                     'Package_SO:TSSOP-16_4.4x5mm_P0.65mm', 'SN74CBTLV3257PWR')
        sh.connect_all(s, {'1': 'g:SD_SEL', '15': 'GND', '16': '+3V3', '8': 'GND'})
    for x in (200.66, 208.28):
        C(sh, ref('C'), '0.1uF', x, 140.97)
    return sh


def usb_sheet(path, insts, ref):
    t = new_sheet('A3')
    sh = Sheet(t, path, insts)

    # USB-C, ESD, VBUS into +5VD through an ideal diode
    j = sh.place('Connector:USB_C_Receptacle_USB2.0_16P', ref('J'), 'USB_C', 40.64, 71.12, 0,
                 fp='Connector_USB:USB_C_Receptacle_HRO_TYPE-C-31-M-12', mpn='TYPE-C-31-M-12')
    sh.connect_all(j, {'A4': 'VBUS', 'A5': 'CC1', 'B5': 'CC2', 'A7': 'USB_N', 'B7': 'USB_N',
                       'A6': 'USB_P', 'B6': 'USB_P', 'A8': 'NC', 'B8': 'NC',
                       'A1': 'GND', 'S1': 'GND'})
    e = sh.place('Power_Protection:USBLC6-2SC6', ref('U'), 'USBLC6-2SC6', 96.52, 60.96,
                 fp='Package_TO_SOT_SMD:SOT-23-6', mpn='USBLC6-2SC6')
    sh.connect_all(e, {'1': 'USB_P', '6': 'USB_P', '3': 'USB_N', '4': 'USB_N',
                       '5': 'VBUS', '2': 'GND'})
    d = sh.place('Power_Management:LM66100DCK', ref('U'), 'LM66100', 96.52, 101.6,
                 fp='Package_TO_SOT_SMD:SOT-363_SC-70-6', mpn='LM66100DCKR')
    sh.connect_all(d, {'1': 'VBUS', '3': 'GND', '4': 'NC', '2': 'GND', '6': '+5VD', '5': 'NC'})
    sh.power((60.96, 116.84), (0, -1), 'VBUS')
    sh.wire((60.96, 116.84), (71.12, 116.84))
    sh.power((71.12, 116.84), (0, -1), 'PWR_FLAG')

    # RP2040
    u = sh.place('MCU_RaspberryPi:RP2040', ref('U'), 'RP2040', 215.9, 152.4,
                 fp='Package_DFN_QFN:QFN-56-1EP_7x7mm_P0.4mm_EP3.2x3.2mm', mpn='RP2040')
    sh.join(u, ['1', '48', '43', '44'], '+3V3')         # IOVDD, USB_VDD, ADC_AVDD, VREG_IN
    sh.join(u, ['45', '23'], '+1V1')                    # VREG_VOUT, DVDD
    sh.connect_all(u, {
        '57': 'GND', '19': 'GND',                       # TESTEN
        '26': 'RP_RUN', '47': 'RP_DP', '46': 'RP_DM',
        '56': 'QSPI_SS', '53': 'QSPI_SD0', '55': 'QSPI_SD1', '54': 'QSPI_SD2',
        '51': 'QSPI_SD3', '52': 'QSPI_SCLK',
        '20': 'XIN', '21': 'XOUT', '24': 'SWCLK', '25': 'SWDIO',
        '2': 'g:FPGA_RX', '3': 'g:FPGA_TX',             # GPIO0 UART0 TX, GPIO1 UART0 RX
        '4': ('RP_SCK', 17.78), '5': ('RP_COPI', 17.78), '6': 'g:SPI_CIPO', '7': ('RP_CS', 17.78),
        '8': 'g:~{CRESET}', '9': 'g:CDONE',
        '11': 'g:SD_REQ', '12': 'g:SD_REL', '13': 'g:PFAIL', '14': 'g:SD_SEL', '15': 'g:SD_CD',
        '16': 'NC', '17': 'NC', '18': 'NC',
        '27': 'g:RP_SD_CLK', '28': 'g:RP_SD_CMD', '29': 'g:RP_SD_D0', '30': 'g:RP_SD_D1',
        '31': 'g:RP_SD_D2', '32': 'g:RP_SD_D3',
        '34': 'VBUS_DET', '35': 'NC', '36': 'NC', '37': 'RP_LED',
        '38': 'V5_SENSE', '39': 'NC', '40': 'NC', '41': 'NC',
    })

    # its flash, BOOTSEL, crystal, SWD
    f = sh.place('Memory_Flash:W25Q16JVSS', ref('U'), 'W25Q16JVSS', 119.38, 152.4,
                 fp='Package_SO:SOIC-8_5.3x5.3mm_P1.27mm', mpn='W25Q16JVSSIQ')
    sh.connect_all(f, {'1': 'QSPI_SS', '6': 'QSPI_SCLK', '5': 'QSPI_SD0', '2': 'QSPI_SD1',
                       '3': 'QSPI_SD2', '7': 'QSPI_SD3', '8': '+3V3', '4': 'GND'})
    y = sh.place('Device:Crystal_GND24_Small', ref('Y'), '12MHz', 60.96, 213.36,
                 fp='Crystal:Crystal_SMD_3225-4Pin_3.2x2.5mm', mpn='ABM8-272-T3')
    sh.connect_all(y, {'1': 'XIN', '3': 'XTAL', '2': 'GND', '4': 'GND'})
    sw = sh.place('Switch:SW_Push', ref('SW'), 'BOOTSEL', 60.96, 254.0,
                  fp='Button_Switch_SMD:SW_SPST_B3U-1000P', mpn='B3U-1000P')
    sh.connect_all(sw, {'1': 'BOOTSEL', '2': 'GND'})
    h = sh.place('Connector_Generic:Conn_01x05', ref('J'), 'SWD (not fitted)', 121.92, 236.22, 90,
                 fp='Connector_PinHeader_2.54mm:PinHeader_1x05_P2.54mm_Vertical')
    sh.connect_all(h, {'1': '+3V3', '2': 'SWCLK', '3': 'GND', '4': 'SWDIO', '5': 'RP_RUN'})
    led = sh.place('Device:LED_Small_Filled', ref('D'), 'GRN', 375.92, 213.36, 90,
                   fp='LED_SMD:LED_0603_1608Metric')
    k, a = sh.pin_by_name('Device:LED_Small_Filled', 'K'), sh.pin_by_name('Device:LED_Small_Filled', 'A')
    sh.connect(led, k[0], 'GND')
    sh.connect(led, a[0], 'LED_A')

    # decoupling, in a row along the top
    x = 154.94
    for v, n in [('0.1uF', '+3V3')] * 9 + [('1uF', '+3V3'), ('1uF', '+1V1'),
                                            ('0.1uF', '+1V1'), ('0.1uF', '+1V1')]:
        C(sh, ref('C'), v, x, 38.1, n)
        x += 7.62
    C(sh, ref('C'), '4.7uF', x, 38.1, 'VBUS', fp=C0805)

    # resistors and the rest, in rows on the right
    parts = [
        ('R', '27', 'RP_DP', 'USB_P'), ('R', '27', 'RP_DM', 'USB_N'),
        ('R', '5.1K', 'CC1', 'GND'), ('R', '5.1K', 'CC2', 'GND'),
        ('R', '33', 'RP_SCK', 'g:SPI_SCK'), ('R', '33', 'RP_COPI', 'g:SPI_COPI'),
        ('R', '33', 'RP_CS', 'g:SPI_~{CS}'),
        ('R', '10K', 'g:SD_SEL', 'GND'), ('R', '10K', '+3V3', 'RP_RUN'),
        ('R', '1K', 'XOUT', 'XTAL'),
        ('C', '15pF', 'XIN', 'GND'), ('C', '15pF', 'XTAL', 'GND'),
        ('R', '1K', 'QSPI_SS', 'BOOTSEL'),
        ('R', '330', 'RP_LED', 'LED_A'),
        ('R', '10K', '+5V', 'V5_SENSE'), ('R', '15K', 'V5_SENSE', 'GND'),
        ('C', '0.1uF', 'V5_SENSE', 'GND'),
        ('R', '10K', 'VBUS', 'VBUS_DET'), ('R', '15K', 'VBUS_DET', 'GND'),
    ]
    for i, (kind, v, n1, n2) in enumerate(parts):
        px = 289.56 + 12.7 * (i % 8)
        py = 63.5 + 55.88 * (i // 8)
        if kind == 'R':
            R(sh, ref('R'), v, px, py, n1, n2)
        else:
            C(sh, ref('C'), v, px, py, n1, n2)
    return t


def psram_sheet(path, insts, ref):
    t = new_sheet('A4')
    sh = Sheet(t, path, insts)
    m = sh.place('Memory_RAM:APS6404L-3SQRx-SN', ref('U'), 'APS6404L-3SQR-SN', 99.06, 88.9,
                 fp='Package_SO:SOIC-8_3.9x4.9mm_P1.27mm', mpn='APS6404L-3SQR-SN')
    sh.connect_all(m, {'1': 'g:PS_~{CS}', '6': 'g:PS_CLK', '5': 'g:PS_D0', '2': 'g:PS_D1',
                       '3': 'g:PS_D2', '7': 'g:PS_D3', '8': '+3V3', '4': 'GND'})
    R(sh, ref('R'), '10K', 63.5, 127.0, '+3V3', 'g:PS_~{CS}')
    C(sh, ref('C'), '0.1uF', 127.0, 76.2)
    for i in range(4):
        tp = sh.place('Connector:TestPoint', ref('TP'), 'TP', 160.02 + 15.24 * i, 88.9,
                      fp='TestPoint:TestPoint_Pad_D1.5mm')
        sh.connect(tp, '1', 'g:TP%d' % (i + 1))
    return t


def main():
    S.seed(3)
    if os.path.exists(DST):
        shutil.rmtree(DST)
    os.makedirs(DST)
    load = lambda f: K.parse(open(os.path.join(SRC, f + '.kicad_sch')).read())  # noqa: E731
    top, bus, pw, sd = load('DifNif'), load('DifNifBus'), load('DifNifPower'), load('SDCard')
    insts = K.first(top, 'symbol_instances')
    sheets = {K.prop(s, 'Sheet name'): s for s in K.find(top, 'sheet')}
    path = {n: '/' + K.first(s, 'uuid')[1] for n, s in sheets.items()}

    used = {}
    for p in K.find(insts, 'path'):
        r = K.first(p, 'reference')[1]
        pre = ''.join(c for c in r if c.isalpha())
        if not r.startswith('#') and r[len(pre):].isdigit():
            used[pre] = max(used.get(pre, 0), int(r[len(pre):]))
    ref = Refs({'U': max(used['U'], 14), 'R': used['R'], 'C': used['C'], 'J': used['J'],
                'D': used['D'], 'Y': 0, 'SW': 0, 'TP': 0})

    sh_top, removed = edit_top(top, insts)
    S.remove(insts, [p for p in K.find(insts, 'path') if p[1].rsplit('/', 1)[1] in removed])
    for lab in K.find(pw, 'label'):         # the same nets on the power sheet
        if lab[1] in TOP_GLOBAL:
            to_global(lab, lab[1])
    edit_bus(bus, path['DifNifBus'], insts)
    edit_sd(sd, path['SDCard'], insts, ref)

    # the new sheets' symbols on the top sheet, where there's room
    like = sheets['DifNifPower']
    spots = [(45.72, 152.4), (45.72, 167.64)]     # beside DifNifPower, clear on Rev P2
    assert all(free_rect(top, x, y, 25.4, 10.16, 2) for x, y in spots), 'no room on the top sheet'
    new = {}
    for (name, file, build), (x, y) in zip(
            [('USB', 'USB.kicad_sch', usb_sheet), ('PSRAM', 'PSRAM.kicad_sch', psram_sheet)], spots):
        u = sheet_symbol(top, like, name, file, x, y)
        new[file] = build('/' + u, insts, ref)
        pages = K.first(top, 'sheet_instances')
        pages.append(['path', Str('/' + u), ['page', Str(str(len(K.find(pages, 'path')) + 1))]])
        path[name] = '/' + u

    out = {'DifNif': top, 'DifNifBus': bus, 'DifNifPower': pw, 'SDCard': sd}
    for name, tree in out.items():
        open(os.path.join(DST, name + '.kicad_sch'), 'w').write(K.dump(tree) + '\n')
    for file, tree in new.items():
        open(os.path.join(DST, file), 'w').write(K.dump(tree) + '\n')

    pro = json.load(open(os.path.join(SRC, 'DifNif.kicad_pro')))
    for name in ('USB', 'PSRAM'):
        pro['sheets'].append([path[name][1:], name])
    json.dump(pro, open(os.path.join(DST, 'DifNif.kicad_pro'), 'w'), indent=2)
    shutil.copy(os.path.join(SRC, 'DifNif.kicad_pcb'), DST)
    print('wrote', DST)


if __name__ == '__main__':
    main()
