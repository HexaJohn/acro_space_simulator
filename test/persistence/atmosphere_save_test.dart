// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/adapters/repositories/in_memory_atmosphere_repository.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/persistence/game_state_codec.dart';
import 'package:acro_space_simulator/application/snapshot/atmosphere_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/planetary/atmospheric_composition.dart';
import 'package:acro_space_simulator/domain/planetary/planet_atmosphere.dart';
import 'package:acro_space_simulator/domain/planetary/planet_atmosphere_service.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

/// A planet's gas inventory is the one piece of planetary state a colony can
/// change, so it is the one piece the save carries (docs/plans/terraforming.md
/// §5.4). Bodies stay reference data: a load rebuilds them and republishes the
/// saved air onto them.
void main() {
  const codec = GameStateCodec();
  const mars = BodyId('mars');

  ({
    StaticUniverseRepository universe,
    InMemoryAtmosphereRepository air,
    InMemoryCityRepository cities,
  }) freshWorld() {
    final system = RealSolarSystem.build();
    return (
      universe: StaticUniverseRepository(system),
      air: InMemoryAtmosphereRepository.seeded(system),
      cities: InMemoryCityRepository(),
    );
  }

  Map<String, dynamic> save(
          InMemoryAtmosphereRepository air, InMemoryCityRepository cities) =>
      jsonDecode(jsonEncode(codec.encode(
        vessels: InMemoryVesselRepository(),
        colonies: InMemoryColonyRepository(),
        deposits: InMemoryDepositRepository(),
        clock: SimulationClock(),
        cities: cities,
        atmospheres: air,
      ))) as Map<String, dynamic>;

  void load(Map<String, dynamic> json,
      ({
        StaticUniverseRepository universe,
        InMemoryAtmosphereRepository air,
        InMemoryCityRepository cities,
      }) w) {
    codec.decode(
      json,
      vessels: InMemoryVesselRepository(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: SimulationClock(),
      cities: w.cities,
      bodies: w.universe.current().all.where((b) => !b.isStar).toList(),
      atmospheres: w.air,
      universe: w.universe,
    );
  }

  test('a terraformed sky survives a save and load', () {
    final before = freshWorld();
    final state = before.air.forBody('mars')!
      ..add(AtmosphereGas.oxygen, 3e18)
      ..add(AtmosphereGas.carbonDioxide, 1e16)
      ..aerosolBurden = 0.25;
    final json = save(before.air, before.cities);
    expect(json['version'], GameStateCodec.schemaVersion);
    expect(GameStateCodec.schemaVersion, greaterThanOrEqualTo(2));

    final after = freshWorld();
    load(json, after);
    final restored = after.air.forBody('mars')!;
    for (final g in AtmosphereGas.values) {
      expect(restored.molesOf(g), state.molesOf(g), reason: g.name);
    }
    expect(restored.aerosolBurden, 0.25);
    // And the rebuilt universe carries that air, not the reference.
    final body = after.universe.current().require(mars);
    expect(body.atmosphere!.seaLevelPressure,
        closeTo(state.air!.seaLevelPressure, 1e-9));
    expect(body.composition!.fractions[AtmosphereGas.oxygen],
        closeTo(state.composition!.fractions[AtmosphereGas.oxygen]!, 1e-12));
    // Untouched worlds keep their reference air — the very same (const)
    // model the system definition built.
    final earth = after.universe.current().require(const BodyId('earth'));
    expect(
        identical(earth.atmosphere,
            RealSolarSystem.build().require(const BodyId('earth')).atmosphere),
        isTrue);
  });

  test("a warmed Mars's stores, agent and leaking Moon survive a load", () {
    // Terraforming phase 2: the caps and soil, the super-greenhouse agent
    // and an airless world's vented sky are state too.
    final before = freshWorld();
    final state = before.air.forBody('mars')!;
    state.greenhouseAgentMoles =
        3 / (PlanetAtmosphere.agentMolarMass * state.pascalsPerKg);
    const PlanetAtmosphereService()
        .advance(state, AtmosphereFlows(), dt: 10 * 686.98 * 86400);
    final moon = before.air.forBody('moon')!
      ..add(AtmosphereGas.oxygen, 1e17)
      ..escapeSuppression = 0.5;
    final json = save(before.air, before.cities);

    final after = freshWorld();
    load(json, after);
    final restored = after.air.forBody('mars')!;
    expect(restored.greenhouseAgentMoles, state.greenhouseAgentMoles);
    for (var i = 0; i < state.reservoirs.length; i++) {
      expect(restored.reservoirs[i].moles, state.reservoirs[i].moles,
          reason: state.reservoirs[i].name);
      expect(restored.reservoirs[i].moles,
          isNot(restored.reservoirs[i].referenceMoles),
          reason: 'the warming moved it');
    }
    expect(after.universe.current().require(mars).atmosphere!
        .seaLevelTemperature, closeTo(state.surfaceTemperatureK, 1e-9));
    final lunar = after.air.forBody('moon')!;
    expect(lunar.molesOf(AtmosphereGas.oxygen), moon.molesOf(AtmosphereGas.oxygen));
    expect(lunar.escapeSuppression, 0.5);
    expect(after.universe.current().require(const BodyId('moon')).hasAtmosphere,
        isTrue);
  });

  test('a save from before the inventory loads with reference air', () {
    // A session whose Mars a colony had already changed...
    final live = freshWorld();
    final state = live.air.forBody('mars')!..add(AtmosphereGas.oxygen, 5e18);
    live.universe
        .replaceBody(state.applyTo(live.universe.current().require(mars)));
    // ...loads a version-1 save, which knows nothing of atmospheres.
    final old = save(live.air, live.cities)
      ..remove('atmospheres')
      ..['version'] = 1;

    load(old, live);
    final reference = RealSolarSystem.build().require(mars);
    expect(live.air.forBody('mars')!.molesOf(AtmosphereGas.oxygen),
        live.air.forBody('mars')!.referenceMolesOf(AtmosphereGas.oxygen));
    final body = live.universe.current().require(mars);
    expect(body.atmosphere!.seaLevelPressure,
        reference.atmosphere!.seaLevelPressure);
    expect(body.composition!.fractions, reference.composition!.fractions);
  });

  test('a loaded colony reads the air the load republished', () {
    final before = freshWorld();
    final bodies =
        before.universe.current().all.where((b) => !b.isStar).toList();
    before.cities.add(CitySim.found(
        const CityConfig(bodyId: 'mars', gridSize: 16),
        bodies: bodies,
        id: 'ares'));
    before.air.forBody('mars')!.add(AtmosphereGas.oxygen, 2e18);
    final json = save(before.air, before.cities);

    final after = freshWorld();
    load(json, after);
    final city = after.cities.byId('ares')!;
    expect(identical(city.body, after.universe.current().require(mars)),
        isTrue);
    expect(city.body.atmosphere!.seaLevelPressure, greaterThan(610));
  });

  test('saving without an atmosphere repository writes no block', () {
    final json = codec.encode(
      vessels: InMemoryVesselRepository(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      clock: SimulationClock(),
    );
    expect(json.containsKey('atmospheres'), isFalse);
  });

  test('the fingerprint tells apart two skies that differ only in suppression',
      () {
    // Review 2026-10-10: suppression scales every escape rate, so two runs
    // apart only in it agree on every mole until the leak has diverged them.
    String fp(PlanetAtmosphere a) {
      final buf = StringBuffer();
      AtmosphereSnapshot.of(a).writeFingerprint(buf);
      return buf.toString();
    }

    final moon = RealSolarSystem.build().require(const BodyId('moon'));
    final open = PlanetAtmosphere.seed(moon)!;
    final held = PlanetAtmosphere.seed(moon)!..escapeSuppression = 0.9;
    expect(fp(open), isNot(fp(held)));
    expect(fp(open), fp(PlanetAtmosphere.seed(moon)!),
        reason: 'no suppression, no key: old fingerprints unchanged');
  });
}
