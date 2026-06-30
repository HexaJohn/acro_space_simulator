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
  test('vessel inside the Moon SOI transitions to Moon and emits the event', () {
    final system = SampleWorld.realSystem();
    const ephemeris = BodyEphemeris();
    final moon = system.require(SampleWorld.moon);
    final moonPos =
        ephemeris.positionRelativeToParent(moon, system, Epoch.zero);
    final moonVel =
        ephemeris.velocityRelativeToParent(moon, system, Epoch.zero);

    // Start in the Earth (planet) frame, 2,000 km from the Moon — above its
    // 1,737 km surface yet deep inside its 66,100 km SOI — moving with the Moon.
    final vessel = Vessel(
      id: const VesselId('explorer'),
      name: 'Explorer',
      ownerId: 'p',
      state: StateVector(
        position: moonPos + const Vector3(2000000, 0, 0),
        velocity: moonVel + const Vector3(0, 200, 0), // 200 m/s rel to Moon
      ),
      dominantBody: SampleWorld.earth,

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
    expect(after.dominantBody, SampleWorld.moon);
    // In the Moon frame the vessel is now ~2,000 km out, not ~384,400 km.
    expect(after.state.position.length, lessThan(moon.soiRadius));
    expect(events.recent.whereType<SoiTransition>().isNotEmpty, isTrue);
  });
}
