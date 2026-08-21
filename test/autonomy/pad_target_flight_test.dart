// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/autonomy/landing_target.dart';
import 'package:acro_space_simulator/domain/colony/city/city_building_spec.dart';
import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/shuttle_run.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

/// "Target this pad", flown for real.
///
/// The flat map's answer to landing on a spaceport was to push a second scene
/// running a scripted descent. Aimed from the world, a craft carries a
/// [LandingTarget] and the ordinary tick flies it down with the same
/// [LandingGuidance] the colony's own shuttles use — no separate scene, no
/// separate physics.
void main() {
  ({CitySim city, Vector3 padBF, AdvanceSimulationTick tick,
    InMemoryVesselRepository vessels, SimulationClock clock}) setUpMoonPort() {
    final system = SampleWorld.realSystem();
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
    // Keep the colony's own shuttles out of it — one craft under test.
    city.nextShuttleEpoch = double.infinity;

    final body = system.body(city.body.id)!;
    // The pad stands on the GROUND. Aiming at the datum sphere under a site
    // that sits on a rise points the descent through the hillside — guidance
    // reads hundreds of metres still in hand while the craft is in the dirt.
    final dir = city
        .localToBodyFixed(lot.centroid, bodyRadiusM: body.radius)
        .normalized;
    final field = body.terrainField;
    final padBF = dir *
        (field?.groundRadiusAt(dir.x, dir.y, dir.z) ?? body.radius);

    final vessels = InMemoryVesselRepository(const []);
    final tick = AdvanceSimulationTick(
      vessels: vessels,
      universe: StaticUniverseRepository(system),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: InMemoryEventBus(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
      cities: InMemoryCityRepository([city]),
    );
    return (
      city: city,
      padBF: padBF,
      tick: tick,
      vessels: vessels,
      clock: SimulationClock(warpFactor: 1, fixedStep: 0.1),
    );
  }

  /// A craft above the pad, descending — the state a player is in when they
  /// point at a spaceport on the way down.
  Vessel craftOverPad(CitySim city, Vector3 padBF, SimulationClock clock) {
    final body = SampleWorld.realSystem().body(city.body.id)!;
    return const ColonyShuttleFactory().build(
      id: 'player-craft',
      body: body,
      padBF: padBF,
      bodyOrientation: body.orientationAt(clock.epoch),
    );
  }

  test('an untargeted craft is left alone', () {
    final s = setUpMoonPort();
    final v = craftOverPad(s.city, s.padBF, s.clock)..setThrottle(0);
    s.vessels.save(v);

    s.tick.execute(s.clock);
    expect(v.landingTarget, isNull);
    expect(v.throttle, 0, reason: 'nothing is flying it but the player');
  });

  test('a targeted craft is flown onto the pad and the target clears', () {
    final s = setUpMoonPort();
    final v = craftOverPad(s.city, s.padBF, s.clock);
    v.landingTarget = LandingTarget(
      bodyId: s.city.body.id.value,
      padBF: s.padBF,
      colonyId: s.city.id,
      site: s.city.parcelBuildings.keys.first,
    );
    s.vessels.save(v);

    var landed = false;
    for (var i = 0; i < 6000 && !landed; i++) {
      s.tick.execute(s.clock);
      landed = v.landed;
    }

    expect(landed, isTrue, reason: 'guidance actually brings it down');
    expect(s.vessels.byId(v.id), isNotNull, reason: 'it survived the descent');
    // Down ON the pad, not somewhere over the horizon. Compared body-fixed,
    // because the ground has turned under the descent.
    final restBF = SampleWorld.realSystem()
        .body(s.city.body.id)!
        .orientationAt(s.clock.epoch)
        .conjugate
        .rotate(v.state.position);
    expect((restBF - s.padBF).length, lessThan(400));
    // Landed hands the controls back.
    s.tick.execute(s.clock);
    expect(v.landingTarget, isNull);
    expect(v.throttle, 0);
  });

  test('a target on another body is dropped rather than steering the craft',
      () {
    final s = setUpMoonPort();
    final v = craftOverPad(s.city, s.padBF, s.clock);
    v.landingTarget = LandingTarget(
      bodyId: 'mars', // not where this craft is
      padBF: s.padBF,
      colonyId: s.city.id,
      site: 'lot',
    );
    s.vessels.save(v);

    s.tick.execute(s.clock);
    expect(v.landingTarget, isNull);
    expect(v.throttle, 0);
  });
}
