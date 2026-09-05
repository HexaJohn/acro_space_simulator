// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Pure-Dart coverage for the staged-upload patch's slicing arithmetic: the
// slices a StagedMeshUpload copies frame by frame must tile its device
// buffer exactly, one contiguous run per source segment, never crossing a
// segment boundary and never exceeding the byte cap of the call. Nothing
// here touches the GPU: `MeshGeometry.stageFromArrays` needs a context to
// allocate its buffer, so the layout it drives is pinned on its own.

import 'package:flutter_scene/src/geometry/mesh_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

/// Walks the layout as `StagedMeshUpload.step` does — a call of [maxBytes]
/// at a time from the start — and returns every slice in order.
List<StagedUploadSlice> _walk(StagedUploadLayout layout, int maxBytes) {
  final slices = <StagedUploadSlice>[];
  var cursor = 0;
  var guard = 0;
  while (cursor < layout.totalBytes) {
    final batch = layout.slicesFrom(cursor, maxBytes);
    expect(batch, isNotEmpty, reason: 'no progress at $cursor');
    var moved = 0;
    for (final s in batch) {
      moved += s.length;
    }
    expect(moved, lessThanOrEqualTo(maxBytes), reason: 'over the cap');
    slices.addAll(batch);
    cursor += moved;
    if (++guard > 100000) fail('the walk did not terminate');
  }
  return slices;
}

/// Every slice lies inside its segment, lands where that segment's bytes
/// belong, and the run of slices covers the buffer once, in order.
void _expectTiles(StagedUploadLayout layout, List<StagedUploadSlice> slices) {
  var expectedDestination = 0;
  for (final s in slices) {
    expect(s.length, greaterThan(0));
    expect(s.offsetInSegment, greaterThanOrEqualTo(0));
    expect(
      s.offsetInSegment + s.length,
      lessThanOrEqualTo(layout.segmentLengths[s.segment]),
      reason: 'a slice ran past its segment',
    );
    expect(
      s.destinationOffset,
      layout.segmentOffsets[s.segment] + s.offsetInSegment,
      reason: 'a slice landed away from its segment',
    );
    expect(
      s.destinationOffset,
      expectedDestination,
      reason: 'a gap or overlap before the slice at ${s.destinationOffset}',
    );
    expectedDestination += s.length;
  }
  expect(expectedDestination, layout.totalBytes, reason: 'the buffer is not covered');
}

void main() {
  // A 1000-vertex unskinned mesh with 16-bit indices, as fromArrays lays it
  // out: position, normal, texcoord, color, then the indices.
  const vertexCount = 1000;
  final meshLike = StagedUploadLayout([
    vertexCount * 12,
    vertexCount * 12,
    vertexCount * 8,
    vertexCount * 16,
    5400 * 2,
  ]);

  test('the offsets are the prefix sums and the total is their sum', () {
    expect(meshLike.segmentOffsets, [0, 12000, 24000, 32000, 48000]);
    expect(meshLike.totalBytes, 58800);
  });

  test('a cap larger than the buffer moves everything in one call', () {
    final slices = meshLike.slicesFrom(0, 1 << 20);
    expect(slices.map((s) => s.segment), [0, 1, 2, 3, 4]);
    expect(slices.map((s) => s.length), [12000, 12000, 8000, 16000, 10800]);
    _expectTiles(meshLike, slices);
  });

  test('a small cap tiles the buffer exactly and never crosses a segment', () {
    for (final cap in [1, 7, 1000, 4096, 12000, 12001, 30000]) {
      final slices = _walk(meshLike, cap);
      _expectTiles(meshLike, slices);
      // One slice per segment touched per call means a call that spans a
      // boundary yields one slice ending exactly on it.
      for (final s in slices) {
        expect(s.length, lessThanOrEqualTo(cap));
      }
    }
  });

  test('a cursor on a boundary starts the next segment', () {
    final slices = meshLike.slicesFrom(12000, 100);
    expect(slices, hasLength(1));
    expect(slices.single.segment, 1);
    expect(slices.single.offsetInSegment, 0);
    expect(slices.single.destinationOffset, 12000);
  });

  test('a call that spans a boundary yields one slice per segment', () {
    final slices = meshLike.slicesFrom(11000, 3000);
    expect(slices.map((s) => (s.segment, s.offsetInSegment, s.length)), [
      (0, 11000, 1000),
      (1, 0, 2000),
    ]);
  });

  test('empty segments are skipped, before and between', () {
    final layout = StagedUploadLayout([0, 10, 0, 0, 5, 0]);
    expect(layout.totalBytes, 15);
    final slices = _walk(layout, 4);
    _expectTiles(layout, slices);
    expect(slices.map((s) => s.segment).toSet(), {1, 4});
  });

  test('an unindexed mesh has four segments and no fifth', () {
    final layout = StagedUploadLayout([12, 12, 8, 16]);
    final slices = _walk(layout, 5);
    _expectTiles(layout, slices);
    expect(slices.map((s) => s.segment).toSet(), {0, 1, 2, 3});
  });

  test('at the end, or under a non-positive cap, nothing moves', () {
    expect(meshLike.slicesFrom(meshLike.totalBytes, 100), isEmpty);
    expect(meshLike.slicesFrom(0, 0), isEmpty);
    expect(meshLike.slicesFrom(0, -1), isEmpty);
    expect(StagedUploadLayout(const []).totalBytes, 0);
    expect(StagedUploadLayout(const []).slicesFrom(0, 100), isEmpty);
  });

  test('a cursor outside the buffer or a negative length is refused', () {
    expect(() => meshLike.slicesFrom(-1, 10), throwsRangeError);
    expect(
      () => meshLike.slicesFrom(meshLike.totalBytes + 1, 10),
      throwsRangeError,
    );
    expect(() => StagedUploadLayout([4, -1]), throwsArgumentError);
  });
}
