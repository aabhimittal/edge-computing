# Algorithms

Three primitives, each chosen to be correct in O(1) memory on an 8-bit MCU while
staying simple enough to reproduce exactly in Ruby.

## 1. Streaming anomaly detection (EWMA z-score)

A microcontroller cannot store a window of history to compute a rolling mean and
variance. EdgeSuite instead tracks both incrementally.

**Mean** — exponentially weighted moving average:

```
mean ← mean + α·(x − mean)
```

**Variance** — West's incremental EWMA variance (1979), which needs only the
running mean and variance:

```
diff ← x − mean_before
mean ← mean_before + α·diff
var  ← (1 − α)·(var + diff·(α·diff))
```

**Score** — a z-score against the current estimate: `z = (x − mean) / √var`. A
sample is anomalous when `|z| > threshold` (default 3.5) after a short warmup.

### The predict-then-update detail (why ordering matters)

The score is computed **before** folding the sample into the estimate. If you
update first, a large spike inflates its own variance and its z-score collapses
back under the threshold — the outlier masks itself. Scoring against the prior
estimate makes a genuine spike read as `z ≈ 15–20` instead of `≈ 3`. This was a
real bug caught by the test suite; both the C++ and Ruby implementations use the
predict-then-update ordering.

**Parameters:** `α` sets reactivity (larger = adapts faster, tolerates drift but
is noisier); `threshold` trades sensitivity against false positives; `warmup`
suppresses flags until the estimate settles.

## 2. Adaptive event-driven sampling

Sampling and transmitting are the dominant energy and bandwidth costs at the
edge. A fixed rate is wasteful: too fast on a quiet signal, too slow to catch a
transient. EdgeSuite scales the interval to how much the signal is actually
moving.

**Activity** — an EWMA of the absolute first difference:

```
activity ← activity + α·(|x − x_prev| − activity)
```

**Interval** — high activity shortens it toward `minInterval`, low activity
relaxes it toward `maxInterval`:

```
norm     ← clamp((activity / refRange)·gain, 0, 1)
interval ← maxInterval − (maxInterval − minInterval)·norm
```

An anomaly overrides this and forces `minInterval` for that decision, so events
are never sampled slowly. `refRange` is the signal swing considered "fully
active"; `gain` sharpens the response curve.

The result: a sensor idles at, say, one sample every 2 s when nothing is
happening and jumps to 50 ms bursts the moment the signal moves — capturing
detail exactly when it exists.

## 3. Delta + zigzag + RLE compression

Sensor batches are dominated by small, often-repeating changes. The codec
exploits that in three cheap layers, each reversible without side tables.

1. **Delta** — store `x[i] − x[i−1]` instead of `x[i]`. Slowly varying signals
   have small deltas.
2. **Zigzag** — map signed deltas to unsigned so small magnitudes of either sign
   become small numbers: `0,−1,1,−2,2 → 0,1,2,3,4`. This keeps the varint short.
3. **Varint (LEB128)** — 7 bits per byte, so a delta in ±63 costs one byte,
   ±8191 costs two, and so on.
4. **Zero-run RLE** — a flat stretch (delta 0) is encoded as a single `0` token
   followed by a run length, collapsing constant regions to a few bytes.

A **raw fallback** guards the worst case: if the compressed body is not smaller
than plain `int16` deltas (incompressible input), the encoder ships raw deltas
and sets a flag, so the format never expands the payload beyond raw + framing.

Every value is covered by a trailing **CRC-8/SMBUS** byte, so corruption on the
serial/radio link is detected rather than silently decoded into garbage.

### Measured results

From `ruby/benchmark/compression_bench.rb` (batch 32):

| Signal | Saved |
|--------|------:|
| flat/constant | 81% |
| slow sine | 34% |
| noisy | 29% |
| random walk | 31% |
| full-scale random | −7% (raw fallback + framing) |

## Why keep the two implementations in lockstep?

Running the *same* detector and sampler on the device and the gateway means the
server can (a) independently confirm what the device flagged, and (b) predict
the device's cadence to recommend retuning — without the device having to report
its internal state. The shared codec is what makes that mirror trustworthy, and
CI's byte-for-byte cross-language test is what keeps it honest.
