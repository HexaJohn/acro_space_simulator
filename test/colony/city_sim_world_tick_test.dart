// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

/// The colony sim used to live inside the city builder's `State`, so a city
/// only advanced while you were looking at it. These pin the unified behaviour:
/// a colony registered with the world runs off the SAME tick as the vessels.
void main() {
  CitySim foundColony() => CitySim.found(
        const CityConfig(bodyId: 'earth', gridSize: 20),
        bodies:
            RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
        id: 'test-colony',
      );

  /// Place a mine (plus the solar farm that powers it) either side of the hub,
  /// so both are road-connected and the mine actually runs.
  void addMine(CitySim city) {
    final mine = kUtilCatalog.firstWhere((s) => s.label == 'Mine');
    final solar = kUtilCatalog.firstWhere((s) => s.label == 'Solar Farm');
    city.placeUtil(city.hubKey + 1, mine);
    city.placeUtil(city.hubKey - 1, solar);
    city.population = 200; // staff it
    // Start well below the stockpile cap, or production has nowhere to go.
    city.stock[Commodity.ore] = 50;
    city.recompute();
  }

  AdvanceSimulationTick tickWith(CitySim city) => AdvanceSimulationTick(
        vessels:
            InMemoryVesselRepository([SampleWorld.buildVessel(altitude: 400000)]),
        universe: StaticUniverseRepository(SampleWorld.realSystem()),
        compute: DartCompute(),
        soi: const SoiTransitionService(),
        events: InMemoryEventBus(),
        colonies: InMemoryColonyRepository(),
        deposits: InMemoryDepositRepository(),
        weather: const NullWeatherRepository(),
        cities: InMemoryCityRepository([city]),
      );

  test('a registered colony advances on the world tick with no screen', () {
    final city = foundColony()..infiniteRobotics = true;
    addMine(city);
    final before = city.stock[Commodity.ore] ?? 0;

    final tick = tickWith(city);
    final clock = SimulationClock(warpFactor: 1, fixedStep: 1.0);
    for (var i = 0; i < 10; i++) {
      tick.execute(clock);
    }

    expect(city.stock[Commodity.ore], greaterThan(before),
        reason: 'the mine should have produced ore while nothing was mounted');
  });

  test('advance is paced by the caller, not by the colony time warp', () {
    // timeWarp is the city screen's speed control. If advance() applied it
    // internally, a world-driven colony would silently run N times faster than
    // the vessels sharing its clock.
    final slow = foundColony()..infiniteRobotics = true;
    final fast = foundColony()..infiniteRobotics = true;
    addMine(slow);
    addMine(fast);
    fast.timeWarp = 8;

    for (var i = 0; i < 20; i++) {
      slow.advance(0.1);
      fast.advance(0.1);
    }

    expect(fast.stock[Commodity.ore], closeTo(slow.stock[Commodity.ore]!, 1e-6));
  });

  test('city buildings reach the world snapshot', () {
    final city = foundColony();
    addMine(city);
    final cities = InMemoryCityRepository([city]);

    final snap = WorldSnapshot.capture(
      0,
      InMemoryVesselRepository(const []),
      system: SampleWorld.realSystem(),
      cities: cities,
    );

    expect(snap.buildings, isNotEmpty);
    final b = snap.buildings.values.first;
    expect(b.colonyId, 'test-colony');
    expect(b.body, 'earth');
    // Placed on (not inside, not far above) the surface of the host body.
    final r = math.sqrt(b.px * b.px + b.py * b.py + b.pz * b.pz);
    final earth = SampleWorld.realSystem().body(city.body.id)!;
    expect(r, closeTo(earth.radius, earth.radius * 0.01));
  });
}
