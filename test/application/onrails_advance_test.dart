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

  test('a landed vessel co-rotates with the spinning body (does not drift)', () {
    final system = SampleWorld.realSystem(); // miner lands on this system's body
    final miner = SampleWorld.buildMiner(); // landed on a body
    final vessels = InMemoryVesselRepository([miner]);
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
    final body = system.body(miner.dominantBody)!;
    final start = vessels.byId(miner.id)!.state.position;

    // Warp so the body's spin advances appreciably over the ticks.
    final clock = SimulationClock(warpFactor: 1000, fixedStep: 1.0);
    for (var i = 0; i < 30; i++) {
      advance.execute(clock);
    }

    final v = vessels.byId(miner.id)!;
    expect(v.landed, isTrue, reason: 'still landed');
    // Radius (altitude) is preserved — it only rotated, not drifted off.
    expect(v.state.position.length, closeTo(start.length, 1.0),
        reason: 'co-rotation keeps it on the surface, same radius');
    if (body.angularVelocity != 0) {
      // On a spinning body it must have MOVED (rotated with the surface).
      expect((v.state.position - start).length, greaterThan(1.0),
          reason: 'a landed craft must track the rotating surface');
    }
  });
}
