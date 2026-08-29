/*
 * FrameStream.h - Resynchronising frame reassembler for a raw byte stream.
 *
 * EdgeCompressor produces frames; radios and UARTs deliver bytes. Between the
 * two sit all the ways a stream goes wrong: a frame split across two reads,
 * noise before it, a bit flipped inside it, and the magic pair 'E','S'
 * appearing in a payload by chance. Feed every received byte to push() and it
 * hands back only whole, CRC-valid frames:
 *
 *   * scan to the next magic pair, counting the bytes skipped
 *   * size the frame from its own header (the format is self-delimiting)
 *   * wait for more bytes if it is not complete yet
 *   * on a bad header or a failed CRC, step ONE byte past the false magic, so
 *     a real frame overlapping a false one is still recovered
 *
 * Fixed CAPACITY buffer, no allocation, no recursion: a stream of pure noise
 * costs one memmove per byte and never grows. The counters make link quality
 * visible before frames stop arriving altogether — droppedBytes() and
 * crcErrors() rising is what a marginal antenna looks like.
 *
 * Mirrored server-side, resync for resync, by frame_stream.rb.
 *
 *   FrameStream<256> rx;
 *   while (LoRa.available())
 *     if (rx.push(LoRa.read())) handle(rx.frame(), rx.frameLength());
 */
#ifndef FRAME_STREAM_H
#define FRAME_STREAM_H

#include <string.h>

#include "EdgeCompressor.h"

namespace edge {

template <uint16_t CAPACITY = 256> class FrameStream {
public:
  FrameStream() { reset(); }

  void reset() {
    _len = 0;
    _frameLen = 0;
    _frames = 0;
    _dropped = 0;
    _resyncs = 0;
    _crcErrors = 0;
    _overflows = 0;
  }

  // Feed one received byte. Returns true when frame()/frameLength() describe a
  // complete, CRC-valid frame; that frame stays valid until the next push().
  bool push(uint8_t b) {
    if (_frameLen) { // consume the frame handed out by the previous push
      shiftOut(_frameLen);
      _frameLen = 0;
    }
    if (_len >= CAPACITY) { // no room: a frame this long can never complete
      _overflows++;
      _dropped++;
      shiftOut(1);
    }
    _buf[_len++] = b;
    return extract();
  }

  const uint8_t *frame() const { return _buf; }
  uint16_t frameLength() const { return _frameLen; }
  uint16_t pending() const { return _len; }

  uint32_t frames() const { return _frames; }
  uint32_t droppedBytes() const { return _dropped; }
  uint32_t resyncs() const { return _resyncs; }
  uint32_t crcErrors() const { return _crcErrors; }
  uint32_t overflows() const { return _overflows; }

private:
  // Slide the buffer left, discarding the first n bytes.
  void shiftOut(uint16_t n) {
    if (n >= _len) {
      _len = 0;
      return;
    }
    memmove(_buf, _buf + n, (size_t)(_len - n));
    _len = (uint16_t)(_len - n);
  }

  // Index of the next plausible frame start, or -1. A lone magic0 at the very
  // end counts: its partner may be the next byte to arrive.
  int32_t indexOfMagic() const {
    for (uint16_t i = 0; i < _len; i++) {
      if (_buf[i] == ES_MAGIC0 &&
          (i + 1 == _len || _buf[i + 1] == ES_MAGIC1)) {
        return (int32_t)i;
      }
    }
    return -1;
  }

  // Length of the frame at the head of the buffer:
  //   >0 complete frame, 0 need more bytes, -1 structurally impossible.
  int32_t lengthAt() const {
    if (_len < ES_HEADER_LEN) return 0;
    if (_buf[0] != ES_MAGIC0 || _buf[1] != ES_MAGIC1) return -1;
    if (_buf[2] != ES_VERSION) return -1;

    uint16_t count = (uint16_t)_buf[5] | ((uint16_t)_buf[6] << 8);
    if (count == 0) return -1;

    uint32_t bodyLen;
    if (_buf[4] & ES_FLAG_COMPRESSED) {
      size_t pos = ES_HEADER_LEN;
      uint32_t have = 0;
      while (have < (uint32_t)(count - 1)) {
        uint32_t token;
        if (!getVarint(_buf, _len, &pos, &token)) return truncatedOrBad(pos);
        if (token == 0) {
          uint32_t run;
          if (!getVarint(_buf, _len, &pos, &run)) return truncatedOrBad(pos);
          // A zero-length run consumes bytes without producing samples; a
          // stream of them would scan forever, so treat it as corruption.
          if (run == 0) return -1;
          have += run;
        } else {
          have++;
        }
      }
      bodyLen = (uint32_t)pos - ES_HEADER_LEN;
    } else {
      bodyLen = (uint32_t)(count - 1) * 2;
    }

    uint32_t total = ES_HEADER_LEN + bodyLen + 1;
    if (total > CAPACITY) return -1; // longer than we could ever buffer
    if (total > _len) return 0;
    return (int32_t)total;
  }

  // getVarint fails both on truncation and on a malformed (>5 byte) varint;
  // only the first is worth waiting for, and only while the buffer can grow.
  int32_t truncatedOrBad(size_t pos) const {
    if (pos >= _len && _len < CAPACITY) return 0;
    return -1;
  }

  // Step past a false frame start: one byte, so an overlapping real frame is
  // not skipped along with it.
  void desync() {
    _resyncs++;
    _dropped++;
    shiftOut(1);
  }

  bool extract() {
    for (;;) {
      int32_t idx = indexOfMagic();
      if (idx < 0) { // nothing here can start a frame
        _dropped += _len;
        _len = 0;
        return false;
      }
      if (idx > 0) {
        _dropped += (uint32_t)idx;
        shiftOut((uint16_t)idx);
      }

      int32_t len = lengthAt();
      if (len == 0) return false; // wait for more bytes
      if (len < 0) {
        desync();
        continue;
      }

      uint8_t expected = _buf[len - 1];
      if (crc8(_buf, (size_t)(len - 1)) != expected) {
        _crcErrors++;
        desync();
        continue;
      }

      _frameLen = (uint16_t)len;
      _frames++;
      return true;
    }
  }

  uint8_t _buf[CAPACITY];
  uint16_t _len;
  uint16_t _frameLen;
  uint32_t _frames, _dropped, _resyncs, _crcErrors, _overflows;
};

} // namespace edge

#endif // FRAME_STREAM_H
