// DifNif bench test
//
// Checks the link between the Teensy and the FPGA with the board on the
// bench, powered from the Teensy's USB port and NOT plugged into a PS/2.
// The FPGA must already be programmed (make BOARD=ps2; make prog BOARD=ps2).
//
// Load this with the Arduino IDE (Teensy 4.1), open the Serial Monitor, and
// the tests run once. Send 'r' to run them again.
//
// What it checks:
//   1. The FPGA drives the bus when read (it's configured and RD works)
//   2. All 16 data lines, through the FPGA's scratch register (REG_TEST)
//   3. All 4 address lines, against registers with known contents
//   4. The FPGA's version registers (and prints the version)
//   5. The Teensy-owned flag bits, and the sector buffer's (if the FPGA has it)
//   6. The FPGA's 50 MHz clock, through a flag set by clocked logic
//   7. The interrupt line from the FPGA
//   8. A long run of random writes and reads at difnift.ino's timing, plus
//      the same with more write setup time and shorter read strobes
//
// Pin assignments are the same as difnift.ino. Teensy pins and FPGA pins
// for each signal come from verilog/difnif.pcf and the pcb_formfactor
// schematic; both boards wire the Teensy to the FPGA identically.
//
// This file is part of a fork of DifNif; CERN-OHL-S-2.0.

#define PIN_RD 36
#define PIN_WR 37
#define PIN_INT 29

// Address lines: Teensy pin for tn_addr[0..3]
const int addrpin[4] = {10, 12, 11, 13};
const int addrfpga[4] = {24, 20, 22, 19};

// Data lines: data bit i is GPIO6 bit 16+i
const int datapin[16] = {19, 18, 14, 15, 40, 41, 17, 16, 22, 23, 20, 21, 38, 39, 26, 27};
const int datafpga[16] = {29, 28, 21, 23, 17, 18, 26, 25, 33, 34, 31, 32, 11, 16, 15, 12};

#define DPORT_MASK (0xFFFF0000)

// FPGA registers (teensy.v)
#define REG_TEST 0
#define REG_FLAGS 1
#define REG_ISR 3
#define REG_SIFR 5
#define REG_POS01 7
#define REG_POS23 8
#define REG_POS4 9
#define REG_VER_YEAR 10   // FPGA version, BCD (verilog/version.vh)
#define REG_VER_DATE 11
#define REG_VER_COUNT 12
#define REG_VARIANT 13    // 1 = make BOARD=ps2, 0 = ThinkPad build
#define REG_CTRL 15       // bit 0: burst DMA allowed (v2026.11.19-1 and later); bit 2: DMA
                          // waits for the interrupt (v2026.11.21-1); with no host the other
                          // bits read 0, and older builds read 0 throughout

// Flag register bits
#define FLAG_ISR_FULL 1
#define FLAG_HARD_RESET 4
#define FLAG_TREQ_SET 5   // write-only, reads 0
#define FLAG_CMD_PROG 6
#define FLAG_BUSY_N 7     // reads 1; writing 0 clears busy
#define FLAG_CLEAR_ALL 10
#define FLAG_BUF_MODE 11    // sector buffer (FPGA v2026.11.18-3 and later)
#define FLAG_BUF_DIR 12
#define FLAGS_IDLE (1 << FLAG_BUSY_N)   // safe value to write: no actions

// Bus timing. difnift.ino uses a 200 ns read strobe and no extra setup time
// between putting data on the bus and raising WR.
uint32_t rd_ns = 200;
uint32_t wr_setup_ns = 0;

int failures;
int warnings;


void setAddr(uint8_t a)
{
  for (int i = 0; i < 4; i++) {
    digitalWriteFast(addrpin[i], (a >> i) & 1);
  }
}


// Read a value from the FPGA port, as difnift.ino does
uint16_t portRead(uint8_t a)
{
  uint16_t ret;
  setAddr(a);
  digitalWriteFast(PIN_RD, 1);
  delayNanoseconds(rd_ns);
  ret = GPIO6_PSR >> 16;
  digitalWriteFast(PIN_RD, 0);
  return ret;
}


// Write a value to the FPGA port, as difnift.ino does (with optional setup)
void portWrite(uint8_t a, uint16_t d)
{
  setAddr(a);
  GPIO6_GDIR |= DPORT_MASK;
  GPIO6_DR = (GPIO6_DR & 0xFFFF) | ((uint32_t)d << 16);
  if (wr_setup_ns) {
    delayNanoseconds(wr_setup_ns);
  }
  digitalWriteFast(PIN_WR, 1);
  delayNanoseconds(200);
  digitalWriteFast(PIN_WR, 0);
  GPIO6_GDIR &= ~DPORT_MASK;
}


// Leaves the opposite of the expected value on the bus, so that a line the
// FPGA isn't driving reads wrong instead of keeping the value just written
void precharge(uint16_t expected)
{
  portWrite(REG_CTRL, ~expected);
}


void clearAll()
{
  portWrite(REG_FLAGS, FLAGS_IDLE | (1 << FLAG_CLEAR_ALL));
  delayMicroseconds(2);
  portWrite(REG_FLAGS, FLAGS_IDLE);
  delayMicroseconds(2);
}


void print16hex(uint16_t v)
{
  char s[8];
  sprintf(s, "%04X", v);
  Serial.print(s);
}


void printBits(uint16_t bits)
{
  for (int i = 0; i < 16; i++) {
    if (bits & (1 << i)) {
      Serial.print("    D");
      Serial.print(i);
      Serial.print(": Teensy pin ");
      Serial.print(datapin[i]);
      Serial.print(", FPGA pin ");
      Serial.println(datafpga[i]);
    }
  }
}


void pass(const char *name)
{
  Serial.print("PASS  ");
  Serial.println(name);
}


void fail(const char *name)
{
  Serial.print("FAIL  ");
  Serial.println(name);
  failures++;
}


void warn(const char *name)
{
  Serial.print("WARN  ");
  Serial.println(name);
  warnings++;
}


// 1. Is the FPGA there and driving the bus?
bool testAlive()
{
  uint16_t first, a, b;

  first = portRead(REG_TEST);
  Serial.print("      REG_TEST reads ");
  print16hex(first);
  if (first == 0xABCD) {
    Serial.println(" (its power-up value: the FPGA was freshly configured)");
  } else {
    Serial.println(" (keeps its value until the FPGA is reconfigured, fine on a re-run)");
  }

  // Register 15 must read 0 in bits 15-1 whatever was left on the bus (bit 0
  // reads back what was written, on builds that have it)
  precharge(0x0000);
  a = portRead(REG_CTRL);
  portWrite(REG_CTRL, 0x0000);
  b = portRead(REG_CTRL);
  if ((a & 0xFFFA) == 0x0000 && b == 0x0000) {
    pass("FPGA drives the bus on reads");
    return true;
  }
  fail("FPGA drives the bus on reads");
  Serial.print("      register 15 read ");
  print16hex(a);
  Serial.print(" (bus left at FFFF; should be 0000, 0001, 0004 or 0005), then ");
  print16hex(b);
  Serial.println(" (bus left at 0000; should be 0000)");
  Serial.println("      If these just echo what was left on the bus, the FPGA isn't driving it:");
  Serial.println("      check CDONE (J2 pin 2) is high (3.3 V), and the RD line (Teensy pin 36, FPGA pin 143).");
  return false;
}


// 2. Data lines, through the scratch register
bool checkWord(uint16_t w, uint16_t &stuck0, uint16_t &stuck1, bool show)
{
  uint16_t r;
  portWrite(REG_TEST, w);
  precharge(w);
  r = portRead(REG_TEST);
  stuck0 |= w & ~r;    // should have read 1
  stuck1 |= ~w & r;    // should have read 0
  if (r != w && show) {
    Serial.print("      wrote ");
    print16hex(w);
    Serial.print(", read ");
    print16hex(r);
    Serial.println();
  }
  return r == w;
}


void testData()
{
  uint16_t stuck0 = 0, stuck1 = 0;
  int bad = 0;
  int shown = 0;
  const uint16_t fixed[] = {0x0000, 0xFFFF, 0xAAAA, 0x5555, 0x00FF, 0xFF00, 0x0F0F, 0xF0F0};

  for (unsigned i = 0; i < sizeof(fixed) / sizeof(fixed[0]); i++) {
    if (!checkWord(fixed[i], stuck0, stuck1, shown < 12)) { bad++; shown++; }
  }
  for (int i = 0; i < 16; i++) {
    // Walking one, then walking zero: a short between two lines shows up as
    // an extra bit set (or cleared) next to the one being tested
    if (!checkWord(1 << i, stuck0, stuck1, shown < 12)) { bad++; shown++; }
    if (!checkWord(~(1 << i), stuck0, stuck1, shown < 12)) { bad++; shown++; }
  }

  if (bad == 0) {
    pass("data lines D0-D15 (walking ones and zeros, fixed patterns)");
    return;
  }
  fail("data lines D0-D15");
  if (stuck0) {
    Serial.println("      lines that failed to read 1:");
    printBits(stuck0);
  }
  if (stuck1) {
    Serial.println("      lines that failed to read 0:");
    printBits(stuck1);
  }
  Serial.println("      Look for an unsoldered pin or a solder bridge at those Teensy socket and FPGA pins.");
}


// Is v a BCD number from lo to hi?
bool bcdInRange(uint16_t v, int digits, int lo, int hi)
{
  int n = 0;
  for (int i = digits - 1; i >= 0; i--) {
    int d = (v >> (4 * i)) & 0xF;
    if (d > 9) return false;
    n = n * 10 + d;
  }
  return (v >> (4 * digits)) == 0 && n >= lo && n <= hi;
}


// 4. The FPGA's version registers
void testVersion()
{
  uint16_t r[4];
  for (int i = 0; i < 4; i++) {
    precharge(0);
    r[i] = portRead(REG_VER_YEAR + i);
  }
  if (r[0] == 0 && r[1] == 0 && r[2] == 0 && r[3] == 0) {
    warn("FPGA has no version registers: an FPGA build from before v2026.11.18-1");
    return;
  }
  bool ok = bcdInRange(r[0], 4, 2026, 2099) &&
            bcdInRange(r[1] >> 8, 2, 1, 12) && bcdInRange(r[1] & 0xFF, 2, 1, 31) &&
            bcdInRange(r[2], 4, 1, 9999) && r[3] <= 1;
  if (!ok) {
    fail("FPGA version registers");
    Serial.print("      read ");
    for (int i = 0; i < 4; i++) {
      print16hex(r[i]);
      Serial.print(i < 3 ? " " : "");
    }
    Serial.println(" at 10-13; expected a BCD year, month and day, count, then 0 or 1");
    return;
  }
  char s[64];
  sprintf(s, "FPGA version v%04X.%02X.%02X-%X (%s)", r[0], r[1] >> 8, r[1] & 0xFF, r[2],
          r[3] ? "ps2" : "thinkpad");
  pass(s);
}


// 3. Address lines, against registers with known contents
void testAddress()
{
  // Known, distinct values; 0 is left out of the diagnosis because several
  // registers read 0
  uint16_t known[16];
  bool have[16];
  int bad = 0;
  uint16_t pos23;

  for (int i = 0; i < 16; i++) { known[i] = 0; have[i] = false; }

  clearAll();
  portWrite(REG_TEST, 0x1234);
  portWrite(REG_ISR, 0x00A5);   // 8-bit register
  portWrite(REG_SIFR, 0x5A3C);
  clearAll();                   // drop the "full" flags those writes set

  known[REG_TEST] = 0x1234; have[REG_TEST] = true;
  known[REG_ISR] = 0x00A5; have[REG_ISR] = true;
  known[REG_SIFR] = 0x5A3C; have[REG_SIFR] = true;
  known[REG_POS01] = 0xDF9F; have[REG_POS01] = true;   // adapter ID, fixed in the FPGA
  // 10-13 hold the FPGA version, checked by testVersion()
  for (int a = 14; a < 16; a++) { known[a] = 0x0000; have[a] = true; }

  const uint8_t addrs[] = {0, 1, 3, 5, 7, 14, 15};
  for (unsigned i = 0; i < sizeof(addrs); i++) {
    uint8_t a = addrs[i];
    uint16_t v;
    bool ok;
    uint16_t exp = (a == REG_FLAGS) ? 0 : known[a];

    precharge(exp);
    v = portRead(a);
    if (a == REG_FLAGS) {
      // Bit 7 always reads 1, bit 5 and bits 11-15 always read 0
      ok = (v & 0xF8A0) == 0x0080 && v != 0x1234;
    } else if (a == REG_CTRL) {
      // Bits 0 and 2 hold what precharge() just wrote there (control bits)
      ok = (v & 0xFFFA) == 0x0000;
    } else {
      ok = (v == known[a]);
    }
    if (ok) continue;

    bad++;
    Serial.print("      address ");
    Serial.print(a);
    Serial.print(" read ");
    print16hex(v);
    if (a == REG_FLAGS) {
      Serial.print(", expected the flag register (bit 7 set)");
    } else {
      Serial.print(", expected ");
      print16hex(known[a]);
    }
    // Does it look like another address's contents?
    for (int k = 0; k < 4; k++) {
      uint8_t b = a ^ (1 << k);
      if (have[b] && known[b] != 0 && v == known[b]) {
        Serial.print(" -- that's address ");
        Serial.print(b);
        Serial.print("'s value: suspect ADDR");
        Serial.print(k);
        Serial.print(" (Teensy pin ");
        Serial.print(addrpin[k]);
        Serial.print(", FPGA pin ");
        Serial.print(addrfpga[k]);
        Serial.print(")");
      }
    }
    Serial.println();
  }

  if (bad == 0) {
    pass("address lines ADDR0-ADDR3, and the DF9F adapter ID");
  } else {
    fail("address lines ADDR0-ADDR3");
  }

  // Which FPGA build is this? POS 2 starts at 78 with POS on, 79 without.
  precharge(0);
  pos23 = portRead(REG_POS23);
  if (pos23 == 0x0078) {
    pass("FPGA build has POS enabled (make BOARD=ps2)");
  } else if (pos23 == 0x0079) {
    warn("FPGA build has POS bypassed (the ThinkPad build): use make BOARD=ps2");
  } else {
    Serial.print("WARN  POS 2/3 read ");
    print16hex(pos23);
    Serial.println(", expected 0078. The PS/2-side inputs float on the bench, so this can be noise.");
    warnings++;
  }
}


// 5. Teensy-owned flag bits
void testFlags()
{
  uint16_t on, off;

  portWrite(REG_FLAGS, FLAGS_IDLE | (1 << FLAG_CMD_PROG));
  on = portRead(REG_FLAGS);
  portWrite(REG_FLAGS, FLAGS_IDLE);
  off = portRead(REG_FLAGS);

  if ((on & (1 << FLAG_CMD_PROG)) && !(off & (1 << FLAG_CMD_PROG))) {
    pass("flag register: command-in-progress bit writes and reads back");
  } else {
    fail("flag register: command-in-progress bit");
    Serial.print("      read ");
    print16hex(on);
    Serial.print(" with bit 6 set, ");
    print16hex(off);
    Serial.println(" with it clear");
  }
}


// 5b. The sector buffer's flag bits. Moving data through it needs a host,
// so on the bench this only checks the mode, direction and status bits.
void testBufferFlags()
{
  uint16_t on_rd, on_wr, off;
  clearAll();
  portWrite(REG_FLAGS, FLAGS_IDLE | (1 << FLAG_BUF_MODE));
  delayMicroseconds(1);
  on_rd = portRead(REG_FLAGS);
  if (!(on_rd & (1 << FLAG_BUF_MODE))) {
    Serial.println("      no sector buffer in this FPGA build (older than v2026.11.18-3)");
    portWrite(REG_FLAGS, FLAGS_IDLE);
    return;
  }
  portWrite(REG_FLAGS, FLAGS_IDLE | (1 << FLAG_BUF_MODE) | (1 << FLAG_BUF_DIR));
  delayMicroseconds(1);
  on_wr = portRead(REG_FLAGS);
  portWrite(REG_FLAGS, FLAGS_IDLE);
  delayMicroseconds(1);
  off = portRead(REG_FLAGS);
  // Bits 15-11: idle, can arm / -, ready, dir, mode
  if ((on_rd >> 11) == 0x15 && (on_wr >> 11) == 0x1B && (off >> 11) == 0 &&
      portRead(14) == 0) {
    pass("sector buffer flags (disk read and write modes, and off)");
  } else {
    fail("sector buffer flags");
    Serial.print("      flags ");
    print16hex(on_rd);
    Serial.print(" for disk read (bits 15-11 should be 10101), ");
    print16hex(on_wr);
    Serial.print(" for disk write (11011), ");
    print16hex(off);
    Serial.println(" off (00000)");
  }
}


// 5c. Burst DMA control (register 15 bit 0). Bursts need a host, so on the
// bench this only checks the bit can be set and cleared.
void testBurstCtrl()
{
  uint16_t on, off;
  portWrite(REG_CTRL, 0x0001);
  on = portRead(REG_CTRL);
  portWrite(REG_CTRL, 0x0000);
  off = portRead(REG_CTRL);
  if (on == 0x0000 && off == 0x0000) {
    Serial.println("      no burst DMA control in this FPGA build (older than v2026.11.19-1)");
  } else if (on == 0x0001 && off == 0x0000) {
    pass("burst DMA control bit (register 15)");
  } else {
    fail("burst DMA control bit (register 15)");
    Serial.print("      read ");
    print16hex(on);
    Serial.print(" after writing 0001, ");
    print16hex(off);
    Serial.println(" after writing 0000");
  }
}


// 6. The FPGA's clock: the ISR "full" flag is set by logic clocked at 50 MHz
void testClock()
{
  uint16_t f0, f1, f2;

  f0 = portRead(REG_FLAGS);
  if (f0 & (1 << FLAG_HARD_RESET)) {
    warn("clock test skipped: the hard-reset flag is set, which holds all flags clear");
    return;
  }

  clearAll();
  f0 = portRead(REG_FLAGS);
  portWrite(REG_ISR, 0x00A5);
  delayMicroseconds(5);
  f1 = portRead(REG_FLAGS);
  clearAll();
  f2 = portRead(REG_FLAGS);

  if (!(f0 & (1 << FLAG_ISR_FULL)) && (f1 & (1 << FLAG_ISR_FULL)) && !(f2 & (1 << FLAG_ISR_FULL))) {
    pass("FPGA clock running (ISR flag set and cleared by clocked logic)");
    Serial.println("      LED D2 should be flickering about 12 times a second; on the scope, the");
    Serial.println("      FPGA end of R13 should be an 11.92 Hz square wave (50 MHz / 2^22).");
  } else {
    fail("FPGA clock");
    Serial.print("      flags ");
    print16hex(f0);
    Serial.print(" before, ");
    print16hex(f1);
    Serial.print(" after writing ISR (bit 1 should set), ");
    print16hex(f2);
    Serial.println(" after clear-all");
    Serial.println("      Check the oscillator with the scope: 10 MHz at X1 pin 3 (through R3 to FPGA pin 49).");
  }
}


// 7. Interrupt line: the FPGA drives it low unless the host has written ATN.
// With the Teensy's pull-up on, an open line reads high. The PS/2-side
// inputs float on the bench and could fake a host write, so try 3 times.
void testInt()
{
  int v = 1;
  pinMode(PIN_INT, INPUT_PULLUP);
  for (int i = 0; i < 3 && v; i++) {
    clearAll();
    delayMicroseconds(10);
    v = digitalReadFast(PIN_INT);
  }
  pinMode(PIN_INT, INPUT);
  if (v == 0) {
    pass("interrupt line driven low by the FPGA (it can only go high from a PS/2)");
  } else {
    fail("interrupt line reads high with the pull-up on: check Teensy pin 29 to FPGA pin 144");
  }
}


// 8. Many random words; returns the number of mismatches
uint32_t rng = 0x12345678;
uint16_t nextRandom()
{
  rng ^= rng << 13;
  rng ^= rng >> 17;
  rng ^= rng << 5;
  return rng & 0xFFFF;
}


uint32_t soak(uint32_t n, uint16_t &badbits)
{
  uint32_t errors = 0;
  uint16_t s0 = 0, s1 = 0;
  badbits = 0;
  for (uint32_t i = 0; i < n; i++) {
    uint16_t w = nextRandom();
    if (!checkWord(w, s0, s1, false)) errors++;
  }
  badbits = s0 | s1;
  return errors;
}


void testSoak()
{
  const uint32_t n = 200000;
  uint32_t e;
  uint16_t bits;

  rd_ns = 200; wr_setup_ns = 0;
  e = soak(n, bits);
  if (e == 0) {
    pass("200,000 random writes and reads at difnift.ino's timing");
  } else {
    fail("random writes and reads at difnift.ino's timing");
    Serial.print("      ");
    Serial.print(e);
    Serial.println(" of 200000 wrong; lines involved:");
    printBits(bits);
  }

  // For information: does it get better with setup time, or worse with a
  // shorter read strobe? Errors only here point at timing, not soldering.
  Serial.println("      timing margin (errors in 50,000 each):");
  const uint32_t setups[] = {0, 20, 50};
  const uint32_t reads[] = {200, 100, 50, 25};
  for (unsigned i = 0; i < 3; i++) {
    for (unsigned j = 0; j < 4; j++) {
      wr_setup_ns = setups[i];
      rd_ns = reads[j];
      e = soak(50000, bits);
      Serial.print("        write setup ");
      Serial.print(setups[i]);
      Serial.print(" ns, read strobe ");
      Serial.print(reads[j]);
      Serial.print(" ns: ");
      Serial.println(e);
    }
  }
  rd_ns = 200;
  wr_setup_ns = 0;
}


void runAll()
{
  failures = 0;
  warnings = 0;
  Serial.println();
  Serial.println("DifNif bench test. Bench only: don't run this with the board in a PS/2.");
  Serial.println();

  if (!testAlive()) {
    Serial.println();
    Serial.println("Stopping: nothing else can be tested until the FPGA answers.");
    return;
  }
  testData();
  testAddress();
  testVersion();
  testFlags();
  testBufferFlags();
  testBurstCtrl();
  testClock();
  testInt();
  testSoak();

  // Leave the FPGA idle, with burst DMA not allowed (the tests above leave
  // test values in register 15)
  clearAll();
  portWrite(REG_CTRL, 0x0000);

  Serial.println();
  Serial.print("Done: ");
  Serial.print(failures);
  Serial.print(" failed, ");
  Serial.print(warnings);
  Serial.println(" warnings. Send 'r' to run again.");
}


void setup()
{
  Serial.begin(115200);
  while (!Serial && millis() < 5000) {
    // Wait up to 5 s for the Serial Monitor
  }

  pinMode(PIN_RD, OUTPUT);
  pinMode(PIN_WR, OUTPUT);
  digitalWriteFast(PIN_RD, 0);
  digitalWriteFast(PIN_WR, 0);
  pinMode(PIN_INT, INPUT);
  for (int i = 0; i < 4; i++) {
    pinMode(addrpin[i], OUTPUT);
  }
  for (int i = 0; i < 16; i++) {
    pinMode(datapin[i], INPUT);
  }

  runAll();
}


void loop()
{
  if (Serial.available() > 0) {
    if (Serial.read() == 'r') {
      runAll();
    }
  }
}
