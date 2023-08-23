
#define PIN_RD 36
#define PIN_WR 37
#define ADDR0 10
#define ADDR1 12
#define ADDR2 11
#define ADDR3 13

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
}


void loop() {
  uint16_t d, i;
  // put your main code here, to run repeatedly:
  Serial.println("Hello3");
  delay(1000);
  return;
//  for (i = 0; i < 16; i++) {
//    d = portRead(i);
//    Serial.print(d >> 12, HEX);
//    Serial.print((d >> 8) & 0xF, HEX);
//    Serial.print((d >> 4) & 0xF, HEX);
//    Serial.println(d & 0xF, HEX);
// }

  for (i = 0; i <= 0xFFFF; i++) {
    portWrite(0, i);
    d = portRead(0);
    //Serial.print(d >> 12, HEX);
    //Serial.print((d >> 8) & 0xF, HEX);
    //Serial.print((d >> 4) & 0xF, HEX);
    //Serial.println(d & 0xF, HEX);
    if (i == 0) Serial.println("Looped back");
    if (d != i) Serial.println("Mismatch");
  }

}
