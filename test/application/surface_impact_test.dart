// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/domain_event.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AdvanceSimulationTick buildTick(InMemoryVesselRepository vessels) =>
      AdvanceSimulationTick(
        vessels: vessels,
        universe: StaticUniverseRepository(SampleWorld.realSystem()),
        compute: DartCompute(),
        soi: const SoiTransitionService(),
        events: InMemoryEventBus(),
        colonies: InMemoryColonyRepository(),
        deposits: InMemoryDepositRepository(),
        weather: const NullWeatherRepository(),
      );

  Vessel faller({required double speed}) {
    final body = SampleWorld.realSystem().require(SampleWorld.earth);
    // Just above the REAL surface under this direction, falling straight
    // down. With Earth on the GEBCO DEM the datum is no longer the ground —
    // (+X, epoch 0) sits over the Gulf of Guinea, ~4.9 km of water column
    // above the sea floor a datum-relative spawn would start from. Contact is
    // checked per fixed step, so the drop must stay SHORT or gravity accrued
    // during the overshoot turns a gentle release into a >12 m/s "impact".
    final ground =
        body.terrainGroundRadius(Vector3(body.radius, 0, 0), Epoch.zero);
    return Vessel(
      id: const VesselId('faller'),
      name: 'Faller',
      ownerId: 'p',
      state: StateVector(
        position: Vector3(ground + 1, 0, 0),
        velocity: Vector3(-speed, 0, 0),
      ),
      dominantBody: SampleWorld.earth,
      stages: const [],
    );
  }

  test('a slow descent below the surface lands the vessel (no destruction)', () {
    final v = faller(speed: 2); // gentle
    final vessels = InMemoryVesselRepository([v]);
    final tick = buildTick(vessels);
    // Fine steps so contact lands within ~0.5 s of release: at 1 s steps the
    // craft accrues ~2 s of gravity (>20 m/s) before the surface check sees
    // it, which reads as a crash, not a touchdown.
    final clock = SimulationClock(warpFactor: 1, fixedStep: 0.25);
    for (var i = 0; i < 20; i++) {
      tick.execute(clock);
    }
    final after = vessels.byId(const VesselId('faller'))!;
    expect(after.landed, isTrue);
  });

  test('a fast impact destroys the vessel and emits an Impact event', () {
    final v = faller(speed: 300); // slams in
    final events = InMemoryEventBus();
    final vessels = InMemoryVesselRepository([v]);
    final tick = AdvanceSimulationTick(
      vessels: vessels,
      universe: StaticUniverseRepository(SampleWorld.realSystem()),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: events,
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
    );
    final clock = SimulationClock(warpFactor: 1, fixedStep: 0.5);
    for (var i = 0; i < 10; i++) {
      tick.execute(clock);
    }
    // Destroyed vessels are removed from the repository.
    expect(vessels.byId(const VesselId('faller')), isNull);
    expect(events.recent.whereType<Impact>().isNotEmpty, isTrue);
  });
}
