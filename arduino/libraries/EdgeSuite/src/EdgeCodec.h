/*
 * EdgeCodec.h - Low-level wire primitives shared by the whole EdgeSuite.
 *
 * These primitives define the on-the-wire contract that the Ruby gateway
 * (ruby/lib/edge_suite/codec.rb) mirrors byte-for-byte. Keep the two in sync:
 * any change here must be reflected there, or frames will fail to decode.
 *
 *   - LEB128 unsigned varint (little-endian, 7 bits/byte, MSB = continuation)
 *   - 32-bit zigzag mapping of signed deltas to unsigned
 *   - CRC-8/SMBUS (poly 0x07, init 0x00) for frame integrity
 *
 * No dynamic allocation: callers pass fixed buffers and a cursor.
 */
#ifndef EDGE_CODEC_H
#define EDGE_CODEC_H

#include <stdint.h>
#include <stddef.h>

namespace edge {

// Map a signed 32-bit value onto an unsigned one so small magnitudes (of
// either sign) become small unsigned numbers that varint-encode compactly.
inline uint32_t zigzagEncode(int32_t v) {
  return (uint32_t)((v << 1) ^ (v >> 31));
}

inline int32_t zigzagDecode(uint32_t u) {
  return (int32_t)(u >> 1) ^ -(int32_t)(u & 1);
}

// Append an unsigned LEB128 varint to buf at *pos. Returns false on overflow.
inline bool putVarint(uint8_t *buf, size_t cap, size_t *pos, uint32_t value) {
  do {
    if (*pos >= cap) return false;
    uint8_t byte = value & 0x7F;
    value >>= 7;
    if (value) byte |= 0x80;
    buf[(*pos)++] = byte;
  } while (value);
  return true;
}

// Read an unsigned LEB128 varint from buf at *pos. Returns false on overflow
// or malformed (over 5 bytes) input.
inline bool getVarint(const uint8_t *buf, size_t len, size_t *pos, uint32_t *out) {
  uint32_t result = 0;
  uint8_t shift = 0;
  while (shift <= 28) {
    if (*pos >= len) return false;
    uint8_t byte = buf[(*pos)++];
    result |= (uint32_t)(byte & 0x7F) << shift;
    if (!(byte & 0x80)) { *out = result; return true; }
    shift += 7;
  }
  return false; // more than 5 bytes: malformed
}

// CRC-8/SMBUS over a byte range. Incrementally seed with prior crc for chaining.
inline uint8_t crc8(const uint8_t *data, size_t len, uint8_t crc = 0x00) {
  for (size_t i = 0; i < len; i++) {
    crc ^= data[i];
    for (uint8_t b = 0; b < 8; b++) {
      crc = (crc & 0x80) ? (uint8_t)((crc << 1) ^ 0x07) : (uint8_t)(crc << 1);
    }
  }
  return crc;
}

} // namespace edge

#endif // EDGE_CODEC_H
