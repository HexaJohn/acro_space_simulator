import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an on-rails vessel advances along its orbit at high warp (not frozen)',
      () {
    final system = SampleWorld.realSystem();
    final orbiter = SampleWorld.buildEarthOrbiter(altitude: 400000);
    final vessels = InMemoryVesselRepository([orbiter]);
    final universe = StaticUniverseRepository(system);

    final advance = AdvanceSimulationTick(
      vessels: vessels,
      universe: universe,
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: InMemoryEventBus(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: InMemoryWeatherRepository(),
    );

    // High warp -> forces rails (warp > 4).
    final clock = SimulationClock(warpFactor: 100, fixedStep: 1.0);

    final start = vessels.byId(orbiter.id)!.state.position;

    // A handful of ticks should move the craft a meaningful distance along orbit.
    for (var i = 0; i < 20; i++) {
      advance.execute(clock);
    }

    final v = vessels.byId(orbiter.id)!;
    expect(v.mode, PropagationMode.onRails, reason: 'should be on rails at warp 100');
    final moved = (v.state.position - start).length;
    expect(moved, greaterThan(1000),
        reason: 'on-rails craft must advance along its orbit, not freeze');
  });
}
