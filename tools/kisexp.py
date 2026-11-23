"""Minimal reader and writer for KiCad's s-expression files (schematics).

parse(text) -> a tree of lists; atoms are strings, quoted strings are Str.
dump(tree) -> text KiCad reads back (formatting differs from KiCad's own,
which it doesn't mind; it reformats on save).

This file is part of a fork of DifNif; CERN-OHL-S-2.0.
"""


class Str(str):
    """A quoted string in the file (as opposed to a bare atom)"""


def parse(text):
    stack = [[]]
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '(':
            stack.append([])
            i += 1
        elif c == ')':
            node = stack.pop()
            stack[-1].append(node)
            i += 1
        elif c == '"':
            j = i + 1
            buf = []
            while text[j] != '"':
                if text[j] == '\\':
                    buf.append(text[j + 1])
                    j += 2
                else:
                    buf.append(text[j])
                    j += 1
            stack[-1].append(Str(''.join(buf)))
            i = j + 1
        elif c.isspace():
            i += 1
        else:
            j = i
            while j < n and not text[j].isspace() and text[j] not in '()':
                j += 1
            stack[-1].append(text[i:j])
            i = j
    assert len(stack) == 1
    return stack[0][0]


def _atom(a):
    if isinstance(a, Str):
        return '"' + a.replace('\\', '\\\\').replace('"', '\\"') + '"'
    return a


def dump(node, indent=0):
    if not isinstance(node, list):
        return _atom(node)
    # short lists on one line
    flat = '(' + ' '.join(dump(x) if isinstance(x, list) else _atom(x) for x in node) + ')'
    if len(flat) < 100 and '\n' not in flat:
        return flat
    # keep the order: KiCad mixes bare words with sub-lists (a pin's "hide")
    pad = '\t' * (indent + 1)
    out = '('
    seen_list = False
    for k, x in enumerate(node):
        if isinstance(x, list):
            out += '\n' + pad + dump(x, indent + 1)
            seen_list = True
        elif seen_list:
            out += '\n' + pad + _atom(x)
        else:
            out += (' ' if k else '') + _atom(x)
    return out + '\n' + '\t' * indent + ')'


def find(node, key):
    """children of node that are lists starting with key"""
    return [x for x in node if isinstance(x, list) and x and x[0] == key]


def first(node, key):
    r = find(node, key)
    return r[0] if r else None


def prop(sym, name):
    for p in find(sym, 'property'):
        if p[1] == name:
            return p[2]
    return None
