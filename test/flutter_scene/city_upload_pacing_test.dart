// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The mesh step's pacing: a merged group's upload is resumable, moves at
// most what the frame has left, and the frame's byte cap is shared across
// every group it touches. The engine's staged upload needs a GPU context,
// so the step is driven through a fake that only counts bytes; what is
// pinned here is CityNodes's bookkeeping, not the engine's copy.

import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_nodes.dart';
import 'package:flutter_test/flutter_test.dart';

/// A staged upload that moves bytes without a buffer, and remembers the cap
/// of every call so the test can see what the step asked of it.
class _FakeUpload implements CityStagedUpload {
  _FakeUpload(this.totalBytes);
  @override
  final int totalBytes;
  @override
  int uploadedBytes = 0;
  final List<int> caps = [];

  @override
  bool step(int maxBytes) {
    caps.add(maxBytes);
    if (maxBytes > 0) {
      final left = totalBytes - uploadedBytes;
      uploadedBytes += maxBytes < left ? maxBytes : left;
    }
    return uploadedBytes >= totalBytes;
  }
}

/// A step over a fake of [bytes], counting the residency callbacks.
(CityMeshUploadStep, _FakeUpload, List<int>) _step(int bytes) {
  final upload = _FakeUpload(bytes);
  final finished = <int>[];
  var staged = 0;
  final step = CityMeshUploadStep(
    bytes,
    () {
      staged++;
      return upload;
    },
    () => finished.add(staged),
  );
  return (step, upload, finished);
}

void main() {
  const kib = 1024;

  test('a step is not done while bytes remain, and stages once at the end', () {
    final (step, upload, finished) = _step(1000 * kib);
    expect(step.done, isFalse);
    expect(step.remainingBytes, 1000 * kib);

    expect(step.advance(400 * kib), 400 * kib);
    expect(step.done, isFalse);
    expect(step.uploadedBytes, 400 * kib);
    expect(step.remainingBytes, 600 * kib);
    expect(finished, isEmpty, reason: 'staged before the mesh was resident');

    expect(step.advance(400 * kib), 400 * kib);
    expect(step.done, isFalse);

    // The last slice is what is left, not the cap.
    expect(step.advance(400 * kib), 200 * kib);
    expect(step.done, isTrue);
    expect(step.remainingBytes, 0);
    expect(finished, [1], reason: 'the node is staged exactly once');
    expect(upload.caps, [400 * kib, 400 * kib, 400 * kib]);

    // Done is done: nothing more moves and nothing is staged again.
    expect(step.advance(400 * kib), 0);
    expect(finished, [1]);
  });

  test('the upload is staged on the first advance, not at construction', () {
    var staged = 0;
    final step = CityMeshUploadStep(10, () {
      staged++;
      return _FakeUpload(10);
    }, () {});
    expect(staged, 0);
    expect(step.totalBytes, 10, reason: 'the estimate stands in until then');
    step.advance(4);
    expect(staged, 1);
    step.advance(4);
    expect(staged, 1, reason: 'one staging per step');
  });

  test('a cap of zero moves nothing and stages nothing', () {
    final (step, upload, finished) = _step(100);
    expect(step.advance(0), 0);
    expect(step.advance(-5), 0);
    expect(step.done, isFalse);
    expect(upload.caps, isEmpty, reason: 'the engine was not even asked');
    expect(finished, isEmpty);
  });

  test('the true size replaces the estimate once the upload exists', () {
    // The engine adds a colour stream the mesher does not count.
    final upload = _FakeUpload(116);
    final step = CityMeshUploadStep(100, () => upload, () {});
    expect(step.totalBytes, 100);
    step.advance(50);
    expect(step.totalBytes, 116);
    expect(step.remainingBytes, 66);
  });

  group("the frame's byte cap is shared across groups", () {
    test('two groups: the second gets what the first left', () {
      final (a, uploadA, finishedA) = _step(600 * kib);
      final (b, uploadB, finishedB) = _step(600 * kib);
      final cap = 768 * kib;

      // Frame one, as the build loop runs it: the nearest tile's steps in
      // order, each taking what is left.
      final frame1 = CityUploadByteBudget(cap);
      expect(frame1.take(a), 600 * kib);
      expect(a.done, isTrue);
      expect(frame1.remaining, 168 * kib);
      expect(frame1.take(b), 168 * kib);
      expect(b.done, isFalse);
      expect(frame1.remaining, 0);
      expect(frame1.spent, cap, reason: 'the frame moved exactly its cap');
      expect(uploadB.caps, [168 * kib], reason: 'b was offered only the rest');
      expect(finishedA, [1]);
      expect(finishedB, isEmpty);

      // Nothing left: a further take moves nothing and the step is still
      // there for the next frame.
      expect(frame1.take(b), 0);
      expect(b.remainingBytes, 432 * kib);

      // Frame two: a fresh cap, and b finishes within it.
      final frame2 = CityUploadByteBudget(cap);
      expect(frame2.take(b), 432 * kib);
      expect(b.done, isTrue);
      expect(frame2.spent, 432 * kib);
      expect(finishedB, [1]);
      expect(uploadA.caps, [768 * kib]);
    });

    test('a group larger than the cap takes several frames, one slice each',
        () {
      final (step, upload, finished) = _step(2000 * kib);
      final cap = 768 * kib;
      var frames = 0;
      while (!step.done) {
        final frame = CityUploadByteBudget(cap);
        frame.take(step);
        expect(frame.spent, lessThanOrEqualTo(cap));
        frames++;
      }
      expect(frames, 3);
      expect(upload.caps, [cap, cap, cap]);
      expect(upload.uploadedBytes, 2000 * kib);
      expect(finished, [1]);
    });
  });

  test('the default cap is under eight milliseconds of raster copy', () {
    // ~10 ms per MB on ANGLE/GLES: 768 KiB is ~7.5 ms.
    expect(CityNodes.uploadBytesPerFrame, 768 * kib);
    expect(CityNodes.uploadBytesPerFrame / (1024 * 1024) * 10, lessThan(8));
  });
}
