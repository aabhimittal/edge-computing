/*
 * EdgeSuite.h - Umbrella header for the EdgeSuite edge-computing library.
 *
 * Three composable, allocation-free primitives for constrained MCUs:
 *   - AnomalyDetector : streaming EWMA z-score outlier detection
 *   - AdaptiveSampler : activity-driven sampling-interval control
 *   - EdgeCompressor  : delta + zigzag + RLE frame encoder
 *   - SwingingDoor    : bounded-error lossy sample selection (send less)
 *   - FrameStream     : resynchronising frame reassembler for a byte stream
 *
 * They share EdgeCodec's varint/zigzag/crc primitives, whose wire format is
 * matched byte-for-byte by the companion Ruby gateway gem.
 *
 * Include this single header to pull in the whole suite:
 *   #include <EdgeSuite.h>
 */
#ifndef EDGE_SUITE_H
#define EDGE_SUITE_H

#include "EdgeCodec.h"
#include "AnomalyDetector.h"
#include "AdaptiveSampler.h"
#include "EdgeCompressor.h"
#include "SwingingDoor.h"
#include "FrameStream.h"

#define EDGE_SUITE_VERSION "0.2.0"

#endif // EDGE_SUITE_H
