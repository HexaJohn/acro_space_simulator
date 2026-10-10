// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_atmosphere_repository.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/aerodynamics/aero_force.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/dynamics/mass_properties.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/planetary/atmospheric_composition.dart';
import 'package:acro_space_simulator/domain/planetary/planet_atmosphere_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

/// The planetary-atmosphere phase (docs/plans/terraforming.md §5.1-5.3): a
/// colony's towers and industry change its world's real air, the world
/// republishes the body, and everything that reads the body — the colony
/// itself and the flight — reads the new sky.
void main() {
  const mars = BodyId('mars');

  /// A Mars colony running [towers] Terraforming Towers, powered, computed
  /// and staffed, so every tower runs at full throttle.
  CitySim terraformingColony(List<CelestialBody> bodies,
      {String id = 'mars-colony', int towers = 1}) {
    final city = CitySim.found(
      const CityConfig(bodyId: 'mars', gridSize: 20),
      bodies: bodies,
      id: id,
    )..infiniteRobotics = true;
    CityBuildingSpec spec(String type) =>
        kUtilCatalog.firstWhere((s) => s.type == type);
    final g = city.grid;
    final h = city.hubKey;
    city.placeUtil(h - 1, spec('fusion'));
    city.placeUtil(h + g, spec('datacenter'));
    final towerSites = [h + 1, h - g, h + 2, h - 2];
    for (var i = 0; i < towers; i++) {
      city.placeUtil(towerSites[i], spec('terraformer'));
    }
    city.population = 300;
    city.stock[Commodity.electronics] = 1e6;
    city.recompute();
    return city;
  }

  ({
    AdvanceSimulationTick tick,
    StaticUniverseRepository universe,
    InMemoryAtmosphereRepository air,
  }) world(List<CitySim> Function(List<CelestialBody> bodies) colonies) {
    final system = RealSolarSystem.build();
    final universe = StaticUniverseRepository(system);
    final air = InMemoryAtmosphereRepository.seeded(system);
    final bodies = system.all.where((b) => !b.isStar).toList();
    final tick = AdvanceSimulationTick(
      vessels: InMemoryVesselRepository(),
      universe: universe,
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: InMemoryEventBus(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
      cities: InMemoryCityRepository(colonies(bodies)),
      atmosphere: air,
    );
    return (tick: tick, universe: universe, air: air);
  }

  test('a colony\'s towers vent oxygen into its planet and the body follows',
      () {
    late CitySim city;
    final w = world((bodies) => [city = terraformingColony(bodies)]);
    final refO2 = w.air.forBody('mars')!.molesOf(AtmosphereGas.oxygen);
    final refP = w.universe.current().require(mars).atmosphere!.seaLevelPressure;

    // A day of warp-sized steps.
    final clock = SimulationClock(warpFactor: 1, fixedStep: 3600);
    for (var i = 0; i < 24; i++) {
      w.tick.execute(clock);
    }

    expect(city.oxygenatorRun, greaterThan(0.5),
        reason: 'the tower is powered, computed and staffed');
    final state = w.air.forBody('mars')!;
    expect(state.molesOf(AtmosphereGas.oxygen), greaterThan(refO2));
    final published = w.universe.current().require(mars);
    expect(published.atmosphere!.seaLevelPressure, greaterThan(refP),
        reason: 'the world republished Mars with the air it now has');
    expect(published.composition!.fractions[AtmosphereGas.oxygen]!,
        greaterThan(RealSolarSystem.build()
            .require(mars)
            .composition!
            .fractions[AtmosphereGas.oxygen]!));
    // And the colony reads that same body, not the one it was founded on.
    expect(identical(city.body, published), isTrue);
  });

  test('colonies on one world share its air', () {
    double ventedBy(List<CitySim> Function(List<CelestialBody>) colonies) {
      final w = world(colonies);
      final ref = w.air.forBody('mars')!.molesOf(AtmosphereGas.oxygen);
      final clock = SimulationClock(warpFactor: 1, fixedStep: 3600);
      for (var i = 0; i < 4; i++) {
        w.tick.execute(clock);
      }
      return w.air.forBody('mars')!.molesOf(AtmosphereGas.oxygen) - ref;
    }

    final one = ventedBy((b) => [terraformingColony(b)]);
    final two = ventedBy((b) => [
          terraformingColony(b, id: 'a'),
          terraformingColony(b, id: 'b'),
        ]);
    expect(one, greaterThan(0));
    expect(two, closeTo(2 * one, one * 0.02),
        reason: 'two colonies on one planet both work on the same sky');
  });

  test('a colony\'s body follows a republish it did not cause', () {
    late CitySim city;
    final w = world((bodies) => [
          city = CitySim.found(const CityConfig(bodyId: 'mars', gridSize: 16),
              bodies: bodies, id: 'quiet'),
        ]);
    final old = city.body;
    final state = w.air.forBody('mars')!..add(AtmosphereGas.oxygen, 1e19);
    w.universe.replaceBody(state.applyTo(w.universe.current().require(mars)));
    state.markPublished();

    w.tick.execute(SimulationClock(warpFactor: 1, fixedStep: 1));
    expect(identical(city.body, old), isFalse);
    expect(identical(city.body, w.universe.current().require(mars)), isTrue);
    expect(city.body.atmosphere!.seaLevelPressure,
        greaterThan(old.atmosphere!.seaLevelPressure));
  });

  test('flight drag on Mars rises with the pressure a colony made', () {
    final w = world((_) => const []);
    final state = w.air.forBody('mars')!;
    final reference = w.universe.current().require(mars);

    // Thirty years' worth of towers, published the way the tick does.
    state.add(AtmosphereGas.oxygen, 1e19);
    w.universe.replaceBody(state.applyTo(reference));
    final thick = w.universe.current().require(mars);

    double dragAt(CelestialBody body, double altitude) {
      final sample = body.atmosphere!.sampleAt(altitude);
      final force = AeroForce(
        atmosphere: sample,
        dragCoefficient: 0.5,
        referenceArea: 10,
      ).evaluate(
        StateVector(
          position: Vector3(body.radius + altitude, 0, 0),
          velocity: const Vector3(0, 300, 0),
        ),
        const MassProperties(
            mass: 1000, centerOfMass: Vector3.zero, inertia: Vector3(1, 1, 1)),
      );
      return force.force.length;
    }

    for (final h in [0.0, 5000.0, 20000.0]) {
      expect(dragAt(thick, h), greaterThan(dragAt(reference, h) * 5),
          reason: 'at $h m the air is many times thicker');
    }
    final ratio = thick.atmosphere!.seaLevelPressure /
        reference.atmosphere!.seaLevelPressure;
    expect(ratio, greaterThan(10));
  });

  test('a craft in Mars\'s sky flies through the air the tick published', () {
    // Through the vessel path, not a hand-built AeroForce: the flight tick
    // resolves its body from the universe every tick, so the air the
    // planetary phase republished is the air the craft meets. 5 km up at
    // 1200 m/s is ~9 kPa of dynamic pressure in reference air and ~10x that
    // once thirty years of towers have run — so a 40 kPa max-Q is the
    // difference between a routine pass and breaking apart.
    ({
      AdvanceSimulationTick tick,
      InMemoryVesselRepository vessels,
      SimulationClock clock,
    }) flight(
        {required bool terraformed}) {
      final system = RealSolarSystem.build();
      final body = system.require(mars);
      final universe = StaticUniverseRepository(system);
      final air = InMemoryAtmosphereRepository.seeded(system);
      if (terraformed) {
        // A tower programme's output, still waiting for the planetary phase
        // to take it — as a frame-budgeted colony's replays leave it.
        air.forBody('mars')!.pendingFlows.addColony(
              pollutionRate: 0,
              oxygenatorRun: 1e19 / const TerraformTuning().oxygenatorRate,
              dt: 1,
            );
      }
      final vessels = InMemoryVesselRepository([
        Vessel(
          id: const VesselId('glider'),
          name: 'Glider',
          ownerId: 'p',
          state: StateVector(
            position: Vector3(body.radius + 5000, 0, 0),
            velocity: const Vector3(0, 1200, 0),
          ),
          dominantBody: mars,
          stages: const [],
        ),
      ]);
      final tick = AdvanceSimulationTick(
        vessels: vessels,
        universe: universe,
        compute: DartCompute(),
        soi: const SoiTransitionService(),
        events: InMemoryEventBus(),
        colonies: InMemoryColonyRepository(),
        deposits: InMemoryDepositRepository(),
        weather: const NullWeatherRepository(),
        atmosphere: air,
        maxDynamicPressure: 40000,
      );
      return (
        tick: tick,
        vessels: vessels,
        clock: SimulationClock(warpFactor: 1, fixedStep: 0.1),
      );
    }

    const id = VesselId('glider');
    final reference = flight(terraformed: false);
    final thick = flight(terraformed: true);
    reference.tick.execute(reference.clock);
    thick.tick.execute(thick.clock);
    expect(thick.vessels.byId(id), isNotNull,
        reason: 'the vessels fly before the planetary phase publishes');
    reference.tick.execute(reference.clock);
    thick.tick.execute(thick.clock);
    expect(reference.vessels.byId(id), isNotNull,
        reason: 'reference Mars air is far below max-Q at this speed');
    expect(thick.vessels.byId(id), isNull,
        reason: 'the thickened sky the tick published tears the craft apart');
  });

  test('a world with no colonies keeps its reference bodies', () {
    final w = world((_) => const []);
    final before = w.universe.current().require(mars);
    final clock = SimulationClock(warpFactor: 1, fixedStep: 3600);
    for (var i = 0; i < 5; i++) {
      w.tick.execute(clock);
    }
    expect(identical(w.universe.current().require(mars), before), isTrue);
  });
}
