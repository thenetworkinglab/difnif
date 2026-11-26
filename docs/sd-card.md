# The SD card

How to put a disk image on the card, and what the serial log's start-up
messages mean when the board can't use it. The commands are for macOS; the
same steps work on other systems with their own tools.

## What the card needs

- **FAT32 or exFAT**, on the whole card or in its first partition (an MBR
  partition table). FAT12 and FAT16 aren't supported: macOS's Disk Utility
  picks FAT16 for "MS-DOS (FAT)" on small cards, so ask for FAT32 by name.
- **512-byte sectors**, which is what every SD card has.
- **`disk0.img` in the root directory:** a whole number of megabytes, up to
  1023 MB (the most a DBA-ESDI drive can address).
- **In 32 pieces or fewer** (the FPGA-only build). An image copied onto a
  freshly erased card is in one piece. One copied over an older image, or
  onto a card that has had files added and deleted, can be in many.

## Putting an image on a card

Erase the card and make the image the first file written to it, so it goes
on in one piece. Erasing removes everything on the card, so copy off
anything you want to keep first.

1. Find the card's disk number: the entry that is "external, physical" and
   the size of the card.

       diskutil list

2. Erase it as FAT32, naming the volume `DIFNIF`. Replace `diskN` with the
   card's disk: check it twice, as erasing the wrong disk loses everything
   on it.

       diskutil eraseDisk FAT32 DIFNIF MBRFormat /dev/diskN

3. Copy the image on as `disk0.img`. `-X` leaves out macOS's extended
   attributes, which would otherwise be written as a second file,
   `._disk0.img`, beside it.

       cp -X ~/path/to/IMAGE.img /Volumes/DIFNIF/disk0.img

   Or, for a new blank drive (here 120 MB), write it straight onto the
   card:

       dd if=/dev/zero of=/Volumes/DIFNIF/disk0.img bs=1048576 count=120

4. Finish writing and eject before taking the card out:

       sync && diskutil eject /dev/diskN

The first start with a new drive gives error 165 (configuration changed):
run the Reference Diskette's automatic configuration, then format or install
as on a new drive.

## Backing up an image

Shut the PS/2's operating system down properly before switching off (so its
last writes reach the card), then copy the image off:

    cp -X /Volumes/DIFNIF/disk0.img ~/path/to/BACKUP.img

To change images, follow "Putting an image on a card" again instead of
copying the new image over the old one: an overwrite can leave the file in
more pieces than the firmware can follow.

## When the board can't use the card

The FPGA-only build reports what it found on its serial log at start-up
(README, "Making a board", step 6; any key prints it again). If the card or
the image can't be used, the board still answers the PS/2, as a drive with
no disk, and lights LED 0 (the card) or LED 1 (the image).

### `disk0.img not usable, reason N`

| Reason | Meaning | What to do |
|---|---|---|
| 1 | A read from the card failed | Reseat the card; try another card |
| 2 | Block 0 isn't a boot sector or partition table: the card isn't formatted | Erase it (above) |
| 3 | The first partition isn't FAT32 or exFAT (or there's no filesystem at its start) | Erase it as FAT32 (above) |
| 4 | Sectors aren't 512 bytes | Erase it (above) |
| 5 | The card is FAT12 or FAT16 | Erase it as FAT32 (above) |
| 6 | No `disk0.img` in the root directory (or a read failed while looking) | Check the name (`DISK0.IMG` is the same) and that it isn't in a folder; exFAT images of 4 GB or more are skipped |
| 7 | The image's chain of clusters can't be followed: more than 32 pieces, a chain that doesn't match the file's size (an interrupted copy, or a card pulled before macOS finished writing), or a failed read | Erase the card and copy the image on again (above); if it happens again on a freshly erased card, suspect the card |

### `SD card start-up failed at step N`

| Step | Meaning | What to do |
|---|---|---|
| 1 | No card, or a very old (version 1, pre-SDHC) card that doesn't answer | Check the card is in; use an SDHC or SDXC card |
| 2-4 | The card didn't finish powering up within a second | Reseat the card; try another card |
| 5-12 | The card stopped answering while being set up (identification, selection, 4-bit bus, block size, status) | Reseat the card; try another card. The log's `status` line shows the controller's status at the step that failed |

## The Teensy build

The Teensy build reads the card with the Teensy's own SD library, from the
Teensy's slot, and doesn't print these reasons, but the card is prepared the
same way.
