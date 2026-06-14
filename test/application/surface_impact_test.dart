import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/domain_event.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  AdvanceSimulationTick buildTick(InMemoryVesselRepository vessels) =>
      AdvanceSimulationTick(
        vessels: vessels,
        universe: StaticUniverseRepository(SampleWorld.buildSystem()),
        compute: DartCompute(),
        soi: const SoiTransitionService(),
        events: InMemoryEventBus(),
        colonies: InMemoryColonyRepository(),
        deposits: InMemoryDepositRepository(),
        weather: const NullWeatherRepository(),
      );

  Vessel faller({required double speed}) {
    final body = SampleWorld.buildSystem().require(SampleWorld.kerbin);
    // Just above the surface, falling straight down.
    return Vessel(
      id: const VesselId('faller'),
      name: 'Faller',
      ownerId: 'p',
      state: StateVector(
        position: Vector3(body.radius + 10, 0, 0),
        velocity: Vector3(-speed, 0, 0),
      ),
      dominantBody: SampleWorld.kerbin,
      stages: const [],
    );
  }

  test('a slow descent below the surface lands the vessel (no destruction)', () {
    final v = faller(speed: 2); // gentle
    final vessels = InMemoryVesselRepository([v]);
    final tick = buildTick(vessels);
    final clock = SimulationClock(warpFactor: 1, fixedStep: 1.0);
    for (var i = 0; i < 20; i++) {
      tick.execute(clock);
    }
    final after = vessels.byId(const VesselId('faller'))!;
    expect(after.landed, isTrue);
  });

  test('a fast impact destroys the vessel and emits an Impact event', () {
    final v = faller(speed: 300); // slams in
    final events = InMemoryEventBus();
    final vessels = InMemoryVesselRepository([v]);
    final tick = AdvanceSimulationTick(
      vessels: vessels,
      universe: StaticUniverseRepository(SampleWorld.buildSystem()),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: events,
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
    );
    final clock = SimulationClock(warpFactor: 1, fixedStep: 0.5);
    for (var i = 0; i < 10; i++) {
      tick.execute(clock);
    }
    // Destroyed vessels are removed from the repository.
    expect(vessels.byId(const VesselId('faller')), isNull);
    expect(events.recent.whereType<Impact>().isNotEmpty, isTrue);
  });
}
