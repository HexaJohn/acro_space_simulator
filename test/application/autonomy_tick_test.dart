import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/autonomy/flight_plan.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('autopilot maneuver node raises apoapsis through the tick', () {
    final system = SampleWorld.buildSystem();
    final vessel = SampleWorld.buildVessel(altitude: 120000);
    final apoBefore = vessel.state.velocity.length;

    // Schedule a 200 m/s prograde burn at t=2s.
    vessel.flightPlan = FlightPlan(
      vessel: vessel.id,
      legs: [
        FlightLeg(
          targetBody: SampleWorld.kerbin,
          targetAltitude: 300000,
          nodes: [
            ManeuverNode(executeAt: const Epoch(2), deltaV: const Vector3(200, 0, 0)),
          ],
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

    // Physics mode so the burn shows in velocity (low warp).
    final clock = SimulationClock(warpFactor: 1, fixedStep: 1.0);
    for (var i = 0; i < 5; i++) {
      tick.execute(clock);
    }

    final after = vessels.byId(vessel.id)!;
    // Burn fired -> faster than the pre-burn circular speed, and the node is gone.
    expect(after.state.velocity.length, greaterThan(apoBefore));
    expect(after.flightPlan!.isComplete, isTrue);
  });
}
