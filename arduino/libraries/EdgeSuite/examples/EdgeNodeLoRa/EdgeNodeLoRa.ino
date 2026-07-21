/*
 * EdgeNodeLoRa.ino - EdgeNode variant that ships frames over LoRa instead of
 * the USB serial line, for long-range, low-power fleets.
 *
 * Same on-device pipeline as EdgeNode.ino (anomaly detection -> adaptive
 * sampling -> batched compression); only the transport changes. Each frame is
 * sent as the raw bytes of a single LoRa packet — no hex expansion on air.
 *
 * Requires the "LoRa" library by Sandeep Mistry (Library Manager) and an
 * SX127x-class radio. Pair with LoRaGateway.ino, which receives these packets
 * and re-emits them as hex over Serial for the Ruby gateway's serial reader.
 */
#include <SPI.h>
#include <LoRa.h>
#include <EdgeSuite.h>

using namespace edge;

static const uint8_t  SENSOR_PIN = A0;
static const uint8_t  CHANNEL    = 1;
static const uint16_t BATCH      = 32;
static const long     LORA_FREQ  = 915E6; // set to 433E6 / 868E6 for your region

AnomalyDetector detector(0.1f, 3.5f, 20);
AdaptiveSampler sampler(50, 2000, 50.0f, 0.2f, 1.0f);

int16_t  batch[BATCH];
uint16_t batchLen = 0;
bool     batchAnomaly = false;
uint8_t  frame[128];

void flushBatch() {
  if (batchLen == 0) return;
  size_t n = EdgeCompressor::encode(batch, batchLen, CHANNEL, batchAnomaly,
                                    frame, sizeof(frame));
  if (n > 0) {
    LoRa.beginPacket();
    LoRa.write(frame, n);   // send the frame bytes verbatim
    LoRa.endPacket();       // blocking; returns when the packet is on air
  }
  batchLen = 0;
  batchAnomaly = false;
}

void setup() {
  Serial.begin(115200);
  if (!LoRa.begin(LORA_FREQ)) {
    Serial.println("LoRa init failed");
    while (true) {}
  }
}

void loop() {
  int16_t x = (int16_t)analogRead(SENSOR_PIN);

  bool anomaly = detector.update((float)x);
  uint32_t nextInterval = sampler.update((float)x, anomaly);

  batch[batchLen++] = x;
  if (anomaly) batchAnomaly = true;

  if (batchLen >= BATCH || (anomaly && batchLen >= 4)) {
    flushBatch();
  }

  delay(nextInterval);
}
