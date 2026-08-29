/*
 * SwingingDoor.h - Lossy sample selection with a hard error bound.
 *
 * EdgeCompressor makes what you send smaller; this decides whether to send at
 * all. A slow signal sampled every 100 ms is mostly redundant: a receiver can
 * rebuild it by drawing straight lines between a few archived points. The
 * swinging-door rule keeps only the points where that line would go wrong by
 * more than `deviation`.
 *
 * From the current anchor, every held sample constrains the slope of a line
 * that stays within `deviation` of it to an interval; the feasible slopes are
 * the intersection of those intervals - the "doors", swinging shut as samples
 * accumulate. While the intersection is non-empty one segment covers
 * everything held. When a sample empties it, the segment closes at the
 * previous sample and a new anchor starts there. The closing endpoint is the
 * real sample whenever its own slope is still feasible (the usual case), and a
 * clamped value otherwise - which is what makes the bound exact rather than
 * typical.
 *
 * Two floats of state per segment, no buffer, no allocation: the whole point
 * is to run before the radio does. Mirrored server-side by swinging_door.rb.
 *
 *   SwingingDoor door(0.5f, 60000);        // 0.5 units, 60 s heartbeat
 *   if (door.update(millis(), reading))
 *     enqueue(door.pointTime(), door.pointValue());
 *   // ... and door.flush() before sleeping, to close the open segment.
 */
#ifndef SWINGING_DOOR_H
#define SWINGING_DOOR_H

#include <math.h>
#include <stdint.h>

namespace edge {

class SwingingDoor {
public:
  // deviation: maximum absolute reconstruction error, in sample units.
  // maxInterval: optional heartbeat in t units (0 = none) so a perfectly flat
  // signal still archives a point now and then.
  SwingingDoor(float deviation = 1.0f, uint32_t maxInterval = 0)
      : _dev(deviation < 0 ? 0 : deviation), _maxInterval(maxInterval) {
    reset();
  }

  void reset() {
    _has = false;
    _seen = 0;
    _emitted = 0;
    _anchorT = 0;
    _anchorV = 0;
    _lastT = 0;
    _lastV = 0;
    openFullCone();
  }

  // Feed one sample. Returns true when a point has been archived by this
  // sample - pointTime()/pointValue() then hold it (the *previous* sample, or
  // the very first one). Timestamps must strictly increase.
  bool update(uint32_t t, float value) {
    _seen++;

    if (!_has) {
      _anchorT = _lastT = t;
      _anchorV = _lastV = value;
      _has = true;
      emit(t, value);
      return true;
    }
    // Modular comparison, so a millis() rollover is handled rather than
    // stalling the door for 49 days; out-of-order samples are ignored.
    if ((int32_t)(t - _lastT) <= 0) return false;

    float dt = (float)(t - _anchorT);
    float lo = (value - _dev - _anchorV) / dt;
    float hi = (value + _dev - _anchorV) / dt;
    float newLo = lo > _lo ? lo : _lo;
    float newHi = hi < _hi ? hi : _hi;

    if (newLo > newHi || heartbeatDue(t)) {
      closeSegment(); // archives the held sample into _pointT/_pointV
      _anchorT = _pointT;
      _anchorV = _pointV;
      _lastT = t;
      _lastV = value;
      openConeForLast();
      _emitted++;
      return true;
    }

    _lo = newLo;
    _hi = newHi;
    _lastT = t;
    _lastV = value;
    return false;
  }

  // Close the open segment (before sleeping, or at the end of a burst).
  // Returns true when a final point was archived.
  bool flush() {
    if (!_has || _lastT == _anchorT) return false;

    closeSegment();
    _anchorT = _lastT = _pointT;
    _anchorV = _lastV = _pointV;
    openFullCone();
    _emitted++;
    return true;
  }

  uint32_t pointTime() const { return _pointT; }
  float pointValue() const { return _pointV; }
  uint32_t seen() const { return _seen; }
  uint32_t emitted() const { return _emitted; }
  float deviation() const { return _dev; }

private:
  void openFullCone() {
    _lo = -INFINITY;
    _hi = INFINITY;
  }

  void openConeForLast() {
    float dt = (float)(_lastT - _anchorT);
    if (dt <= 0) {
      openFullCone();
      return;
    }
    _lo = (_lastV - _dev - _anchorV) / dt;
    _hi = (_lastV + _dev - _anchorV) / dt;
  }

  // End the segment at the held sample, keeping its own value when that slope
  // is still inside the cone and clamping into the cone when it is not.
  void closeSegment() {
    float dt = (float)(_lastT - _anchorT);
    _pointT = _lastT;
    if (dt <= 0) {
      _pointV = _lastV;
      return;
    }
    float direct = (_lastV - _anchorV) / dt;
    float slope = direct < _lo ? _lo : (direct > _hi ? _hi : direct);
    _pointV = (slope == direct) ? _lastV : _anchorV + slope * dt;
  }

  bool heartbeatDue(uint32_t t) const {
    if (_maxInterval == 0 || (int32_t)(_lastT - _anchorT) <= 0) return false;
    return (t - _anchorT) >= _maxInterval;
  }

  void emit(uint32_t t, float value) {
    _pointT = t;
    _pointV = value;
    _emitted++;
  }

  float _dev;
  uint32_t _maxInterval;
  bool _has;
  uint32_t _anchorT, _lastT, _pointT;
  float _anchorV, _lastV, _pointV;
  float _lo, _hi;
  uint32_t _seen, _emitted;
};

} // namespace edge

#endif // SWINGING_DOOR_H
