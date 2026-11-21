// DifNif FPGA-only firmware (work in progress)
//
// Starts the SD card, finds disk0.img, then runs the drive (esdi.c). The
// log is on the serial port at 1 Mbaud. If the card or the image isn't
// usable it still answers the PS/2, as a drive with no disk, with LED 0
// (card) or LED 1 (image) on.
//
// This file is part of a fork of DifNif; CERN-OHL-S-2.0.

#include "fw.h"

int main(void)
{
    int e;
    uint32_t blocks = 0;

    puts_("\nDifNif FPGA-only firmware " FW_VERSION ", FPGA v");
    puthex(MBOX(MB_VER_YEAR), 4);
    putch('.');
    puthex(MBOX(MB_VER_DATE) >> 8, 2);
    putch('.');
    puthex(MBOX(MB_VER_DATE) & 0xFF, 2);
    putch('-');
    putdec(MBOX(MB_VER_COUNT));
    putch('\n');

    e = sd_init();
    if (e) {
        logline("SD card start-up failed at step ", e);
        logline("  status ", sd_status);
        LEDS = 1;
    } else {
        puts_(sd_high_capacity ? "SD card ready (high capacity)\n" : "SD card ready\n");
        e = find_image();
        if (e) {
            logline("disk0.img not usable, reason ", e);
            LEDS = 2;
        } else {
            blocks = img_blocks;
            LEDS = 3;
        }
    }
    esdi_run(blocks);
}
