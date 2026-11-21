// DifNif FPGA-only firmware (work in progress): bring-up
//
// Starts the SD card, finds disk0.img, and reads the image's first block,
// logging each step on the serial port (1 Mbaud). It only reads the card.
// The ESDI command handling (difnift.ino's) comes next.
//
// This file is part of a fork of DifNif; CERN-OHL-S-2.0.

#include "fw.h"

static void stop(int led)
{
    for (;;) {
        LEDS = led;
        uint32_t t = MICROS;
        while (MICROS - t < 250000) {
        }
        LEDS = 0;
        t = MICROS;
        while (MICROS - t < 250000) {
        }
    }
}

int main(void)
{
    int e;

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
        stop(1);
    }
    puts_(sd_high_capacity ? "SD card ready (high capacity)\n" : "SD card ready\n");

    e = find_image();
    if (e) {
        logline("disk0.img not usable, reason ", e);
        stop(2);
    }

    e = sd_read_cpu(img_lba);
    if (e) {
        logline("reading the image failed, status ", sd_status);
        stop(3);
    }
    puts_("image block 0:");
    for (int i = 0; i < 16; i++) {
        putch(' ');
        puthex(cbuf_byte(i), 2);
    }
    putch('\n');
    puts_("bring-up done\n");
    LEDS = 3;
    for (;;) {
    }
}
