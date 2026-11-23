"""Read a KiCad netlist (kicad-cli sch export netlist --format kicadsexpr).

This file is part of a fork of DifNif; CERN-OHL-S-2.0.
"""

import os
import subprocess
import tempfile

import kisexp as K

KICAD_CLI = os.environ.get('KICAD_CLI', '/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli')


def export(sch):
    out = os.path.join(tempfile.mkdtemp(), 'n.net')
    subprocess.run([KICAD_CLI, 'sch', 'export', 'netlist', '--format', 'kicadsexpr', '-o', out,
                    sch], check=True, capture_output=True)
    return read(out)


def read(path):
    """-> (comps {ref: dict}, nets {name: [(ref, pin)]})"""
    t = K.parse(open(path).read())
    comps = {}
    for c in K.find(K.first(t, 'components'), 'comp'):
        d = {'ref': str(K.first(c, 'ref')[1]), 'value': str(K.first(c, 'value')[1])}
        fp = K.first(c, 'footprint')
        d['footprint'] = str(fp[1]) if fp else ''
        d['props'] = {str(K.first(p, 'name')[1]): str(K.first(p, 'value')[1])
                      for p in K.find(c, 'property') if K.first(p, 'value')}
        sp = K.first(c, 'sheetpath')
        d['sheet'] = str(K.first(sp, 'tstamps')[1])
        d['uuid'] = str(K.first(c, 'tstamps')[1])
        comps[d['ref']] = d
    nets = {}
    for n in K.find(K.first(t, 'nets'), 'net'):
        name = str(K.first(n, 'name')[1])
        nets[name] = [(str(K.first(x, 'ref')[1]), str(K.first(x, 'pin')[1]))
                      for x in K.find(n, 'node')]
    return comps, nets
