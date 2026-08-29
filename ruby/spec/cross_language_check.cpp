// Host-side harness that exercises the EdgeSuite firmware headers with a plain
// g++ compiler (no Arduino core needed — the headers only use stdint/math).
//
// It encodes several sample batches with the firmware EdgeCompressor and prints
// each frame as a hex line. spec/cross_language_spec.rb compiles and runs this,
// then asserts the Ruby encoder produces the identical bytes — proving the two
// implementations share one wire format.
#include <cstdio>
#include "EdgeSuite.h"

using namespace edge;

// Build the same noisy byte stream the Ruby spec builds, push it through the
// firmware FrameStream, and print what came back out. Reassembly and
// resynchronisation have to agree across the two implementations too — not
// just the frame bytes — or a gateway and a node disagree about where frames
// begin after a burst of line noise.
static void frameStreamCheck() {
  uint8_t wire[1024];
  size_t n = 0;

  // 1. noise, including a lone false magic byte
  wire[n++] = 0xFF; wire[n++] = 0x00; wire[n++] = 0x45;

  // 2. a good frame
  int16_t a[] = {100, 101, 103, 106, 110};
  n += EdgeCompressor::encode(a, 5, 1, false, wire + n, sizeof(wire) - n);

  // 3. a frame corrupted in its body: the CRC must reject it
  int16_t flat[64];
  for (int i = 0; i < 64; i++) flat[i] = 512;
  size_t corruptAt = n + 10;
  n += EdgeCompressor::encode(flat, 64, 1, false, wire + n, sizeof(wire) - n);
  wire[corruptAt] ^= 0xFF;

  // 4. another good frame, which must still be recovered after the bad one
  int16_t mixed[] = {512, 512, 515, 515, 500};
  n += EdgeCompressor::encode(mixed, 5, 1, true, wire + n, sizeof(wire) - n);

  // 5. trailing false magic with an unusable version byte
  wire[n++] = 0x45; wire[n++] = 0x53; wire[n++] = 0x09;

  FrameStream<256> rx;
  for (size_t i = 0; i < n; i++) {
    if (!rx.push(wire[i])) continue;
    printf("rx ");
    for (uint16_t j = 0; j < rx.frameLength(); j++) printf("%02x", rx.frame()[j]);
    printf("\n");
  }
  printf("rxstats %lu %lu %lu\n", (unsigned long)rx.frames(),
         (unsigned long)rx.crcErrors(), (unsigned long)rx.droppedBytes());
}

// Segment the same series the Ruby spec uses and print the archived sample
// indices: the door decisions, which are what the two implementations must
// agree on for a device and a gateway to reconstruct the same signal.
static void swingingDoorCheck() {
  SwingingDoor door(2.0f, 0);
  printf("sd");
  for (uint32_t i = 0; i < 60; i++) {
    float v;
    if (i < 20) v = (float)(i * 10);           // steep ramp
    else if (i < 40) v = 190.0f;               // flat
    else v = (float)(190 - (int)(i - 40) * 7); // ramp back down
    if (door.update(i, v)) printf(" %lu", (unsigned long)door.pointTime());
  }
  if (door.flush()) printf(" %lu", (unsigned long)door.pointTime());
  printf("\n");
}

static void emit(const int16_t *s, uint16_t n, uint8_t ch, bool anomaly) {
  uint8_t frame[512];
  size_t len = EdgeCompressor::encode(s, n, ch, anomaly, frame, sizeof(frame));
  for (size_t i = 0; i < len; i++) printf("%02x", frame[i]);
  printf("\n");
}

int main() {
  int16_t ascending[] = {100, 101, 103, 106, 110};
  emit(ascending, 5, 1, false);

  int16_t flat[64];
  for (int i = 0; i < 64; i++) flat[i] = 512;
  emit(flat, 64, 1, false);

  int16_t mixed[] = {512, 512, 515, 515, 500};
  emit(mixed, 5, 1, true);

  int16_t extremes[] = {-32768, 32767, 0, -100, 100, -32768};
  emit(extremes, 6, 3, false);

  // Compression-defeating: alternating large deltas -> raw fallback.
  int16_t alt[40];
  for (int i = 0; i < 40; i++) alt[i] = (i % 2 == 0) ? 0 : 20000;
  emit(alt, 40, 2, false);

  frameStreamCheck();
  swingingDoorCheck();
  return 0;
}
