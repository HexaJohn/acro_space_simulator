// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Road upkeep: every road costs its type's rate per week to keep — on
/// piers and underground at multiples of it — and the treasury pays it per
/// second of colony time.
library;

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_catalog.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final bodies = RealSolarSystem.build().all.where((b) => !b.isStar).toList();
  CitySim colony({String body = 'earth'}) => CitySim.found(
        CityConfig(bodyId: body, gridSize: 20, latitude: 0, longitude: 0),
        bodies: bodies,
        id: 'c',
        name: 'c',
      );
  const street400 = [Vec2(0, 0), Vec2(400, 0)];

  test("a week is seven of the colony's days", () {
    for (final body in ['earth', 'moon']) {
      final sim = colony(body: body);
      final rot = sim.body.siderealRotationPeriod.abs();
      final day = rot <= 1 ? 120.0 : 120.0 * (rot / 86400.0);
      expect(sim.dayLengthSec, closeTo(day.clamp(20.0, 1200.0), 1e-9),
          reason: body);
      expect(sim.weekSec, closeTo(7 * sim.dayLengthSec, 1e-9), reason: body);
    }
  });

  test('the day turns exactly as it did', () {
    final sim = colony()..dayPhase = 0.25;
    final dayLen = sim.dayLengthSec;
    sim.advance(0.5);
    expect(sim.dayPhase, closeTo((0.25 + 0.5 / dayLen) % 1.0, 1e-12));
  });

  test('upkeep is every road at its own rate, per week and per second', () {
    final sim = colony();
    expect(sim.roadUpkeepPerWeek, 0);
    sim.commitRoad(street400, RoadClass.street);
    expect(sim.roadUpkeepPerWeek, closeTo(50 * 0.32, 1e-9));
    expect(sim.roadUpkeepRate, closeTo(50 * 0.32 / sim.weekSec, 1e-12));
    sim.commitRoad(const [Vec2(0, 200), Vec2(400, 200)], RoadClass.avenue);
    expect(sim.roadUpkeepPerWeek, closeTo(50 * 0.32 + 50 * 0.80, 1e-9));
  });

  test('raised and sunk roads cost their multiples to keep', () {
    final raised = colony()
      ..commitRoad(street400, RoadClass.street,
          deck: const RoadDeck(
              startM: 12,
              endM: 12,
              startOffsetM: 12,
              endOffsetM: 12,
              structures: [(0, 400)]));
    expect(raised.roadUpkeepPerWeek,
        closeTo(16 * RoadCosts.structureUpkeepMult, 1e-9));
    final sunk = colony()
      ..commitRoad(street400, RoadClass.street,
          deck: const RoadDeck(
              startM: -12,
              endM: -12,
              startOffsetM: -12,
              endOffsetM: -12,
              tunnels: [(0, 400)]));
    expect(
        sunk.roadUpkeepPerWeek, closeTo(16 * RoadCosts.tunnelUpkeepMult, 1e-9));
    // The highway's own rows: 0.96 at grade, 2.08 up, 5.12 under.
    expect(0.96 * RoadCosts.structureUpkeepMult, closeTo(2.08, 1e-9));
    expect(0.96 * RoadCosts.tunnelUpkeepMult, closeTo(5.12, 1e-9));
  });

  test('the treasury pays it, second by second', () {
    final sim = colony()..funds = 1000;
    sim.commitRoad(street400, RoadClass.street);
    final before = sim.funds;
    sim.advance(0.5);
    expect(sim.roadUpkeepRate, greaterThan(0));
    expect(sim.netFundsRate,
        closeTo(sim.taxIncomeRate + sim.lawUpkeepRate - sim.roadUpkeepRate,
            1e-12));
    expect(sim.funds - before, closeTo(sim.netFundsRate * 0.5, 1e-9));
  });

  test('the cached upkeep follows every change to the roads', () {
    final sim = colony();
    sim.commitRoad(street400, RoadClass.street);
    final a = sim.roadUpkeepPerWeek;
    for (var i = 0; i < 10; i++) {
      sim.advance(0.1);
    }
    expect(sim.roadUpkeepPerWeek, a, reason: 'nothing changed');
    // An upgrade in place keeps the road count; the cache still sees it.
    sim.layout.upgradeRoad('r0', roadClass: RoadClass.avenue);
    expect(sim.roadUpkeepPerWeek, closeTo(50 * 0.80, 1e-9));
    // So does an edit straight to the layout — the generator's way.
    sim.layout.updateRoad(
        sim.layout.roadById('r0')!.copyWith(roadClass: RoadClass.boulevard));
    expect(sim.roadUpkeepPerWeek, closeTo(50 * 0.96, 1e-9));
    sim.layout.removeRoad('r0');
    expect(sim.roadUpkeepPerWeek, 0);
  });

  test('the starter kit lays its crossroads free, then keeps them', () {
    final sim = CityStarterKit.found(
      bodies: bodies,
      config: const CityConfig(bodyId: 'earth', gridSize: 20),
    );
    expect(sim.funds, CityStart.standard.funds,
        reason: 'founding roads are free');
    // Two 600 m streets: 150 cells of two-lane road.
    expect(sim.roadUpkeepPerWeek, closeTo(1200 / 8 * 0.32, 1e-6));
    final before = sim.funds;
    sim.advance(0.5);
    expect(sim.roadUpkeepRate, greaterThan(0));
    expect(sim.funds - before, closeTo(sim.netFundsRate * 0.5, 1e-6));
  });
}
