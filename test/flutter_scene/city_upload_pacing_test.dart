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

  group('the reveal shows a swapped tile a chunk at a time', () {
    /// A reveal over chunks of [bytes] each, with what each showed and
    /// how many times the old set was dropped.
    (CityTileReveal, List<bool>, List<int>) reveal(List<int> bytes) {
      final shown = List.filled(bytes.length, false);
      final dropped = <int>[];
      final chunks = [
        for (var i = 0; i < bytes.length; i++)
          CityRevealChunk(bytes[i], () => shown[i] = true),
      ];
      final r = CityTileReveal(chunks,
          onDone: () => dropped.add(shown.where((s) => s).length));
      return (r, shown, dropped);
    }

    test('two chunks under the cap together go on consecutive frames', () {
      final cap = 768 * kib;
      final (r, shown, dropped) = reveal([700 * kib, 700 * kib]);
      expect(r.remainingChunks, 2);
      expect(r.remainingBytes, 1400 * kib);

      final frame1 = CityUploadByteBudget(cap);
      expect(r.advance(frame1, first: true), 1);
      expect(shown, [true, false]);
      expect(frame1.spent, 700 * kib);
      expect(r.done, isFalse);
      expect(dropped, isEmpty, reason: 'the old set stays until the last');
      // Nothing more this frame: the second would take the frame over.
      expect(r.advance(frame1), 0);

      final frame2 = CityUploadByteBudget(cap);
      expect(r.advance(frame2, first: true), 1);
      expect(shown, [true, true]);
      expect(r.done, isTrue);
      expect(dropped, [2], reason: 'dropped once, with every chunk shown');
      expect(r.remainingChunks, 0);

      // Done is done.
      expect(r.advance(CityUploadByteBudget(cap), first: true), 0);
      expect(dropped, [2]);
    });

    test('small chunks fill a frame; a big one waits for its own', () {
      final cap = 768 * kib;
      final (r, shown, _) = reveal([200 * kib, 200 * kib, 600 * kib]);
      final frame = CityUploadByteBudget(cap);
      expect(r.advance(frame, first: true), 2);
      expect(shown, [true, true, false]);
      expect(frame.remaining, 368 * kib);
      expect(r.advance(CityUploadByteBudget(cap), first: true), 1);
      expect(r.done, isTrue);
    });

    test("the frame's first reveal runs whatever the chunk costs", () {
      // A chunk over the cap — the chunk cap is two megabytes, the frame's
      // is less — would otherwise never show at all.
      final cap = 768 * kib;
      final (r, shown, _) = reveal([1024 * kib, 100 * kib]);
      final frame = CityUploadByteBudget(cap);
      expect(r.advance(frame, first: true), 1);
      expect(shown, [true, false]);
      expect(frame.remaining, lessThan(0));
      // And nothing else moves this frame: a mesh step offered what is
      // left gets nothing.
      final (step, upload, _) = _step(100 * kib);
      expect(frame.take(step), 0);
      expect(upload.caps, isEmpty);
    });

    test('a reveal that is not the frame\'s first waits for the bytes', () {
      final cap = 768 * kib;
      final (r, shown, _) = reveal([500 * kib]);
      final frame = CityUploadByteBudget(cap)..spend(400 * kib);
      expect(r.advance(frame), 0);
      expect(shown, [false]);
      expect(r.advance(CityUploadByteBudget(cap)), 1);
    });

    test('the staging takes what the reveals left', () {
      final cap = 768 * kib;
      final (r, _, _) = reveal([500 * kib]);
      final frame = CityUploadByteBudget(cap);
      r.advance(frame, first: true);
      final (step, upload, _) = _step(600 * kib);
      expect(frame.take(step), 268 * kib);
      expect(upload.caps, [268 * kib]);
      expect(frame.spent, cap);
    });

    test('a tile hidden mid-reveal finishes on re-attach', () {
      // Hidden, the tile is skipped by the pass: no advance. Its cursor
      // keeps, and the frames after it is attached again carry on from
      // the chunk it stopped at, dropping the old set only at the end.
      final cap = 768 * kib;
      final (r, shown, dropped) = reveal([700 * kib, 700 * kib, 700 * kib]);
      r.advance(CityUploadByteBudget(cap), first: true);
      expect(shown, [true, false, false]);
      // Two frames hidden: nothing happens to it.
      expect(shown, [true, false, false]);
      expect(dropped, isEmpty);
      expect(r.done, isFalse);
      // Back in view.
      r.advance(CityUploadByteBudget(cap), first: true);
      expect(shown, [true, true, false]);
      expect(dropped, isEmpty);
      r.advance(CityUploadByteBudget(cap), first: true);
      expect(shown, [true, true, true]);
      expect(dropped, [3]);
    });

    test('no chunks: done at once, the old set dropped', () {
      final (r, _, dropped) = reveal([]);
      expect(r.advance(CityUploadByteBudget(1), first: true), 0);
      expect(r.done, isTrue);
      expect(dropped, [0]);
    });

    group('the reveals leave the staging half the frame', () {
      // The build loop's frame: a tile mid-reveal and a tile in the queue
      // with a geometry to stage. The reveals ran first and took the whole
      // cap, and while a zoom's tiles revealed nothing behind them was
      // staged; now they may take half of it when anything is stageable.
      final cap = 768 * kib;
      final share = CityNodes.revealBytesPerFrameWhileStaging;

      test('the share is half the frame', () {
        expect(share, 384 * kib);
        expect(CityUploadByteBudget(cap, revealCap: share).revealCap, share);
        // Alone, the reveals have the cap; a share over it is the cap.
        expect(CityUploadByteBudget(cap).revealCap, cap);
        expect(CityUploadByteBudget(cap, revealCap: 2 * cap).revealCap, cap);
      });

      test('a revealing tile and a stageable tile share a frame', () {
        final (r, shown, _) = reveal([300 * kib, 300 * kib, 300 * kib]);
        final frame = CityUploadByteBudget(cap, revealCap: share);
        // One chunk: the second would take the reveals over their share.
        expect(r.advance(frame, first: true), 1);
        expect(shown, [true, false, false]);
        expect(frame.revealRemaining, 84 * kib);
        expect(frame.remaining, 468 * kib);
        // The staging gets the rest — at least half the frame.
        final (step, upload, _) = _step(600 * kib);
        expect(frame.take(step), 468 * kib);
        expect(upload.caps, [468 * kib]);
        expect(frame.spent, cap);
        // Next frame the reveal carries on, from the chunk it stopped at.
        expect(r.advance(CityUploadByteBudget(cap, revealCap: share),
            first: true), 1);
        expect(shown, [true, true, false]);
      });

      test("the frame's first chunk shows over the share", () {
        // A chunk over the share still shows, as one over the cap does:
        // what is left is the staging's, however little.
        final (r, shown, _) = reveal([500 * kib, 100 * kib]);
        final frame = CityUploadByteBudget(cap, revealCap: share);
        expect(r.advance(frame, first: true), 1);
        expect(shown, [true, false]);
        expect(frame.revealRemaining, lessThan(0));
        expect(frame.remaining, 268 * kib);
        final (step, _, _) = _step(600 * kib);
        expect(frame.take(step), 268 * kib);
      });

      test('a second tile\'s reveal waits on the share too', () {
        final (a, shownA, _) = reveal([300 * kib]);
        final (b, shownB, _) = reveal([100 * kib]);
        final frame = CityUploadByteBudget(cap, revealCap: share);
        expect(a.advance(frame, first: true), 1);
        expect(b.advance(frame), 0, reason: '84 KiB of the share is left');
        expect(shownA, [true]);
        expect(shownB, [false]);
        expect(frame.remaining, 468 * kib);
      });

      test('nothing stageable: the reveals take the whole cap', () {
        final (r, shown, _) = reveal([300 * kib, 300 * kib, 300 * kib]);
        final frame = CityUploadByteBudget(cap);
        expect(r.advance(frame, first: true), 2);
        expect(shown, [true, true, false]);
        expect(frame.revealRemaining, 168 * kib);
        expect(frame.remaining, 168 * kib);
      });
    });
  });
}
