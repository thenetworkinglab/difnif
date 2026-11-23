#!/usr/bin/env python3
"""Build Rev P3's board (pcb_p3/DifNif.kicad_pcb) from Rev P2's.

Run with KiCad's own Python, which has the pcbnew module:

    /Applications/KiCad/KiCad.app/Contents/Frameworks/Python.framework/Versions/Current/bin/python3 tools/p3_pcb.py

Starts from pcb_formfactor/DifNif.kicad_pcb and pcb_p3's schematic:
- does what KiCad's "Update PCB from Schematic" would: drops the Teensy and
  R23, adds the new parts (KiCad's own footprints), and puts every pad on
  its Rev P3 net;
- keeps Rev P2's tracks where their net is unchanged (renamed or with new
  pins is fine), deletes those of nets that are gone or split, and trims
  the dead ends the Teensy leaves on GND and +5VD;
- places the new parts (PLACE below), unrouted: the new routing is done by
  hand in KiCad (see docs/rev-p3-design.md);
- refills the zones and saves.

Rerunning overwrites the board, so only rerun it before hand routing
starts (or to start again).

This file is part of a fork of DifNif; CERN-OHL-S-2.0.
"""

import collections
import math
import os
import sys

import pcbnew

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kinet  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, 'pcb_formfactor', 'DifNif.kicad_pcb')
DST = os.path.join(ROOT, 'pcb_p3', 'DifNif.kicad_pcb')
SCH = os.path.join(ROOT, 'pcb_p3', 'DifNif.kicad_sch')
FPLIB = os.environ.get('KICAD9_FOOTPRINT_DIR',
                       '/Applications/KiCad/KiCad.app/Contents/SharedSupport/footprints')

GONE = {'U13', 'R23'}

# Rev P2 nets whose tracks stay although they lose the Teensy's pins: the
# dead ends are trimmed
TRIM = {'GND', '+5VD'}

# kept nets whose Rev P2 tracks cross where new parts go: routed again
REROUTE = {'SD_CD'}

# split nets whose Rev P2 tracks stay, less the stub to the pad that left:
# U7's DIR now has its own line (DATA_DIR_HI); U6, R7 and J4 keep DATA_DIR
SPLIT_KEEP = {'/DATA_DIR': ('U7', '2')}

# where the new parts go: ref -> (x, y, rotation in degrees); all on the
# top side. The Teensy's space (right of J4) takes the RP2040 and USB; the
# bus switches sit between the FPGA's SD pins and the card socket, the PSRAM
# beside the FPGA's bank 3.
PLACE = {
    # USB-C on the edge opposite the card edge, above the microSD socket
    'J5': (186.35, 64.0, 90),
    'U17': (179.0, 64.0, 0),        # USBLC6-2: D+/D- flow through
    'R26': (180.2, 70.6, 270),      # CC1 5.1k
    'R27': (180.2, 57.4, 90),       # CC2 5.1k
    'C51': (184.6, 70.6, 0),        # VBUS 4.7uF
    'U18': (184.6, 73.4, 0),        # LM66100: VBUS -> +5VD
    'R38': (184.9, 76.4, 180),      # VBUS divider -> VBUS_DET
    'R39': (184.9, 78.0, 0),
    # RP2040 and its flash, crystal and decoupling
    'U19': (176.0, 80.0, 0),
    'U20': (170.0, 70.5, 90),       # W25Q16: pins 1-4 face the RP2040's QSPI pins
    'C44': (167.0, 63.8, 90),        # flash VCC
    'R24': (176.7, 70.6, 90),       # 27 ohm D+
    'R25': (178.2, 70.6, 90),       # 27 ohm D-
    'C38': (170.3, 76.4, 180),      # pin 1
    'C39': (170.3, 81.0, 180),      # pin 10
    'C40': (175.4, 85.9, 90),       # pin 22
    'C41': (181.7, 81.0, 0),        # pin 33
    'C42': (181.7, 77.4, 0),        # pin 42
    'C43': (179.9, 74.2, 90),       # pins 43, 44
    'C47': (181.4, 74.2, 90),       # VREG_IN 1uF
    'C45': (176.4, 74.4, 90),       # pins 48, 49
    'C46': (178.4, 85.9, 270),      # spare 0.1uF on +3V3, by RUN's pull-up
    'C48': (178.4, 74.2, 90),       # VREG_VOUT 1uF
    'C49': (181.4, 86.0, 90),       # +1V1, by C50
    'C50': (176.9, 85.9, 90),       # pin 23
    'Y1': (172.6, 90.0, 0),
    'C52': (169.7, 90.4, 90),
    'C53': (175.6, 91.6, 90),
    'R33': (176.3, 89.0, 0),        # XOUT 1k
    'R32': (179.9, 85.9, 90),       # RUN pull-up
    'R28': (167.8, 84.6, 0),        # 33 ohm to the config flash's SPI
    'R29': (167.8, 86.2, 0),
    'R30': (167.8, 87.8, 0),
    'R36': (184.9, 81.0, 180),      # +5V divider -> V5_SENSE
    'R37': (184.9, 82.6, 0),
    'C54': (184.9, 84.2, 0),
    'R35': (177.0, 44.2, 0),        # status LED, beside D1/D2
    'D4': (180.2, 44.2, 180),
    'SW1': (171.8, 62.0, 0),        # BOOTSEL
    'R34': (175.3, 62.6, 90),
    'J6': (178.6, 95.4, 90),        # SWD, not fitted
    # SD bus switches between the FPGA's SD pins and the card socket
    'U15': (163.0, 102.525, 0),
    'U16': (171.4, 102.525, 0),
    'C36': (166.7, 98.8, 0),
    'C37': (175.1, 98.8, 0),
    'R31': (167.2, 107.0, 90),      # SD_SEL pull-down
    # PSRAM beside the FPGA's bank 3
    'U21': (162.0, 85.505, 0),
    'R40': (162.0, 81.8, 0),
    'C55': (162.0, 89.4, 0),
    'TP1': (155.2, 100.0, 0),
    'TP2': (157.8, 100.0, 0),
    'TP3': (155.2, 102.6, 0),
    'TP4': (157.8, 102.6, 0),
}


def mm(v):
    return pcbnew.FromMM(v)


def to_mm(v):
    return round(pcbnew.ToMM(v), 4)


def pt(x, y):
    return pcbnew.VECTOR2I(mm(x), mm(y))


class Pcb:
    def __init__(self, board):
        self.b = board
        self.nets = {}

    def net(self, name):
        if not name:
            return self.b.FindNet(0)
        n = self.b.FindNet(name)
        if n is None:
            n = pcbnew.NETINFO_ITEM(self.b, name)
            self.b.Add(n)
        return n

    def fp(self, ref):
        return self.b.FindFootprintByReference(ref)

    def pad(self, ref, num):
        ps = [p for p in self.fp(ref).Pads() if p.GetNumber() == str(num)]
        assert ps, (ref, num)
        return ps[0]

    def track(self, pts, width, layer, net):
        lid = self.b.GetLayerID(layer)
        for (x1, y1), (x2, y2) in zip(pts, pts[1:]):
            t = pcbnew.PCB_TRACK(self.b)
            t.SetStart(pt(x1, y1))
            t.SetEnd(pt(x2, y2))
            t.SetWidth(mm(width))
            t.SetLayer(lid)
            t.SetNet(self.net(net))
            self.b.Add(t)

    def via(self, x, y, net, size=0.6096, drill=0.3048):
        v = pcbnew.PCB_VIA(self.b)
        v.SetPosition(pt(x, y))
        v.SetWidth(mm(size))
        v.SetDrill(mm(drill))
        v.SetNet(self.net(net))
        self.b.Add(v)
        return v


def new_footprint(comp):
    lib, name = comp['footprint'].split(':')
    f = pcbnew.FootprintLoad(os.path.join(FPLIB, lib + '.pretty'), name)
    assert f, comp['footprint']
    f.SetFPIDAsString(comp['footprint'])
    return f


def update(p, comps, nets):
    b = p.b
    of = {(r, n): name for name, nodes in nets.items() for r, n in nodes}
    old = collections.defaultdict(set)
    for f in b.GetFootprints():
        for pad in f.Pads():
            if pad.GetNetname():
                old[pad.GetNetname()].add((f.GetReference(), pad.GetNumber()))

    # which Rev P2 nets keep their tracks, and under which name
    rename, drop = {}, set()
    for name, pads in old.items():
        live = {x for x in pads if x[0] not in GONE}
        new = {of.get(x) for x in live}
        if len(new) == 1 and None not in new and (live == pads or name in TRIM):
            rename[name] = new.pop()
        else:
            drop.add(name)

    for ref in GONE:
        b.Delete(b.FindFootprintByReference(ref))
    have = {f.GetReference() for f in b.GetFootprints()}
    for ref, c in sorted(comps.items()):
        if ref in have:
            continue
        f = new_footprint(c)
        f.SetReference(ref)
        f.SetValue(c['value'])
        if c['props'].get('MPN'):
            fld = pcbnew.PCB_FIELD(f, f.GetNextFieldId(), 'MPN')
            fld.SetText(c['props']['MPN'])
            fld.SetVisible(False)
            fld.SetLayer(pcbnew.F_Fab)
            f.AddField(fld)
        f.SetPath(pcbnew.KIID_PATH(c['sheet'] + c['uuid']))
        f.SetSheetname(c['props'].get('Sheetname', ''))
        f.SetSheetfile(c['props'].get('Sheetfile', ''))
        x, y, rot = PLACE.get(ref, (200, 60, 0))
        f.SetPosition(pt(x, y))
        f.SetOrientationDegrees(rot)
        if ref.startswith('TP'):
            f.SetExcludedFromBOM(False)     # as the schematic's symbol
        b.Add(f)

    for f in b.GetFootprints():
        ref = f.GetReference()
        if ref not in comps:
            continue
        for pad in f.Pads():
            pad.SetNet(p.net(of.get((ref, pad.GetNumber()), '')))

    for name, (ref, num) in SPLIT_KEEP.items():
        drop.discard(name)
        rename[name] = name
        stub(p, name, p.pad(ref, num))
    for t in list(b.GetTracks()):
        name = t.GetNetname()
        if name in drop or rename.get(name) in REROUTE:
            b.Delete(t)
        elif name in rename:
            t.SetNet(p.net(rename[name]))
    return rename, drop


def stub(p, name, pad):
    """delete a net's tracks from a pad back to the first via or junction"""
    b = p.b
    segs = [t for t in b.GetTracks() if t.GetNetname() == name and t.GetClass() == 'PCB_TRACK']
    at = pad.GetPosition()
    q = None
    while True:
        hit = [t for t in segs if (q is None and pad.HitTest(t.GetStart()) or pad.HitTest(t.GetEnd()))
               or (q is not None and (t.GetStart() == q or t.GetEnd() == q))] if q is None else \
              [t for t in segs if t.GetStart() == q or t.GetEnd() == q]
        if q is None:
            hit = [t for t in segs if pad.HitTest(t.GetStart()) or pad.HitTest(t.GetEnd())]
        if len(hit) != 1:
            return
        t = hit[0]
        segs.remove(t)
        far = t.GetEnd() if (pad.HitTest(t.GetStart()) if q is None else t.GetStart() == q) else t.GetStart()
        b.Delete(t)
        q = far
        others = [s for s in segs if s.GetStart() == q or s.GetEnd() == q]
        vias = [v for v in b.GetTracks() if v.GetClass() == 'PCB_VIA' and v.GetPosition() == q]
        if vias or len(others) != 1:
            return


def prune(p, names):
    """delete track segments of these nets with an end that touches
    nothing of the same net (pad, other track, via), until none are left"""
    b = p.b
    while True:
        segs = [t for t in b.GetTracks() if t.GetNetname() in names and t.GetClass() == 'PCB_TRACK']
        vias = [t for t in b.GetTracks() if t.GetNetname() in names and t.GetClass() == 'PCB_VIA']
        ends = collections.Counter()
        for t in segs:
            for q in (t.GetStart(), t.GetEnd()):
                ends[(t.GetNetname(), t.GetLayer(), q.x, q.y)] += 1
        viaat = {(v.GetNetname(), v.GetPosition().x, v.GetPosition().y) for v in vias}
        pads = [pad for f in b.GetFootprints() for pad in f.Pads() if pad.GetNetname() in names]
        dead = []
        for t in segs:
            for q in (t.GetStart(), t.GetEnd()):
                n = t.GetNetname()
                if ends[(n, t.GetLayer(), q.x, q.y)] > 1 or (n, q.x, q.y) in viaat:
                    continue
                if any(pad.GetNetname() == n and pad.IsOnLayer(t.GetLayer()) and
                       pad.HitTest(q) for pad in pads):
                    continue
                dead.append(t)
                break
        if not dead:
            return
        for t in dead:
            b.Delete(t)


def clear_vias(p, refs, margin=0.5):
    """delete Rev P2's lone GND stitching vias where the new parts go"""
    b = p.b
    boxes = []
    for f in b.GetFootprints():
        if f.GetReference() in refs:
            bb = f.GetCourtyard(pcbnew.F_CrtYd).BBox()
            if bb.GetWidth() == 0:
                bb = f.GetBoundingBox(False)
            bb.Inflate(mm(margin))
            boxes.append(bb)
    ends = {(q.x, q.y) for t in b.GetTracks() if t.GetClass() == 'PCB_TRACK'
            for q in (t.GetStart(), t.GetEnd())}
    for v in list(b.GetTracks()):
        if v.GetClass() != 'PCB_VIA' or v.GetNetname() != 'GND':
            continue
        q = v.GetPosition()
        if (q.x, q.y) not in ends and any(bb.Contains(q) for bb in boxes):
            b.Delete(v)


def main():
    comps, nets = kinet.export(SCH)
    b = pcbnew.LoadBoard(SRC)
    p = Pcb(b)
    rename, drop = update(p, comps, nets)
    prune(p, TRIM | set(SPLIT_KEEP))
    clear_vias(p, set(PLACE))
    for d in list(b.GetDrawings()):
        # Rev P2's joke about the Teensy's size, now about nothing
        if d.GetClass() == 'PCB_TEXT' and 'TEENSY' in d.GetText():
            b.Delete(d)
    pcbnew.ZONE_FILLER(b).Fill(b.Zones())
    # saving a board rewrites its .kicad_pro, losing the schematic's sheet
    # list: keep the project file as p3_schematic.py wrote it
    pro = os.path.splitext(DST)[0] + '.kicad_pro'
    keep = open(pro, 'rb').read()
    b.Save(DST)
    open(pro, 'wb').write(keep)
    print(f'{len(comps)} parts; kept the tracks of {len(rename)} nets, '
          f'dropped {len(drop)}; wrote {os.path.relpath(DST, ROOT)}')


if __name__ == '__main__':
    main()
