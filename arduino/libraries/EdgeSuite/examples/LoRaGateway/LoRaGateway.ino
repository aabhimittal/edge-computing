/*
 * LoRaGateway.ino - LoRa-to-Serial bridge.
 *
 * Receives EdgeSuite frames sent by EdgeNodeLoRa nodes and re-emits each one as
 * a hex line over USB Serial — the exact format the Ruby gateway's serial
 * transport expects:
 *
 *     ruby ruby/bin/edge-gateway --serial /dev/ttyUSB0 --persist ./stats
 *
 * So a bare radio + this sketch turns a long-range LoRa fleet into the same
 * hex-frame stream a directly-wired EdgeNode produces. No EdgeSuite decoding
 * happens here; the bridge just forwards bytes, keeping it tiny and transport-
 * agnostic. Requires the "LoRa" library by Sandeep Mistry and an SX127x radio.
 */
#include <SPI.h>
#include <LoRa.h>

static const long LORA_FREQ = 915E6; // match the nodes' region setting

void setup() {
  Serial.begin(115200);
  while (!Serial) {}
  if (!LoRa.begin(LORA_FREQ)) {
    Serial.println("LoRa init failed");
    while (true) {}
  }
}

void loop() {
  int packetSize = LoRa.parsePacket();
  if (packetSize <= 0) return;

  // Print the packet's bytes as a single hex line terminated by newline.
  while (LoRa.available()) {
    uint8_t b = (uint8_t)LoRa.read();
    if (b < 16) Serial.print('0');
    Serial.print(b, HEX);
  }
  Serial.println();
}
