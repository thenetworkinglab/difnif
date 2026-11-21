#!/usr/bin/env python3
# Firmware binary to $readmemh words for soc.v's RAM, padded to its size.
# This file is part of a fork of DifNif; CERN-OHL-S-2.0.
import struct, sys
data = open(sys.argv[1], 'rb').read()
words = int(sys.argv[3])
if len(data) > words * 4:
    sys.exit("firmware is %d bytes, more than the %d of RAM" % (len(data), words * 4))
data += b'\0' * (words * 4 - len(data))
with open(sys.argv[2], 'w') as f:
    for i in range(words):
        f.write('%08x\n' % struct.unpack_from('<I', data, 4 * i))
