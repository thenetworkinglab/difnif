
// Pin definitions
#define PIN_RD 36
#define PIN_WR 37
#define PIN_INT 29
#define ADDR0 10
#define ADDR1 12
#define ADDR2 11
#define ADDR3 13

// Register definitions for Teensy interface
#define REG_TEST 0
#define REG_FLAGS 1
#define REG_ATN 2
#define REG_ISR 3
#define REG_CIFR 4
#define REG_SIFR 5
#define REG_DREG 6
#define REG_POS01 7
#define REG_POS23 8
#define REG_POS4 9

// Bit definitions for REG_FLAGS
#define FLAG_ATN_FULL 0
#define FLAG_ISR_FULL 1
#define FLAG_CIFR_FULL 2
#define FLAG_SIFR_FULL 3
#define FLAG_HARD_RESET 4
#define FLAG_TREQ_SET 5
#define FLAG_CMD_PROG 6
#define FLAG_BUSY 7
#define FLAG_TREQ_STATE 8
#define FLAG_TRANSFER_16 9
#define FLAG_CLEAR_ALL 10

// Some ESDI-DBA values
#define DEV_CONTROLLER (0xE0)
#define DEV_DRIVE (0x00)

// ATN commands
#define ATN_COMMAND 0x1
#define ATN_EOI     0x2
#define ATN_ABORT   0x3
#define ATN_RESET   0x4

#define ATN_DEV_MASK 0xE0
#define ATN_CMD_MASK 0x0F

// ISR interrupt values
#define ISR_RESET_OK 0xEA
#define ISR_RESET_FAIL 0xFA
#define ISR_CMD_ERROR 0x0E
#define ISR_ATN_ERROR 0x0F
#define ISR_DATA_XFER_RDY 0x0B

// Command block values
#define CMD_NO_OPT_MASK (0xC0FF) // Page 29, ignores options field
#define CMD_CMD_MASK (0x001F)
#define CMD_DEV_MASK (0x00E0)

// Status block values
#define STAT_BLEN_MASK (0xFF00) // Page 50.
#define STAT_DEV_MASK (0x00E0)
#define STAT_CMD_MASK (0x001F)

// Pin definitions for 16-bit data port
const int portpin[] = {27, 26, 39, 38,
                        21, 20, 23, 22,
                        16, 17, 41, 40,
                        15, 14, 18, 19};

uint8_t oldint = 0; // only used in debug version of loop()

// Status and command block buffers
uint16_t status_block[8] = {0};
uint8_t status_count = 0;
uint8_t status_max = 0;
uint16_t cmd_block[8] = {0};
uint8_t cmd_count = 0;

// Data transfer buffer
uint8_t transfer_buffer[512];
uint16_t transfer_count = 0;
uint16_t transfer_index = 0;

#define TS_IDLE 0
#define TS_READ 1
#define TS_WRITE 2
uint8_t transfer_state = TS_IDLE;

// Interrupt state
#define PEND_INT 1
#define PEND_INT_RESET 2
uint8_t int_pending = 0;

// Status block fields
uint8_t sb_cmd_status = 0; // This is just ISR contents.
uint8_t sb_cmd_error = 0;
#define CMD_ERR_PARAM (0x1)
#define CMD_ERR_UNSUPP (0x3)
#define CMD_ERR_INVDEV (0x13)

uint8_t sb_dev_status = 0x19; // READY, SELECTED, cmd complete
uint8_t sb_dev_error = 0;
#define DEV_ERR_BADRBA (0x7)
#define DEV_ERR_NOTREADY (0x10)
uint8_t sb_por_error = 0;
uint8_t sb_test_error = 0;

// Set 16-bit data port direction
void setPortMode(uint8_t mode)
{
    for (int i = 0; i < 16; i++) {
      pinMode(portpin[i], mode);
    }
}


// Read a value from the FPGA port
uint16_t portRead(uint8_t address)
{
    uint16_t ret;
    digitalWriteFast(ADDR0, address & 1);
    digitalWriteFast(ADDR1, (address >> 1) & 1);
    digitalWriteFast(ADDR2, (address >> 2) & 1);
    digitalWriteFast(ADDR3, (address >> 3) & 1);
    digitalWriteFast(PIN_RD, 1);
    delayMicroseconds(3);
    ret = GPIO6_PSR >> 16;
    // Grab port contents
    digitalWriteFast(PIN_RD, 0);
    return ret;
}


// Write a value to the FPGA port
void portWrite(uint8_t address, uint16_t data)
{
    digitalWriteFast(ADDR0, address & 1);
    digitalWriteFast(ADDR1, (address >> 1) & 1);
    digitalWriteFast(ADDR2, (address >> 2) & 1);
    digitalWriteFast(ADDR3, (address >> 3) & 1);
    setPortMode(OUTPUT);
    GPIO6_DR = (GPIO6_DR & 0xFFFF) | (data << 16);
    digitalWriteFast(PIN_WR, 1);
    delayMicroseconds(3);
    digitalWriteFast(PIN_WR, 0);
    setPortMode(INPUT);
}


// Configure the device and print the menu options
void setup() {
  // put your setup code here, to run once:
  Serial.begin(115200);
  setPortMode(INPUT);
  pinMode(PIN_RD, OUTPUT);
  pinMode(PIN_WR, OUTPUT);
  pinMode(PIN_INT, INPUT);
  pinMode(ADDR0, OUTPUT);
  pinMode(ADDR1, OUTPUT);
  pinMode(ADDR2, OUTPUT);
  pinMode(ADDR3, OUTPUT);

  Serial.println("Press 'f' for flag register contents.");
  Serial.println("Press 'F' to set flag register.");
  Serial.println("Press 'a' for ATN register contents.");
  Serial.println("Press 'i' to write to ISR and trig an interrupt.");
  Serial.println("Press 'c' to read Command Interface Reg.");
  Serial.println("Press 'C' for CIFR read loop test.");
  Serial.println("Press 'S' for SIFR write loop test.");
  Serial.println("Press 'A' for ATN read loop test.");
  Serial.println("Press 'I' for ISR write loop test.");
  Serial.println("Press '1' for Teensy-to-host loop test.");
  Serial.println("Press '2' for host-to-Teensy loop test.");
  Serial.println("Press 's' to write Status Interface Reg.");
  Serial.println("Press 'G' to run the main loop.");
}


// Prints a 16-bit hex value to the USB console
void print16hex(uint16_t val)
{
    Serial.print(val >> 12, HEX);
    Serial.print((val >> 8) & 0xF, HEX);
    Serial.print((val >> 4) & 0xF, HEX);
    Serial.print(val & 0xF, HEX); 
}


// Reads a hex digit from the USB console
uint8_t readhex()
{
  char d;
  while(1) {
    if (Serial.available() > 0) {
      d = Serial.read();
      if ((d >= 0x30) && (d <= 0x39)) {
        return d - 0x30;
      }
      if ((d >= 0x41) && (d <= 0x46)) {
        return d + 0xA - 0x41;
      }
      if ((d >= 0x61) && (d <= 0x66)) {
        return d + 0xa - 0x61;
      }
    }
  }
}


// Reads 2 hex digits from the console
uint8_t read8()
{
  uint8_t d;
  d = readhex();
  Serial.print(d, HEX);
  d = (d << 4) | readhex();
  Serial.print(d & 0xF, HEX);
  return d;
}


// Reads 4 hex digits from the console
uint16_t read16()
{
  uint16_t d;
  d = readhex();
  Serial.print(d, HEX);
  d = (d << 4) | readhex();
  Serial.print(d & 0xF, HEX);
  d = (d << 4) | readhex();
  Serial.print(d & 0xF, HEX);
  d = (d << 4) | readhex();
  Serial.print(d & 0xF, HEX);
  return d;
}


// Checks first word of command block, returns length
uint8_t cmdBlockLen()
{
  uint16_t t = cmd_block[0] >> 14;
  if (t == 0) return 2;
  if (t == 1) return 4;
  // TODO: what if t is reserved?
  return 2;
}


// Loads the ISR with the code, updates the command status register
void doISR(uint16_t code)
{
  sb_cmd_status = code & 0xF;
  portWrite(REG_ISR, code);
}


// Fills in basic info for the status block
void startStatusBlock(uint8_t len, uint8_t code)
{
  status_block[0] = (len << 8) | code;
  status_count = 0;
  status_max = len;
}


// Writes a word of the status block to the host
void loadStatusBlock()
{
  status_max--;
  portWrite(REG_SIFR, status_block[status_count]);
  Serial.print("SIFR: count ");
  Serial.println(status_count);
  status_count++;
}


// Set up the first part of the status block (page 49)
void prepDefaultSB()
{
  startStatusBlock(7, cmd_block[0]);
  status_block[1] = (sb_cmd_status << 8) | sb_cmd_error; // command status, command error code
  status_block[2] = (sb_dev_status << 8) | sb_dev_error; // device status, device error code
  status_block[3] = 0x0000;
  status_block[4] = 0x0000; 
  status_block[5] = 0x0000; 
  status_block[6] = 0x0000;
}


// Sets a bit in the FPGA flag register
void setFlag(uint16_t flag)
{
  uint16_t old;
  old = portRead(REG_FLAGS);
  portWrite(REG_FLAGS, old | flag);
}


// Clears a bit in the FPGA flag register
void clearFlag(uint16_t flag)
{
  uint16_t old;
  old = portRead(REG_FLAGS);
  portWrite(REG_FLAGS, old & ~flag);
}


// Sets up a pending interrupt to the host
void pendInterrupt(uint8_t kind)
{
  int_pending = kind;
}


// Reset procedure, both hard and soft. Page 22.
void esdiReset()
{
  //
  // Do initialization tasks here
  //

  // Make sure all handshaking flags are cleared
  setFlag(_BV(FLAG_CLEAR_ALL));
  delayMicroseconds(10);
  Serial.print("in clear. flags: ");
  Serial.println(portRead(REG_FLAGS), HEX);
  clearFlag(_BV(FLAG_CLEAR_ALL));
  clearFlag(_BV(FLAG_CMD_PROG)); // Clear any commands in progress
  
  transfer_state = TS_IDLE;

  // Generate reset complete interrupt
  startStatusBlock(1, DEV_CONTROLLER); // Page 61: load status block data
  loadStatusBlock();
  doISR(ISR_RESET_OK); // Success. Failure is 0xFA
  pendInterrupt(PEND_INT_RESET);
}


// Processes a received command block (page 24)
void processCmdBlock()
{
  uint16_t i;
  uint16_t cmd_no_opt = cmd_block[0] & CMD_NO_OPT_MASK;

  // After command, fill in the status block
  // then trigger a command complete interrupt

  switch (cmd_no_opt) {
    case 0x4001: // Read data (sector) page 41
      Serial.println("Preparing sector.");
      status_max = 0; // No status data
      for (i = 0; i < 512; i++) {
        transfer_buffer[i] = i & 0xFF;
      }
      doISR(DEV_DRIVE | ISR_DATA_XFER_RDY);
      transfer_state = TS_READ;
      transfer_count = cmd_block[1] * 512;
      transfer_index = 0;
      // TODO: Validate transfer count or trigger a command error
      Serial.print("ReadData: ");
      Serial.println(transfer_count, DEC);
      // Do not pend interrupt since we do not expect EOI for this
      return;

    case 0x4002: // Write data (sector) page 48
    case 0x4004: // Write with verify (page 49)
      status_max = 0; // No status data
      // TODO: Validate RBA?
      doISR(DEV_DRIVE | ISR_DATA_XFER_RDY);
      transfer_state = TS_WRITE;
      transfer_count = cmd_block[1] * 512;
      transfer_index = 0;
      Serial.print("WriteData: ");
      Serial.println(transfer_count, DEC);
      // Do not pend interrupt since we do not expect EOI for this
      return;

    case 0x4003: // Read Verify (page 42)
      Serial.println("Read verify.");
      doISR(0x01);
      prepDefaultSB();
      // cmd_block[1] = number of blocks requested
      // cmd_block[2], cmd_block[3] = RBA, low and high
      break;

    case 0x4005: // Seek (page 44)
      Serial.println("SEEK COMMAND");
      doISR(0x01); // Command complete for drive
      prepDefaultSB();
      break;

    case 0x0006: // Park head
      Serial.println("Park head");
      doISR(0x01);
      prepDefaultSB();
      break;

    case (DEV_CONTROLLER | 0x7):
    case 0x7: // Get command complete status
      Serial.println("CmdComplete Status");
      portWrite(REG_ISR, 0x01); // Manually trigger ISR. Retain and send existing status block
      break;

    case (DEV_CONTROLLER | 0x8):
    case 0x8: // Get device status
      Serial.println("Get Device Status");
      startStatusBlock(3, cmd_block[0]);
      status_block[1] = 0x0000;
      status_block[2] = (sb_dev_status << 8) | sb_dev_error; // TODO: error codes depend on drive/controller
      doISR(0x01);
      break;

    case 0x9: // Get Configuration (Drive) (page 37, 55)
      Serial.println("Get config, drive");
      // Check bit 11 (cmd_block[0] & _BV(11)) for 0=physical or 1=pseudo
      startStatusBlock(6, cmd_block[0]);
      status_block[1] = 0x0; // FIXME, status bits should be what?
      status_block[2] = 0x0; // Low word number of RBAs
      status_block[3] = 0x0; // High word number of RBAs
      status_block[4] = 0x0; // Number of cylinders
      status_block[5] = 0x0; // Sectors per track, tracks per cylinder
      doISR(0x01);
      break;

    case (DEV_CONTROLLER  | 0x9): // Get Configuration (controller) (page 37, 56)
      Serial.println("Get config, controller");
      doISR(DEV_CONTROLLER  | 0x1); // Command complete for controller
      startStatusBlock(6, cmd_block[0]);
      status_block[1] = 0x0000; // Reserved
      status_block[2] = 0x0001; // Firmware revision code, low word
      status_block[3] = 0x3101; // buf_size1, revision code high byte, buffer size code (256 words)
      status_block[4] = 0x0000; // buf_size2
      status_block[5] = 0x0000; // Reserved
      break;

    case (DEV_CONTROLLER | 0xA): // Get POS information (page 39)
      Serial.println("Get POS info");
      doISR(DEV_CONTROLLER | 0x1);
      startStatusBlock(5, cmd_block[0]);
      i = portRead(REG_POS01);
      status_block[1] = (i >> 8) | (i << 8);
      i = portRead(REG_POS23);
      status_block[2] = (i >> 8) | (i << 8);
      i = portRead(REG_POS4);
      status_block[3] = (i << 8) | 0xFF;
      status_block[4] = 0xFFFF;
      break;

    //case 0x400B: // Translate RBA, seldom used, really only for low level format (page 47)

    case (DEV_CONTROLLER | 0x10): // Write attachment buffer (page 48)
      // cmd_block[1] = the block count, same for all data transfer commands
      status_max = 0; // No status block
      doISR(DEV_CONTROLLER | ISR_DATA_XFER_RDY);
      setFlag(_BV(FLAG_TREQ_SET)); // Tell host (initially) to send us data
      transfer_state = TS_WRITE;
      transfer_count = cmd_block[1] * 512;
      transfer_index = 0;
      // TODO: Validate transfer count or trigger a command error
      Serial.print("WriteAttachBuffer: ");
      Serial.println(transfer_count, DEC);
      // Do not pend interrupt since we do not expect EOI for this
      return;

    case (DEV_CONTROLLER | 0x11): // Read attachment buffer (page 41)
      status_max = 0; // No status block
      doISR(DEV_CONTROLLER | ISR_DATA_XFER_RDY);
      transfer_state = TS_READ;
      transfer_count = cmd_block[1] * 512;
      transfer_index = 0;
      // TODO: Validate transfer count or trigger a command error
      Serial.print("ReadAttachBuffer: ");
      Serial.println(transfer_count, DEC);
      // Do not pend since we do not expect EOI for this
      return;

    case 0x0012: // Run diagnostic test (page 43)
      // Test number is in cmd_block[1]
      // TODO: perform a test, set a code, whatever
      doISR(0x01); // Command complete for drive.
      prepDefaultSB();
      break;

    case (DEV_CONTROLLER | 0x0012): // Run diagnostic test (page 43)
      // Test number is in cmd_block[1]
      // TODO: perform a test, set a code, whatever
      doISR(0x01); // Command complete for drive.
      prepDefaultSB();
      break;

    case 0x0014: // Get Diagnostic Status Block, drive 0 (page 37)
      // See page 58 and page 49
      doISR(0x01); // Command complete for drive. Page 25
      prepDefaultSB();
      status_block[3] = 0x0000; // por error code, test error code
      status_block[4] = 0x0000; // diagnostic command (probably from last Run Diagnostics command)
      status_block[5] = 0x0000; // Reserved
      status_block[6] = 0x0000; // Reserved
      break;

    case 0x0015: // Get Manufacturing Header (page 38)
      Serial.println("Preparing manufacturing header.");
      status_max = 0; // No status data

      // TODO: fill in manufacturing header (see page 72)
      strncpy((char *)transfer_buffer, "DEFECT", 6);
      transfer_buffer[6] = 0x0; transfer_buffer[7] = 0x0;
      transfer_buffer[8] = 0x0;
      transfer_buffer[9] = 0xff;
      //Drive bar code number
      //Drive manufacturing date
      //Use a blank defect map
      
      doISR(DEV_DRIVE | ISR_DATA_XFER_RDY);
      transfer_state = TS_READ;
      transfer_count = cmd_block[1] * 512;
      transfer_index = 0;
      // TODO: Validate transfer count or trigger a command error!
      Serial.print("ReadMfgHdr: ");
      Serial.println(transfer_count, DEC);
      // Do not pend interrupt since we do not expect EOI for this
      return;

    // case 0x0016: Format unit not supported
    // case 0x0017: Format prepare not supported
    
    case 0x401A: // Set Max RBA (page 44)
      // Max RBA is in cmd_block[2] and cmd_block[3]
      // TODO: what to do about this?
      doISR(0x01); // Command complete for drive. Page 25
      prepDefaultSB();
      break;
    
    case (DEV_CONTROLLER | 0x401B): // Set power saving mode (page 40)
      // cmd_block[3] contains idle to standby timeout value. We don't care about that.
      doISR(0x01); // Command complete for drive. Page 25
      prepDefaultSB();
      break;
    
    case (DEV_CONTROLLER | 0x001C): // Power conservation command (page 39)
      // cmd_block[1] contains the power mode requested. We don't care about that.
      doISR(0x01);
      prepDefaultSB();
      break;

    default:
      Serial.print("Unknown command ");
      Serial.println(cmd_no_opt, DEC);
      doISR((cmd_block[0] & ATN_DEV_MASK) | ISR_CMD_ERROR);
      sb_cmd_error = CMD_ERR_UNSUPP;
      prepDefaultSB();
      break;
  }

  loadStatusBlock(); // Load initial word of status block
  clearFlag(_BV(FLAG_CMD_PROG));
  pendInterrupt(PEND_INT);

}


// Issues an attention error
void atnError(uint8_t atn_cmd)
{
  doISR(ISR_ATN_ERROR | (atn_cmd & ATN_DEV_MASK));
  pendInterrupt(PEND_INT_RESET); // Clear busy bit when we get EOI.
}


// Processing loop for host register interface
void mainLoop() {
  uint16_t flags;
  uint8_t atn_cmd;
  uint16_t d;
  bool expect_cb = false;
  bool reset_pending = false;
  bool hard_reset = false;
  
  while (1) {
    flags = portRead(REG_FLAGS);

    // Hard reset bit has been set, we should check to see if we've exited it or
    // just skip all processing if we stay in hard reset.
    if (flags & _BV(FLAG_HARD_RESET)) {
      hard_reset = true;
      continue;
    } else if (hard_reset) {
      hard_reset = false;
      reset_pending = false; // Just in case
      Serial.println("Hard reset.");
      expect_cb = false;
      esdiReset();
    }

    // Soft reset must wait for any write transfers to complete.
    // TODO: ensure that any disk image file writes also happen!
    if (reset_pending && (transfer_state != TS_WRITE)) {
      reset_pending = false;
      expect_cb = false;
      esdiReset();
    }

    // Host has read status block word and we have more to
    // push out
    if (status_max > 0 && !(flags & _BV(FLAG_SIFR_FULL))) {
      loadStatusBlock();
    }

    if (transfer_state == TS_READ) {
      if (!(portRead(REG_FLAGS) & _BV(FLAG_TREQ_STATE))) { // Nothing in data buffer
        if (transfer_index < transfer_count) {
          //Serial.print("being read at index: ");
          //Serial.println(transfer_index, HEX);
          d = transfer_buffer[transfer_index] | (transfer_buffer[transfer_index + 1] << 8);
          transfer_index += 2;
          portWrite(REG_DREG, d);
          setFlag(_BV(FLAG_TREQ_SET)); // Tell host there is data
        } else {
          Serial.print("Done with read data transfer. Last index ");
          Serial.println(transfer_index, HEX);
          transfer_state = TS_IDLE;
          sb_cmd_status = 1;

          prepDefaultSB();
          status_block[3] = 0x0000; // Words left to be processed
          status_block[4] = 0x0000; // TODO: last RBA processed (low)
          status_block[5] = 0x0000; // last RBA processed (high)
          status_block[6] = 0x0000; // Number of blocks required to recover error
          loadStatusBlock();
          
          doISR((cmd_block[0] & ATN_DEV_MASK) | 0x1); // Command complete
          pendInterrupt(PEND_INT);
        }
      }

    }

    if (transfer_state == TS_WRITE) {
      if (!(portRead(REG_FLAGS) & _BV(FLAG_TREQ_STATE))) { // Host sent us data
        d = portRead(REG_DREG);
        // FIXME: handle 8 or 16 bit transfers
        //Serial.print("being written at index: ");
        //Serial.print(transfer_index, HEX);
        //Serial.print("data: ");
        //Serial.println(d, HEX);
        transfer_buffer[transfer_index++] = d & 0xFF;
        transfer_buffer[transfer_index++] = d >> 8;
        if (transfer_index < transfer_count) {
          setFlag(_BV(FLAG_TREQ_SET)); // Ready for more data
        } else {
          Serial.print("Done with write data transfer. Last index ");
          Serial.print(transfer_index, HEX);
          Serial.print(" data: ");
          Serial.println(d, HEX);
          transfer_state = TS_IDLE;

          //
          // TODO: Check original command, see if we need to write data
          //
          
          sb_cmd_status = 1;
          
          prepDefaultSB();
          status_block[3] = 0x0000; // Words left to be processed
          status_block[4] = 0x0000; // TODO: last RBA processed (low)
          status_block[5] = 0x0000; // last RBA processed (high)
          status_block[6] = 0x0000; // Number of blocks required to recover error
          loadStatusBlock();

          doISR((cmd_block[0] & ATN_DEV_MASK) | 0x1); // Command complete
          pendInterrupt(PEND_INT);
        }
      }
    }

    // We have command block words coming in from the host.
    if (expect_cb && (flags & _BV(FLAG_CIFR_FULL))) {
      cmd_block[cmd_count] = portRead(REG_CIFR);
      Serial.print("Got cmd block byte: ");
      Serial.print(cmd_count);
      Serial.print(" - ");
      Serial.println(cmd_block[cmd_count], HEX);
      cmd_count++;
      if ((cmd_count > 1) && (cmd_count == cmdBlockLen())) {
        // Pg 14: [busy] is cleared upon completion of the command block transfer...
        clearFlag(_BV(FLAG_BUSY));
        // Pg 14: This bit is set when all words of the command block have been received.
        setFlag(_BV(FLAG_CMD_PROG));

        // Now process the command itself.
        processCmdBlock();
        expect_cb = false;
      }
    }

    // We have a waiting ATN command from the host.
    if (flags & _BV(FLAG_ATN_FULL)) {
      atn_cmd = portRead(REG_ATN);
      Serial.print("ATN recieved: ");
      Serial.println(atn_cmd, HEX);

      switch(atn_cmd & ATN_CMD_MASK) {
        case ATN_EOI: 
          // FIXME, check Device Select bits
          // since technically we can have an interrupt pending
          // from both the controller and the drive at the same time.
          // Check if we have a pending interrupt
          if (int_pending == PEND_INT_RESET) {
            int_pending = 0;
            // Reset interrupt clears the busy flag (Page 23)
            clearFlag(_BV(FLAG_CMD_PROG));
            clearFlag(_BV(FLAG_BUSY));
            Serial.println("Cleared pending reset int.");
          } else if (int_pending != 0) {
            int_pending = 0;
            clearFlag(_BV(FLAG_CMD_PROG));
            clearFlag(_BV(FLAG_BUSY)); // FIXME: may not want to clear busy flag here?
            Serial.println("Cleared some other int.");
          }
          break;
        case ATN_RESET:
          if ((atn_cmd & ATN_DEV_MASK) == 0xE0) {
            setFlag(_BV(FLAG_BUSY));
            Serial.println("Soft reset pending.");
            reset_pending = true;
          } else {
            atnError(atn_cmd);
          }
          break;
        case ATN_COMMAND:
          // Expect to receive command blocks
          Serial.println("Set busy");
          portRead(REG_CIFR); // Ensure interface is empty
          expect_cb = true;
          cmd_count = 0;
          break;
        case ATN_ABORT:
          // TODO: Process abort command
          break;
        default:
          Serial.println("Invalid command.");
          atnError(atn_cmd);
          break;
      }
    }
    
  }
}


// Tests the ATN register mailboxes
void ATNTestLoop()
{
  uint16_t flags;
  uint8_t d = 0;
  uint8_t d2 = 0;;
  Serial.println("Begin.");
  clearFlag(_BV(FLAG_BUSY));
  while (1) {
    flags = portRead(REG_FLAGS);
    if (flags & _BV(FLAG_ATN_FULL)) {
      d = portRead(REG_ATN);
      if (d != d2 + 1) {
        Serial.print("Skipped from ");
        Serial.print(d2, DEC);
        Serial.print(" to ");
        Serial.println(d, DEC);
      }
      d2 = d;
      clearFlag(_BV(FLAG_BUSY));
    }
  }
  Serial.println("???");
}


// Tests the ISR register mailboxes
void ISRTestLoop()
{
  uint16_t flags;
  uint8_t d = 0;
  while(1) {
    flags = portRead(REG_FLAGS);
    if (!(flags & _BV(FLAG_ISR_FULL))) { // Not full
      portWrite(REG_ISR, d++);
    }
  }  
}


// Tests the Status Interface Register mailboxes
void SIFRTestLoop()
{
  uint16_t flags, d = 0;
  while(1) {
    flags = portRead(REG_FLAGS);
    if (!(flags & _BV(FLAG_SIFR_FULL))) { // Not full
      portWrite(REG_SIFR, d++);
    }
  }
}


// Tests the data register (to host)
void DREGToHostTestLoop()
{
  uint16_t flags, d = 0;
  while(1) {
    flags = portRead(REG_FLAGS);
    if (!(flags & _BV(FLAG_TREQ_STATE))) { // Nothing in data buffer
      portWrite(REG_DREG, d++);
      setFlag(_BV(FLAG_TREQ_SET)); // Tell host there is data
    }
  }
}


// Tests the data register (from host)
void DREGFromHostTestLoop()
{
  uint16_t flags, d, d2 = 0;
  setFlag(_BV(FLAG_TREQ_SET)); // Tell host (initially) to send us data
  while(1) {
    flags = portRead(REG_FLAGS);
    if (!(flags & _BV(FLAG_TREQ_STATE))) { // Host sent us data
      d = portRead(REG_DREG);
      if (d != d2 + 1) {
        Serial.print("Skipped from ");
        Serial.print(d2, DEC);
        Serial.print(" to ");
        Serial.println(d, DEC);
        Serial.println(flags, HEX);
      }
      d2 = d;
      setFlag(_BV(FLAG_TREQ_SET)); // Ready for more data
    }
  }
}


// Tests the Command Interface Register mailboxes
void CIFRTestLoop()
{
  uint16_t flags;
  uint16_t d = 0;
  uint16_t d2 = 0;
  
  while(1) {
    #if 1
    flags = portRead(REG_FLAGS);
    if (flags & _BV(FLAG_CIFR_FULL)) {
      //delay(5);
      d = portRead(REG_CIFR);

      if (d != d2 + 1) {
        Serial.print("Skipped from ");
        Serial.print(d2, DEC);
        Serial.print(" to ");
        Serial.println(d, DEC);
      }
      d2 = d;
    }
    #else
    d = portRead(REG_CIFR);
    if (d != d2) {
      if (d != d2 + 1) {
        Serial.print("Skipped from ");
        Serial.print(d2, DEC);
        Serial.print(" to ");
        Serial.println(d, DEC);
      }
      d2 = d;
    }
    //Serial.print(portRead(REG_CIFR), HEX);
    //Serial.print(" ");
    //if (c++ > 25) {
    //  c = 0;
    //  Serial.println();
    //}
    #endif
  }
}


// Main loop.
void loop() {
  uint16_t d, i;
  uint8_t cmd, t;
  // put your main code here, to run repeatedly:

  // FIXME: make it an interrupt?
  t = digitalReadFast(PIN_INT);
  if (t != oldint) {
    oldint = t;
    if (t == 1) {
      Serial.println("Interrupt asserted.");
    }
    if (t == 0) {
      Serial.println("Interrupt deasserted.");
    }
  }

  if (Serial.available() > 0) {
    cmd = Serial.read();
    if (cmd == 'F') {
      Serial.print("Enter data for flags: ");
      d = read8();
      portWrite(REG_FLAGS, d);
      Serial.println();
    }
    if (cmd == 'f') {
      d = portRead(REG_FLAGS);
      Serial.print("Flag reg: ");
      Serial.println(d, HEX);
    }
    if (cmd == 'a') {
      i = portRead(REG_ATN);
      Serial.print("ATN reg: ");
      Serial.println(i & 0xFF, HEX);
    }
    if (cmd == 'i') {
      Serial.print("Enter data for ISR: ");
      d = read8();
      portWrite(REG_ISR, d);
      Serial.println();
    }
    if (cmd == 'c') {
      i = portRead(REG_CIFR);
      Serial.print("CIFR reg: ");
      print16hex(i);
      Serial.println();
    }
    if (cmd == 'C') {
      Serial.println("CIFR test loop.");
      CIFRTestLoop();
    }
    if (cmd == 'S') {
      Serial.println("SIFR test loop.");
      SIFRTestLoop();
    }
    if (cmd == 'A') {
      Serial.println("ATN test loop.");
      ATNTestLoop();
    }
    if (cmd == 'I') {
      Serial.println("ISR test loop.");
      ISRTestLoop();
    }
    if (cmd == '1') {
      Serial.println("Teensy -> DREG -> host");
      DREGToHostTestLoop();
    }
    if (cmd == '2') {
      Serial.println("Teensy <- DREG <- host");
      DREGFromHostTestLoop();
    }
    if (cmd == 's') {
      Serial.print("Enter data for SIFR: ");
      d = read16();
      portWrite(REG_SIFR, d);
      Serial.println();
    }
    if (cmd == 'G') {
      Serial.println("Starting main loop.");
      esdiReset();
      mainLoop();
    }
  }
}
