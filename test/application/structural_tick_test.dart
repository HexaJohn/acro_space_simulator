import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/domain_event.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a vessel screaming through dense atmosphere breaks apart', () {
    final system = SampleWorld.realSystem();
    final body = system.require(SampleWorld.earth);
    // 5 km altitude (dense), horizontal at 1200 m/s -> very high dynamic pressure.
    final v = Vessel(
      id: const VesselId('overstressed'),
      name: 'Overstressed',
      ownerId: 'p',
      state: StateVector(
        position: Vector3(body.radius + 5000, 0, 0),
        velocity: Vector3(0, 1200, 0),
      ),
      dominantBody: SampleWorld.earth,
      stages: const [],
    );

    final events = InMemoryEventBus();
    final vessels = InMemoryVesselRepository([v]);
    final tick = AdvanceSimulationTick(
      vessels: vessels,
      universe: StaticUniverseRepository(system),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: events,
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
      maxDynamicPressure: 80000,
    );
    tick.execute(SimulationClock(warpFactor: 1, fixedStep: 0.1));

    expect(vessels.byId(const VesselId('overstressed')), isNull); // destroyed
    expect(events.recent.whereType<StructuralFailure>().isNotEmpty, isTrue);
  });

  test('the same vessel survives in vacuum (no dynamic pressure)', () {
    final system = SampleWorld.realSystem();
    final body = system.require(SampleWorld.earth);
    final v = Vessel(
      id: const VesselId('vac'),
      name: 'Vac',
      ownerId: 'p',
      state: StateVector(
        position: Vector3(body.radius + 200000, 0, 0), // above atmosphere
        velocity: Vector3(0, 3000, 0),
      ),
      dominantBody: SampleWorld.earth,
      stages: const [],
    );
    final vessels = InMemoryVesselRepository([v]);
    final tick = AdvanceSimulationTick(
      vessels: vessels,
      universe: StaticUniverseRepository(system),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: InMemoryEventBus(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
    );
    tick.execute(SimulationClock(warpFactor: 1, fixedStep: 0.1));
    expect(vessels.byId(const VesselId('vac')), isNotNull); // survived
  });
}
