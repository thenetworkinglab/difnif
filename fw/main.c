// DifNif FPGA-only firmware (work in progress)
//
// Starts the SD card, finds disk0.img, then runs the drive (esdi.c). The
// log is on the serial port at 1 Mbaud. If the card or the image isn't
// usable it still answers the PS/2, as a drive with no disk, with LED 0
// (card) or LED 1 (image) on.
//
// This file is part of a fork of DifNif; CERN-OHL-S-2.0.

#include "fw.h"

static int sd_err, img_err;

// The start-up summary: printed at start-up, and again whenever a byte
// arrives on the serial port (press Enter in the serial monitor)
void show_status(void)
{
    puts_("\nDifNif FPGA-only firmware " FW_VERSION ", FPGA v");
    puthex(MBOX(MB_VER_YEAR), 4);
    putch('.');
    puthex(MBOX(MB_VER_DATE) >> 8, 2);
    putch('.');
    puthex(MBOX(MB_VER_DATE) & 0xFF, 2);
    putch('-');
    putdec(MBOX(MB_VER_COUNT));
    putch('\n');
    {
        // As the BIOS set them (0 until POST has run: press Enter after boot)
        uint32_t p23 = MBOX(MB_POS23);
        puts_("POS 2 ");
        puthex(p23 & 0xFF, 2);
        puts_(", 3 ");
        puthex(p23 >> 8, 2);
        puts_(", 4 ");
        puthex(MBOX(MB_POS4), 2);
        putch('\n');
    }
    if (sd_err) {
        logline("SD card start-up failed at step ", sd_err);
        logline("  status ", sd_status);
    } else {
        puts_(sd_high_capacity ? "SD card ready (high capacity)\n" : "SD card ready\n");
        if (img_err) {
            logline("disk0.img not usable, reason ", img_err);
        } else {
            puts_(img_exfat ? "exFAT, " : "FAT32, ");
            logline("disk0.img at block ", img_lba);
            logline("blocks ", img_blocks);
        }
    }
}

// Starts the card and finds disk0.img; the image's blocks, or 0
static uint32_t start_card(void)
{
    uint32_t blocks = 0;

    img_err = 0;
    sd_err = sd_init();
    if (sd_err) {
        LEDS = 1;
    } else {
        img_err = find_image();
        if (img_err) {
            LEDS = 2;
        } else {
            blocks = img_blocks;
            LEDS = 3;
        }
    }
    return blocks;
}

// After the card stopped answering, or at a hard reset when it doesn't (it
// was taken out and put back while the board kept its power from USB)
uint32_t card_restart(void)
{
    uint32_t blocks;

    sd_stop(0);                        // sdhost's data engine, if it's waiting
    puts_("SD card not answering: starting it again\n");
    blocks = start_card();
    show_status();
    return blocks;
}

int main(void)
{
    uint32_t blocks = start_card();
    show_status();
    esdi_run(blocks);
}
