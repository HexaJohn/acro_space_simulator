import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/lifesupport/crew.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/domain_event.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/vessel/part.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:acro_space_simulator/domain/vessel/stage.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('crew run out of oxygen during the tick and are lost', () {
    final system = SampleWorld.buildSystem();
    final body = system.require(SampleWorld.kerbin);
    final oxy = ResourceContainer(
        type: ResourceType.oxygen, capacity: 100, amount: 0.5, unitMass: 1);
    final cabin = Part(
        id: const PartId('cab'), name: 'cab', dryMass: 1000, resources: [oxy]);
    final v = Vessel(
      id: const VesselId('crew'),
      name: 'Crew',
      ownerId: 'p',
      state: StateVector(
        position: Vector3(body.radius + 100000, 0, 0),
        velocity: Vector3.zero,
      ),
      dominantBody: SampleWorld.kerbin,
      stages: [Stage(index: 0, parts: [cabin])],
      landed: true,
    )..crew = CrewModule(count: 3, oxygenPerCrewPerSecond: 0.1);

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
    );
    final clock = SimulationClock(warpFactor: 1, fixedStep: 1.0);
    for (var i = 0; i < 5; i++) {
      tick.execute(clock);
    }

    expect(vessels.byId(const VesselId('crew'))!.crew!.count, 0);
    expect(events.recent.whereType<CrewLost>().isNotEmpty, isTrue);
  });
}
