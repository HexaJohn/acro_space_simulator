import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/autonomy/flight_plan.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/domain_event.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an under-fuelled autonomous transfer is aborted with an event', () {
    final system = SampleWorld.buildSystem();
    final body = system.require(SampleWorld.kerbin);
    final vessel = SampleWorld.buildVessel(altitude: 100000);

    // Demand a wildly unaffordable burn (10 km/s).
    vessel.flightPlan = FlightPlan(
      vessel: vessel.id,
      legs: [
        FlightLeg(
          targetBody: SampleWorld.kerbin,
          targetAltitude: 5000000,
          nodes: [
            ManeuverNode(executeAt: const Epoch(1), deltaV: const Vector3(10000, 0, 0)),
          ],
        ),
      ],
    );
    // Sanity: capacity really is below the demand.
    expect(vessel.deltaVCapacity(), lessThan(10000));

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
    for (var i = 0; i < 5; i++) {
      tick.execute(clock);
    }

    expect(events.recent.whereType<PlanAborted>().isNotEmpty, isTrue);
    expect(vessels.byId(vessel.id)!.flightPlan, isNull);
    // body referenced to keep the import meaningful
    expect(body.radius, greaterThan(0));
  });
}
