import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('attitude controller slews the vessel toward its target facing in the tick',
      () {
    final body = SampleWorld.realSystem().require(SampleWorld.earth);
    // Landed so it stays put; we only test the attitude slew.
    final v = Vessel(
      id: const VesselId('turner'),
      name: 'Turner',
      ownerId: 'p',
      state: StateVector(
        position: Vector3(body.radius, 0, 0),
        velocity: Vector3.zero,
        attitude: Quaternion.identity, // forward = +Z
      ),
      dominantBody: SampleWorld.earth,
      stages: const [],
      landed: true,
    )..targetFacing = Vector3.unitX;

    final vessels = InMemoryVesselRepository([v]);
    final tick = AdvanceSimulationTick(
      vessels: vessels,
      universe: StaticUniverseRepository(SampleWorld.realSystem()),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: InMemoryEventBus(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
    );

    final before =
        v.state.attitude.rotate(Vector3.unitZ).dot(Vector3.unitX);
    final clock = SimulationClock(warpFactor: 1, fixedStep: 0.5);
    for (var i = 0; i < 200; i++) {
      tick.execute(clock);
    }
    final after = vessels
        .byId(const VesselId('turner'))!
        .state
        .attitude
        .rotate(Vector3.unitZ)
        .dot(Vector3.unitX);

    expect(after, greaterThan(before));
    expect(after, greaterThan(0.9));
  });
}
