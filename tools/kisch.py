"""Geometry and editing helpers for KiCad schematics, on kisexp trees.

This file is part of a fork of DifNif; CERN-OHL-S-2.0.
"""

import uuid as _uuid

import kisexp as K


_rng = None


def seed(n):
    """make uid() repeatable, so a regenerated file only differs where it changed"""
    global _rng
    import random
    _rng = random.Random(n)


def uid():
    if _rng is None:
        return str(_uuid.uuid4())
    return str(_uuid.UUID(int=_rng.getrandbits(128), version=4))


def r(v):
    """round a coordinate to KiCad's 0.0001 mm grid, as a key"""
    return round(float(v), 4)


def lib_pins(lib_sym, unit, angles=False):
    """[(number, name, x, y)] of a library symbol's pins for one unit
    (sub-symbols NAME_U_S; unit 0 belongs to every unit), in library
    coordinates (Y up); with angles, (number, name, x, y, angle)"""
    out = []
    for sub in K.find(lib_sym, 'symbol'):
        parts = sub[1].rsplit('_', 2)
        if len(parts) != 3:
            continue
        u = int(parts[1])
        if u not in (0, unit):
            continue
        for p in K.find(sub, 'pin'):
            at = K.first(p, 'at')
            num = K.first(p, 'number')[1]
            nm = K.first(p, 'name')[1]
            t = (str(num), str(nm), float(at[1]), float(at[2]))
            out.append(t + (int(float(at[3])),) if angles else t)
    return out


def transform(sym, px, py):
    """library point -> sheet point for a placed symbol"""
    at = K.first(sym, 'at')
    sx, sy, rot = float(at[1]), float(at[2]), int(float(at[3])) if len(at) > 3 else 0
    mir = K.first(sym, 'mirror')
    x, y = px, -py                      # library Y up -> sheet Y down
    if mir and mir[1] == 'x':
        y = -y
    if mir and mir[1] == 'y':
        x = -x
    # rotation is counter-clockwise on screen (Y down)
    for _ in range((rot // 90) % 4):
        x, y = y, -x
    return r(sx + x), r(sy + y)


def lib_symbols(sheet):
    ls = K.first(sheet, 'lib_symbols')
    return {s[1]: s for s in K.find(ls, 'symbol')} if ls else {}


def symbol_pins(sheet, sym, libs=None):
    """{pin number: (x, y)} on the sheet for a placed symbol"""
    libs = libs or lib_symbols(sheet)
    lid = K.first(sym, 'lib_id')[1]
    unit = int(K.first(sym, 'unit')[1]) if K.first(sym, 'unit') else 1
    return {n: transform(sym, x, y) for n, nm, x, y in lib_pins(libs[lid], unit)}


def ref(sym):
    return K.prop(sym, 'Reference')


def point_set(sheet):
    """every wire end, label, junction and no-connect position"""
    pts = set()
    for w in K.find(sheet, 'wire'):
        for xy in K.find(K.first(w, 'pts'), 'xy'):
            pts.add((r(xy[1]), r(xy[2])))
    for kind in ('label', 'global_label', 'hierarchical_label', 'junction', 'no_connect'):
        for l in K.find(sheet, kind):
            at = K.first(l, 'at')
            pts.add((r(at[1]), r(at[2])))
    return pts


def _on_seg(p, a, b):
    (x, y), (x1, y1), (x2, y2) = p, a, b
    if (x2 - x1) * (y - y1) - (y2 - y1) * (x - x1) != 0:
        return False
    return min(x1, x2) <= x <= max(x1, x2) and min(y1, y2) <= y <= max(y1, y2)


def groups(sheet, libs=None):
    """Connectivity of one sheet, ignoring labels' names: a list of groups,
    each a dict with 'wires', 'labels', 'junctions', 'noconnects' (the
    nodes themselves) and 'pins' [(symbol node, pin number, point)]."""
    libs = libs or lib_symbols(sheet)
    items = []                      # (kind, node, [points])
    for w in K.find(sheet, 'wire'):
        pts = [(r(xy[1]), r(xy[2])) for xy in K.find(K.first(w, 'pts'), 'xy')]
        items.append(('wires', w, pts))
    for kind, key in (('label', 'labels'), ('global_label', 'labels'),
                      ('hierarchical_label', 'labels'), ('junction', 'junctions'),
                      ('no_connect', 'noconnects')):
        for n in K.find(sheet, kind):
            at = K.first(n, 'at')
            items.append((key, n, [(r(at[1]), r(at[2]))]))
    for sym in K.find(sheet, 'symbol'):
        for num, p in symbol_pins(sheet, sym, libs).items():
            items.append(('pins', (sym, num, p), [p]))
    parent = list(range(len(items)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    at_pt = {}
    for i, (k, n, pts) in enumerate(items):
        for p in pts:
            at_pt.setdefault(p, []).append(i)
    for idxs in at_pt.values():
        for j in idxs[1:]:
            parent[find(j)] = find(idxs[0])
    # points on a wire's interior
    for i, (k, n, pts) in enumerate(items):
        if k != 'wires':
            continue
        a, b = pts[0], pts[-1]
        for p, idxs in at_pt.items():
            if p != a and p != b and _on_seg(p, a, b):
                for j in idxs:
                    parent[find(j)] = find(i)
    out = {}
    for i, (k, n, pts) in enumerate(items):
        g = out.setdefault(find(i), {'wires': [], 'labels': [], 'junctions': [],
                                     'noconnects': [], 'pins': []})
        g[k].append(n)
    return list(out.values())


def remove(sheet, nodes):
    ids = {id(n) for n in nodes}
    sheet[:] = [x for x in sheet if id(x) not in ids]
