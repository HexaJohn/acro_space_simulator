// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// How a colony runs its floors each tick (docs/plans/factory-floors.md §3
/// "Coupling to the colony", "Reward"): the flat-rate bypass, the port's
/// clipping, the 1.5x reward cap and the one-driver rule.
library;

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/economy/earth_market.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/city_factory_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_ledger.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/floor_blueprint.dart';
import 'package:flutter_test/flutter_test.dart';

import 'factory_colony_fixture.dart';

/// Colony seconds each comparison runs: long enough for a few hundred ticks
/// of every plant, short enough to stay under the 700-unit storage cap.
const double kRunS = 120;

/// One tick, as the colony screens drive it.
const double kTickS = 0.5;

/// A floor sim that only counts how often it is stepped.
class _CountingSim implements FactorySim {
  _CountingSim(this.blueprint);

  @override
  final FloorBlueprint blueprint;

  int steps = 0;

  @override
  int get layoutRev => 0;

  @override
  void step(double dt, FactoryColonyPort port) => steps++;

  @override
  FactoryLedger takeLedger() => FactoryLedger();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

/// Runs a fresh colony with one [type] plant for [kRunS] and returns the
/// stock change of each of the plant's goods, plus the plant's floor
/// seconds (0 when its floor never ran).
({Map<String, double> delta, double floorS}) runPlant(
  String type, {
  required bool floors,
  void Function(CitySim)? setup,
}) {
  final sim = foundedColony();
  sim.population = 300; // enough hands for the kit and the plant
  final spec = specOf(type);
  final lot = placeOnFreeLot(sim, spec);
  sim.factoryFloorsEnabled = floors;
  setup?.call(sim);
  final keys = {...spec.inputs.keys, ...spec.outputs.keys};
  final s0 = {for (final k in keys) k: sim.stockOf(k)};
  for (var t = 0.0; t < kRunS; t += kTickS) {
    sim.advance(kTickS);
  }
  return (
    delta: {for (final k in keys) k: sim.stockOf(k) - s0[k]!},
    floorS: sim.factoryFloors.takeLedger(lot).seconds,
  );
}

void expectSameWithin2pc(Map<String, double> a, Map<String, double> b) {
  for (final k in a.keys) {
    final tol = 0.02 * [a[k]!.abs(), b[k]!.abs()].reduce((x, y) => x > y ? x : y);
    expect(a[k]!, closeTo(b[k]!, tol + 1e-6), reason: k);
  }
}

void main() {
  // THE regression: a colony with template floors makes what it made before
  // floors existed. Without the seeded template rates the mill would make
  // nothing; with a double count it would make twice as much.
  group('regression: templates match the flat rate', () {
    test('steel mill', () {
      final on = runPlant('steelmill', floors: true);
      final off = runPlant('steelmill', floors: false);
      expect(on.floorS, greaterThan(kRunS * 0.9), reason: 'the floor ran');
      expect(off.floorS, 0, reason: 'the kill-switch never steps it');
      expect(off.delta['steel'], greaterThan(10), reason: 'the mill works');
      expectSameWithin2pc(on.delta, off.delta);
    });

    test('electronics plant', () {
      void feed(CitySim sim) {
        sim.stock['steel'] = 300; // its input, for the whole run
        sim.infinitePower = true; // power and compute for a kit colony
      }

      final on = runPlant('electronics', floors: true, setup: feed);
      final off = runPlant('electronics', floors: false, setup: feed);
      expect(on.floorS, greaterThan(kRunS * 0.9));
      expect(off.delta['electronics'], greaterThan(10));
      expectSameWithin2pc(on.delta, off.delta);
    });
  });

  // A designed floor that claims 10 steel/s (vs the spec's 1.5 + 0.4 tubes)
  // is held to 1.5x the template's raw-input-equivalent value: the cap
  // that stops one perfect floor breaking the colony's economy.
  test('the reward cap clips an overpowered designed floor', () {
    final sim = foundedColony();
    sim.population = 300;
    sim.infinitePower = true;
    sim.infiniteRobotics = true;
    final spec = specOf('steelmill');
    final lot = placeOnFreeLot(sim, spec);
    sim.factoryFloors.assign(lot, factoryTemplateFor('steelmill')!,
        designed: true,
        rates: const MeasuredRates(
            inPerS: {'ore': 2}, outPerS: {'steel': 10},
            powerKw: 30000, jobs: 35, seconds: 300));
    sim.stock['steel'] = 0;
    sim.stock['ore'] = 600;
    for (var t = 0.0; t < 60; t += kTickS) {
      sim.advance(kTickS);
    }
    final capValue = kFloorRewardCap * flatOutputValuePerS(spec.outputs) * 60;
    // The cap is on what the floor makes; the colony's multipliers (bounty,
    // events, biome) then apply to what lands, as on a flat-rate plant.
    final mult =
        sim.biomeMult('steel') * sim.bountyMult * sim.eventProductionMult;
    final capSteel = capValue / earthPrice('steel') * mult;
    expect(sim.stockOf('steel'), lessThanOrEqualTo(capSteel + 1e-6));
    expect(sim.stockOf('steel'), greaterThan(capSteel * 0.97),
        reason: 'held AT the cap, not below it');
    expect(capSteel, lessThan(10 * 60 * mult), reason: 'the cap did bind');
    expect(sim.stockOf('steel'),
        greaterThan(spec.outputs['steel']! * 60 * mult),
        reason: 'a design may still beat the template');
  });

  // Exactly one driver: the colony steps a floor open in the editor once a
  // tick (the editor watches, drivesSim false). Two drivers would double it.
  test('a live floor is stepped exactly once per tick', () {
    final sim = foundedColony();
    sim.population = 300;
    final lot = placeOnFreeLot(sim, specOf('steelmill'));
    late _CountingSim live;
    sim.factoryFloors.open(lot, (bp) => live = _CountingSim(bp));
    for (var i = 0; i < 7; i++) {
      sim.advance(kTickS);
    }
    expect(live.steps, 7);
  });

  group('CityFactoryPort', () {
    CityFactoryPort port(Map<String, double> stock,
            {double cap = 100, double allowance = 1e9}) =>
        CityFactoryPort(
            stock: stock,
            stockCap: cap,
            powerShare: 1,
            staffingShare: 1,
            valueAllowance: allowance);

    // A floor can't draw a commodity below zero.
    test('never takes more than stock holds', () {
      final s = {'ore': 3.0};
      final p = port(s);
      expect(p.take('ore', 5), 3);
      expect(s['ore'], 0);
      expect(p.take('ore', 1), 0);
      expect(p.take('water', 1), 0);
    });

    // The ore-cap invariant: a full store refuses, and the port says so.
    test('never gives beyond the storage cap, reporting what landed', () {
      final s = {'steel': 95.0};
      final p = port(s);
      expect(p.give('steel', 10), closeTo(5, 1e-12));
      expect(s['steel'], closeTo(100, 1e-12));
      expect(p.give('steel', 1), 0);
    });

    // Unused input handed back is a refund: no cap, no value charge.
    test('a refund goes back whole and costs no allowance', () {
      final s = {'ore': 10.0};
      final p = port(s, cap: 10, allowance: 0);
      expect(p.take('ore', 4), 4);
      expect(p.give('ore', 3), 3, reason: 'refund despite a zero allowance');
      expect(s['ore'], 9);
      expect(p.valueAllowance, 0);
      expect(p.give('ore', 2), 1, reason: 'one more refund unit, then cap');
    });

    // Output is limited by value, the 1.5x cap's currency.
    test('output stops when the value allowance runs out', () {
      final s = <String, double>{};
      final price = earthPrice('steel');
      final p = port(s, cap: 1e9, allowance: price * 2.5);
      expect(p.give('steel', 4), closeTo(2.5, 1e-9));
      expect(p.valueAllowance, closeTo(0, 1e-9));
      expect(p.clippedByCap, closeTo(1.5, 1e-9));
    });
  });
}
