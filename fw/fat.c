// DifNif FPGA-only firmware: finding disk0.img on the card
//
// The card holds one FAT32 or exFAT filesystem, either on the whole card or
// in its first partition, with disk0.img in the root directory, as for the
// Teensy firmware. The image must be contiguous (one run of clusters), which
// it is when it's the first large file written to a freshly formatted card,
// as with dd. Then drive block N is card block img_lba + N, and nothing
// about the filesystem is needed again.
//
// This file is part of a fork of DifNif; CERN-OHL-S-2.0.

#include "fw.h"

uint32_t img_lba;
uint32_t img_blocks;

static uint32_t fat_lba;      // first block of the FAT
static uint32_t heap_lba;     // block of cluster 2
static uint32_t spc_shift;    // blocks per cluster, as a power of 2
static int      exfat;

static uint32_t clus_lba(uint32_t c)
{
    return heap_lba + ((c - 2) << spc_shift);
}

// The FAT entry for cluster c (both use 32-bit entries; FAT32's top 4 bits
// are reserved)
static uint32_t cached_fat = 0xFFFFFFFFu;
static int fat_entry(uint32_t c, uint32_t *next)
{
    uint32_t b = fat_lba + (c >> 7);
    if (b != cached_fat) {
        if (sd_read_cpu(b)) return 1;
        cached_fat = b;
    }
    *next = cbuf_u32((c & 127) * 4);
    if (!exfat) *next &= 0x0FFFFFFFu;
    return 0;
}

static int is_end(uint32_t c)
{
    return exfat ? c >= 0xFFFFFFF8u : c >= 0x0FFFFFF8u;
}

static int log2_(uint32_t v)
{
    int n = 0;
    while (v > 1) {
        v >>= 1;
        n++;
    }
    return n;
}

// Checks that clusters first .. first + n - 1 follow each other in the FAT
static int contiguous(uint32_t first, uint32_t n)
{
    uint32_t c = first, next;
    while (--n) {
        if (fat_entry(c, &next)) return 1;
        if (next != c + 1) return 1;
        c = next;
    }
    if (fat_entry(c, &next)) return 1;
    return !is_end(next);
}

static int lower(int ch)
{
    return (ch >= 'A' && ch <= 'Z') ? ch + 32 : ch;
}

// Searches the root directory, a cluster chain from root; on finding the
// image sets first and bytes, and whether the FAT says nothing (exFAT's
// NoFatChain: contiguous by definition)
static int search_root(uint32_t root, uint32_t *first, uint32_t *bytes, int *nochain)
{
    static const char name[] = "disk0.img";
    uint32_t c = root;
    int state = 0;        // exFAT: 1 after a file entry, 2 after its stream entry
    int namepos = 0, namelen = 0, match = 0;

    while (!is_end(c) && c >= 2) {
        for (uint32_t blk = 0; blk < (1u << spc_shift); blk++) {
            if (sd_read_cpu(clus_lba(c) + blk)) return 1;
            for (int e = 0; e < 512; e += 32) {
                int t = cbuf_byte(e);
                if (t == 0) return 2;                  // end of directory
                if (!exfat) {
                    if (t == 0xE5 || (cbuf_byte(e + 11) & 0x18)) continue;
                    match = 1;
                    for (int i = 0; i < 11; i++)
                        if (cbuf_byte(e + i) != "DISK0   IMG"[i]) match = 0;
                    if (match) {
                        *first = ((uint32_t)cbuf_u16(e + 20) << 16) | cbuf_u16(e + 26);
                        *bytes = cbuf_u32(e + 28);
                        *nochain = 0;
                        return 0;
                    }
                } else if (t == 0x85) {                // file
                    state = (cbuf_u16(e + 4) & 0x10) ? 0 : 1;   // not a directory
                } else if (t == 0xC0 && state == 1) {  // stream extension
                    *nochain = (cbuf_byte(e + 1) >> 1) & 1;
                    namelen = cbuf_byte(e + 3);
                    *first = cbuf_u32(e + 20);
                    *bytes = cbuf_u32(e + 24);
                    if (cbuf_u32(e + 28) != 0) state = 0;   // 4 GB or more
                    else state = 2;
                    namepos = 0;
                    match = (namelen == 9);
                } else if (t == 0xC1 && state == 2) {  // file name, 15 characters
                    for (int i = 0; i < 15 && namepos < namelen; i++, namepos++)
                        if (lower(cbuf_u16(e + 2 + 2 * i)) != name[namepos]) match = 0;
                    if (namepos >= namelen) {
                        if (match) return 0;
                        state = 0;
                    }
                } else {
                    state = 0;
                }
            }
        }
        if (fat_entry(c, &c)) return 1;
    }
    return 2;
}

// The block in the processor's buffer is a filesystem's first block (its
// name is at offset 3 for exFAT, 82 for FAT32, 54 for FAT12 and FAT16)
static int is_vbr(void)
{
    if (cbuf_byte(3) == 'E' && cbuf_byte(4) == 'X' && cbuf_byte(5) == 'F') return 1;
    if (cbuf_byte(82) == 'F' && cbuf_byte(83) == 'A' && cbuf_byte(84) == 'T') return 1;
    return cbuf_byte(54) == 'F' && cbuf_byte(55) == 'A' && cbuf_byte(56) == 'T';
}

int find_image(void)
{
    uint32_t part = 0, root, first, bytes;
    int nochain;

    // Sector 0: a filesystem on the whole card, or a partition table
    if (sd_read_cpu(0)) return 1;
    if (cbuf_u16(510) != 0xAA55) return 2;
    if (!is_vbr()) {
        part = cbuf_u32(446 + 8);                // first partition's start
        if (sd_read_cpu(part)) return 1;
        if (cbuf_u16(510) != 0xAA55 || !is_vbr()) return 3;
    }

    if (cbuf_byte(3) == 'E' && cbuf_byte(4) == 'X' && cbuf_byte(5) == 'F') {
        exfat = 1;
        if (cbuf_byte(108) != 9) return 4;       // 512-byte sectors only
        spc_shift = cbuf_byte(109);
        fat_lba = part + cbuf_u32(80);
        heap_lba = part + cbuf_u32(88);
        root = cbuf_u32(96);
    } else {
        exfat = 0;
        if (cbuf_u16(11) != 512) return 4;
        if (cbuf_u16(22) != 0) return 5;         // FAT12 or FAT16: not supported
        spc_shift = log2_(cbuf_byte(13));
        fat_lba = part + cbuf_u16(14);
        heap_lba = fat_lba + cbuf_byte(16) * cbuf_u32(36);
        root = cbuf_u32(44);
    }
    logline(exfat ? "exFAT at block " : "FAT32 at block ", part);

    if (search_root(root, &first, &bytes, &nochain)) return 6;
    img_lba = clus_lba(first);
    img_blocks = bytes >> 9;
    logline("disk0.img at block ", img_lba);
    logline("blocks ", img_blocks);
    if (!nochain) {
        uint32_t cbytes = 512u << spc_shift;
        if (contiguous(first, (bytes + cbytes - 1) >> (9 + spc_shift))) return 7;
    }
    return 0;
}
