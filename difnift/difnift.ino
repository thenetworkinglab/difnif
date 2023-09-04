
#define PIN_RD 36
#define PIN_WR 37
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

const int portpin[] = {27, 26, 39, 38,
                        21, 20, 23, 22,
                        16, 17, 41, 40,
                        15, 14, 18, 19};

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
  pinMode(ADDR0, OUTPUT);
  pinMode(ADDR1, OUTPUT);
  pinMode(ADDR2, OUTPUT);
  pinMode(ADDR3, OUTPUT);

  Serial.println("Press 'f' for flag register contents.");
  Serial.println("Press 'a' for ATN register contents.");
  Serial.println("Press 'i' to write to ISR and trig an interrupt.");
  Serial.println("Press 'c' to read Command Interface Reg.");
  Serial.println("Press 's' to write Status Interface Reg.");
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

void loop() {
  uint16_t d, i;
  uint8_t cmd;
  // put your main code here, to run repeatedly:

  if (Serial.available() > 0) {
    cmd = Serial.read();

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
