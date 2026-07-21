/*
 * EdgeSuite.h - Umbrella header for the EdgeSuite edge-computing library.
 *
 * Three composable, allocation-free primitives for constrained MCUs:
 *   - AnomalyDetector : streaming EWMA z-score outlier detection
 *   - AdaptiveSampler : activity-driven sampling-interval control
 *   - EdgeCompressor  : delta + zigzag + RLE frame encoder
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

#define EDGE_SUITE_VERSION "0.1.0"

#endif // EDGE_SUITE_H
