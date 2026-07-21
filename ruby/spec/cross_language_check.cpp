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

  return 0;
}
