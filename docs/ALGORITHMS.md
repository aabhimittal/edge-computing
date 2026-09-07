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

## 4. Bounded-error sample selection (swinging door)

Compression shrinks what you send; this decides whether to send at all. A slow
signal sampled every 100 ms is mostly redundant: a receiver can rebuild it by
drawing straight lines between a handful of archived points. The swinging door
keeps only the points where that line would go wrong.

From the current anchor `(t0, v0)`, a sample `(ti, vi)` constrains the slope of
any line that passes within `deviation` of it:

```
lo_i = (vi - deviation - v0) / (ti - t0)
hi_i = (vi + deviation - v0) / (ti - t0)
```

The feasible slopes for the whole held run are the intersection
`[max lo_i, min hi_i]` — the two "doors", swinging shut as samples accumulate.
While the intersection is non-empty, one segment represents everything held.
When a new sample empties it, the segment closes at the *previous* sample and a
new anchor starts there.

### Why the bound is exact, not typical

The segment closes at the held sample, using its own slope when that slope is
still inside the cone (the usual case, so archived points are real readings) and
a slope clamped into the cone when it is not. That clamp is what turns "usually
within `deviation`" into a guarantee: the emitted endpoint is by construction on
a line that every discarded sample sits within `deviation` of. Because each
segment starts exactly where the previous one ended, the reconstruction is
continuous, and the bound holds across segment boundaries too.

`SwingingDoor.max_error(series, points)` measures the realised error; the specs
assert it stays inside `deviation` on random walks, ramps, steps, flat lines,
uneven spacing and extreme magnitudes.

State is one anchor, one held sample and two slopes — constant memory, so the
same recurrence runs on an MCU (`SwingingDoor.h`) before the radio wakes up.

Measured on a 2000-sample random walk (±3 per step, seed 7) plus the
degenerate cases, via `ruby/benchmark/compression_bench.rb`:

| Signal (2000 samples) | deviation | Points kept | Worst error |
|-----------------------|----------:|------------:|------------:|
| straight ramp | 0.0 | 2 (0.1%) | 0.000 |
| flat | 0.0 | 2 (0.1%) | 0.000 |
| random walk | 0.5 | 1262 (63%) | 0.500 |
| random walk | 2.0 | 392 (20%) | 2.000 |
| random walk | 10.0 | 55 (2.8%) | 10.000 |

The worst error landing exactly on the deviation is the algorithm working as
specified: it spends the whole error budget and never a fraction more.

Two knobs matter. `deviation` is the contract with whoever reads the data — set
it to the sensor's own accuracy and the compression is free in information
terms. `max_interval` is a heartbeat: without it a perfectly flat signal emits
nothing for hours, and a dead node becomes indistinguishable from a calm one.

## 5. Framing a byte stream (resynchronisation)

Frames are produced as messages and delivered as bytes. A reader has to answer
"where does a frame begin?" against reads that land mid-frame, noise between
frames, bit flips inside them, and the magic pair `'E','S'` appearing in a
payload by chance.

The format is **self-delimiting**: the header gives the sample count and body
kind, so a raw body is `(count - 1) * 2` bytes and a compressed one is measured
by walking its varint tokens until `count - 1` deltas are accounted for. No
length prefix is needed — and a length prefix would be one more field to corrupt.

`FrameStream` (Ruby) and `FrameStream.h` (C++) run the same loop:

1. scan to the next magic pair, counting skipped bytes;
2. size the frame with `Frame.frame_length`;
3. if the buffer stops short, wait — `IncompleteFrame` is deliberately a
   different signal from `DecodeError`, because "read more" and "this is
   garbage" call for opposite responses;
4. on a bad header or a failed CRC, step **one** byte past the false magic and
   scan again. Skipping the whole suspect window would swallow a real frame that
   happens to overlap it.

Two guards keep a hostile or broken link cheap: a frame longer than `max_frame`
is treated as corruption rather than a promise to buffer, and the buffer itself
is capped, dropping its oldest bytes instead of growing without bound. Both are
tested, along with reassembly one byte at a time.

The counters (`frames`, `dropped_bytes`, `crc_errors`, `resyncs`) are the link's
health. They climb long before frames stop arriving altogether, which makes them
the earliest warning available that an antenna is going bad.

## Why keep the two implementations in lockstep?

Running the *same* detector and sampler on the device and the gateway means the
server can (a) independently confirm what the device flagged, and (b) predict
the device's cadence to recommend retuning — without the device having to report
its internal state. The shared codec is what makes that mirror trustworthy, and
CI's byte-for-byte cross-language test is what keeps it honest.

The same argument extends to the newer pair. The cross-language check pushes an
identical noisy stream (noise, a good frame, a corrupted one, another good one,
a trailing false magic) through both `FrameStream`s and asserts they recover the
same frames *and* the same counters — agreeing on the frame bytes is not enough
if the two ends disagree about where a frame starts after a burst of noise. It
also segments one series with both swinging doors and asserts identical archive
decisions, so a node and its gateway reconstruct the same signal.
