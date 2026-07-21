/*
 * EdgeNode.ino - Reference edge node using all three EdgeSuite primitives.
 *
 * Pipeline per loop:
 *   1. Read a sensor sample (analog pin here; swap for your transducer).
 *   2. Run streaming anomaly detection on it.
 *   3. Ask the adaptive sampler how long to wait before the next sample.
 *   4. Buffer samples; when the batch fills (or an anomaly occurs) compress
 *      the batch into a frame and stream it out over Serial as hex.
 *
 * The emitted frames are consumed by the Ruby gateway:
 *   ruby ruby/bin/edge-gateway            # reads hex frames from stdin
 * or exercised end-to-end without hardware via ruby/bin/edge-sim.
 */
#include <EdgeSuite.h>

using namespace edge;

static const uint8_t  SENSOR_PIN = A0;
static const uint8_t  CHANNEL    = 1;
static const uint16_t BATCH      = 32;

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
    for (size_t i = 0; i < n; i++) {
      if (frame[i] < 16) Serial.print('0');
      Serial.print(frame[i], HEX);
    }
    Serial.println();
  }
  batchLen = 0;
  batchAnomaly = false;
}

void setup() {
  Serial.begin(115200);
  while (!Serial) {}
}

void loop() {
  int16_t x = (int16_t)analogRead(SENSOR_PIN);

  bool anomaly = detector.update((float)x);
  uint32_t nextInterval = sampler.update((float)x, anomaly);

  batch[batchLen++] = x;
  if (anomaly) batchAnomaly = true;

  // Flush when the buffer is full or an anomaly should be reported promptly.
  if (batchLen >= BATCH || (anomaly && batchLen >= 4)) {
    flushBatch();
  }

  delay(nextInterval);
}
