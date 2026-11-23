#!/usr/bin/env python3
"""
Builds a small SD card image for soc_t.v: a 600 MB card with a
partition table, a FAT32 filesystem with 4 KB clusters, and disk0.img (1 MB
of random data) in its root directory, as $readmemh bytes for
sdcard_model.v. The image is in 4 runs of clusters, with a cluster of other
data between them, as a Mac leaves an image copied onto a fresh card: the
firmware has to follow them (fat.c), and a block mapped wrongly reads junk.
The runs start at drive blocks 0 and SPLITS, which some of difnif72_t.v's
transfers cross. Only the blocks in use are
written; the card model reports CARD_BLOCKS and reads the rest as 0.

  mksdimg.py OUT.hex [exfat]      (exFAT: not yet)

Prints the defines soc_t.v needs: the image's first block and its size.

This file is part of a fork of DifNif; CERN-OHL-S-2.0.
"""
import os, random, struct, sys

CARD_BLOCKS = 1228800         # 600 MB
PART = 2048
IMG_CLUSTERS = 256            # 1 MB with 4 KB clusters
SPLITS = (304, 320, 408)      # drive blocks where a new run starts (cluster multiples)
random.seed(1)

blocks = {}                   # block number -> 512 bytes

def put(lba, data):
    blocks[lba] = data.ljust(512, b'\0')

# Partition table: one FAT32 (LBA) partition
total = CARD_BLOCKS - PART
mbr = bytearray(512)
mbr[446:462] = struct.pack('<BBBBBBBBII', 0, 0, 2, 0, 0x0C, 0, 0, 0, PART, total)
mbr[510:512] = b'\x55\xaa'
put(0, bytes(mbr))

# FAT32 with 4 KB clusters: enough of them to be FAT32
RSVD, NFATS, SPC = 32, 2, 8
fatsz = 1
while True:
    clusters = (total - RSVD - NFATS * fatsz) // SPC
    need = ((clusters + 2) * 4 + 511) // 512
    if need <= fatsz:
        break
    fatsz = need
assert clusters >= 65525
vbr = bytearray(512)
vbr[0:3] = b'\xEB\x58\x90'
vbr[3:11] = b'MSDOS5.0'
struct.pack_into('<HBHBHHBHHHII', vbr, 11, 512, SPC, RSVD, NFATS, 0, 0, 0xF8, 0, 63, 255, PART, total)
struct.pack_into('<IHHIHH', vbr, 36, fatsz, 0, 0, 2, 1, 6)
vbr[64] = 0x80
vbr[66] = 0x29
vbr[67:71] = b'\x12\x34\x56\x78'
vbr[71:82] = b'DIFNIF     '
vbr[82:90] = b'FAT32   '
vbr[510:512] = b'\x55\xaa'
put(PART, bytes(vbr))
fsinfo = bytearray(512)
struct.pack_into('<I', fsinfo, 0, 0x41615252)
struct.pack_into('<III', fsinfo, 484, 0x61417272, 0xFFFFFFFF, 0xFFFFFFFF)
fsinfo[510:512] = b'\x55\xaa'
put(PART + 1, bytes(fsinfo))

fat_lba = PART + RSVD
heap = fat_lba + NFATS * fatsz
def clus_lba(c):
    return heap + (c - 2) * SPC

# FAT: root directory in cluster 2, disk0.img from cluster 3, with one
# cluster of something else before each of its runs after the first
first = 3
img_clus = []                 # card cluster of each of the image's clusters
c = first
for k in range(IMG_CLUSTERS):
    if k * SPC in SPLITS:
        c += 1                # skip a cluster: another file's
    img_clus.append(c)
    c += 1
gaps = [c for c in range(first, img_clus[-1]) if c not in img_clus]
fat = [0x0FFFFFF8, 0x0FFFFFFF, 0x0FFFFFFF] + [0] * (img_clus[-1] + 1 - 3)
for k, c in enumerate(img_clus):
    fat[c] = img_clus[k + 1] if k + 1 < IMG_CLUSTERS else 0x0FFFFFFF
for c in gaps:
    fat[c] = 0x0FFFFFFF       # a one-cluster file of its own
fatbytes = b''.join(struct.pack('<I', e) for e in fat)
for copy in range(NFATS):
    for i in range(0, len(fatbytes), 512):
        put(fat_lba + copy * fatsz + i // 512, fatbytes[i:i + 512])

# Root directory: a volume label, a deleted entry, another file, disk0.img
def dirent(name, attr, clus, size, deleted=False):
    e = bytearray(32)
    e[0:11] = name
    if deleted:
        e[0] = 0xE5
    e[11] = attr
    struct.pack_into('<H', e, 20, clus >> 16)
    struct.pack_into('<H', e, 26, clus & 0xFFFF)
    struct.pack_into('<I', e, 28, size)
    return bytes(e)
root = (dirent(b'DIFNIF     ', 0x08, 0, 0) +
        dirent(b'DISK0   IMG', 0x20, 0, 0, deleted=True) +
        dirent(b'README  TXT', 0x20, 0, 0) +
        dirent(b'DISK0   IMG', 0x20, first, IMG_CLUSTERS * 512 * SPC))
put(clus_lba(2), root)

img_lba = clus_lba(first)
for k, c in enumerate(img_clus):
    for b in range(SPC):
        put(clus_lba(c) + b, bytes(random.getrandbits(8) for _ in range(512)))
for c in gaps:                # junk the firmware mustn't hand over
    for b in range(SPC):
        put(clus_lba(c) + b, bytes([0xA5, c & 0xFF]) * 256)

with open(sys.argv[1], 'w') as f:
    for lba in sorted(blocks):
        f.write('@%x\n' % (lba * 512))
        f.write('\n'.join('%02x' % x for x in blocks[lba]))
        f.write('\n')
# IMG_GAP and IMG_S1-3: difnif72_t.v's img_blk() maps a drive block the same way
print('-DIMG_LBA=%d -DIMG_BLOCKS=%d -DMEM_BLOCKS=%d -DCARD_BLOCKS=%d -DIMG_GAP=%d '
      '-DIMG_S1=%d -DIMG_S2=%d -DIMG_S3=%d' %
      (img_lba, IMG_CLUSTERS * SPC, max(blocks) + 1, CARD_BLOCKS, SPC, *SPLITS))
