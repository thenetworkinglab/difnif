#!/usr/bin/env python3
import fileinput
import re
import sys

signals = {}
signal_names = {}

dump_lines = []

while True:
    time = 0
    cmd_start_time = 0
    ic = 0
    last = ""
    last_cmd = 2

    line = sys.stdin.readline()
    if not line:
        break
    if not line.startswith('$comment data_end'):
        dump_lines.append(line)
        continue

    for line in dump_lines:
        if line.startswith('$'):
            if line.startswith('$var'):
                idx = 2
                if 'var wire' in line:
                    idx += 1
                if 'var reg' in line:
                    idx += 1
                toks = line.split()
                sig_num = int(toks[idx])

                sig_name = toks[idx+1]
                signal_names[sig_num] = sig_name
                signals[sig_name] = 0
#                sys.stderr.write(line)
#                sys.stderr.write(" %i, %s\n" % (sig_num, sig_name))
            elif line.startswith('$dumpvars'):
                print('$name busstate')
                print('#0')

            continue

        if line.startswith('#'):
            time = int(line[1:])
            continue

        state = int(line[0]) if line[0] not in 'zx' else 0
        sig_num = int(line[1:])
        sig_name = signal_names[sig_num]
        signals[sig_name] = state

        # Check for falling edge of cmd
        do_out = False
        if last_cmd and not signals['cmd_l']:
            cmd_start_time = time
            la_rd = signals['s1_r_l']
            la_wr = signals['s0_w_l']
            la_io = signals['m_io_l']
            s = ""
            if not la_io:
                s = "IO"
            if not la_wr:
                s += "WRITE"
            if not la_rd:
                s += "READ"
        # Check for rising edge of cmd
        if not last_cmd and signals['cmd_l']:
            # Emit data for both edges
            print('#%u %s' % (cmd_start_time, s))
            print('#%u' % (time))


        last_cmd = signals['cmd_l']

    print('$finish')
    sys.stdout.flush()
    dump_lines = []
