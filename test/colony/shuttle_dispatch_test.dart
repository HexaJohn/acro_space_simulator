// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/shuttle_run.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

/// The whole shuttle loop, flown for real: dispatch spawns a vessel, the
/// guidance lands it on the colony's pad through the ordinary motion phase,
/// the pad-side cargo service unloads it, and it climbs out and is recovered.
///
/// On the MOON: no atmosphere, so the physics the shuttle flies is exactly the
/// physics the guidance was proven against.
void main() {
  test('a colony with a served pad gets a supply run, end to end', () {
    final city = CitySim.found(
      const CityConfig(bodyId: 'moon', gridSize: 20),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      id: 'moonbase',
    );
    city.layout.addRoad(const RoadSpline(
        id: 'main', controls: [Vec2(0, -150), Vec2(0, 150)]));
    final lot = city.layout.autoParcels.first;
    city.parcelBuildings[lot.id] =
        kUtilCatalog.firstWhere((s) => s.label == 'Spaceport');
    city.stock[Commodity.food] = 0;
    city.nextShuttleEpoch = 0;

    final vessels = InMemoryVesselRepository(const []);
    final tick = AdvanceSimulationTick(
      vessels: vessels,
      universe: StaticUniverseRepository(SampleWorld.realSystem()),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: InMemoryEventBus(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
      cities: InMemoryCityRepository([city]),
      // The dev cheats stay OFF: a landing that only works with impact
      // destruction disabled is not a landing.
    );
    final clock = SimulationClock(warpFactor: 1, fixedStep: 0.1);

    // One tick dispatches.
    tick.execute(clock);
    expect(vessels.all(), hasLength(1), reason: 'shuttle spawned');
    expect(city.shuttleRuns.single.phase, ShuttleRunPhase.inbound);
    final shuttleId = city.shuttleRuns.single.vesselId;

    // Fly it down. 16 km under lunar gravity with a 60 m/s head start: the
    // whole descent fits comfortably in 500 s of sim time.
    var landedAt = -1.0;
    for (var i = 0; i < 5000 && city.shuttleRuns.isNotEmpty; i++) {
      tick.execute(clock);
      final run = city.shuttleRuns.firstOrNull;
      if (landedAt < 0 &&
          run != null &&
          run.phase != ShuttleRunPhase.inbound) {
        landedAt = i * 0.1;
      }
    }

    expect(landedAt, greaterThan(0),
        reason: 'the shuttle must actually touch down');
    expect(city.stock[Commodity.food], greaterThan(0),
        reason: 'the pad-side cargo service unloads a landed shuttle');
    expect(city.shuttleRuns, isEmpty, reason: 'the round trip completed');
    expect(vessels.all().where((v) => v.id.value == shuttleId), isEmpty,
        reason: 'the hull climbed out and was recovered');
    expect(city.nextShuttleEpoch, greaterThan(0),
        reason: 'the next run is scheduled, not immediate');
  });

  test('no served pad, no shuttle', () {
    final city = CitySim.found(
      const CityConfig(bodyId: 'moon', gridSize: 20),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      id: 'padless',
    );
    // Zoned street, no spaceport anywhere.
    city.layout.addRoad(const RoadSpline(
        id: 'main', controls: [Vec2(0, -150), Vec2(0, 150)]));
    city.nextShuttleEpoch = 0;

    final vessels = InMemoryVesselRepository(const []);
    final tick = AdvanceSimulationTick(
      vessels: vessels,
      universe: StaticUniverseRepository(SampleWorld.realSystem()),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: InMemoryEventBus(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
      cities: InMemoryCityRepository([city]),
    );
    final clock = SimulationClock(warpFactor: 1, fixedStep: 0.1);
    for (var i = 0; i < 50; i++) {
      tick.execute(clock);
    }
    expect(vessels.all(), isEmpty);
    expect(city.shuttleRuns, isEmpty);
  });

  test('a lost shuttle frees the slot for the next dispatch', () {
    final city = CitySim.found(
      const CityConfig(bodyId: 'moon', gridSize: 20),
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      id: 'unlucky',
    );
    city.layout.addRoad(const RoadSpline(
        id: 'main', controls: [Vec2(0, -150), Vec2(0, 150)]));
    final lot = city.layout.autoParcels.first;
    city.parcelBuildings[lot.id] =
        kUtilCatalog.firstWhere((s) => s.label == 'Spaceport');
    city.nextShuttleEpoch = 0;
    city.shuttleIntervalSec = 1;

    final vessels = InMemoryVesselRepository(const []);
    final tick = AdvanceSimulationTick(
      vessels: vessels,
      universe: StaticUniverseRepository(SampleWorld.realSystem()),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: InMemoryEventBus(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
      cities: InMemoryCityRepository([city]),
    );
    final clock = SimulationClock(warpFactor: 1, fixedStep: 0.1);
    tick.execute(clock);
    expect(vessels.all(), hasLength(1));

    // The freighter meets a mishap.
    vessels.remove(vessels.all().first.id);
    for (var i = 0; i < 20; i++) {
      tick.execute(clock);
    }
    expect(vessels.all(), hasLength(1),
        reason: 'the schedule replaces a lost hull instead of hanging');
  });
}
