import 'dart:math' as math;

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/autonomy/flight_plan.dart';
import 'package:acro_space_simulator/domain/autonomy/maneuver_planner.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/orbits/state_vector_converter.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('planned Hohmann transfer, flown by autopilot, raises the orbit', () {
    final system = SampleWorld.buildSystem();
    final body = system.require(SampleWorld.kerbin);
    final vessel = SampleWorld.buildVessel(altitude: 100000);

    final r1 = body.radius + 100000;
    final r2 = body.radius + 250000;

    const planner = ManeuverPlanner();
    final nodes = planner.hohmann(
      mu: body.mu,
      fromRadius: r1,
      toRadius: r2,
      startEpoch: const Epoch(1),
    );
    vessel.flightPlan = FlightPlan(
      vessel: vessel.id,
      legs: [
        FlightLeg(
          targetBody: SampleWorld.kerbin,
          targetAltitude: 250000,
          nodes: nodes,
        ),
      ],
    );

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
    );

    // Low warp so physics integrates the burns. Run past the second burn time.
    const converter = StateVectorOrbitConverter();
    final at = (r1 + r2) / 2;
    final tHalf = math.pi * math.sqrt(at * at * at / body.mu);
    final clock = SimulationClock(warpFactor: 1, fixedStep: 1.0);
    final steps = (tHalf + 30).ceil();

    for (var i = 0; i < steps; i++) {
      tick.execute(clock);
    }

    final after = vessels.byId(vessel.id)!;
    final orbit = converter.toOrbit(
      position: after.state.position,
      velocity: after.state.velocity,
      body: body,
      epoch: clock.epoch,
    );

    // Both burns spent.
    expect(after.flightPlan!.isComplete, isTrue);
    // Apoapsis raised well above the original ~100 km orbit.
    expect(orbit.apoapsis, greaterThan(r1 + 100000));
  });
}
