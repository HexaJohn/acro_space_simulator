// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_nodes.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/frame_budget.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/terrain/terrain_nodes.dart';
import 'package:flutter_test/flutter_test.dart';

/// The frame budget is numbers in and a number out — the measured build,
/// the engine's fixed cost, the target — so the whole policy (the cut, the
/// halving, the slow recovery, the clamps, the off switch) is walked
/// through here without a frame. The derivations from slice to the
/// streamers' knobs are pure too, and pinned at the reference slice so
/// the budget changes nothing there.
void main() {
  const kib = 1024;
  setUp(() {
    FrameBudget.enabled = true;
    FrameBudget.targetMs = 15.0;
  });
  tearDown(() {
    FrameBudget.enabled = true;
    FrameBudget.targetMs = 15.0;
    FrameBudget.stallMs = 6.0;
    FrameBudget.judgeBySpend = true;
    FrameBudget.pacerFollowsSlice = true;
    CityFrameBudgets.scaleBytes = false;
    CityNodes.frameSliceMs = null;
    TerrainNodes.frameSliceMs = null;
  });

  group('the slice is the target less the fixed cost less the margin', () {
    test('with no measured frame yet, from the engine alone', () {
      final b = FrameBudget();
      expect(b.beginFrame(engineMs: 3), closeTo(15 - 3 - 0.5, 1e-9));
      expect(b.fixedMs, 3);
      expect(b.sliceMs, closeTo(11.5, 1e-9));
      expect(b.overruns, 0);
    });

    test('the overhead is what the build cost beyond the budgeted parts', () {
      final b = FrameBudget();
      // Built 10 ms: the engine's 3 and the streamers' 4 leave 3 ms of
      // overhead, weighted in at a tenth.
      b.feed(10);
      b.beginFrame(engineMs: 3, spentMs: 4);
      expect(b.overheadMs, closeTo(0.3, 1e-9));
      expect(b.fixedMs, closeTo(3.3, 1e-9));
      expect(b.sliceMs, closeTo(15 - 3.3 - 0.5, 1e-9));
    });

    test('a frame under its own slice is not negative overhead', () {
      final b = FrameBudget();
      b.beginFrame(engineMs: 3); // slice 11.5, assumed spent in full
      b.feed(4); // ...but the frame took 4: the sample clamps at zero
      b.beginFrame(engineMs: 3);
      expect(b.overheadMs, 0);
    });

    test('the target is a knob', () {
      FrameBudget.targetMs = 8;
      final b = FrameBudget();
      expect(b.beginFrame(engineMs: 2), closeTo(8 - 2 - 0.5, 1e-9));
    });
  });

  group('an overrun halves the slice, judged once per measured frame', () {
    test('halving', () {
      final b = FrameBudget();
      b.beginFrame(engineMs: 1);
      expect(b.sliceMs, 12, reason: 'the ceiling, the room being 13.5');
      // The streamers spent eighteen of the twenty: the overrun is theirs
      // (a frame they could not explain would be a stall, below).
      b.feed(20);
      expect(b.beginFrame(engineMs: 1, spentMs: 18), 6);
      expect(b.overruns, 1);
      // The same measured frame is not judged twice: with nothing new
      // fed, the next frame keeps the slice.
      expect(b.beginFrame(engineMs: 1, spentMs: 18), 6);
      expect(b.overruns, 1);
      b.feed(20);
      expect(b.beginFrame(engineMs: 1, spentMs: 18), 3);
      b.feed(20);
      expect(b.beginFrame(engineMs: 1, spentMs: 18), 1.5);
      b.feed(20);
      expect(b.beginFrame(engineMs: 1, spentMs: 18), 0.75);
      b.feed(20);
      expect(b.beginFrame(engineMs: 1, spentMs: 18), 0.5,
          reason: 'the floor');
      b.feed(20);
      expect(b.beginFrame(engineMs: 1, spentMs: 18), 0.5);
      expect(b.overruns, 6);
      expect(b.stalls, 0);
    });

    test("an overrun the frame's parts do not explain is a stall", () {
      final b = FrameBudget();
      b.beginFrame(engineMs: 5);
      expect(b.sliceMs, closeTo(9.5, 1e-9));
      // Forty milliseconds with the engine at five and the streamers at
      // three: a collector pause, not theirs. The ceiling stands and the
      // overhead learns nothing from it.
      b.feed(40);
      expect(b.beginFrame(engineMs: 5, spentMs: 3), closeTo(9.5, 1e-9));
      expect(b.stalls, 1);
      expect(b.overruns, 0);
      expect(b.overheadMs, 0);
      expect(b.ceilingMs, 12);
      // Twenty with the streamers at twelve against a slice of 9.5:
      // three unexplained, and they spent past their slice — theirs.
      b.feed(20);
      expect(b.beginFrame(engineMs: 5, spentMs: 12), 6);
      expect(b.overruns, 1);
      expect(b.stalls, 1);
    });

    test('stallMs zero, judged by the frame, halves on every overrun', () {
      FrameBudget.stallMs = 0;
      FrameBudget.judgeBySpend = false;
      final b = FrameBudget();
      b.beginFrame(engineMs: 5);
      b.feed(40);
      expect(b.beginFrame(engineMs: 5, spentMs: 3), lessThan(9.5));
      expect(b.overruns, 1);
      expect(b.stalls, 0);
    });

    test('an overrun the streamers did not spend shrinks the room, not the '
        'ceiling', () {
      final b = FrameBudget();
      b.beginFrame(engineMs: 5);
      expect(b.sliceMs, closeTo(9.5, 1e-9));
      // Sixteen with the engine at five and the streamers at five of
      // their 9.5: six unexplained — on the stall line, not past it — and
      // not their spend. The overhead takes the six (a tenth of it) and
      // the room shrinks by that; the ceiling stands.
      b.feed(16);
      expect(b.beginFrame(engineMs: 5, spentMs: 5), closeTo(8.9, 1e-9));
      expect(b.overruns, 0);
      expect(b.fixedOverruns, 1);
      expect(b.stalls, 0);
      expect(b.ceilingMs, 12);
      expect(b.overheadMs, closeTo(0.6, 1e-9));
      // Judged by the frame instead, the same frame halves.
      FrameBudget.judgeBySpend = false;
      final c = FrameBudget();
      c.beginFrame(engineMs: 5);
      c.feed(16);
      expect(c.beginFrame(engineMs: 5, spentMs: 5), 6);
      expect(c.overruns, 1);
    });

    test('the slice is the lesser of the ceiling and the room', () {
      final b = FrameBudget();
      b.feed(20);
      // Spent all 19 beyond the engine: no overhead learned, so the fixed
      // cost below is the engine alone.
      b.beginFrame(engineMs: 1, spentMs: 19); // ceiling 6
      expect(b.overheadMs, 0);
      // Room 4.5 is under the ceiling; the fixed cost wins.
      expect(b.beginFrame(engineMs: 10), closeTo(4.5, 1e-9));
    });
  });

  group('the slice recovers half a millisecond a frame under the target', () {
    test('recovery, to the room and no further', () {
      final b = FrameBudget();
      b.feed(20);
      b.beginFrame(engineMs: 1, spentMs: 19); // 6
      final seen = <double>[];
      for (var i = 0; i < 14; i++) {
        b.feed(10);
        seen.add(b.beginFrame(engineMs: 1));
      }
      expect(seen.take(12).toList(),
          [6.5, 7, 7.5, 8, 8.5, 9, 9.5, 10, 10.5, 11, 11.5, 12]);
      expect(seen.skip(12).toList(), [12, 12], reason: 'the ceiling');
      expect(b.overruns, 1);
    });

    test('no oscillation: a spike answered at once, withdrawn slowly', () {
      final b = FrameBudget();
      b.beginFrame(engineMs: 1);
      b.feed(20);
      final low = b.beginFrame(engineMs: 1, spentMs: 19);
      var frames = 0;
      while (b.sliceMs < 12) {
        b.feed(10);
        b.beginFrame(engineMs: 1);
        frames++;
      }
      expect(low, 6);
      expect(frames, 12, reason: 'twelve frames to earn back one halving');
    });
  });

  group('clamps', () {
    test('a fixed cost over the target leaves the floor, never zero', () {
      final b = FrameBudget();
      expect(b.beginFrame(engineMs: 20), 0.5);
      expect(b.beginFrame(engineMs: 14.8), 0.5);
    });

    test('an empty frame gets the ceiling, not the whole target', () {
      final b = FrameBudget();
      expect(b.beginFrame(engineMs: 0), 12);
    });

    test('the floor and ceiling are knobs', () {
      final b = FrameBudget(minSliceMs: 1, maxSliceMs: 8);
      expect(b.beginFrame(engineMs: 0), 8);
      expect(b.beginFrame(engineMs: 20), 1);
    });

    test('the scale against the reference is a quarter to one', () {
      expect(FrameBudget.scaleOf(9), 1);
      expect(FrameBudget.scaleOf(12), 1, reason: 'never above the tuning');
      expect(FrameBudget.scaleOf(4.5), 0.5);
      expect(FrameBudget.scaleOf(0.5), 0.25);
    });
  });

  group('the collector pacer follows the slice', () {
    test('full at the reference, gone at the floor, one when not following',
        () {
      final b = FrameBudget();
      b.beginFrame(engineMs: 5.5); // room 9, the reference
      expect(b.pacerScale, closeTo(1.0, 1e-9));
      b.beginFrame(engineMs: 10); // room 4.5
      expect(b.pacerScale, closeTo(0.5, 1e-9));
      b.beginFrame(engineMs: 20); // the floor
      expect(b.pacerScale, closeTo(0.5 / 9, 1e-9));
      FrameBudget.pacerFollowsSlice = false;
      expect(b.pacerScale, 1.0);
      FrameBudget.pacerFollowsSlice = true;
      FrameBudget.enabled = false;
      b.beginFrame(engineMs: 20);
      expect(b.pacerScale, 1.0, reason: 'the budget off leaves the pacer');
    });
  });

  group('disabled is a passthrough', () {
    test('the slice reads the reference and the consumers read null', () {
      FrameBudget.enabled = false;
      final b = FrameBudget();
      b.feed(40);
      expect(b.beginFrame(engineMs: 12), FrameBudget.referenceSliceMs);
      expect(b.sliceForConsumers, isNull);
      expect(b.overruns, 0, reason: 'not judging');
      // Back on, the state is where it was: nothing was halved while off.
      FrameBudget.enabled = true;
      expect(b.beginFrame(engineMs: 1), 12);
      expect(b.sliceForConsumers, 12);
    });
  });

  group('the colony streamer derives its three knobs from the slice', () {
    test('null hands the fixed knobs back untouched', () {
      final b = CityFrameBudgets.forSlice(null,
          buildMs: 9, uploadMs: 2, baseUploadBytes: 768 * kib);
      expect(b.buildMs, 9);
      expect(b.uploadMs, 2);
      expect(b.uploadBytes, 768 * kib);
    });

    test('at the reference slice the bytes are the fixed cap', () {
      final b = CityFrameBudgets.forSlice(9,
          buildMs: 9, uploadMs: 2, baseUploadBytes: 768 * kib);
      expect(b.buildMs, closeTo(5.4, 1e-9), reason: '60% of the slice');
      expect(b.uploadMs, 2, reason: 'min(2, 30% of 9 = 2.7)');
      expect(b.uploadBytes, 768 * kib);
    });

    test('by default the bytes do not scale with the slice', () {
      expect(CityFrameBudgets.scaleBytes, isFalse);
      final b = CityFrameBudgets.forSlice(0.5,
          buildMs: 9, uploadMs: 2, baseUploadBytes: 768 * kib);
      expect(b.buildMs, closeTo(0.3, 1e-9));
      expect(b.uploadBytes, 768 * kib,
          reason: "the cap is the raster thread's tolerance, not this "
              "thread's time");
    });

    test('a short slice cuts all three, the bytes to a quarter at least', () {
      CityFrameBudgets.scaleBytes = true;
      final b = CityFrameBudgets.forSlice(4,
          buildMs: 9, uploadMs: 2, baseUploadBytes: 768 * kib);
      expect(b.buildMs, closeTo(2.4, 1e-9));
      expect(b.uploadMs, closeTo(1.2, 1e-9));
      expect(b.uploadBytes, (768 * kib * 4 / 9).round());
      final floor = CityFrameBudgets.forSlice(0.5,
          buildMs: 9, uploadMs: 2, baseUploadBytes: 768 * kib);
      expect(floor.buildMs, closeTo(0.3, 1e-9));
      expect(floor.uploadMs, closeTo(0.15, 1e-9));
      expect(floor.uploadBytes, 192 * kib);
    });

    test('a long slice builds longer but never uploads more bytes', () {
      final b = CityFrameBudgets.forSlice(12,
          buildMs: 9, uploadMs: 2, baseUploadBytes: 768 * kib);
      expect(b.buildMs, closeTo(7.2, 1e-9));
      expect(b.uploadMs, 2);
      expect(b.uploadBytes, 768 * kib,
          reason: 'the raster thread pays for the bytes, not this one');
    });

    test('CityNodes reads its statics through the same derivation', () {
      final fixed = CityNodes.budgetsFor(null);
      expect(fixed.buildMs, CityNodes.buildBudgetMs);
      expect(fixed.uploadMs, CityNodes.uploadBudgetMs);
      expect(fixed.uploadBytes, CityNodes.uploadBytesPerFrame);
      final ref = CityNodes.budgetsFor(FrameBudget.referenceSliceMs);
      expect(ref.uploadBytes, CityNodes.uploadBytesPerFrame);
      expect(CityNodes.revealShareOf(CityNodes.uploadBytesPerFrame),
          CityNodes.revealBytesPerFrameWhileStaging);
    });
  });

  group('the ground streamer scales its counts, never below one', () {
    test('null hands the fixed knobs back untouched', () {
      final t = TerrainFrameBudgets.forSlice(null,
          uploadsPerFrame: 4, meshJobsInFlight: 6, batchRebuildsPerFrame: 8);
      expect(t.uploadsPerFrame, 4);
      expect(t.meshJobsInFlight, 6);
      expect(t.batchRebuildsPerFrame, 8);
    });

    test('the reference slice is the fixed knobs; half is half', () {
      final ref = TerrainFrameBudgets.forSlice(9,
          uploadsPerFrame: 4, meshJobsInFlight: 6, batchRebuildsPerFrame: 8);
      expect([ref.uploadsPerFrame, ref.meshJobsInFlight,
          ref.batchRebuildsPerFrame], [4, 6, 8]);
      final half = TerrainFrameBudgets.forSlice(4.5,
          uploadsPerFrame: 4, meshJobsInFlight: 6, batchRebuildsPerFrame: 8);
      expect([half.uploadsPerFrame, half.meshJobsInFlight,
          half.batchRebuildsPerFrame], [2, 3, 4]);
    });

    test('the floor keeps one of each a frame', () {
      final t = TerrainFrameBudgets.forSlice(0.5,
          uploadsPerFrame: 1, meshJobsInFlight: 1, batchRebuildsPerFrame: 1);
      expect([t.uploadsPerFrame, t.meshJobsInFlight, t.batchRebuildsPerFrame],
          [1, 1, 1]);
    });

    test('TerrainNodes reads its statics through the same derivation', () {
      final fixed = TerrainNodes.budgetsFor(null);
      expect(fixed.uploadsPerFrame, TerrainNodes.uploadBudgetPerFrame);
      expect(fixed.meshJobsInFlight, TerrainNodes.meshBudgetPerFrame);
      expect(
          fixed.batchRebuildsPerFrame, TerrainNodes.batchRebuildBudgetPerFrame);
      TerrainNodes.frameSliceMs = 4.5;
      expect(TerrainNodes.frameBudgets.uploadsPerFrame,
          (TerrainNodes.uploadBudgetPerFrame / 2).round());
    });
  });
}
