# Architecture

EdgeSuite is a two-tier system with one shared contract.

```
   ┌─────────────────────────── edge node (MCU) ───────────────────────────┐
   │  sensor ─▶ AnomalyDetector ─▶ AdaptiveSampler ─▶ batch ─▶ EdgeCompressor│
   │                 │ z-score          │ interval                 │ frame  │
   └─────────────────┼──────────────────┼──────────────────────────┼────────┘
                     │                  │                          │
                     │            (controls delay)            hex over Serial / radio
                     │                                             │
   ┌─────────────────┼──────────────── gateway (Ruby) ────────────▼────────┐
   │                 ▼                                        Frame.decode  │
   │   AnomalyDetector (mirror)  ◀── reconstructed samples ───────┘         │
   │   AdaptiveSampler (mirror)  ──▶ bandwidth accounting + retuning advice │
   └───────────────────────────────────────────────────────────────────────┘
```

## Components

### Device (`arduino/libraries/EdgeSuite`)
- **`EdgeCodec.h`** — the primitives everything rests on: LEB128 varint, 32-bit
  zigzag, CRC-8/SMBUS. Header-only, no allocation, cursor-based.
- **`AnomalyDetector.h`** — streaming EWMA z-score, O(1) state.
- **`AdaptiveSampler.h`** — maps signal activity to a sampling interval.
- **`EdgeCompressor.h`** — serializes a sample batch into a frame, choosing
  compressed or raw body by size.
- **`SwingingDoor.h`** — drops readings a straight line already predicts, within
  a hard error bound; runs before the radio does.
- **`FrameStream.h`** — fixed-capacity reassembler that turns a noisy byte
  stream back into whole, CRC-valid frames.
- **`EdgeSuite.h`** — umbrella include.

### Gateway (`ruby/lib/edge_suite`)
- **`codec.rb` / `frame.rb`** — the exact inverse of the device codec, plus an
  encoder used by the simulator and tests.
- **`anomaly_detector.rb` / `adaptive_sampler.rb`** — line-for-line mirrors of
  the device recurrences, so server and device agree.
- **`gateway.rb`** — ingests frames, tracks per-channel stats and bandwidth
  savings, emits retuning recommendations.
- **`device_simulator.rb`** — generates a synthetic sensor stream and runs the
  real on-device pipeline, emitting the same frames a board would.
- **`frame_stream.rb` / `swinging_door.rb`** — mirrors of the two above, so the
  gateway can carve frames out of a raw link and predict what a node will keep.
- **`transport/`** — pluggable frame sources (`stdin`, `serial`, `mqtt`, `raw`), each
  exposing `each_frame { |frame| ... }`. The gateway never knows or cares which
  one is in use.
- **`stats_store.rb`** — durable statistics: an atomic `snapshot.json` and an
  append-only `anomalies.jsonl`.
- **`gateway_runner.rb`** — wires a transport to the gateway and (optionally) a
  store: pull frames, ingest, log anomalies, snapshot every N frames, and skip
  a corrupt frame rather than aborting the stream.

### Transport topology

```
directly wired :  [EdgeNode] --USB hex--> Serial ----------┐
LoRa fleet     :  [EdgeNodeLoRa] --LoRa--> [LoRaGateway] --USB hex--> Serial ─┤
binary link    :  [node] --binary--> [BinaryBridge / --raw] -> FrameStream ───┤
Wi-Fi / MQTT   :  [nodes] --------------------------> MQTT topic ─────────────┤
                                                                              ▼
                                                        Transport.each_frame → GatewayRunner
```

A LoRa or Wi-Fi bridge simply republishes frames (as hex over Serial, or onto an
MQTT topic); because every path terminates in the same `each_frame` contract,
the gateway core is identical regardless of the physical link.

## Data flow

1. The node reads a sample and passes it to the detector (predict-then-update:
   the sample is scored against the prior estimate, then folded in).
2. The sampler updates its activity EWMA and returns the delay to the next
   sample; an anomaly forces the minimum delay.
3. Samples accumulate into a batch. When the batch fills — or an anomaly should
   be reported promptly — the compressor emits a frame.
4. The gateway decodes the frame (validating magic, version, and CRC),
   reconstructs the samples, re-runs detection server-side, and updates stats.

## Wire format

A frame is a header, a body, and a trailing CRC. All multi-byte header fields
are little-endian.

```
offset  size  field
0       1     magic 'E' (0x45)
1       1     magic 'S' (0x53)
2       1     version (1)
3       1     channel id
4       1     flags   bit0 = compressed body, bit1 = anomaly in batch
5       2     sampleCount (uint16)
7       2     firstValue  (int16, absolute; the rest are deltas)
9..     var   body
last    1     crc8 over every preceding byte
```

**Compressed body** (`flags bit0 = 1`): a token stream reconstructing
`sampleCount − 1` deltas. Read an unsigned varint `u`:
- `u == 0` → a *zero-run*: the next varint `r` means "`r` samples with delta 0"
  (cheap encoding of a flat signal).
- `u > 0` → one delta, `zigzagDecode(u)`.

**Raw body** (`flags bit0 = 0`): `sampleCount − 1` `int16` little-endian deltas,
verbatim. The encoder emits raw only when it is smaller than the compressed
body (incompressible input), and the decoder honors the flag.

Reconstruction: `x[0] = firstValue`, `x[i] = x[i-1] + delta[i]`. Because deltas
derive from `int16` samples, reconstruction is exact.

## The shared-contract guarantee

`ruby/spec/cross_language_spec.rb` compiles the firmware headers with `g++`,
encodes a set of batches on **both** sides, and asserts the bytes are identical
— then decodes the C++ output with the Ruby decoder. CI runs this on every
push, so the two implementations cannot silently drift.
