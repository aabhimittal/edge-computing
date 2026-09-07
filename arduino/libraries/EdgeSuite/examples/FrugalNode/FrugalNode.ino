/*
 * FrugalNode - send only the samples that carry information.
 *
 * EdgeNode.ino batches every reading and compresses the batch. This sketch
 * adds the step before that: a SwingingDoor decides which readings are worth
 * keeping at all, guaranteeing the gateway can rebuild the signal to within
 * `kDeviation` units by drawing straight lines between what it receives.
 *
 * On a slow real-world signal (temperature, tank level, battery voltage) that
 * is usually a 10-50x cut in points, on top of the ~2-4x the frame codec
 * gives — and it happens before the radio is powered up, which is where the
 * energy actually goes.
 *
 * The anomaly path is deliberately not filtered: an outlier is archived
 * immediately and flushes the batch, so an event never waits for the door to
 * close. The heartbeat guarantees a point every kHeartbeatMs even if the
 * signal never moves, so the gateway can tell "quiet" from "dead".
 *
 * Wiring: analog sensor on A0. Output: hex frames on Serial, one per line —
 * feed straight into `ruby bin/edge-gateway`.
 */
#include <EdgeSuite.h>

using namespace edge;

static const uint8_t kChannel = 1;
static const float kDeviation = 2.0f;        // max reconstruction error (ADC counts)
static const uint32_t kHeartbeatMs = 30000;  // never go quiet longer than this
static const uint16_t kBatchSize = 16;       // archived points per frame

SwingingDoor door(kDeviation, kHeartbeatMs);
AnomalyDetector detector(0.1f, 3.5f, 20);
AdaptiveSampler sampler(50, 2000);

int16_t batch[kBatchSize];
uint16_t batchLen = 0;
bool batchAnomaly = false;
uint32_t nextSampleAt = 0;
uint32_t seen = 0, kept = 0;

void sendBatch() {
  if (batchLen == 0) return;

  uint8_t frame[192];
  size_t len = EdgeCompressor::encode(batch, batchLen, kChannel, batchAnomaly,
                                      frame, sizeof(frame));
  if (len) {
    for (size_t i = 0; i < len; i++) {
      if (frame[i] < 0x10) Serial.print('0');
      Serial.print(frame[i], HEX);
    }
    Serial.println();
  }
  batchLen = 0;
  batchAnomaly = false;
}

void keep(int16_t value, bool anomaly) {
  kept++;
  batch[batchLen++] = value;
  if (anomaly) batchAnomaly = true;
  // Flush on a full batch, or straight away if this point is an event.
  if (batchLen >= kBatchSize || anomaly) sendBatch();
}

void setup() {
  Serial.begin(115200);
  while (!Serial) {}
}

void loop() {
  uint32_t now = millis();
  if ((int32_t)(now - nextSampleAt) < 0) return;

  int16_t raw = (int16_t)analogRead(A0);
  seen++;

  bool anomaly = detector.update((float)raw);
  nextSampleAt = now + sampler.update((float)raw, anomaly);

  // The door archives the *previous* sample when this one closes a segment.
  if (door.update(now, (float)raw)) keep((int16_t)door.pointValue(), false);

  // An outlier bypasses the door: close the open segment and send now.
  if (anomaly) {
    if (door.flush()) keep((int16_t)door.pointValue(), false);
    keep(raw, true);
  }

  // Every 500 readings, report how much of the stream never had to be sent.
  if (seen % 500 == 0) {
    Serial.print("# kept ");
    Serial.print(kept);
    Serial.print('/');
    Serial.println(seen);
  }
}
