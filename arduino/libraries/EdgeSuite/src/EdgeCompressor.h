/*
 * EdgeCompressor.h - Frame encoder: turn a batch of int16 samples into a
 * compact, self-describing, CRC-protected frame ready for the radio/serial.
 *
 * Wire format (mirrored by ruby/lib/edge_suite/frame.rb):
 *
 *   offset  size  field
 *   0       1     magic 'E' (0x45)
 *   1       1     magic 'S' (0x53)
 *   2       1     version (currently 1)
 *   3       1     channel id (application-defined stream id)
 *   4       1     flags  (bit0: compressed body, bit1: anomaly in batch)
 *   5       2     sampleCount, uint16 little-endian
 *   7       2     firstValue, int16 little-endian (absolute; deltas follow)
 *   9..     var   body
 *   last    1     crc8 over every byte before it
 *
 * Body, compressed (flags bit0 = 1): a token stream of (sampleCount - 1)
 * deltas. Each token is read as an unsigned varint u:
 *   u == 0            -> zero-run: next varint r means "r delta-zero samples"
 *   u  > 0            -> a single delta = zigzagDecode(u)
 * Body, raw (flags bit0 = 0): (sampleCount - 1) int16 LE deltas verbatim.
 * The encoder picks whichever body is smaller; the decoder honors the flag.
 */
#ifndef EDGE_COMPRESSOR_H
#define EDGE_COMPRESSOR_H

#include "EdgeCodec.h"

namespace edge {

static const uint8_t ES_MAGIC0 = 0x45; // 'E'
static const uint8_t ES_MAGIC1 = 0x53; // 'S'
static const uint8_t ES_VERSION = 1;
static const uint8_t ES_FLAG_COMPRESSED = 0x01;
static const uint8_t ES_FLAG_ANOMALY    = 0x02;
static const size_t  ES_HEADER_LEN = 9;

class EdgeCompressor {
public:
  // Encode `count` samples into `out` (capacity `cap`). Returns the frame
  // length in bytes, or 0 if the buffer was too small. `anomaly` sets the
  // anomaly flag so downstream can prioritize the batch without decoding.
  static size_t encode(const int16_t *samples, uint16_t count,
                       uint8_t channel, bool anomaly,
                       uint8_t *out, size_t cap) {
    if (count == 0 || cap < ES_HEADER_LEN + 1) return 0;

    // Build the compressed body into a scratch region past the header, then
    // decide whether raw would be smaller before committing flags/crc.
    size_t bodyStart = ES_HEADER_LEN;
    size_t pos = bodyStart;
    bool compressed = writeCompressedBody(samples, count, out, cap, &pos);

    size_t rawLen = (size_t)(count - 1) * 2;
    if (!compressed || (pos - bodyStart) >= rawLen) {
      // Fall back to raw deltas if compression failed or did not help.
      pos = bodyStart;
      if (bodyStart + rawLen + 1 > cap) return 0;
      for (uint16_t i = 1; i < count; i++) {
        int32_t d = (int32_t)samples[i] - (int32_t)samples[i - 1];
        out[pos++] = (uint8_t)(d & 0xFF);
        out[pos++] = (uint8_t)((d >> 8) & 0xFF);
      }
      compressed = false;
    }

    uint8_t flags = 0;
    if (compressed) flags |= ES_FLAG_COMPRESSED;
    if (anomaly)    flags |= ES_FLAG_ANOMALY;

    out[0] = ES_MAGIC0;
    out[1] = ES_MAGIC1;
    out[2] = ES_VERSION;
    out[3] = channel;
    out[4] = flags;
    out[5] = (uint8_t)(count & 0xFF);
    out[6] = (uint8_t)((count >> 8) & 0xFF);
    out[7] = (uint8_t)(samples[0] & 0xFF);
    out[8] = (uint8_t)(((uint16_t)samples[0] >> 8) & 0xFF);

    if (pos + 1 > cap) return 0;
    out[pos] = crc8(out, pos);
    return pos + 1;
  }

private:
  // Returns false (and leaves *pos advanced arbitrarily) on buffer overflow.
  static bool writeCompressedBody(const int16_t *samples, uint16_t count,
                                  uint8_t *out, size_t cap, size_t *pos) {
    uint16_t i = 1;
    while (i < count) {
      int32_t d = (int32_t)samples[i] - (int32_t)samples[i - 1];
      if (d == 0) {
        uint32_t run = 0;
        while (i < count &&
               ((int32_t)samples[i] - (int32_t)samples[i - 1]) == 0) {
          run++; i++;
        }
        if (!putVarint(out, cap, pos, 0)) return false;       // zero-run marker
        if (!putVarint(out, cap, pos, run)) return false;     // run length
      } else {
        if (!putVarint(out, cap, pos, zigzagEncode(d))) return false;
        i++;
      }
    }
    return true;
  }
};

} // namespace edge

#endif // EDGE_COMPRESSOR_H
