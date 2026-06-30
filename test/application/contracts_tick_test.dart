import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/contracts/contract.dart';
import 'package:acro_space_simulator/domain/contracts/contract_tracker.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a "reach low orbit" contract completes as the vessel flies the tick', () {
    final system = SampleWorld.realSystem();
    final vessel = SampleWorld.buildVessel(altitude: 200000); // lowOrbit:earth

    final contract = Contract(
      id: 'first-orbit',
      title: 'Achieve orbit of Earth',
      rewardFunds: 50000,
      rewardScience: 10,
      objectives: [ReachSituationObjective(situation: 'lowOrbit:earth')],
    );
    final board = ContractBoard(contracts: [contract]);

    final vessels = InMemoryVesselRepository([vessel]);
    final tick = AdvanceSimulationTick(
      vessels: vessels,
      universe: StaticUniverseRepository(system),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: InMemoryEventBus(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
      contracts: board,
    );

    expect(contract.isComplete, isFalse);
    final clock = SimulationClock(warpFactor: 1, fixedStep: 1.0);
    tick.execute(clock); // first tick classifies the situation -> event -> contract

    expect(contract.isComplete, isTrue);
    expect(contract.rewarded, isTrue);
  });
}
