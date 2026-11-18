#!/usr/bin/env python3
"""
DifNif copy test: make the test files, and check the results by reading the
SD card's disk image directly (read-only, nothing is mounted).

  copytest.py files DIR
      Writes T1.BIN (512 KB) and T2.BIN (1 MB) of random data, P1.BIN (1 MB,
      each 32-bit word holds its own byte offset) and SUMS.TXT (their SHA-256
      checksums) into DIR. Copy the .BIN and .BAT files to the root of D:.

  copytest.py check IMAGE SUMS
      Lists the partitions in IMAGE (disk0.img), checks D:'s T1/T2/P1 against
      SUMS, checks the copies the test made (C:\\DNTEST\\*.BIN and D:\\R*.BIN),
      summarises D:\\FCLOG.TXT, and for a damaged pattern file reports where
      the damage starts and by how many bytes the data is shifted.

The DOS side is TEST.BAT, ROUND.BAT and CHECK.BAT in this folder: copied to
the root of D: and run as D:\\TEST.BAT.

This file is part of a fork of DifNif; CERN-OHL-S-2.0.
"""

import hashlib
import os
import struct
import sys

SECTOR = 512
FAT_TYPES = (0x01, 0x04, 0x06, 0x0E)
EXTENDED = (0x05, 0x0F)


def make_files(d):
    os.makedirs(d, exist_ok=True)
    files = {
        "T1.BIN": os.urandom(512 * 1024),
        "T2.BIN": os.urandom(1024 * 1024),
        "P1.BIN": b"".join(struct.pack("<I", i) for i in range(0, 1024 * 1024, 4)),
    }
    with open(os.path.join(d, "SUMS.TXT"), "w") as s:
        for name, data in files.items():
            with open(os.path.join(d, name), "wb") as f:
                f.write(data)
            s.write("%s  %s\n" % (hashlib.sha256(data).hexdigest(), name))
    print("Wrote T1.BIN, T2.BIN, P1.BIN and SUMS.TXT to", d)


class Image:
    def __init__(self, path):
        self.f = open(path, "rb")

    def read(self, lba, count=1):
        self.f.seek(lba * SECTOR)
        return self.f.read(count * SECTOR)

    def partitions(self):
        """FAT partitions in drive-letter order: primaries, then logicals."""
        found = []

        def entries(sector):
            if sector[510:512] != b"\x55\xaa":
                return None
            out = []
            for i in range(4):
                e = sector[446 + 16 * i:462 + 16 * i]
                start, size = struct.unpack("<II", e[8:16])
                if e[4]:
                    out.append((e[4], start, size))
            return out

        mbr = entries(self.read(0))
        if mbr is None:
            sys.exit("No 55 AA signature in sector 0: not a partitioned disk image")
        logical = []
        for ptype, start, size in mbr:
            if ptype in FAT_TYPES:
                found.append((ptype, start, size))
            elif ptype in EXTENDED:
                ebr_lba = start
                while True:
                    ebr = entries(self.read(ebr_lba))
                    if not ebr:
                        break
                    nxt = None
                    for t, s, n in ebr:
                        if t in FAT_TYPES:
                            logical.append((t, ebr_lba + s, n))
                        elif t in EXTENDED:
                            nxt = start + s
                    if nxt is None:
                        break
                    ebr_lba = nxt
        return found + logical


class Fat16:
    def __init__(self, img, lba):
        self.img = img
        self.lba = lba
        bs = img.read(lba)
        self.bps, self.spc, self.reserved, self.nfats, self.rootents = \
            struct.unpack("<HBHBH", bs[11:19])
        self.spf = struct.unpack("<H", bs[22:24])[0]
        self.label = bs[43:54].decode("ascii", "replace").strip()
        if self.bps != SECTOR:
            sys.exit("Unexpected sector size %d" % self.bps)
        self.fat = img.read(lba + self.reserved, self.spf)
        self.root = lba + self.reserved + self.nfats * self.spf
        self.data = self.root + (self.rootents * 32 + SECTOR - 1) // SECTOR

    def chain(self, cluster):
        out = []
        while 2 <= cluster < 0xFFF8 and len(out) < 65536:
            out.append(cluster)
            cluster = struct.unpack("<H", self.fat[2 * cluster:2 * cluster + 2])[0]
        return out

    def cluster_data(self, clusters):
        return b"".join(self.img.read(self.data + (c - 2) * self.spc, self.spc) for c in clusters)

    def entries(self, raw):
        out = {}
        for i in range(0, len(raw), 32):
            e = raw[i:i + 32]
            if e[0] == 0:
                break
            if e[0] == 0xE5 or e[11] == 0x0F or e[11] & 0x08:
                continue
            name = e[0:8].decode("ascii", "replace").rstrip()
            ext = e[8:11].decode("ascii", "replace").rstrip()
            full = name + ("." + ext if ext else "")
            out[full] = (e[11], struct.unpack("<H", e[26:28])[0], struct.unpack("<I", e[28:32])[0])
        return out

    def listdir(self, path=""):
        raw = self.img.read(self.root, (self.rootents * 32) // SECTOR)
        for part in [p for p in path.split("\\") if p]:
            ents = self.entries(raw)
            if part not in ents or not ents[part][0] & 0x10:
                return None
            raw = self.cluster_data(self.chain(ents[part][1]))
        return self.entries(raw)

    def readfile(self, path):
        parts = [p for p in path.split("\\") if p]
        ents = self.listdir("\\".join(parts[:-1]))
        if ents is None or parts[-1] not in ents:
            return None
        attr, cluster, size = ents[parts[-1]]
        return self.cluster_data(self.chain(cluster))[:size]


def pattern_damage(data):
    """For a P1.BIN copy: first bad offset and the apparent shift."""
    def word(o):
        return struct.unpack("<I", data[o:o + 4])[0] if 0 <= o <= len(data) - 4 else None

    for off in range(0, len(data) - 3, 4):
        if word(off) != off:
            # The damage may have destroyed the word at the first bad offset,
            # so look for the next few expected words nearby
            for k in range(1, 9):
                target = off + 4 * k
                for shift in range(-64, 65):
                    if word(target + shift) == target:
                        return off, shift
            return off, None
    return None, None


def check(image, sumsfile):
    sums = {}
    for line in open(sumsfile):
        h, name = line.split()
        sums[name] = h

    img = Image(image)
    parts = img.partitions()
    drives = {}
    print("Partitions:")
    for letter, (ptype, start, size) in zip("CDEFG", parts):
        fs = Fat16(img, start)
        drives[letter] = fs
        print("  %s: type %02X, sector %d, %.1f MB, label %s" %
              (letter, ptype, start, size * SECTOR / 1048576, fs.label))
    if "D" not in drives:
        sys.exit("No D: partition found")
    C, D = drives["C"], drives["D"]

    print("\nFiles (expected checksums from %s):" % sumsfile)
    problems = 0
    checks = [("D", "T1.BIN", "T1.BIN"), ("D", "T2.BIN", "T2.BIN"), ("D", "P1.BIN", "P1.BIN"),
              ("C", "DNTEST\\T1.BIN", "T1.BIN"), ("C", "DNTEST\\T2.BIN", "T2.BIN"),
              ("C", "DNTEST\\P1.BIN", "P1.BIN"),
              ("D", "R1.BIN", "T1.BIN"), ("D", "R2.BIN", "T2.BIN"), ("D", "RP1.BIN", "P1.BIN")]
    for drive, path, original in checks:
        data = drives[drive].readfile(path)
        where = "%s:\\%s" % (drive, path)
        if data is None:
            print("  %-18s not found" % where)
            problems += 1
            continue
        ok = hashlib.sha256(data).hexdigest() == sums[original]
        print("  %-18s %8d bytes  %s" % (where, len(data), "OK" if ok else "DIFFERENT from " + original))
        if not ok:
            problems += 1
            if original == "P1.BIN":
                off, shift = pattern_damage(data)
                if off is not None:
                    print("      first wrong word at offset %d (0x%X), sector %d of the file;" %
                          (off, off, off // SECTOR), end=" ")
                    print("data shifted by %+d bytes" % shift if shift is not None else "no shift found nearby")

    log = D.readfile("FCLOG.TXT")
    print("\nD:\\FCLOG.TXT:")
    if log is None:
        print("  not found (has TEST.BAT been run?)")
        problems += 1
    else:
        lines = [l.strip() for l in log.decode("ascii", "replace").splitlines() if l.strip()]
        same = sum(1 for l in lines if l == "1")
        differ = [lines[i - 1] for i, l in enumerate(lines) if l == "0" and i > 0]
        print("  %d comparisons identical, %d different" % (same, len(differ)))
        for d in differ:
            print("    different:", d)
        problems += len(differ)
        if not lines or lines[-1] != "Done":
            print("  the log doesn't end with 'Done': the test didn't finish")
            problems += 1

    print("\nResult:", "all files and comparisons correct" if problems == 0
          else "%d problem(s), see above" % problems)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "files":
        make_files(sys.argv[2])
    elif len(sys.argv) == 4 and sys.argv[1] == "check":
        check(sys.argv[2], sys.argv[3])
    else:
        sys.exit(__doc__)
