// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_atmosphere_repository.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/persistence/game_state_codec.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/commodity.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/planetary/atmospheric_composition.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// A frame-budgeted colony — every player colony in the game — has its ticks
/// held and replayed after the host's tick loop, so its gas flows reach the
/// planetary phase a tick late. These pin that they land exactly once: not
/// dropped by a save, not doubled by a load, not lost to a tick rebuild.
void main() {
  /// A Mars colony running two towers at full throttle, with agents on so
  /// a frame budget actually holds its ticks.
  CitySim terraformingColony(List<CelestialBody> bodies) {
    final city = CitySim.found(
      const CityConfig(bodyId: 'mars', gridSize: 20),
      bodies: bodies,
      id: 'held',
    )..infiniteRobotics = true;
    CityBuildingSpec spec(String type) =>
        kUtilCatalog.firstWhere((s) => s.type == type);
    final g = city.grid;
    final h = city.hubKey;
    city.placeUtil(h - 1, spec('fusion'));
    city.placeUtil(h + g, spec('datacenter'));
    city.placeUtil(h + 1, spec('terraformer'));
    city.placeUtil(h - g, spec('terraformer'));
    city.population = 300;
    city.stock[Commodity.electronics] = 1e6;
    city.recompute();
    city.agents.enabled = true;
    return city;
  }

  _World world({required bool budgeted, bool colony = true}) {
    final system = RealSolarSystem.build();
    final bodies = system.all.where((b) => !b.isStar).toList();
    final cities = InMemoryCityRepository([
      if (colony) terraformingColony(bodies)..agents.frameBudgeted = budgeted,
    ]);
    return _World(
      StaticUniverseRepository(system),
      InMemoryAtmosphereRepository.seeded(system),
      cities,
    );
  }

  test('held ticks vent what inline ticks vent, once', () {
    final inline = world(budgeted: false);
    final held = world(budgeted: true);
    final ref = inline.o2;
    for (var f = 0; f < 3; f++) {
      inline.frame();
      held.frame();
    }
    // The held colony's last frame replayed after its last tick's
    // planetary phase: one more tick integrates it (and holds its own share).
    held.tick.execute(held.clock);
    final vented = inline.o2 - ref;
    expect(vented, greaterThan(0));
    expect(held.o2 - ref, closeTo(vented, vented * 1e-9));
  });

  test('a save carries the flows a replay left for the next tick', () {
    final a = world(budgeted: true);
    a.frame();
    a.frame();
    final json = a.save();
    expect(a.air.forBody('mars')!.toJson()['pending'], isNotNull,
        reason: 'the last frame\'s replays are still waiting for a tick');

    final b = world(budgeted: true, colony: false)..load(json);
    // The next tick takes those flows; the colonies' own shares of it are
    // held. One tick, so the comparison is the sky's alone — a reloaded
    // colony's staffing restarts with its agents, which is not this test's.
    for (final w in [a, b]) {
      w.tick.execute(w.clock);
    }
    expect(a.o2, greaterThan(a.air.forBody('mars')!.referenceMolesOf(
        AtmosphereGas.oxygen)));
    expect(b.o2, a.o2, reason: 'save, load and carry on is carrying on');
  });

  test('a load drops the flows the session had waiting', () {
    final a = world(budgeted: true);
    a.frame();
    final json = a.save();
    a.frame(); // leaves this frame's replayed flows waiting

    a.load(json);
    final b = world(budgeted: true, colony: false)..load(json);
    for (final w in [a, b]) {
      w.frame();
      w.tick.execute(w.clock);
    }
    expect(
      a.o2,
      closeTo(b.o2, b.o2 * 1e-12),
      reason: 'the loaded sky is the save\'s, not the session\'s',
    );
  });

  test('a tick rebuild keeps the flows a replay left waiting', () {
    final a = world(budgeted: true);
    final b = world(budgeted: true);
    for (final w in [a, b]) {
      w.frame();
    }
    b.rebuild(); // a cheat toggle between frames
    for (final w in [a, b]) {
      w.frame();
      w.tick.execute(w.clock);
    }
    expect(b.o2, closeTo(a.o2, a.o2 * 1e-12));
  });
}

const codec = GameStateCodec();

/// One world: the repositories a session owns, and a tick built over them.
class _World {
  _World(this.universe, this.air, this.cities)
    : tick = build(universe, air, cities);

  final StaticUniverseRepository universe;
  final InMemoryAtmosphereRepository air;
  final InMemoryCityRepository cities;
  final SimulationClock clock = SimulationClock(warpFactor: 1, fixedStep: 3600);
  AdvanceSimulationTick tick;

  static AdvanceSimulationTick build(
    StaticUniverseRepository universe,
    InMemoryAtmosphereRepository air,
    InMemoryCityRepository cities,
  ) => AdvanceSimulationTick(
    vessels: InMemoryVesselRepository(),
    universe: universe,
    compute: DartCompute(),
    soi: const SoiTransitionService(),
    events: InMemoryEventBus(),
    colonies: InMemoryColonyRepository(),
    deposits: InMemoryDepositRepository(),
    weather: const NullWeatherRepository(),
    cities: cities,
    atmosphere: air,
  );

  /// What FlightSession.rebuildTick does on a cheat toggle.
  void rebuild() => tick = build(universe, air, cities);

  double get o2 => air.forBody('mars')!.molesOf(AtmosphereGas.oxygen);

  /// [ticks] host ticks, then the frame's replay, as SimulationView runs it
  /// — and, since one frame's budget may not cover a 4-tick backlog, the
  /// tick-less frames after it until the backlog is worked off, so every
  /// run compared here has replayed the same ticks.
  void frame({int ticks = 4}) {
    for (var i = 0; i < ticks; i++) {
      tick.execute(clock);
    }
    for (final c in cities.all()) {
      for (var f = 0; f < 64 && c.agents.heldTicks > 0; f++) {
        c.agents.endFrame();
      }
      expect(c.agents.heldTicks, 0, reason: 'the backlog is worked off');
    }
  }

  Map<String, dynamic> save() {
    for (final c in cities.all()) {
      c.agents.flushHeld();
    }
    return jsonDecode(
          jsonEncode(
            codec.encode(
              vessels: InMemoryVesselRepository(),
              colonies: InMemoryColonyRepository(),
              deposits: InMemoryDepositRepository(),
              clock: clock,
              cities: cities,
              atmospheres: air,
            ),
          ),
        )
        as Map<String, dynamic>;
  }

  void load(Map<String, dynamic> json) {
    codec.decode(
      json,
      vessels: InMemoryVesselRepository(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: clock,
      cities: cities,
      bodies: universe.current().all.where((b) => !b.isStar).toList(),
      atmospheres: air,
      universe: universe,
    );
    for (final c in cities.all()) {
      c.agents.frameBudgeted = true;
    }
  }
}
