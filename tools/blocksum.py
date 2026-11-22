#!/usr/bin/env python3
"""Expected checksums for the FPGA-only firmware's trace.

With the trace on, the firmware logs a line after each disk transfer:

    C4601 0004 00000229 @02B3B35E
     D card 1234ABCD host 1234ABCD words 0400/0400

"card" and "host" are Fletcher sums of the 16-bit words on each side of the
sector buffer (A = sum of words, B = sum of the running A's; B << 16 | A).
This works them out from the drive image, for every read in a log, and says
which match. A read where both sides agree with each other but not with the
image went wrong before the sector buffer (or the image has changed since);
one where host differs from card went wrong between the buffer and the PS/2.

Usage: blocksum.py disk0.img LOG       (check every read in a saved log)
       blocksum.py disk0.img RBA [N]   (one transfer, RBA in hex)

Give it the image as it was before the session (a copy taken first, if the
PS/2 has written since). A read of exactly the blocks of an earlier write in
the log is checked against that write; a read overlapping one any other way
can't be checked and says so. The image is opened read-only.

This file is part of a fork of DifNif; CERN-OHL-S-2.0.
"""

import re
import sys


def fletcher(data):
    a = b = 0
    for i in range(0, len(data), 2):
        a = (a + (data[i] | (data[i + 1] << 8))) & 0xFFFF
        b = (b + a) & 0xFFFF
    return (b << 16) | a


def blocks(img, rba, n):
    img.seek(rba * 512)
    d = img.read(n * 512)
    return d + bytes(n * 512 - len(d))


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    img = open(sys.argv[1], "rb")
    arg = sys.argv[2]
    if re.fullmatch(r"[0-9A-Fa-f]+", arg):
        n = int(sys.argv[3], 16) if len(sys.argv) > 3 else 1
        print("%08X" % fletcher(blocks(img, int(arg, 16), n)))
        return
    cmd = None
    good = bad = unk = 0
    written = {}                          # (rba, n) -> the write's card sum
    for line in open(arg, errors="replace"):
        m = re.match(r"\s*C(46[0-9A-F]{2}) ([0-9A-F]{4}) ([0-9A-F]{8})", line)
        if m:
            cmd = (m.group(1), int(m.group(2), 16), int(m.group(3), 16))
            continue
        m = re.match(r"\s*D card ([0-9A-F]{8}) host ([0-9A-F]{8}) words ([0-9A-F]{4})/([0-9A-F]{4})", line)
        if m and cmd:
            op, n, rba = cmd
            card, host = int(m.group(1), 16), int(m.group(2), 16)
            if op[2:] == "01":            # read data
                overlap = [w for w in written if w[0] < rba + n and rba < w[0] + w[1]]
                if (rba, n) in written:
                    want = written[(rba, n)]
                elif overlap:
                    print("?   read  %08X x%-3X written earlier in this log, can't check; card %08X host %08X%s"
                          % (rba, n, card, host, "" if card == host else "  host differs from card"))
                    unk += 1
                    cmd = None
                    continue
                else:
                    want = fletcher(blocks(img, rba, n))
                ok = card == host == want
                where = ("" if ok else
                         "  card side differs from the image" if card != want and card == host else
                         "  host differs from card" if card == want else
                         "  both differ")
                print("%s read  %08X x%-3X want %08X card %08X host %08X words %s/%s%s"
                      % ("ok " if ok else "BAD", rba, n, want, card, host,
                         m.group(3), m.group(4), where))
                good += ok
                bad += not ok
            else:
                for w in [w for w in written if w[0] < rba + n and rba < w[0] + w[1]]:
                    del written[w]
                written[(rba, n)] = card
                ok = card == host
                print("%s write %08X x%-3X card %08X host %08X words %s/%s"
                      % ("ok " if ok else "BAD", rba, n, card, host, m.group(3), m.group(4)))
            cmd = None
    print("%d reads match, %d don't, %d can't be checked" % (good, bad, unk))


if __name__ == "__main__":
    main()
