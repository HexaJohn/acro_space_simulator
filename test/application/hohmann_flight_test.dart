import 'dart:math' as math;

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/autonomy/flight_plan.dart';
import 'package:acro_space_simulator/domain/autonomy/maneuver_planner.dart';
import 'package:acro_space_simulator/domain/lifesupport/crew.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/orbits/state_vector_converter.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('planned Hohmann transfer, flown by autopilot, raises the orbit', () {
    final system = SampleWorld.realSystem();
    final body = system.require(SampleWorld.earth);
    // Start in a clean low Earth orbit (200 km, clear of the ~140 km atmosphere)
    // and Hohmann up to 350 km, so the craft never dips into atmospheric drag.
    final vessel = SampleWorld.buildVessel(altitude: 200000)
      // A crewed flight computer executes the pre-planned circularization burn
      // even when the craft is on the far side of the body (no ground link).
      ..crew = CrewModule(count: 1);

    final r1 = body.radius + 200000;
    final r2 = body.radius + 350000;

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
          targetBody: SampleWorld.earth,
          targetAltitude: 350000,
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
    // Apoapsis raised well above the original ~200 km orbit.
    expect(orbit.apoapsis, greaterThan(r1 + 100000));
  });
}
