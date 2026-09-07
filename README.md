# edge-computing

**EdgeSuite** — a small, cross-stack framework for on-device intelligence. It
pairs an allocation-free **Arduino/C++ library** that runs on the sensor node
with a **Ruby gateway gem** that coordinates a fleet of nodes. Both sides
implement one wire protocol, verified byte-for-byte in CI.

The suite bundles five composable edge primitives:

| Primitive | Where it runs | What it buys you |
|-----------|---------------|------------------|
| **Streaming anomaly detection** | device + gateway | Catch outliers in O(1) memory with an EWMA z-score — no history buffer, no cloud round-trip. |
| **Adaptive event-driven sampling** | device + gateway | Sample fast when the signal is lively, back off when it's quiet. Less power, less bandwidth, no missed events. |
| **Bounded-error sample selection** | device → gateway | A swinging door drops redundant readings *before* the radio wakes, with a hard guarantee on reconstruction error. 10–50x fewer points on slow signals. |
| **Delta + RLE frame compression** | device → gateway | Pack `int16` sample batches into compact, CRC-protected frames. 28–81% smaller on real sensor signals. |
| **Resynchronising frame reassembly** | device + gateway | Recover whole frames from a raw byte stream — split reads, line noise, bit flips and false magic bytes included. |

Everything runs **without hardware** via a device simulator, so you can try the
whole pipeline on your laptop in seconds.

---

## Why these three, together

Edge computing is bandwidth-, energy-, and latency-constrained. Each primitive
attacks one constraint, and they compound:

- The **anomaly detector** decides *what matters* locally, so only meaningful
  events trigger urgent transmission.
- The **adaptive sampler** decides *how often to look*, spending energy only
  when the signal is changing.
- The **swinging door** decides *which readings are worth keeping*, discarding
  everything a straight line already predicts to within a set error bound.
- The **compressor** decides *how to pack what's left*, shrinking the bytes
  that do go out.
- The **frame stream** decides *where a frame begins* on a link that delivers
  bytes rather than messages, so noise costs bytes instead of whole frames.

An anomaly forces the sampler to its fast rate, bypasses the door, and flags
the frame so the gateway can prioritize it — they are wired together in the
reference node (`EdgeNode`, and `FrugalNode` for the door).

Together they attack the same byte from four directions: don't sample it,
don't keep it, don't send it uncompressed, and don't lose it to line noise.

---

## Quick start (no hardware)

```bash
cd ruby
gem install rspec              # test dep only
ruby -Ilib bin/edge-sim --demo --samples 2000   # simulate a node + gateway
```

Or pipe a simulated node into the gateway exactly as a real board would over
serial:

```bash
ruby -Ilib bin/edge-sim --samples 2000 | ruby -Ilib bin/edge-gateway
```

Example output:

```
! anomaly  ch=1  idx=25    value=781     z=+17.02
=== Gateway summary ===
ch 1: 64 frames, 2000 samples, 2725 B on wire vs 4000 B raw (31.9% saved), 8 anomalies
        advice: nominal
```

Run the tests (Ruby specs **plus** a C++/Ruby byte-compatibility check):

```bash
cd ruby && rspec        # or: bundle exec rspec
```

---

## On real hardware

1. Copy `arduino/libraries/EdgeSuite` into your Arduino `libraries/` folder.
2. Open **File → Examples → EdgeSuite → EdgeNode**, flash it.
3. The node prints hex frames over Serial. Read the port directly:

```bash
ruby -Ilib bin/edge-gateway --serial /dev/ttyUSB0 --baud 115200
```

The `EdgeNode.ino` sketch reads `A0`, runs anomaly detection + adaptive
sampling, batches samples, and streams compressed frames — ~40 lines of glue
over the library.

## Transports

The gateway is decoupled from where frames come from; pick a source with a flag:

```bash
ruby -Ilib bin/edge-gateway                              # stdin (default)
ruby -Ilib bin/edge-gateway --serial /dev/ttyUSB0        # a real serial port
ruby -Ilib bin/edge-gateway --raw /dev/ttyUSB0           # raw binary, no framing
ruby -Ilib bin/edge-gateway --raw capture.bin            # replay a capture
ruby -Ilib bin/edge-gateway --mqtt broker.local --topic 'edge/+/frames'
```

- **Serial** — dependency-free; opens the tty and sets the baud rate via `stty`.
- **Raw** — any binary byte stream or capture file. There are no line
  boundaries to lean on, so every chunk goes through `FrameStream`, which finds
  frame starts, waits out partial frames, and resynchronises after corruption.
  Halves the bytes on the wire compared with hex, and reports link quality
  (dropped bytes, CRC errors, resyncs) at exit.
- **MQTT** — the fan-in point for wireless fleets. Needs the pure-Ruby `mqtt`
  gem (`gem install mqtt`); payloads may be raw binary frames or hex.

### LoRa fleets

For long range, flash **EdgeNodeLoRa** instead of EdgeNode — same pipeline, but
frames go out as raw LoRa packets. A cheap radio running **LoRaGateway** receives
them and re-emits hex over Serial, so the LoRa case reuses the serial reader:

```
[EdgeNodeLoRa] --LoRa--> [LoRaGateway board] --USB hex--> edge-gateway --serial
```

(Both LoRa sketches need the "LoRa" library by Sandeep Mistry and an SX127x radio.)

For a binary link, flash **BinaryBridge** on the bridge board instead: it feeds
every received byte to `FrameStream` and forwards only whole, CRC-valid frames,
so noise on the radio side never reaches the host as a bogus frame.

## Sending less in the first place

`SwingingDoor` (device and gateway) keeps only the readings a straight line
cannot already predict, with a hard bound on the error:

```ruby
door = EdgeSuite::SwingingDoor.new(deviation: 0.5, max_interval: 60_000)
series.each { |t, v| archive(door.update(t, v)) }   # nil = nothing worth sending
archive(door.flush)
```

Every discarded reading is guaranteed within `deviation` of the signal the
gateway reconstructs — `SwingingDoor.max_error` measures it, and the suite's
tests assert the bound holds on random walks, ramps, steps and flat lines.
`max_interval` is a heartbeat, so a silent signal still checks in and a dead
node stays distinguishable from a calm one.

## Knowing a node is gone

A dead sensor and a quiet one look identical in a bandwidth report: the numbers
simply stop moving. The gateway grades each channel against the cadence *it*
recommended to that channel, so a node told to sleep for 2 s is not called late
after 200 ms:

```ruby
gw.health          # => [{channel: 1, status: :ok|:stale|:silent, silent_for: 4.2, ...}]
gw.silent_channels # just the ones that need attention
```

`Gateway.new(max_channels: 64)` bounds the state a fleet can create: channel ids
arrive off the wire, so a faulty node cannot mint them without limit — past the
cap the least recently heard channel is evicted.
## Persisting statistics

Add `--persist DIR` to keep history across restarts:

```bash
ruby -Ilib bin/edge-gateway --serial /dev/ttyUSB0 --persist ./stats
```

- `stats/snapshot.json` — the latest per-channel report, atomically overwritten
  every N frames (`--snapshot-every`, default 50).
- `stats/anomalies.jsonl` — append-only log, one JSON object per anomaly event
  (`tail -f` friendly). On startup the gateway reports what's already on disk.

---

## Compression, measured

`ruby -Ilib benchmark/compression_bench.rb` (batch size 32):

| Signal profile | Ratio | Bandwidth saved |
|----------------|------:|----------------:|
| flat / constant | 0.19 | **81%** |
| slow sine | 0.66 | 34% |
| sine + light noise | 0.69 | 31% |
| noisy | 0.71 | 29% |
| random walk | 0.70 | 31% |
| full-scale random | 1.07 | −7% |

Real sensor streams are structured, so they compress well. Incompressible
full-scale noise is the honest worst case: you pay a small framing overhead and
the encoder falls back to raw deltas rather than expanding further.

The same benchmark measures the swinging door, which composes with the codec:
on that random walk, a deviation of 2.0 keeps 392 of 2000 points and takes the
stream from 2808 B to 528 B on the wire — **5.3x**, with every discarded reading
provably within 2.0 units of what the gateway reconstructs.

---

## Layout

```
arduino/libraries/EdgeSuite/   # C++ library (header-only algorithms + codec)
  src/                         #   EdgeSuite.h, AnomalyDetector.h, AdaptiveSampler.h,
                               #   EdgeCompressor.h, SwingingDoor.h, FrameStream.h,
                               #   EdgeCodec.h
  examples/EdgeNode/           #   reference sketch tying the pipeline together
  examples/FrugalNode/         #   swinging door: send only what carries information
  examples/EdgeNodeLoRa/       #   same pipeline, frames sent over LoRa
  examples/LoRaGateway/        #   LoRa -> Serial hex bridge
  examples/BinaryBridge/       #   raw byte stream -> validated frames
ruby/                          # gateway gem
  lib/edge_suite/              #   codec, frame, detector, sampler, gateway, simulator
    frame_stream.rb            #   byte stream -> frames, with resynchronisation
    swinging_door.rb           #   bounded-error lossy sample selection
    transport/                 #   stdin, serial, mqtt, raw byte-stream sources
    stats_store.rb             #   JSON snapshot + JSONL anomaly log
    gateway_runner.rb          #   transport -> gateway -> store glue
  bin/                         #   edge-sim, edge-gateway
  spec/                        #   rspec suite + C++/Ruby cross-language check
  benchmark/                   #   compression benchmark
docs/                          # ARCHITECTURE.md, ALGORITHMS.md
```

## Documentation

- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — components, data flow, and the wire format.
- [`docs/ALGORITHMS.md`](docs/ALGORITHMS.md) — the math behind each primitive and the design tradeoffs.

## License

MIT — see [LICENSE](LICENSE).
