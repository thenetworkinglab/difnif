
// Compile with Borland C++ using the Large memory model

#include <alloc.h>
#include <bios.h>
#include <dos.h>
#include <mem.h>
#include <stdio.h>
#include <conio.h>
#include <time.h>

#ifdef __cplusplus
#define __CPPARGS ...
#else
#define __CPPARGS
#endif

#define HDD_BASE 0x3510
#define SIFR (HDD_BASE + 0x00) // Status interface register
#define CIFR (HDD_BASE + 0x00) // Command interface register
#define BSR (HDD_BASE + 0x02) // Basic status register
#define BCR (HDD_BASE + 0x02) // Basic command register
#define ISR (HDD_BASE + 0x03) // Interrupt status register
#define ATN (HDD_BASE + 0x03) // Attention register
#define DREG (HDD_BASE + 0x04) // Data register

// BCR definitions
#define RESET (1 << 7)
#define DMA_ENABLE (1 << 1)
#define INT_ENABLE (1 << 0)

// BSR definitions
#define INT_PEND (1 << 6)
#define CMD_IN_PROG (1 << 5)
#define BUSY (1 << 4)
#define CIR_FULL (1 << 2)
#define SIR_FULL (1 << 3)
#define TRANS_REQ (1 << 1)
#define INTERRUPT (1 << 0)

// ISR definitions
#define ISR_COMPLETED (0x1)
#define ISR_DATA_XFER_RDY (0xb)


// Command requests
#define CONTROLLER (0xe0)
#define DEVICE (0xe0)
#define DRIVE (0x00)
#define ATN_CMD (0x01)
#define ATN_EOI (0x02)
#define ATN_ABORT (0x03)
#define ATN_RESET (0x04)

// Commands
#define CMD_READ (0x01)
#define CMD_READVERIFY (0x03)
#define CMD_GETDIAGS (0x14)
#define CMD_RUNDIAGS (0x12)
#define CMD_GETCONFIGS (0x09)
#define CMD_WRITEBUFFER (0x10)
#define CMD_READBUFFER (0x11)
#define CMD_GETPOSINFO (0x0A)
#define CMD_SEEK (0x05)
#define CMD_GETMANUF (0x15)

// Programmable Interrupt Controller 2
#define PIC1_COMMAND 0x20
#define PIC2_COMMAND 0xA0
#define PIC1_MASK 0x21
#define PIC2_MASK 0xA1
#define PIC_EOI 0x20

// PS/2 DMA Controller
#define DMA_WRITE_EXT 0x18
#define DMA_EXEC_EXT 0x1A

#define DMA_EXT_MAR_WRITE 0x20
#define DMA_EXT_TC_WRITE 0x40
#define DMA_EXT_MODE 0x70
#define DMA_EXT_MASK_SET 0x90
#define DMA_EXT_MASK_RESET 0xA0

// 0100 0100 - read memory
// 0100 1100 - write memory
#define DMA_16READMEM (0x44)
#define DMA_16WRITEMEM (0x4c)

#define HIGH(val) ((val >> 8) & 0xFF)
#define LOW(val) (val & 0xFF)
#define UPPER(val) ((val >> 16) & 0xFF)
#define LINEAR_ADDRESS(val) (((unsigned long)FP_SEG(val) << 4) + (unsigned long)FP_OFF(val))
#define PAGE(val) (LINEAR_ADDRESS(val) >> 16)

// Other IO ports
#define KBPORTB 0x61
#define REFRESH_TOGGLE 0x10
#define REFRESH_BIT (inportb(KBPORTB) & REFRESH_TOGGLE)
#define DUMMY_WRITE (outportb(0x4F))
#define DEBUG_IO(val) outportb(0x4F, val)

// IRQ14
#define VECT (0x76)

// Menu system stuff
struct text_info curtextmode;
typedef struct {
	char name[64];
	void (*menufunc)();
	void *submenu;
} MENU_ITEM;

int oldbsr = 0;

unsigned char old_pic1_mask;
unsigned char old_pic2_mask;
void interrupt (*old_interrupt_handler)(__CPPARGS);

volatile char interrupt_detected = 0;
volatile char interrupt_detected2 = 0; // Flag used by status bar only
volatile int interrupt_isr_value = 0;

int dma_arb = 14; // Sane defaults
int dma_channel = 0;

#define DMA_DISABLED 0xff

unsigned int far *buffer_out;
unsigned int far *buffer_in;

#define MAX_BUFFER 65536

// IRQ14 handler
void interrupt interrupt_handler(__CPPARGS)
{
	_disable();
	if (inportb(BSR) & INTERRUPT) {
		interrupt_isr_value = inportb(ISR);
		interrupt_detected = 1;
		interrupt_detected2 = 1;
		outportb(PIC2_COMMAND, PIC_EOI); // IRQ14
		outportb(PIC1_COMMAND, PIC_EOI); // IRQ chain
		_enable();
	} else {
		old_interrupt_handler();
	}
}

// Install our IRQ14 handler
void install_handler()
{
	_disable();
	old_interrupt_handler = getvect(VECT);
	setvect(VECT, interrupt_handler);
	old_pic1_mask = inportb(PIC1_MASK);
	outportb(PIC1_MASK, old_pic1_mask & ~(1 << 2));
	old_pic2_mask = inportb(PIC2_MASK);
	outportb(PIC2_MASK, old_pic2_mask & ~(1 << 6)); // IRQ14
	_enable();
}

// Restore previous IRQ14 handler
void remove_handler()
{
	_disable();
	outportb(PIC2_MASK, old_pic2_mask);
	outportb(PIC1_MASK, old_pic1_mask);
	setvect(VECT, old_interrupt_handler);
	_enable();
}

unsigned int get_dma_channel(unsigned int arblevel)
{
	unsigned int far *ebda_loc;
	unsigned char far *ebda;
	int i;
	ebda_loc = (unsigned int far *)MK_FP(0x40, 0xe);
	ebda = (unsigned char far *)MK_FP(*ebda_loc, 0);
#if 0
	cprintf("EBDA location pointer: %4x:%4x\r\n", FP_SEG(ebda_loc), FP_OFF(ebda_loc));
	cprintf("EBDA pointer: %4x:%4x\r\n", FP_SEG(ebda), FP_OFF(ebda));

	for (i = 0; i < 16; i++) {
		cprintf("%2x ", ebda[0xd2 + i]);
	}
	cprintf("\r\n");
#endif
	return ebda[0xd2 + arblevel];
}

// Waits for the DMA transfer request bit
int trans_reqwait()
{
	unsigned int i, status;
	int a = 0;
	for (i = 0; i < 65535; i++) {
		while (a == REFRESH_BIT) {}
		a = REFRESH_BIT;
		if (inportb(BSR) & TRANS_REQ) {
			return 0;
		}
	}
	return 1;
}

// Uses PIO to read or write data from the drive. 16-bit word size.
int do_pio_transfer(unsigned int far *buffer, unsigned int length, int mode)
{
	unsigned int i;
	for (i = 0; i < length; i++) {
		if (trans_reqwait()) {
			cprintf("Timed out waiting for transfer request bit.\r\n");
			return 1; // Timed out
		}
		if (mode == DMA_16WRITEMEM) {
			buffer[i] = inport(DREG);
		} else {
			outport(DREG, buffer[i]);
		}
	}
	return 0;
}

int start_dma(unsigned int far *buffer, unsigned int length, int mode)
{
	unsigned long addr = LINEAR_ADDRESS(buffer);

	if (dma_channel == 0xff) {
		return 1;
	}

	_disable();
	// Mask off this DMA channel while we configure it
	outportb(DMA_WRITE_EXT, dma_channel | DMA_EXT_MASK_SET);
	outportb(DMA_WRITE_EXT, dma_channel | DMA_EXT_MAR_WRITE);

	// Memory address: this is linear memory address!
	outportb(DMA_EXEC_EXT, LOW(addr)); // LS byte
	outportb(DMA_EXEC_EXT, HIGH(addr));
	outportb(DMA_EXEC_EXT, UPPER(addr)); // MS byte

	// Transfer count
	outportb(DMA_WRITE_EXT, dma_channel | DMA_EXT_TC_WRITE);
	outportb(DMA_EXEC_EXT, LOW(length));
	outportb(DMA_EXEC_EXT, HIGH(length));

	// Mode
	// 4c = 16-bit transfer, write, data transfer, IO addr=0
	// 44 = 16-bit transfer, read, data transfer, IO addr=0
	outportb(DMA_WRITE_EXT, dma_channel | DMA_EXT_MODE);
	outportb(DMA_EXEC_EXT, mode);

	// Allow this DMA channel to operate
	outportb(DMA_WRITE_EXT, dma_channel | DMA_EXT_MASK_RESET);
	_enable();
	return 0;
}

int terminate_dma()
{
	if (dma_channel == 0xff) {
		return 1;
	}
	_disable();
	outportb(DMA_WRITE_EXT, dma_channel | DMA_EXT_MASK_SET); // Mask off the DMA channel
	outportb(BCR, 0x0); // Turn off DMA and interrupt enable
	_enable();
	return 0;
}

// Waits in 15us increments using refresh timer
void refreshwait(unsigned int t)
{
	int a = 0;
	unsigned int i;

	for (i = 0; i < t; i++) {
		while (a == REFRESH_BIT) {} // Wait for refresh to toggle
		a = REFRESH_BIT;
	}
}

// Waits for interrupt
int intwait(unsigned int seconds)
{
	unsigned int i, s;
	int a = 0;
	for (s = 0; s < seconds; s++) {
		for (i = 0; i < 65535; i++) {
			while (a == REFRESH_BIT) {
				if (inportb(BSR) & INTERRUPT) return 0;
			}
			a = REFRESH_BIT;	
		}
	}
	return 1;
}

// Waits for interrupt using IRQ14 handler
int irq14wait(unsigned int seconds)
{
	unsigned int i, s;
	int a = 0;
	_enable();
	DEBUG_IO(0xaa);
	for (s = 0; s < seconds; s++) {
		for (i = 0; i < 65535; i++) {
			while (a == REFRESH_BIT) {
				if (interrupt_detected) {
					DEBUG_IO(interrupt_detected);
					interrupt_detected = 0;
					return 0;
				}
			}
			a = REFRESH_BIT;
		}
	}
	return 1;
}


// Waits for busy bit to go away. Danger: clears interrupts!
int busywait()
{
	unsigned int i;
	int a = 0;
	for (i = 0; i < 65535; i++) {
		while (a == REFRESH_BIT) {
			_disable();
			if (!(inportb(BSR) & BUSY)) return 0;
			_enable();
		}
		a = REFRESH_BIT;
	}
	return 1; // Timed out
}


// Waits for the status interface register to fill up
int statuswait()
{
	unsigned int i, status;
	int a = 0;
	for (i = 0; i < 65535; i++) {
		while (a == REFRESH_BIT) {}
		a = REFRESH_BIT;
		if (inportb(BSR) & SIR_FULL) {
			return 0;
		}
	}
	return 1;
}

// Waits for command interface full bit to clear
int cmdwait()
{
	unsigned int i;
	int status, a = 0;
	for (i = 0; i < 65535; i++) {
		while (a == REFRESH_BIT) {
			status = inportb(BSR);
			if (!(status & CIR_FULL)) {
				return 0;
			}
			// If it isn't busy, something went wrong
			if (!(status & BUSY)) {
				cprintf("Busy bit not set after ATN.\r\n");
				return 2;
			}
		}
		a = REFRESH_BIT;
	}
	cprintf("Command interface full bit never cleared.\r\n");
	return 1;
}

// Sends ATN followed by command block
int send_command_block(unsigned int *block)
{
	int length, count;
	int status;

	outportb(BCR, INT_ENABLE); // Turn on device interrupt enable
	if (busywait()) {
		cprintf("Busy bit never cleared.\r\n");
		return 1;
	}
	outportb(ATN, (block[0] & CONTROLLER) | ATN_CMD);
	_enable();

	// Type field (15:14) is block length, either 2 or 4 words
	length = 2 + (block[0] >> 13);
	for (count = 0; count < length; count++) {
		if (cmdwait() != 0) {
			cprintf("Byte %d\r\n", count);
			return 1;
		}
		outport(CIFR, block[count]);
	}
	return 0;
}

// Retrieves the status block
int get_status_block(unsigned int *block)
{
	int count, length;

	if (statuswait()) {
		cprintf("Status word never filled.\r\n");
		return 1;
	}
	block[0] = inport(SIFR);
	length = block[0] >> 8;
	//cprintf("Status block length: %d\r\n", length);
	cprintf("%.4x ", block[0]);
	if (length > 7) {
		cprintf("Status block too long.\r\n");
		return 1;
	}
	for (count = 1; count < length; count++) {
		if (statuswait()) {
			cprintf("Timout waiting for status word.\r\n");
			return 1;
		}
		block[count] = inport(SIFR);
		cprintf("%.4x ", block[count]);
	}
	cprintf("\r\n");
	return 0;
}

// Handles the end of interrupt command
int handle_eoi(unsigned int *statusblock)
{
	unsigned int block[8];
	int isr = interrupt_isr_value; // Stored by IRQ14 handler
	if ((isr & 0x1f) == ISR_DATA_XFER_RDY) {
		return 0; // No EOI for Data Transfer Ready
	}

	// If there was some error, get the status block
	// BUG: typically this is already retrieved before this
	// function?
	if ((isr & 0x1f) != ISR_COMPLETED) {
		cprintf("Command ISR error: %d\r\n", isr);
		get_status_block(statusblock);
		return 1;
	}
	// EOI is for the controller or the drive, depending
	// on the value in the ISR.
	outportb(ATN, (CONTROLLER & isr) | ATN_EOI); // Send EOI
	return 0;
}

// Runs a basic command with no data transfer
int simple_drive_command(unsigned int *block, unsigned int *statusblock)
{
	if (send_command_block(block)) {
		goto failout;
	}
	if (irq14wait(5)) {
		cprintf("Timed out waiting for IRQ14.\r\n");
		goto failout;
	}
	if (get_status_block(statusblock)) {
		goto failout;
	}
	if (handle_eoi(statusblock)) {
		goto failout;
	}
	return 0;
failout:
	// FIXME: Not all IBM int13 functions fail this way--only some do.
	// Acknowledge whatever error interrupt happened
	outportb(ATN, ((inportb(ISR) & 0xE0) | ATN_EOI));
	return 1;
}

// Runs a command with data transfer involved
int dma_drive_command(unsigned int *block, unsigned int *statusblock, unsigned int far *buffer, unsigned int length, int mode)
{
	if (send_command_block(block)) {
		return 1;
	}
	if (irq14wait(5)) {
		cprintf("Timed out waiting for IRQ14.\r\n");
		return 1;
	}
	if (handle_eoi(statusblock)) {
		return 1;
	}
	if ((interrupt_isr_value & 0x1f) != ISR_DATA_XFER_RDY) {
		// TODO: Process a command error
		return 1;
	}
	if (dma_channel == DMA_DISABLED) {
		outportb(BCR, INT_ENABLE); // IRQ14 for end of transfer
		if (do_pio_transfer(buffer, length, mode)) {
			return 1;
		}
	} else {
		if (start_dma(buffer, length, mode)) {
			cprintf("DMA not working.\r\n");
			return 1;
		}
                interrupt_detected = 0; // Hack because somehow it is getting set without the IRQ getting called.
		outportb(BCR, INT_ENABLE | DMA_ENABLE); // Kick off the transfer!
	}
	if (irq14wait(5)) {
		cprintf("Timed out waiting for IRQ14 (data xfer).\r\n");
		terminate_dma();
		return 1;
	}
	if (handle_eoi(statusblock)) {
		terminate_dma();
		return 1;
	}
	terminate_dma();
	return 0;
}


const char *status_ids[] = {"Reserved",
	                    "Command completed successfully",
			    "Reserved",
			    "Command completed successfully with ECC applied",
			    "Reserved",
			    "Command completed successfully with retries",
			    "Format command partially completed (Status available)",
			    "Command completed successfully with ECC and retries",
			    "Command completed with warning",
			    "Aborted",
			    "Reset completed",
			    "Data transfer ready (no status block)",
			    "Command terminated with failure (Dev error avail)",
			    "DMA error. Retry entire command as recovery",
			    "Command block error",
			    "Attention error (illegal attention code)",
			    "Reserved"};

const char *cmderr_ids[] = {"No error",
	                    "Invalid parameter in command block",
			    "Reserved",
			    "Command not supported",
			    "Command aborted per request",
			    "Reserved",
			    "Command rejected. Attch diag failure",
			    "Format rejected. Prep format cmd req'd",
			    "Format error. Prim map not readable",
			    "Format error. Sec map not readable",
			    "Format error. Diagnose failure",
			    "Format warning. Sec map overflow",
			    "Reserved",
			    "Format error. Host checksum error",
			    "Reserved",
			    "Format warning. Push table overflow",
			    "Format warning. More pushes than allowed",
			    "Reserved",
			    "Format warning. Error during verify",
			    "Invalid device number for command",
			    "Reserved"};

const char *deverr_ids[] = {"No error",
	                    "Seek fault. (Device report)",
			    "Interface fault. Parity,Attn,CmdComplete",
			    "Block not found. ID not found",
			    "Block not found. AM not found",
			    "Data ECC error. Hard error",
			    "ID CRC error",
			    "RBA out of range",
			    "Reserved",
			    "Defective block",
			    "Reserved",
			    "Selection error",
			    "Reserved",
			    "Write fault",
			    "Read fault",
			    "No index or sector pulse",
			    "Device not ready",
			    "Seek error. (Attachment report)",
			    "Bad format",
			    "Volume overflow",
			    "No data AM found",
			    "Block not found. No ID AM/CRC error",
			    "Reserved",
			    "Reserved",
			    "No ID found on track (ID search)",
			    "Reserved"};

const char *poe_ids[] = {"No error",
	                 "Internal RAM failure",
			 "External RAM failure",
			 "ROM checksum error",
			 "HDC registers failure",
			 "HDC abort failure or initialize failure",
			 "HDC ECC correction logic failure",
			 "HDC buffer RAM failure",
			 "MPU and HDC timer failure",
			 "Spindle rotation failure",
			 "Servo initialization failure",
			 "Reserved",
			 "Reserved",
			 "Reserved",
			 "Reserved",
			 "Reserved",
			 "Host interface chip failure",
			 "Reserved"};

const char *tec_ids[] = {"No error",
	                 "Format error",
			 "Head select error",
			 "Read/write sector error",
			 "Primary map IDs not readable",
			 "ECC 16-bit detect/correct error",
			 "ECC 17-bit detection error",
			 "Soft seek error (wrong cylinder)",
			 "Hard seek error (wrong cylinder with retry)",
			 "Drive soft error count exceeded",
			 "Attachment diagnostics error",
			 "Reserved",
			 "Reserved",
			 "Read hard error (fail on test read verify)",
			 "Reserved"};

void print_cmd_stat_err(unsigned int *block)
{
	int temp;
	temp = block[1] >> 8;
	if (temp > 0x10) temp = 0x10; // All these are reserved.
	cprintf("  Command Status Code: %s. ", status_ids[temp]);
	temp = block[1] & 0xff;
	if (temp > 0x14) temp = 0x14; // Reserved
	cprintf(" Command Error Code: %s\r\n", cmderr_ids[temp]);
}

void print_dev_stat_err(unsigned int *block)
{
	int temp;
	cprintf("  Device status: ");
	if (block[2] & (1 << 8))  cprintf("SkCmdComplete "); // Seek or command complete
	if (block[2] & (1 << 9))  cprintf("Trk0 "); // Track 0 (emulated)
	if (block[2] & (1 << 10)) cprintf("WrtFault "); // Write fault
	if (block[2] & (1 << 11)) cprintf("Selct "); // Selected
	if (block[2] & (1 << 12)) cprintf("Rdy "); // Ready
	if (block[2] & (1 << 14)) cprintf("Stby "); // Standby
	// 60 chars

	temp = block[2] & 0xff;
	if (temp > 0x19) temp = 0x19;
	cprintf(". DevErr: %s\r\n", deverr_ids[temp]);
}

void print_poe_err(int code)
{
	if (code > 0x12) code = 0x12;
	cprintf("  Power on error code: %s. ", poe_ids[code]);
}

void print_status_block(unsigned int *block)
{
	int length, dev, cmd, temp;
	unsigned long templ;
	length = block[0] >> 8;
	dev = (block[0] >> 5) & 7;
	cmd = block[0] & 0x1F;

	if (length == 7 && cmd != CMD_GETDIAGS) {
		// Command complete status block
		cprintf("--Command complete status block--\r\n");
		print_cmd_stat_err(block);
		print_dev_stat_err(block);
		cprintf("  Number of blocks left to be executed: %u. ", block[3]);
		templ = block[4] | ((unsigned long)block[5] << 16);
		cprintf("Last RBA processed: %lu. ", templ);
		cprintf("Number of blocks required to recover error: %u.\r\n", block[6]);
	} else if (length == 7 && cmd == CMD_GETDIAGS) { 
		cprintf("--Diagnostic status block--\r\n");
		print_cmd_stat_err(block);
		print_dev_stat_err(block);
		print_poe_err(block[3] >> 8);
		temp = block[3] & 0xFF;
		if (temp > 0x0e) temp = 0x0e;
		cprintf("  Test error code: %s. ", tec_ids[temp]);
		cprintf(" Diagnostic command: %u\r\n", block[4]);
	} else if (length == 6 && cmd == CMD_GETCONFIGS && dev == 0) {
		cprintf("--Device configuration status block, drive--\r\n");
		cprintf("  Number of spare cylinders: %u. Flags: ", block[1] >> 8);
		if (block[1] & (1 << 4)) cprintf("Invalid secondary. ");
		if (block[1] & (1 << 3)) cprintf("Zero defect. ");
		if (block[1] & (1 << 2)) cprintf("Skewed format. ");
		if (block[1] & (1 << 0)) cprintf("Retries disabled. ");
		templ = block[2] | ((unsigned long)block[3] << 16);
		cprintf("\r\n  Number of RBAs: %lu. ", templ);
		cprintf("Number of cylinders: %u. ", block[4]);
		cprintf("Sectors per track: %u. ", block[5] >> 8);
		cprintf("Tracks per cylinder: %u.\r\n", block[5] & 0xff);
	} else if (length == 6 && cmd == CMD_GETCONFIGS && dev == 7) {
		cprintf("--Device Configuration status block, attachment--\r\n");
		templ = block[2] | ((unsigned long)(block[3] & 0xff) << 16);
		cprintf("  Microcode revision: %lu\r\n", templ);
		cprintf("  Buf_Size 1: %x\r\n", block[3] >> 8);
		cprintf("  Buf_Size 2: %x\r\n", block[4] >> 8);
	} else if (length == 3 && cmd == 8) {
		cprintf("--Device status block--\r\n");
		print_dev_stat_err(block);
	} else if (length == 1 && dev == 7) {
		cprintf("--RESET status block--\r\n");
		print_poe_err(cmd);
	}
}


// ** Drive Commands **

// Run diagnostics
int rundiags(unsigned int test, unsigned int device)
{
	unsigned int block[2], statusblock[8];
	int s;
	block[0] = CMD_RUNDIAGS | device | 0x600; // not drive
	block[1] = test;
	// FIXME: Some tests take a really long time. How to deal with this?
	s = simple_drive_command(block, statusblock);
	print_status_block(statusblock);
	return s;
}

// Get diagnostic status block
int getdiags()
{
	unsigned int block[2], statusblock[8];
	int s;
	block[0] = CMD_GETDIAGS | DRIVE | 0x600;
	block[1] = 0x0000;
	cprintf("Sending command: Get diagnostic status block.\r\n");
	s = simple_drive_command(block, statusblock);
	print_status_block(statusblock);
	return s;
}

// Get controller or drive configuration
int getconfigs(int dev)
{
	unsigned int block[2], statusblock[8];
	int s;
	block[0] = CMD_GETCONFIGS | (dev << 5) | 0x600;
	block[1] = 0x0000;
	cprintf("Attempting to get device configuration status block.\r\n");
	s = simple_drive_command(block, statusblock);
	print_status_block(statusblock);
	return s;
}

// Get buffer size of the controller, in 16-bit words
const unsigned int buf_size_table[] = {0x20, 0x01, 0x02, 0x04, 0x08, 0x10, 0x40, 0x80};
unsigned int getbuffersize()
{
	unsigned int block[2], statusblock[8];
	unsigned int buf_size1, buf_size2, buf_size;
	block[0] = CMD_GETCONFIGS | CONTROLLER | 0x600;
	block[1] = 0x0000;
	if (simple_drive_command(block, statusblock)) {
		return 0;
	}
	// Straight from page 56
	buf_size1 = statusblock[3] >> 8;
	buf_size2 = statusblock[4] >> 8;
	if (buf_size2 == 0) {
		buf_size = buf_size1;
	} else {
		buf_size = buf_size2;
	}
	cprintf("buf_size: %x. buf_size1: %x. buf_size2: %x\r\n", buf_size, buf_size1, buf_size2);
	// Range check
	if (buf_size < 0x30 || buf_size > 0x37) {
		return 0;
	}
	return buf_size_table[buf_size - 0x30] << 8;
}

// Gets the POS register contents using a command (pp 39, 62)
int getposinfo()
{
	unsigned int block[2], statusblock[8];
	unsigned int id;
	block[0] = CMD_GETPOSINFO | CONTROLLER | 0x600;
	block[1] = 0x0000;
	if (simple_drive_command(block, statusblock)) {
		return 0;
	}
	cprintf("POS ID: %4x\r\n", statusblock[1]);
	cprintf("POS2: %2x. POS3: %2x. POS4: %2x\r\n", HIGH(statusblock[2]), LOW(statusblock[2]), HIGH(statusblock[3]));
	return (HIGH(statusblock[2]) >> 2) & 0xF; // Return the arbitration level
}


// Seek
int doseek(unsigned long rba)
{
	unsigned int block[4], statusblock[8];
	int s;
	block[0] = CMD_SEEK | 0x200 | 0x4000;
	block[1] = 0x0;
	block[2] = rba & 0xFFFF;
	block[3] = rba >> 16;
	cprintf("Seeking.\r\n");
	s = simple_drive_command(block, statusblock);
	print_status_block(statusblock);
	return s;
}

// Update contents of top and bottom status bars
void do_statusbar()
{
	int bsr;
        int h = curtextmode.screenheight;
        int w = curtextmode.screenwidth;
	int oldx = wherex();
	int oldy = wherey();

        window(1, 1, w, 1);
	textattr(0x1f);
	clrscr();
	cprintf(" *** DBA-ESDI Diagnostics Program ***");
	cprintf("  DMA arb: %x, chan: %x ", dma_arb, dma_channel);
	if (dma_channel == DMA_DISABLED) {
		cprintf("(Using PIO)");
	}
	window(1, h, w, h);
	clrscr();

	// Display basic status register contents
	bsr = inportb(BSR);
	cprintf("BSR: %x ", bsr); // 8
	if (bsr & INT_PEND) {
		cprintf("Pend "); // 5
	}
	if (bsr & TRANS_REQ) {
		cprintf("TransRq "); // 8
	}
	if (bsr & CMD_IN_PROG) {
		cprintf("CmdInPrg "); // 9
	}
	if (bsr & BUSY) {
		cprintf("Busy "); // 5
	}
	if (bsr & SIR_FULL) {
		cprintf("StatAvl "); // 8
	}
	if (bsr & CIR_FULL) {
		cprintf("CmdFull "); // 8
	}
	if (bsr & INTERRUPT) {
		cprintf("Int "); // 4
	} // 55

	// Display interrupt_isr_value
	cprintf("| IntISR Dev%d Err%d ID%x", interrupt_isr_value >> 5,
			                        (interrupt_isr_value & 0x10) >> 4,
	                                        interrupt_isr_value & 0xF); // 23

        window(1, 2, w, h - 1);
        textattr(0x7);
	gotoxy(oldx, oldy);
}

long get_user_int(long min, long max)
{
        int oldx = wherex();
        int oldy = wherey();

	long v;
        char ent[32];
        ent[0] = 32;
        clreol();
        while (1) {
                cgets(ent);
                sscanf(&ent[2], "%lx", &v);
                if (v >= min && v <= max) break;
                gotoxy(oldx, oldy);
        }
        return v;
}

// Page 22 documents the reset process
void menu_dr_reset_on()
{
	outportb(BCR, RESET);
	cprintf("Drive in reset.\r\n");
	delay(100);
}

void menu_dr_reset_off()
{
	outportb(BCR, 0x00); // Take it out of reset
	cprintf("Drive taken out of reset.\r\n");
	cprintf("Wait for the interrupt flag to go high, then you can handle\r\n");
	cprintf("the pending interrupt and find out if it succeeded.\r\n");
}

// Descriptions from page 16
const char *int_ids[] = {"Reserved", 
	                 "Command completed successfully",
			 "Reserved",
	                 "Command completed successfully with ECC applied",
			 "Reserved",
			 "Command completed successfully with retries",
			 "Format command partially completed (Status available)",
			 "Command completed successfully with ECC and retries",
			 "Command completed with warning",
			 "Abort completed",
			 "Reset completed",
			 "Data transfer ready (No status block)",
			 "Command failed",
			 "DMA error",
			 "Command block error",
			 "Attention error"};

// Gets interrupt data from the IRQ14 handler, issues EOI if needed
void menu_handle_int()
{
	int status = interrupt_isr_value;
	if (!interrupt_detected) {
		cprintf("No interrupt detected. End.\r\n");
		return;
	}
	interrupt_detected = 0;

	cprintf("Interrupt code: %2x\r\n", status);
	cprintf("  Device select (7=controller): %x\r\n", status >> 5);
	cprintf("  Attachment error bit: %x\r\n", (status >> 4) & 1);
	cprintf("  Interrupt ID: %x\r\n", (status & 0xF));
	cprintf("    %s.\r\n", int_ids[status & 0xF]);

	if ((status & 0x1f) == ISR_DATA_XFER_RDY) {
		cprintf("Data transfer ready, no EOI.\r\n");
		return;
	}

	if ((status & 0x1f) != ISR_COMPLETED) {
		cprintf("Potential ISR error: %d\r\n", status);
		cprintf("There may be a status word waiting.\r\n");
		return;
	}

	// EOI the interrupt for either the drive or controller depending on the ISR.
	outportb(ATN, (CONTROLLER & status) | ATN_EOI); // Send end of interrupt cmd
	cprintf("End of interrupt command sent.\r\n");
}


void menu_get_status_block()
{
	unsigned int block[8] = {0};

	get_status_block(block);
	print_status_block(block);
	if (interrupt_isr_value != ISR_DATA_XFER_RDY) {
		cprintf("Reminder, you probably need to send EOI.\r\n");
	}
}

void menu_ll_diags()
{
	unsigned int block[2];
	int flag;
	cprintf("Enter 0 for drive or 1 for controller: ");
	flag = get_user_int(0, 1);
	cprintf("\r\n");

	block[0] = CMD_GETDIAGS | (flag ? CONTROLLER : DRIVE) | 0x600;
	block[1] = 0x0000;
	if (inportb(BSR) & BUSY) {
		cprintf("Warning: Drive is busy. Trying anyway but this will cause an error.\r\n");
	}
	cprintf("Sending command: Get diagnostic status block.\r\n");
	send_command_block(block);
}

void menu_ll_getconfigs()
{
	unsigned int block[2];
	int flag, device;
	cprintf("Enter 0 for physical or 1 for pseudo blocks: ");
	flag = get_user_int(0, 1);
	cprintf("\r\n");

	cprintf("Enter 0 for drive or 1 for controller: ");
	device = get_user_int(0, 1);
	cprintf("\r\n");
	block[0] = CMD_GETCONFIGS | (device ? CONTROLLER : DRIVE) | 0x600 | (flag ? 0x800 : 0x000);
	block[1] = 0x0000;
	if (inportb(BSR) & BUSY) {
		cprintf("Warning: Drive is busy. Trying anyway but this will cause an error.\r\n");
	}
	cprintf("Sending command: Get device configuration.\r\n");
	send_command_block(block);
}

void menu_ll_rundiags()
{
	unsigned int block[2];
	int flag, device;
	cprintf("Enter 0 for drive or 1 for controller: ");
	device = get_user_int(0, 1);
	cprintf("\r\n");
	cprintf("Enter diagnostic code from 0 to 8: ");
	flag = get_user_int(0, 8);
	cprintf("\r\n");

	block[0] = CMD_RUNDIAGS | (device ? CONTROLLER : DRIVE) | 0x600;
	block[1] = flag & 0xFF;
	if (inportb(BSR) & BUSY) {
		cprintf("Warning: Drive is busy. Trying anyway but this will cause an error.\r\n");
	}
	cprintf("Sending command: Get device configuration.\r\n");
	send_command_block(block);
}

void menu_ll_getmanuf()
{
	unsigned int block[2];
	block[0] = CMD_GETMANUF | DRIVE | 0x600;
	block[1] = 1; // get one block for now
	if (inportb(BSR) & BUSY) {
		cprintf("Warning: Drive is busy. Trying anyway but this will cause an error.\r\n");
	}
	cprintf("Sending command: Get device configuration.\r\n");
	send_command_block(block);
}

void menu_ll_read()
{
	unsigned int block[4];
	unsigned int numblocks, lowrba, highrba;
	cprintf("Number of blocks to read: ");
	numblocks = get_user_int(0, 0xffff);
	cprintf("\r\n");
	cprintf("Low RBA address: ");
	lowrba = get_user_int(0, 0xffff);
	cprintf("\r\n");
	cprintf("High RBA address: ");
	highrba = get_user_int(0, 0xffff);
	cprintf("\r\n");

	block[0] = CMD_READ | DRIVE | 0x200 | 0x4000;
	block[1] = numblocks;
	block[2] = lowrba;
	block[3] = highrba;
	if (inportb(BSR) & BUSY) {
		cprintf("Warning: Drive is busy. Trying anyway but this will cause an error.\r\n");
	}
	cprintf("Sending command: Get device configuration.\r\n");
	send_command_block(block);
}

void menu_ll_pos()
{
	getposinfo();
}

// Post-processes a reset operation.
void reset_post()
{
	unsigned int block[8];
	int status;
	// Wait for 5s for reset complete interrupt.
	// Real BIOS has a 60s timeout, but nobody has time for that.
	if (intwait(5)) {
		cprintf("Reset complete interrupt never fired.\r\n");
		block[0] = inport(SIFR);
		print_status_block(block);
		outportb(ATN, CONTROLLER | ATN_EOI);
		return;
	}
	status = inportb(ISR); // Get the interrupt code
	if (status != 0xea) {
		cprintf("Reset failed. Interrupt code: %2x\r\n", status);
	} else {
		cprintf("Reset successful.\r\n");
	}
	outportb(ATN, CONTROLLER | ATN_EOI); // Send end of interrupt cmd
	// The code below is not in the original BIOS reset command
	block[0] = inport(SIFR);
	print_status_block(block);
	return;
}

// Implement:
// writing 0x80 to 3512 puts the drive in hardware reset
// writing 0x00 to 3512 takes it back out of reset, drive then spins up.
// see page 22 for reset process.
//
void menu_hardreset()
{
	outportb(BCR, RESET);
	cprintf("Drive in reset.\r\n");
	refreshwait(16); // 240us
	outportb(BCR, 0x00); // Take it out of reset
	cprintf("Drive out of reset.\r\n");
	reset_post();
}

void menu_softreset()
{
	outportb(BCR, 0x0); // Turn off DMA and IRQ
	if (inportb(BSR) & BUSY) {
		cprintf("Busy bit is set, try a hard reset instead.\r\n");
	}
	outportb(ATN, CONTROLLER | ATN_RESET); // Send reset command
	reset_post();
}

void menu_controllerconfig()
{
	getconfigs(0x7); // controller device
}

void menu_driveconfig()
{
	getconfigs(0x0); // drive
}

// Taken from INT13 1C, subcommand 06. e000:6fde
void menu_selftest()
{
	rundiags(0x6, CONTROLLER); // Self test
	// Confirm word3 (low byte) = 0x1e.
}

void menu_rundiags()
{
	int num; 
	int device = CONTROLLER;
	cprintf("Available diagnostics:\r\n");
	cprintf("1. Turn retries off (soft errors return as hard errors)\r\n");
	cprintf("2. Turn retries on\r\n");
	cprintf("3. Test read/write on CE cylinder\r\n");
	cprintf("4. Test seek (for 30 seconds)\r\n");
	cprintf("5. Read verify of entire drive\r\n");
	cprintf("6. Self test (drive POST)\r\n");
	cprintf("7. Read Ahead off\r\n");
	cprintf("8. Read Ahead on\r\n");
	cprintf("Enter diagnostic (or 0 to exit menu): ");
	num = get_user_int(0, 8);
	if (num == 0) return;
	if (num >= 3 && num <= 5) device = DRIVE;
	cprintf("\r\n");
	rundiags(num, device);
	cprintf("Done.");
}

// Allocate a block of memory that doesn't cross a page boundary.
void far *farmalloc_page(unsigned long nbytes)
{
        void far *start;
        void far *temp = NULL;
        unsigned int page_offset;
        // Find out where the next available memory is being allocated.
        start = farmalloc(1);
        if (start == NULL) {
                return NULL;
        }
        page_offset = LINEAR_ADDRESS(start);
#if 0
        cprintf("farmalloc_page: requested length %ld\r\n", nbytes);
        cprintf("farmalloc_page: ptr %Fp\r\n", start);
        cprintf("farmalloc_page: page offset %X\r\n", page_offset);
#endif

        // If we wouldn't have enough room for the buffer in the current
        // page, allocate a temporary buffer to fill up that space, so
        // that our real buffer will start at the beginning of the next
        // page. 
        if ((unsigned long)page_offset + nbytes - 1 > 0xFFFF) {
                temp = farmalloc(0xFFFF - page_offset + 1);
                if (temp == NULL) {
                        cprintf("farmalloc_page: Could not allocate temp buffer\r\n");
                        cprintf("farmalloc_page: farcore left: %ld\r\n", farcoreleft());
                        farfree(start);
                        return NULL;
                }
        }

        // Don't need the temporary buffer anymore. 
        farfree(start);

        // Allocate the real buffer.
        start = farmalloc(nbytes);
        page_offset = LINEAR_ADDRESS(start);
        if (temp != NULL) {
                farfree(temp);
        }
        return start;
}

// Wrapper around BIOS call
unsigned char allocate_dma_channel(int arblevel)
{
	union REGS regs;

	regs.h.ah = 0xce; // Allocate DMA arbitration level
	regs.h.al = 0; // Need a hardware channel
	regs.h.bl = arblevel;
	int86(0x15, &regs, &regs);
	if (regs.h.ah == 0x00) {
		dma_channel = regs.h.al;
	}
	return regs.h.ah;
}

// Configures parameters for the DMA controller
void menu_setup_dma()
{
	unsigned char ret;
	union REGS regs;

	dma_arb = getposinfo();
	cprintf("DMA arbitration level: %d (from POS register)\r\n", dma_arb);
	// Check if the BIOS implements DMA allocation
	if (allocate_dma_channel(0xff) != 0x86) {
		// FIXME: this may be specific to later PS/2 BIOSes.
		dma_channel = get_dma_channel(dma_arb);
		cprintf("DMA channel: %x\r\n", dma_channel);
		if (dma_channel & 0x80) {
			// Channel already allocated, so just capture it.
			dma_channel &= 0x0F;
			cprintf("Using already allocated channel.\r\n");
		} else {
			cprintf("Allocating new DMA channel.\r\n");
			ret = allocate_dma_channel(dma_arb);
			if (ret != 0) {
				cprintf("Couldn't allocate DMA channel.\r\n Error code %x.\r\n", ret);
				dma_channel = DMA_DISABLED;
			}
		}
	} else {
		dma_channel = dma_arb;
		cprintf("Assigning DMA channel %x to arbitration level.\r\n", dma_channel);
	}
	do_statusbar();
}

void print_buffer(unsigned char far *buffer, int length)
{
	unsigned int i = 0;
	int linecount = 0;
	int j;

	while (length > 0) {
		cprintf("%.3x: ", i); // 16 bytes per line
		for (j = 0; j < 16; j++) {
			if (j < length) {
				cprintf("%.2x ", buffer[j]);
			} else {
				cprintf("   ");
			}
			if (j == 7) cprintf("  ");
		}
		cprintf(" ");
		for (j = 0; j < 16 && j < length; j++) {
			if (buffer[j] >= 0x07 && buffer[j] <= 0x0D) {
				cprintf(".");
			} else {
				cprintf("%c", buffer[j]);
			}
		}
		cprintf("\r\n");
		buffer += 16;
		length -= 16;
		i += 16;
		linecount++;
		if (linecount >= 22) {
			linecount = 0;
			cprintf("<more>");
			getch();
			cprintf("\r\n");
		}
	}
}

// Get manufacturing header
void menu_get_mfg_header()
{
	const unsigned int buf_size = 256;
	unsigned int block[4];
	unsigned int statusblock[8] = {0};
	unsigned int i, j;
	char sbuf[17];

	// Clear the buffer
	_fmemset(buffer_in, 0x0, buf_size * 2);

	block[0] = CMD_GETMANUF | 0x600;
	block[1] = 0x0001; // get one block

	if (dma_drive_command(block, statusblock, buffer_in, buf_size, DMA_16WRITEMEM)) {
		cprintf("DMA failed.\r\n");
		return;
	}

	// Dump manufacturing header
	_fmemcpy(sbuf, buffer_in, 6);
	sbuf[6] = 0;
	cputs(sbuf);
	cprintf(" - %d defects in the map.\r\n", buffer_in[3]);
	cprintf("Barcode:");
	_fmemcpy(sbuf, &buffer_in[5], 16);
	sbuf[16] = 0;
	cputs(sbuf);
	cprintf("\r\nDate of manufacture: ");
	_fmemcpy(sbuf, &buffer_in[13], 8);
	sbuf[8] = 0;
	cputs(sbuf);
	cprintf("\r\n");
	print_buffer((unsigned char far *)buffer_in, 80);
}

int buffer_compare(unsigned int far *buffer1, unsigned int far *buffer2, unsigned int length)
{
	unsigned int i;
	int failcount = 0;
	for (i = 0; i < length; i++) {
		if (buffer1[i] != buffer2[i]) {
			cprintf("Failed at %x. Was %x, should be %x.\r\n", i, buffer2[i], buffer1[i]);
			failcount++;
			if (failcount > 4) break;
		}
	}
	return failcount > 0;
}

void buffer_fill(unsigned int far *buffer, unsigned int buf_size, unsigned int pattern, int countup)
{
	unsigned int i;
	unsigned char a = 1;
	if (countup) {
		for (i = 0; i < buf_size; i++) {
			buffer[i] = (a++) | ((a++) << 8);
			if (a == 0) a = 1;
		}
	} else {
		for (i = 0; i < buf_size; i++) {
			buffer[i] = pattern;
		}
	}
}

int buffer_memtest(unsigned int buf_size)
{
	unsigned int block[2];
	unsigned int statusblock[8] = {0};
	unsigned int i;
	// Divide by 256 to get number of blocks
	unsigned int block_size = buf_size >> 8;

	block[0] = CMD_WRITEBUFFER | CONTROLLER | 0x0600; // Write attachment buffer test
	block[1] = block_size; // Max is 64

	if (dma_drive_command(block, statusblock, buffer_out, buf_size, DMA_16READMEM)) {
		cprintf("Transfer out failed.\r\n");
		return 1;
	}

	block[0] = CMD_READBUFFER | CONTROLLER | 0x0600; // Read attachment buffer test
	block[1] = buf_size >> 8;

	if (dma_drive_command(block, statusblock, buffer_in, buf_size, DMA_16WRITEMEM)) {
		cprintf("Transfer in failed.\r\n");
		return 1;
	}
	// Now compare the buffers
	if (buffer_compare(buffer_out, buffer_in, buf_size) == 0) {
		cprintf("OK\r\n");
		return 0;
	}
	cprintf("Failed\r\n");
	return 1;
}
// Tests the controller's onboard buffer
void menu_buffertest()
{
	unsigned int buf_size;
	unsigned int i, j;

	buf_size = getbuffersize(); // How big is the controller's buffer?
	
	cprintf("Buffer size needed: 0x%x bytes\r\n", buf_size * 2);

	cprintf("55aa test. ");
	buffer_fill(buffer_out, buf_size, 0xaa55, 0);
	if (buffer_memtest(buf_size)) return;

	cprintf("aa55 test. ");
	buffer_fill(buffer_out, buf_size, 0x55aa, 0);
	if (buffer_memtest(buf_size)) return;

	cprintf("ff00 test. ");
	buffer_fill(buffer_out, buf_size, 0xff00, 0);
	if (buffer_memtest(buf_size)) return;

	cprintf("00ff test. ");
	buffer_fill(buffer_out, buf_size, 0x00ff, 0);
	if (buffer_memtest(buf_size)) return;

	cprintf("ffff test. ");
	buffer_fill(buffer_out, buf_size, 0xffff, 0);
	if (buffer_memtest(buf_size)) return;

	cprintf("Count up test. ");
	buffer_fill(buffer_out, buf_size, 0, 1);
	if (buffer_memtest(buf_size)) return;
}

// Reads a sector off the drive
void menu_readtest()
{
	unsigned int buf_size;
	unsigned int block[4];
	unsigned int statusblock[8] = {0};
	unsigned int i, j;
	unsigned int lowrba, highrba;
	unsigned int cnt;
	char sbuf[17];

	// Clear the buffer
	_fmemset(buffer_in, 0x0, 512);

	cprintf("Low RBA address: ");
	lowrba = get_user_int(0, 0xffff);
	cprintf("\r\n");
	cprintf("High RBA address: ");
	highrba = get_user_int(0, 0xffff);
	cprintf("\r\n");
	cprintf("Count: ");
	cnt = get_user_int(0, 0xffff); // FIXME: better bounds checking
	cprintf("\r\n");

	block[0] = CMD_READ | 0x4000 | 0x0600; // Read data
	block[1] = cnt;
	block[2] = lowrba;
	block[3] = highrba;

	if (dma_drive_command(block, statusblock, buffer_in, cnt * 256, DMA_16WRITEMEM)) { // word count
		cprintf("DMA failed.\r\n");
		return;
	}
	cprintf("Hit a key to see the buffer.\r\n");
	getch();
	print_buffer((unsigned char far *)buffer_in, cnt * 512); // byte count
	cprintf("Press a key to continue.");
	getch();
}

void menu_seektest()
{
	doseek(0);
}

void menu_readverify()
{
	unsigned int block[4], statusblock[8];

	cprintf("Verifying RBA 0.\r\n");
	block[0] = CMD_READVERIFY | 0x600 | 0x4000;
	block[1] = 1;
	block[2] = 0; // Low RBA
	block[3] = 0; // High RBA
	if (simple_drive_command(block, statusblock)) {
		cprintf("Read verify failed.\r\n");
		print_status_block(statusblock);
		return;
	}
	
	cprintf("Verifying RBA 0 and 1.\r\n");
	block[1] = 2; // Two block transfer
	if (simple_drive_command(block, statusblock)) {
		cprintf("Read verify failed.\r\n");
		print_status_block(statusblock);
		return;
	}
	cprintf("OK.\r\n");
}

// Manually let the user configure DMA channel and arb level
void menu_manual_dma()
{
	cprintf("Use PIO mode? (1 for yes, 0 for no) ");
	if (get_user_int(0, 1)) {
		dma_channel = DMA_DISABLED;
	} else {
		cprintf("Enter DMA arbitration level (from 0 to f, typically 'e') ");
		dma_arb = get_user_int(0, 15);
		cprintf("\r\nEnter DMA channel (from 0 to 7, typically 0) ");
		dma_channel = get_user_int(0, 7);
		cprintf("\r\n");
	}
	do_statusbar();
}

// Waits for a flag bit to match. Has timeout, also checks for key presses
int wait_keyb (int flag, int val) {
	unsigned int i;
	int a = 0;
	for (i = 0; i < 65535; i++) {
		while (a == REFRESH_BIT) {
			_disable();
			if ((inportb(BSR) & flag) == val) {
				_enable();
				return 0;
			}
			_enable();
		}
		a = REFRESH_BIT;
		if (bioskey(1) != 0) {
			getch();
			return 2;
		}
	}
	cprintf("Timed out.\r\n");
	return 1; // Timed out
}

void menu_atn_mailbox()
{
	int a = 0;
	unsigned char v = 0;
	cprintf("Running ATN mailbox test.\r\n");
	while (1) {
		// Wait for busy bit to be cleared
		a = wait_keyb(BUSY, 0);
		if (a == 2) return;
		if (a == 1) continue;
		outportb(ATN, v++);
	}
}

void menu_ci_mailbox()
{
	int a = 0;
	unsigned int v = 0;
	cprintf("Running CIFR mailbox test.\r\n");
	while (1) {
		a = wait_keyb(CIR_FULL, 0);
		if (a == 2) return;
		if (a == 1) continue;
		outport(CIFR, v++);
	}
}

void menu_si_mailbox()
{
	int a;
	unsigned int v, v_prev;
	while(1) {
		a = wait_keyb(SIR_FULL, SIR_FULL);
		if (a == 2) return;
		if (a == 1) continue;
		// Optional: insert delay here
		v = inport(SIFR);
		if (v != v_prev) {
			if (v != v_prev + 1) {
				cprintf("Skipped from %d to %d.\r\n", v_prev, v);
			}
			v_prev = v;
		}
	}
}

void menu_isr_mailbox()
{
	int a;
	unsigned int v, v_prev;
	outportb(BCR, 0); // No interrupts enabled
	while(1) {
		a = wait_keyb(INT_PEND, INT_PEND);
		if (a == 2) return;
		if (a == 1) continue;
		v = inportb(ISR);
		if (v != v_prev) {
			if (v != v_prev + 1) {
				cprintf("Skipped from %d to %d.\r\n", v_prev, v);
			}
			v_prev = v;
		}
	}
}

void menu_dreg_write_mailbox()
{
	int a = 0;
	unsigned int v = 0;
	cprintf("Running data register write mailbox test.\r\n");
	while (1) {
		a = wait_keyb(TRANS_REQ, TRANS_REQ);
		if (a == 2) return;
		if (a == 1) continue;
		outport(DREG, v++);
	}
}

void menu_dreg_read_mailbox()
{
	int a;
	unsigned int v, v_prev;
	cprintf("Running data register read mailbox test.\r\n");
	while (1) {
		a = wait_keyb(TRANS_REQ, TRANS_REQ);
		if (a == 2) return;
		if (a == 1) continue;
		v = inport(DREG);
		if (v != v_prev + 1) {
			cprintf("Skipped from %d to %d.\r\n", v_prev, v);
		}
		v_prev = v;
	}
}

int13h_read(unsigned char *buffer, unsigned long lba, int length)
{
	int c, h, s, ret;

	// Translate lba to chs using IBM's DBA-ESDI algorithm
	// Within limits it will match up with the rba
	s = (lba & 0x1F) + 1;     // 32 sectors (1-based)
	h = (lba >> 5) & 0x3F;    // 64 heads
	c = (lba >> 11) & 0x3FF;  // 1024 cylinders

	// FIXME: hard coded to first hard drive
	ret = biosdisk(0x2, 0x80, h, c, s, length, buffer);
	if (ret != 0) {
		cprintf("Int13h error %x\r\n", ret);
		return 1;
	}
	return 0;
}

menu_int13_readsectors()
{
	int numsectors, x, y;
	unsigned long interation = 0;
	cprintf("Enter number of sectors (1 to 5): ");
	numsectors = get_user_int(1, 5);
	cprintf("Running test, press any key to end.\r\n");

	// First read is our reference read
	int13h_read(buffer_out, 0, numsectors);

	while (1) {
		int13h_read(buffer_in, 0, numsectors);
		if (_fmemcmp(buffer_out, buffer_in, numsectors * 512) != 0) {
			cprintf("Buffer mismatch.\r\n");
			break;
		}
		iteration++;
		x = wherex();
		y = wherey();
		cprintf("Iteration %d       ", iteration);
		gotoxy(x, y);

		if (bioskey(1) != 0) { // End test
			getch();
			break;
		}

	}
	cprintf("Test ended.");
}
		

const MENU_ITEM menu_settings[] = { {"Autoconfigure DMA", menu_setup_dma},
				{"Manual DMA config", menu_manual_dma},
				{0, 0} };

const MENU_ITEM menu_lowlevel[] = { {"Put drive in reset", menu_dr_reset_on}, 
	                        {"Take drive out of reset", menu_dr_reset_off},
				{"Handle pending interrupt", menu_handle_int},
				{"Get status block", menu_get_status_block},
				{"Cmd: Diagnostic status", menu_ll_diags},
				{"Cmd: Get device configuration", menu_ll_getconfigs},
				{"Cmd: Run diagnostic", menu_ll_rundiags},
				{"Cmd: Get manufacturer header", menu_ll_getmanuf},
				{"Cmd: Read", menu_ll_read},
				{0, 0} };

const MENU_ITEM menu_post[] = { {"Hard reset drive", menu_hardreset},
				{"Soft reset drive", menu_softreset},
				{"Self test", menu_selftest},
				{"Buffer test", menu_buffertest},
				{"Seek test", menu_seektest},
				{"Read verify", menu_readverify},
				{0, 0} };

const MENU_ITEM menu_driveinfo[] = { {"Get controller config", menu_controllerconfig},
				{"Get drive config", menu_driveconfig},
				{"Get manufacturing header", menu_get_mfg_header},
				{"Get POS information", menu_ll_pos},
				{0, 0} };

const MENU_ITEM menu_mailbox[] = { {"ATN mailbox test", menu_atn_mailbox},
				   {"CIFR mailbox test", menu_ci_mailbox},
				   {"SIFR mailbox test", menu_si_mailbox},
				   {"ISR mailbox test", menu_isr_mailbox},
				   {"DREG host write test", menu_dreg_write_mailbox},
				   {"DREG host read test", menu_dreg_read_mailbox},
	                        {0, 0} };

const MENU_ITEM menu_int13[] = { {"Repeated read sectors", menu_int13_readsectors},
	                        {0, 0} };

const MENU_ITEM menu_main[] = { {"Settings", 0, (void *)menu_settings},
	                        {"Mailbox tests", 0, (void *)menu_mailbox},
				{"Low level commands", 0, (void *)menu_lowlevel},
				{"Drive information", 0, (void *)menu_driveinfo},
				{"POST tests", 0, (void *)menu_post},
				{"Run diagnostics", menu_rundiags},
				{"Read sector", menu_readtest},
				{0, 0} };


// When waiting for user input, do these tasks over and over again
void display_menu_idle()
{
	if (oldbsr != inportb(BSR)) {
		oldbsr = inportb(BSR);
		do_statusbar();
	} else if (interrupt_detected2) {
		interrupt_detected2 = 0;
		do_statusbar();
	}
	delay(10);
}

// Clear to end of screen
void clear_after()
{
	int oldx = wherex();
	int oldy = wherey();
	int i, j;
	for (i = oldy; i < curtextmode.screenheight - 2; i++) {
		gotoxy(1, i);
		clreol();
	}
	gotoxy(oldx, oldy);
}

// Navigate menu system. Submenus are done recursively.
void display_menu (const MENU_ITEM *menu, char *banner, int top)
{
        int i;
        char ch;

        clrscr();
        while (1) {
                cprintf("%s", banner); clreol();
		cprintf("\r\n"); clreol();
                i = 0;
                do {
                        cprintf(" %d.  %s\r\n", i, menu[i].name); clreol();
                        i++;
                } while (menu[i].menufunc != 0 || menu[i].submenu != 0);
                if (top) {
                        cprintf("\r\nEnter selection or press Esc to quit."); clreol();
                } else {
                        cprintf("\r\nEnter selection or press Esc to return to the previous menu."); clreol();
                }
                do {
			while (!kbhit()) {
				display_menu_idle();
			}
                        ch = getch();
                        if (ch == 27) return;
                } while (ch < '0' || ch >= ('0' + i));
                cprintf("\r\n");
                i = ch - '0';
                if (menu[i].submenu) {
                        display_menu((MENU_ITEM *)menu[i].submenu,
                                     (char *)menu[i].name, 0);
                        clrscr();
                } else {
			clear_after();
                        menu[i].menufunc();
                        gotoxy(1, 1);
                }
        }
}

// Normal command flow:
// 1. Attention request (we write to ATN)
// 2. Command request (we write the command block to the Command Interface Register)
// 3. Data transfer (optional)
// 4. Status data (this is returned by the controller, iirc)
// 5. End of interrupt (using code return in the status data?)


// Demo of using refresh bit for timing
void dtest()
{
	int a = 0;
	unsigned int i;

	for (i = 0; i < 65535; i++) {
		while (a == REFRESH_BIT) {} // Wait for refresh to toggle
		a = REFRESH_BIT;
		// TODO: check the busy bit or whatever
	}
}

void hextest()
{
	unsigned int far *tb;
	unsigned int i;
	tb = (unsigned int far *)farmalloc(512);
	for (i = 0; i < 256; i++) ((unsigned char far *)tb)[i] = i;
	
	print_buffer((unsigned char far *)tb, 256);

	farfree(tb);
}

int main()
{
	gettextinfo(&curtextmode);
	buffer_out = (unsigned int far *)farmalloc_page(MAX_BUFFER);
	if (!buffer_out) return 0;
	buffer_in = (unsigned int far *)farmalloc_page(MAX_BUFFER);
	if (!buffer_in) {
		farfree(buffer_out);
		return 0;
	}

	install_handler();
	clrscr();
	do_statusbar();
	display_menu(menu_main, "Main Menu", 1);

	// Clean up
	window(1, 1, curtextmode.screenwidth, curtextmode.screenheight);
	clrscr();
	remove_handler();
	farfree(buffer_in);
	farfree(buffer_out);
	return 0;
}
