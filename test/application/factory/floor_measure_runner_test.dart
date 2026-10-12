// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/application/factory/floor_measure_runner.dart';
import 'package:acro_space_simulator/application/factory/floor_measure_runner_isolate.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_measure.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../colony/factory/measure_fake_sim.dart';

FloorBlueprint _bp(int w, [String name = 'fake']) =>
    FloorBlueprint(name: name, hall: HallSize(w, 10));

/// Builder that always fails, to prove errors cross back.
FactorySim _boom(FloorBlueprint bp) => throw StateError('no such plant');

/// Off-thread re-measurement (docs/plans/factory-floors.md phase 6). The
/// inline and isolate runners must give the same rates as measuring
/// directly — the off-screen economy runs on them — and the queue must
/// coalesce repeat requests for one site.
void main() {
  test('sync runner matches measureBlueprint exactly', () async {
    // Why: the web (and tests) measure inline; the JSON round trip must not
    // change a single digit of the answer.
    final runner = SyncFloorMeasureRunner(buildFakeSim);
    for (final bp in [_bp(10), _bp(25), _bp(10, 'lumpy')]) {
      final direct = measureBlueprint(bp, buildFakeSim);
      final viaRunner = await runner.measure(bp);
      expect(viaRunner.toJson(), direct.toJson());
    }
    runner.dispose();
    await expectLater(runner.measure(_bp(10)), throwsStateError);
  });

  test('sync runner runs setup once and surfaces builder errors', () async {
    // Why: the worker contract (setup before the first build) must hold on
    // the inline path too, and a bad builder must fail the future, not throw.
    var setups = 0;
    final runner = SyncFloorMeasureRunner(buildFakeSim, setup: () => setups++);
    await runner.measure(_bp(10));
    await runner.measure(_bp(10));
    expect(setups, 1);
    await expectLater(
      SyncFloorMeasureRunner(_boom).measure(_bp(10)),
      throwsStateError,
    );
  });

  group('isolate runner', () {
    test('matches the direct measurement, in order', () async {
      // Why: the real path on desktop; a top-level builder crosses to the
      // worker and the rates come back as JSON identical to inline.
      final runner = PlatformFloorMeasureRunner(buildFakeSim);
      addTearDown(runner.dispose);
      final a = runner.measure(_bp(10));
      final b = runner.measure(_bp(30));
      expect(runner.pending, 2);
      expect(
        (await a).toJson(),
        measureBlueprint(_bp(10), buildFakeSim).toJson(),
      );
      expect(
        (await b).toJson(),
        measureBlueprint(_bp(30), buildFakeSim).toJson(),
      );
      expect(runner.pending, 0);
    });

    test(
      'a queued request is superseded by a newer one for the same key',
      () async {
        // Why: closing the editor three times queues one measurement, and all
        // callers get the newest layout's rates.
        final runner = PlatformFloorMeasureRunner(buildFakeSim);
        addTearDown(runner.dispose);
        final first = runner.measure(_bp(10), key: 'other'); // in flight
        final old = runner.measure(_bp(10), key: 'lot-1');
        final newer = runner.measure(_bp(40), key: 'lot-1');
        expect(runner.pending, 2);
        final want = measureBlueprint(_bp(40), buildFakeSim).toJson();
        expect((await old).toJson(), want);
        expect((await newer).toJson(), want);
        await first;
      },
    );

    test('builder errors fail the future; dispose fails what waits', () async {
      // Why: a broken layout must not wedge the queue, and a disposed runner
      // must not leave futures hanging.
      final bad = PlatformFloorMeasureRunner(_boom);
      addTearDown(bad.dispose);
      await expectLater(bad.measure(_bp(10)), throwsStateError);

      final runner = PlatformFloorMeasureRunner(buildFakeSim);
      final f = runner.measure(_bp(10));
      runner.dispose();
      await expectLater(f, throwsStateError);
    });
  });
}
