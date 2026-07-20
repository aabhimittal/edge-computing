/*
 * AdaptiveSampler.h - Event-driven sampling interval controller.
 *
 * Power and bandwidth at the edge are dominated by how often you sample and
 * transmit. This controller tracks signal "activity" as an EWMA of the
 * absolute first difference and maps it onto a sampling interval: a quiet
 * signal relaxes toward `maxInterval` (save energy), a lively one tightens
 * toward `minInterval` (capture detail). An anomaly forces the fast rate for
 * one decision so events are never missed.
 *
 * Mirrored server-side by adaptive_sampler.rb so the gateway can predict and
 * retune device cadence.
 */
#ifndef ADAPTIVE_SAMPLER_H
#define ADAPTIVE_SAMPLER_H

#include <math.h>
#include <stdint.h>

namespace edge {

class AdaptiveSampler {
public:
  // minInterval/maxInterval in milliseconds. `refRange` is the signal swing
  // (in sample units) considered "fully active"; `gain` sharpens the response.
  AdaptiveSampler(uint32_t minInterval = 50, uint32_t maxInterval = 2000,
                  float refRange = 50.0f, float alpha = 0.2f, float gain = 1.0f)
      : _min(minInterval), _max(maxInterval), _ref(refRange <= 0 ? 1 : refRange),
        _alpha(alpha), _gain(gain), _activity(0), _last(0), _has(false) {}

  // Register a new sample value and return the recommended interval (ms) until
  // the next sample. Pass anomaly=true to force the minimum interval.
  uint32_t update(float x, bool anomaly = false) {
    if (_has) {
      float d = fabsf(x - _last);
      _activity += _alpha * (d - _activity);
    }
    _last = x;
    _has = true;

    if (anomaly) return _min;

    float norm = (_activity / _ref) * _gain;
    if (norm < 0) norm = 0;
    if (norm > 1) norm = 1;
    // High activity -> short interval; low activity -> long interval.
    return _max - (uint32_t)((float)(_max - _min) * norm);
  }

  float activity() const { return _activity; }
  void setGain(float g) { _gain = g; }
  void setBounds(uint32_t mn, uint32_t mx) { _min = mn; _max = mx; }

private:
  uint32_t _min, _max;
  float _ref, _alpha, _gain;
  float _activity, _last;
  bool _has;
};

} // namespace edge

#endif // ADAPTIVE_SAMPLER_H
