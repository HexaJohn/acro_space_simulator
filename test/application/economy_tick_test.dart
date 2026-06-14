import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/contracts/contract.dart';
import 'package:acro_space_simulator/domain/contracts/contract_tracker.dart';
import 'package:acro_space_simulator/domain/economy/treasury.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/science/research_ledger.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('completing a contract deposits funds and science via the tick', () {
    final system = SampleWorld.buildSystem();
    final vessel = SampleWorld.buildVessel(altitude: 120000);

    final board = ContractBoard(contracts: [
      Contract(
        id: 'orbit',
        title: 'Orbit Kerbin',
        rewardFunds: 75000,
        rewardScience: 12,
        objectives: [ReachSituationObjective(situation: 'lowOrbit:kerbin')],
      ),
    ]);
    final treasury = Treasury(balance: 1000);
    final research = ResearchLedger();

    final tick = AdvanceSimulationTick(
      vessels: InMemoryVesselRepository([vessel]),
      universe: StaticUniverseRepository(system),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: InMemoryEventBus(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
      contracts: board,
      treasury: treasury,
      research: research,
    );

    tick.execute(SimulationClock(warpFactor: 1, fixedStep: 1.0));

    expect(treasury.balance, 1000 + 75000);
    expect(research.science, 12);
    expect(treasury.ledger.last.reason, contains('contract'));
  });
}
