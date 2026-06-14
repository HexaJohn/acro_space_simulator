import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/orbits/body_ephemeris.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/domain_event.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('vessel inside the Mun SOI transitions to Mun and emits the event', () {
    final system = SampleWorld.buildSystem();
    const ephemeris = BodyEphemeris();
    final mun = system.require(SampleWorld.mun);
    final munPos =
        ephemeris.positionRelativeToParent(mun, system, Epoch.zero);
    final munVel =
        ephemeris.velocityRelativeToParent(mun, system, Epoch.zero);

    // Start in the Kerbin (planet) frame, 500 km from Mun (inside its 2,429 km
    // SOI), moving with the Mun.
    final vessel = Vessel(
      id: const VesselId('explorer'),
      name: 'Explorer',
      ownerId: 'p',
      state: StateVector(
        position: munPos + const Vector3(500000, 0, 0),
        velocity: munVel + const Vector3(0, 200, 0), // 200 m/s rel to Mun
      ),
      dominantBody: SampleWorld.kerbin,

      stages: const [],
    );

    final events = InMemoryEventBus();
    final vessels = InMemoryVesselRepository([vessel]);
    final tick = AdvanceSimulationTick(
      vessels: vessels,
      universe: StaticUniverseRepository(system),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: events,
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
    );

    final clock = SimulationClock(warpFactor: 1, fixedStep: 1.0);
    tick.execute(clock);

    final after = vessels.byId(vessel.id)!;
    expect(after.dominantBody, SampleWorld.mun);
    // In the Mun frame the vessel is now ~500 km out, not ~12,000 km.
    expect(after.state.position.length, lessThan(mun.soiRadius));
    expect(events.recent.whereType<SoiTransition>().isNotEmpty, isTrue);
  });
}
