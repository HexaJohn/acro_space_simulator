// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The colony host's measurement loop (docs/plans/factory-floors.md §3
/// "Off-screen = measured steady state"): a floor edited in the colony is
/// measured once, its rates land through `applyFloorMeasure`, a pump while
/// it is in flight starts nothing new, and a template is never measured.
library;

import 'package:acro_space_simulator/application/factory/colony_floor_measurer.dart';
import 'package:acro_space_simulator/application/factory/floor_measure_runner.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../colony/factory_integration/factory_colony_fixture.dart';

/// [SyncFloorMeasureRunner], counting the jobs it is given.
class CountingRunner extends SyncFloorMeasureRunner {
  CountingRunner() : super(buildFloorForMeasure);
  int jobs = 0;

  @override
  Future<MeasuredRates> measure(FloorBlueprint bp,
      {MeasureSettings settings = MeasureSettings.standard, String? key}) {
    jobs++;
    return super.measure(bp, settings: settings, key: key);
  }
}

void main() {
  // An edited floor is queued, measured and applied: its rates become the
  // measured ones (not the seeded nominal second) and it is clean.
  test('a dirty floor is measured and applied', () async {
    final city = foundedColony();
    final lot = placeOnFreeLot(city, specOf('steelmill'));
    final rec = city.factoryFloors[lot]!
      ..designed = true
      ..dirty = true;
    final runner = CountingRunner();
    final m = ColonyFloorMeasurer(runner: runner);
    addTearDown(m.dispose);

    m.pump(city);
    // A second pump in the same frame must not start a second job.
    m.pump(city);
    await Future<void>.delayed(Duration.zero);

    expect(runner.jobs, 1);
    expect(m.applied, 1);
    expect(rec.dirty, isFalse);
    expect(rec.rates.seconds, greaterThan(1),
        reason: 'still the seeded rates: the measurement never landed');
    expect(rec.rates.outPerS['steel'], closeTo(1.5, 1.5 * 0.05),
        reason: 'the template layout measures within 5% of its spec');
    // Clean now: nothing more to start.
    m.pump(city);
    expect(runner.jobs, 1);
  });

  // A template floor runs on its seeded rates and is never queued.
  test('a template floor is never measured', () async {
    final city = foundedColony();
    placeOnFreeLot(city, specOf('steelmill'));
    final runner = CountingRunner();
    final m = ColonyFloorMeasurer(runner: runner);
    addTearDown(m.dispose);
    m.pump(city);
    await Future<void>.delayed(Duration.zero);
    expect(runner.jobs, 0);
  });

  // A floor edited again while its job ran gets the newer layout measured;
  // the older result is dropped by the revision check.
  test('a stale result is dropped and the new layout queued', () async {
    final city = foundedColony();
    final lot = placeOnFreeLot(city, specOf('steelmill'));
    final rec = city.factoryFloors[lot]!
      ..designed = true
      ..dirty = true;
    final runner = CountingRunner();
    final m = ColonyFloorMeasurer(runner: runner);
    addTearDown(m.dispose);
    m.pump(city);
    rec.rev++; // edited again before the result came back
    await Future<void>.delayed(Duration.zero);
    expect(m.applied, 0);
    expect(rec.dirty, isTrue);
    m.pump(city);
    await Future<void>.delayed(Duration.zero);
    expect(runner.jobs, 2);
    expect(m.applied, 1);
    expect(rec.dirty, isFalse);
  });
}
