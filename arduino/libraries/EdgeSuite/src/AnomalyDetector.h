/*
 * AnomalyDetector.h - Streaming, O(1)-memory anomaly detection for the edge.
 *
 * Maintains an exponentially weighted moving average (EWMA) of the signal and
 * an incremental EWMA of its variance (West, 1979), so a robust z-score is
 * available after every sample without storing history. A sample is flagged
 * when |z| exceeds `threshold`, once past a short warmup.
 *
 * The Ruby gateway runs the identical recurrence (anomaly_detector.rb) so a
 * device and the server agree on what counts as anomalous.
 */
#ifndef ANOMALY_DETECTOR_H
#define ANOMALY_DETECTOR_H

#include <math.h>
#include <stdint.h>

namespace edge {

class AnomalyDetector {
public:
  // alpha: EWMA weight (0..1], larger = more reactive.
  // threshold: z-score magnitude that trips an anomaly.
  // warmup: samples to observe before any flag (lets the estimate settle).
  explicit AnomalyDetector(float alpha = 0.1f, float threshold = 3.5f,
                           uint16_t warmup = 20)
      : _alpha(alpha), _threshold(threshold), _warmup(warmup),
        _mean(0), _var(0), _n(0), _lastScore(0) {}

  // Feed one sample. Returns true if it is anomalous.
  //
  // Predict-then-update: score the sample against the estimate as it stood
  // *before* this sample, so an outlier cannot inflate its own variance and
  // mask itself. The EWMA mean and West incremental EWMA variance are folded
  // in afterward.
  bool update(float x) {
    _n++;
    if (_n == 1) { _mean = x; _var = 0; _lastScore = 0; return false; }

    float sd = sqrtf(_var);
    _lastScore = (sd > 1e-6f) ? (x - _mean) / sd : 0.0f;
    bool isAnomaly = (_n > _warmup) && (fabsf(_lastScore) > _threshold);

    float diff = x - _mean;
    float incr = _alpha * diff;
    _mean += incr;
    _var = (1.0f - _alpha) * (_var + diff * incr);

    return isAnomaly;
  }

  float mean() const { return _mean; }
  float variance() const { return _var; }
  float score() const { return _lastScore; }
  uint32_t count() const { return _n; }
  void setThreshold(float t) { _threshold = t; }
  void setAlpha(float a) { _alpha = a; }

private:
  float _alpha, _threshold;
  uint16_t _warmup;
  float _mean, _var;
  uint32_t _n;
  float _lastScore;
};

} // namespace edge

#endif // ANOMALY_DETECTOR_H
