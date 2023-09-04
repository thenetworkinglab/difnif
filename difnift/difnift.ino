
#define PIN_RD 36
#define PIN_WR 37
#define PIN_INT 29
#define ADDR0 10
#define ADDR1 12
#define ADDR2 11
#define ADDR3 13

#define REG_TEST 0
#define REG_FLAGS 1
#define REG_ATN 2
#define REG_ISR 3
#define REG_CIFR 4
#define REG_SIFR 5

#define FLAG_ATN_FULL 0
#define FLAG_ISR_FULL 1
#define FLAG_CIFR_FULL 2
#define FLAG_SIFR_FULL 3
#define FLAG_HARD_RESET 4
#define FLAG_INT_PEND 5
#define FLAG_CMD_PROG 6
#define FLAG_BUSY 7

#define PEND_INT 1
#define PEND_INT_RESET 2

// Some ESDI-DBA values
#define DEV_CONTROLLER 7
#define DEV_DRIVE 0

// ATN commands
#define ATN_COMMAND 1
#define ATN_C_EOI 0xE2
#define ATN_D_EOI 0x02
#define ATN_ABORT 3
#define ATN_RESET 0xE4

const int portpin[] = {27, 26, 39, 38,
                        21, 20, 23, 22,
                        16, 17, 41, 40,
                        15, 14, 18, 19};

uint8_t oldint = 0;

uint16_t status_block[8] = {0};
uint8_t status_count = 0;
uint8_t status_max = 0;
uint16_t cmd_block[8] = {0};
uint8_t cmd_count = 0;

uint8_t int_pending = 0;
uint8_t expect_cb = 0;

void setPortMode(uint8_t mode)
{
    for (int i = 0; i < 16; i++) {
      pinMode(portpin[i], mode);
    }
}

uint16_t portRead(uint8_t address)
{
    uint16_t ret;
    digitalWriteFast(ADDR0, address & 1);
    digitalWriteFast(ADDR1, (address >> 1) & 1);
    digitalWriteFast(ADDR2, (address >> 2) & 1);
    digitalWriteFast(ADDR3, (address >> 3) & 1);
    digitalWriteFast(PIN_RD, 1);
    delayMicroseconds(1);
    ret = GPIO6_PSR >> 16;
    // Grab port contents
    digitalWriteFast(PIN_RD, 0);
    return ret;
}

void portWrite(uint8_t address, uint16_t data)
{
    digitalWriteFast(ADDR0, address & 1);
    digitalWriteFast(ADDR1, (address >> 1) & 1);
    digitalWriteFast(ADDR2, (address >> 2) & 1);
    digitalWriteFast(ADDR3, (address >> 3) & 1);
    setPortMode(OUTPUT);
    GPIO6_DR = (GPIO6_DR & 0xFFFF) | (data << 16);
    digitalWriteFast(PIN_WR, 1);
    delayMicroseconds(1);
    digitalWriteFast(PIN_WR, 0);
    setPortMode(INPUT);
}

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
  Serial.println("Press 's' to write Status Interface Reg.");
  Serial.println("Press 'G' to run the main loop.");
}

void print16hex(uint16_t val)
{
    Serial.print(val >> 12, HEX);
    Serial.print((val >> 8) & 0xF, HEX);
    Serial.print((val >> 4) & 0xF, HEX);
    Serial.print(val & 0xF, HEX); 
}

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

uint8_t read8()
{
  uint8_t d;
  d = readhex();
  Serial.print(d, HEX);
  d = (d << 4) | readhex();
  Serial.print(d & 0xF, HEX);
  return d;
}

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

void startStatusBlock(uint8_t len, uint8_t dev, uint8_t code)
{
  status_block[0] = (len << 8) | ((dev & 0x7) << 5) | (code & 0x1F);
  status_count = 0;
  status_max = len;
}

void setFlag(uint16_t flag)
{
  uint16_t old;
  old = portRead(REG_FLAGS);
  portWrite(REG_FLAGS, old | flag);
}

void clearFlag(uint16_t flag)
{
  uint16_t old;
  old = portRead(REG_FLAGS);
  portWrite(REG_FLAGS, old & ~flag);
}

void pendInterrupt(uint8_t kind)
{
  int_pending = kind;
  // Set interrupt pending flag
  setFlag(_BV(FLAG_INT_PEND));
}

// Reset procedure. Page 22.
void esdiReset()
{
  setFlag(_BV(FLAG_BUSY));
  //
  // Do initialization tasks here
  //
  portWrite(REG_ISR, 0xEA); // Success. Failure is 0xFA
  // Load status data block
  startStatusBlock(1, DEV_CONTROLLER, 0); // Page 61
  pendInterrupt(PEND_INT_RESET);
}

// Processes a received command block
// Page 24
void processCmdBlock()
{
  // TODO

  // If command requires data transfer, probably need to
  // set up a state machine that runs in the main loop

  // After command, fill in the status block
  // then trigger a command complete interrupt

  if (cmd_block[0] == 0x0614) { // Get diagnostic status block, drive 0
    // See page 58 and page 49
    startStatusBlock(7, DEV_DRIVE, 0x14);
    // These blocks are probably meant to be assembled from internal
    // state variables. i.e. device status is an internal flag field.
    status_block[1] = 0x0100; // command status, command error code
    status_block[2] = 0x0000; // device status, device error code (was 1900)
    status_block[3] = 0x0000; // por error code, test error code
    status_block[4] = 0x0000; // diagnostic command (probably from last Run Diagnostics command)
    status_block[5] = 0x0000; // Reserved
    status_block[6] = 0x0000; // Reserved

    // Page 25
    portWrite(REG_ISR, 0x01); // Command complete for drive
    clearFlag(_BV(FLAG_CMD_PROG));
    pendInterrupt(PEND_INT);
  }
  
}

// Processing loop for host register interface
// TODO: what to do about error conditions?
void mainLoop() {
  uint16_t flags;
  uint8_t atn_cmd;
  while (1) {
    flags = portRead(REG_FLAGS);

    // Host has read status block word and we have more to
    // push out
    if (status_max > 0 && !(flags & _BV(FLAG_SIFR_FULL))) {
      status_max--;
      portWrite(REG_SIFR, status_block[status_count]);
      Serial.print("SIFR: count ");
      Serial.println(status_count);
      status_count++;
    }

    if (expect_cb && (flags & _BV(FLAG_CIFR_FULL))) {
      Serial.print("Got cmd block byte: ");
      Serial.print(cmd_count);
      Serial.print(" - ");
      cmd_block[cmd_count] = portRead(REG_CIFR);
      Serial.println(cmd_block[cmd_count], HEX);
      cmd_count++;
      if ((cmd_count > 1) && (cmd_count == cmdBlockLen())) {
        // We've gotten all the blocks
        clearFlag(_BV(FLAG_BUSY));
        setFlag(_BV(FLAG_CMD_PROG));
        processCmdBlock();
        expect_cb = 0;
      }
    }

    // We have a waiting ATN command from the host.
    if (flags & _BV(FLAG_ATN_FULL)) {
      atn_cmd = portRead(REG_ATN);
      Serial.print("ATN recieved: ");
      Serial.println(atn_cmd, HEX);

      switch(atn_cmd) {
        case ATN_D_EOI: // FIXME, handle these separately?
        case ATN_C_EOI:
          // Check if we have a pending interrupt
          if (int_pending == PEND_INT_RESET) {
            int_pending = 0;
            // Reset interrupt clears the busy flag
            clearFlag(_BV(FLAG_INT_PEND) | _BV(FLAG_BUSY));
            Serial.println("Cleared pending reset int.");
          } else if (int_pending != 0) {
            int_pending = 0;
            clearFlag(_BV(FLAG_INT_PEND));
            Serial.println("Cleared some other int.");
          }
          break;
        case ATN_RESET:
          Serial.println("Soft reset received.");
          esdiReset();
          break;
        case ATN_COMMAND:
          // Expect to receive command blocks
          setFlag(_BV(FLAG_BUSY));
          expect_cb = 1;
          cmd_count = 0;
          break;
        default:
          Serial.println("Invalid command.");
          break;
      }
    }
    
  }
}


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
      Serial.println(d & 0xFF, HEX);
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

//  for (i = 0; i <= 0xFFFF; i++) {
//    portWrite(REG_TEST, i);
//    d = portRead(REG_TEST);
    //Serial.print(d >> 12, HEX);
    //Serial.print((d >> 8) & 0xF, HEX);
    //Serial.print((d >> 4) & 0xF, HEX);
    //Serial.println(d & 0xF, HEX);
//    if (i == 0) Serial.println("Looped back");
//    if (d != i) Serial.println("Mismatch");
//  }

}
