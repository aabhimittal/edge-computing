# edge-computing

**EdgeSuite** — a small, cross-stack framework for on-device intelligence. It
pairs an allocation-free **Arduino/C++ library** that runs on the sensor node
with a **Ruby gateway gem** that coordinates a fleet of nodes. Both sides
implement one wire protocol, verified byte-for-byte in CI.

The suite bundles three composable edge algorithms:

| Algorithm | Where it runs | What it buys you |
|-----------|---------------|------------------|
| **Streaming anomaly detection** | device + gateway | Catch outliers in O(1) memory with an EWMA z-score — no history buffer, no cloud round-trip. |
| **Adaptive event-driven sampling** | device + gateway | Sample fast when the signal is lively, back off when it's quiet. Less power, less bandwidth, no missed events. |
| **Delta + RLE frame compression** | device → gateway | Pack `int16` sample batches into compact, CRC-protected frames. 28–81% smaller on real sensor signals. |

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
- The **compressor** decides *how to pack what's left*, shrinking the bytes
  that do go out.

An anomaly forces the sampler to its fast rate and flags the frame so the
gateway can prioritize it — the three are wired together in the reference node.

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
ruby -Ilib bin/edge-gateway --mqtt broker.local --topic 'edge/+/frames'
```

- **Serial** — dependency-free; opens the tty and sets the baud rate via `stty`.
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

---

## Layout

```
arduino/libraries/EdgeSuite/   # C++ library (header-only algorithms + codec)
  src/                         #   EdgeSuite.h, AnomalyDetector.h, AdaptiveSampler.h,
                               #   EdgeCompressor.h, EdgeCodec.h
  examples/EdgeNode/           #   reference sketch tying all three together
  examples/EdgeNodeLoRa/       #   same pipeline, frames sent over LoRa
  examples/LoRaGateway/        #   LoRa -> Serial hex bridge
ruby/                          # gateway gem
  lib/edge_suite/              #   codec, frame, detector, sampler, gateway, simulator
    transport/                 #   stdin, serial, mqtt frame sources
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
