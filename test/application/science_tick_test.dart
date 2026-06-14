import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/science/experiment.dart';
import 'package:acro_space_simulator/domain/science/research_ledger.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a vessel with an experiment accrues science through the tick', () {
    final system = SampleWorld.buildSystem();
    final body = system.require(SampleWorld.kerbin);
    final v = Vessel(
      id: const VesselId('probe'),
      name: 'Probe',
      ownerId: 'p',
      state: StateVector(
        position: Vector3(body.radius + 100000, 0, 0),
        velocity: Vector3.zero,
      ),
      dominantBody: SampleWorld.kerbin,
      stages: const [],
      landed: true, // pin it so it stays in one situation
    )..experiments.add(const Experiment(id: 'goo', baseValue: 12));

    final ledger = ResearchLedger();
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
      research: ledger,
    );

    final clock = SimulationClock(warpFactor: 1, fixedStep: 1.0);
    tick.execute(clock);
    expect(ledger.science, greaterThan(0));

    // A second tick in the same situation adds no more (diminishing/suppressed).
    final after = ledger.science;
    tick.execute(clock);
    expect(ledger.science, after);
  });
}
