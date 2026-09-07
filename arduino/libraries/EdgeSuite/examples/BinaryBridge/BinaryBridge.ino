/*
 * BinaryBridge - turn a noisy binary link into clean frames.
 *
 * A gateway MCU sits between a radio (or a second UART) and a host. What
 * arrives is bytes, not messages: reads land mid-frame, noise appears between
 * frames, and a flipped bit corrupts one now and then. FrameStream absorbs all
 * of that and hands up only whole, CRC-valid frames — then this sketch
 * forwards each as a hex line, which is exactly what `ruby bin/edge-gateway`
 * reads on stdin.
 *
 * Binary on the radio, hex on the USB side: the constrained link carries half
 * the bytes, and the host side stays greppable and line-oriented.
 *
 * Nothing is decoded here. Validating and forwarding is O(1) memory per byte,
 * so a bridge with 2 kB of RAM can relay frames it could never hold in full.
 * The counters printed every 10 s are the link's health: dropped bytes and CRC
 * errors climb long before frames stop arriving, which is the warning you want
 * from an antenna that is slowly going bad.
 *
 * Wiring: radio/sensor link on Serial1, host on Serial.
 */
#include <EdgeSuite.h>

using namespace edge;

// 256 B holds any frame this fleet sends; anything longer is corruption, and
// FrameStream rejects it instead of waiting for bytes that will never come.
FrameStream<256> rx;

uint32_t lastReport = 0;

void forward(const uint8_t *frame, uint16_t len) {
  for (uint16_t i = 0; i < len; i++) {
    if (frame[i] < 0x10) Serial.print('0');
    Serial.print(frame[i], HEX);
  }
  Serial.println();
}

void setup() {
  Serial.begin(115200);
  Serial1.begin(9600); // the constrained side: LoRa module, RS-485, sensor bus
  while (!Serial) {}
}

void loop() {
  while (Serial1.available()) {
    if (rx.push((uint8_t)Serial1.read())) {
      // The frame header is readable without decoding the body: channel and
      // the anomaly flag are enough to prioritise a batch on the way through.
      const uint8_t *f = rx.frame();
      if (f[4] & ES_FLAG_ANOMALY) {
        Serial.print("# anomaly on channel ");
        Serial.println(f[3]);
      }
      forward(f, rx.frameLength());
    }
  }

  uint32_t now = millis();
  if ((uint32_t)(now - lastReport) >= 10000) {
    lastReport = now;
    Serial.print("# link frames=");
    Serial.print(rx.frames());
    Serial.print(" dropped=");
    Serial.print(rx.droppedBytes());
    Serial.print(" crc_err=");
    Serial.print(rx.crcErrors());
    Serial.print(" resyncs=");
    Serial.println(rx.resyncs());
  }
}
