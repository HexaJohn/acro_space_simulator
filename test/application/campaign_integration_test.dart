import 'dart:math' as math;

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/autonomy/flight_plan.dart';
import 'package:acro_space_simulator/domain/autonomy/maneuver_planner.dart';
import 'package:acro_space_simulator/domain/contracts/contract.dart';
import 'package:acro_space_simulator/domain/contracts/contract_tracker.dart';
import 'package:acro_space_simulator/domain/economy/treasury.dart';
import 'package:acro_space_simulator/domain/lifesupport/crew.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/orbits/state_vector_converter.dart';
import 'package:acro_space_simulator/domain/science/experiment.dart';
import 'package:acro_space_simulator/domain/science/research_ledger.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'end-to-end: an autonomous vessel flies a Hohmann transfer, collects '
      'science, and completes a contract that pays funds — all through the tick',
      () {
    final system = SampleWorld.buildSystem();
    final body = system.require(SampleWorld.kerbin);

    final vessel = SampleWorld.buildVessel(altitude: 100000)
      // Crewed flight computer executes the planned burns even out of ground
      // link (far side of the body).
      ..crew = CrewModule(count: 1);
    vessel.experiments.addAll(const [
      Experiment(id: 'thermometer', baseValue: 6),
      Experiment(id: 'barometer', baseValue: 9),
    ]);

    final r1 = body.radius + 100000;
    final r2 = body.radius + 300000;
    const planner = ManeuverPlanner();
    vessel.flightPlan = FlightPlan(
      vessel: vessel.id,
      legs: [
        FlightLeg(
          targetBody: SampleWorld.kerbin,
          targetAltitude: 300000,
          nodes: planner.hohmann(
            mu: body.mu,
            fromRadius: r1,
            toRadius: r2,
            startEpoch: const Epoch(2),
          ),
        ),
      ],
    );

    final board = ContractBoard(contracts: [
      Contract(
        id: 'reach-orbit',
        title: 'Reach low Kerbin orbit',
        rewardFunds: 40000,
        rewardScience: 5,
        objectives: [ReachSituationObjective(situation: 'lowOrbit:kerbin')],
      ),
    ]);
    final treasury = Treasury(balance: 0);
    final research = ResearchLedger();

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
      treasury: treasury,
      research: research,
    );

    final at = (r1 + r2) / 2;
    final tHalf = math.pi * math.sqrt(at * at * at / body.mu);
    final clock = SimulationClock(warpFactor: 1, fixedStep: 1.0);
    for (var i = 0; i < (tHalf + 30).ceil(); i++) {
      tick.execute(clock);
    }

    final after = vessels.byId(vessel.id)!;
    const converter = StateVectorOrbitConverter();
    final orbit = converter.toOrbit(
      position: after.state.position,
      velocity: after.state.velocity,
      body: body,
      epoch: clock.epoch,
    );

    // 1) Flew the transfer: plan complete + apoapsis raised.
    expect(after.flightPlan!.isComplete, isTrue);
    expect(orbit.apoapsis, greaterThan(r1 + 100000));

    // 2) Collected science from at least one situation.
    expect(research.science, greaterThan(0));

    // 3) Completed the contract and was paid.
    expect(board.contracts.first.isComplete, isTrue);
    expect(treasury.balance, greaterThanOrEqualTo(40000));
  });
}
