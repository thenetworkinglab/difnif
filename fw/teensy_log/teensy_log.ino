// DifNif FPGA-only build: the Teensy as the log's USB serial port
//
// The processor build (make BOARD=ps2 CPU=1) sends its log at 1 Mbaud on
// Teensy data line 7, which is this Teensy's pin 16, Serial4's input, and
// listens on pin 17 (Serial4's output). This copies Serial4 to the USB
// serial port and back. Every other pin stays an input, as the processor
// build expects. Don't run it with the normal (Teensy) FPGA build.
//
// This file is part of a fork of DifNif; CERN-OHL-S-2.0.

void setup() {
    Serial.begin(115200);       // USB: the speed is ignored
    Serial4.begin(1000000);
}

void loop() {
    while (Serial4.available()) Serial.write(Serial4.read());
    while (Serial.available()) Serial4.write(Serial.read());
}
