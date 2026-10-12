// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_measure.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:flutter_test/flutter_test.dart';

import 'measure_fake_sim.dart';

FloorBlueprint _bp([String name = 'fake', int w = 10]) =>
    FloorBlueprint(name: name, hall: HallSize(w, 10));

/// The measurement harness (docs/plans/factory-floors.md §3, phase 6): every
/// off-screen plant runs on the numbers this returns, so they must be the
/// floor's true steady-state rates — not its start-up, not a lucky window.
void main() {
  test('measures known rates exactly', () {
    // Why: aggregate mode is only as right as this; a fake with exact rates
    // pins the arithmetic (per-second division, power from energy, jobs).
    final r = measureFloor(FakeSim(_bp()));
    expect(r.inPerS['ore'], closeTo(2.0, 1e-9));
    expect(r.outPerS['steel'], closeTo(1.5, 1e-9));
    expect(r.outPerS['tubes'], closeTo(0.4, 1e-9));
    expect(r.powerKw, closeTo(kFakeKw, 1e-9));
    expect(r.jobs, 12);
  });

  test('warm-up is discarded', () {
    // Why: a floor that ships nothing for its first 20 s must not read low.
    // With warm-up off, the filling seconds drag the measured rate down.
    const full = MeasureSettings(warmupS: 0, earlyStop: false, windowS: 60);
    final cold = measureFloor(FakeSim(_bp()), settings: full);
    expect(cold.outPerS['steel'], closeTo(1.5 * 40 / 60, 1e-9));
    final warm = measureFloor(
      FakeSim(_bp()),
      settings: const MeasureSettings(earlyStop: false, windowS: 60),
    );
    expect(warm.outPerS['steel'], closeTo(1.5, 1e-9));
  });

  test('a settled floor stops early; earlyStop off runs the full window', () {
    // Why: re-measures run on a worker for every edited plant; a steady floor
    // must not pay the whole 300 s cap.
    final early = measureFloor(FakeSim(_bp()));
    expect(early.seconds, kMeasureMinWindows * kMeasureSubWindowS);
    final full = measureFloor(
      FakeSim(_bp()),
      settings: const MeasureSettings(earlyStop: false),
    );
    expect(full.seconds, kMeasureWindowS);
    expect(full.outPerS['steel'], closeTo(early.outPerS['steel']!, 1e-9));
  });

  test('lumpy output never stops early and lands within one lump', () {
    // Why: two equal windows of a lumpy floor (4 and 4 lumps of a 7 s cycle)
    // would end the run 7% low; against the running mean it runs to the cap.
    final r = measureFloor(FakeSim(_bp(), cycleS: 7));
    expect(r.seconds, kMeasureWindowS);
    // One lump = 7 s of output; over 300 s that is at most 7/300 = 2.3%.
    expect(r.outPerS['steel']! / 1.5, closeTo(1, 7 / kMeasureWindowS + 1e-9));
  });

  test('a floor that ships nothing runs to the cap and reports zero out', () {
    // Why: two empty windows "agree", but empty is filling, not settled.
    final r = measureFloor(FakeSim(_bp(), startupS: 1e9));
    expect(r.seconds, kMeasureWindowS);
    expect(r.outPerS['steel'] ?? 0, 0);
    expect(r.inPerS['ore'], closeTo(2.0, 1e-9));
  });

  test('a finite port limits what is measured', () {
    // Why: measuring against the colony's real stock (not the sandbox) must
    // show the scarcity: half the ore, half the output.
    final port = StockColonyPort(stock: {'ore': 1e9}, powerShare: 0.5);
    final r = measureFloor(FakeSim(_bp()), port: port);
    expect(r.outPerS['steel'], closeTo(0.75, 1e-9));
  });

  test('measureBlueprint builds and measures; same answer every run', () {
    // Why: the runner and the store go through the builder; determinism is
    // what lets a measurement be cached in the save.
    final a = measureBlueprint(_bp('x', 20), buildFakeSim);
    final b = measureBlueprint(_bp('x', 20), buildFakeSim);
    expect(a.outPerS['steel'], closeTo(3.0, 1e-9));
    expect(a.toJson(), b.toJson());
  });

  test('measureSaved restores a floor from runtime JSON and measures it', () {
    // Why: wave 3 may measure a floor's saved state, not just its layout.
    final r = measureSaved(
      FakeSim(_bp()).toJson(),
      (j) => FakeSim(
        FloorBlueprint.fromJson((j['bp'] as Map).cast<String, Object?>()),
      ),
    );
    expect(r.outPerS['tubes'], closeTo(0.4, 1e-9));
  });

  test('settings and rates survive JSON', () {
    // Why: both cross to the worker isolate as JSON.
    const s = MeasureSettings(
      warmupS: 5,
      windowS: 50,
      subWindowS: 5,
      tolerance: 0.1,
      earlyStop: false,
    );
    final back = MeasureSettings.fromJson(s.toJson());
    expect(back.toJson(), s.toJson());
    final r = measureFloor(FakeSim(_bp()));
    expect(MeasuredRates.fromJson(r.toJson()).toJson(), r.toJson());
  });
}
