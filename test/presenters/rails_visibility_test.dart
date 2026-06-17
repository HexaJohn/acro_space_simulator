import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/presenters/top_down_snapshot.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('snapshot stays finite + on-screen after many ticks (focus vessel)', () {
    final system = SampleWorld.realSystem();
    final vessel = SampleWorld.buildEarthOrbiter(altitude: 400000);
    final freighter = SampleWorld.buildEarthFreighter();
    final vessels = InMemoryVesselRepository([vessel, freighter]);
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
    final presenter =
        TopDownSnapshotPresenter(vessels: vessels, universe: universe);
    final clock = SimulationClock(warpFactor: 50, fixedStep: 0.02);

    TopDownSnapshot snap() => presenter.present(
          focus: vessel.id,
          camera: OrthoCamera(CameraOrbit.top, 25000),
          epoch: clock.epoch,
        );

    void checkFinite(TopDownSnapshot s, String when) {
      for (final b in s.bodies) {
        expect(b.x.isFinite && b.y.isFinite, isTrue,
            reason: '$when body ${b.name} pos non-finite');
        for (final p in b.orbitPath) {
          expect(p.x.isFinite && p.y.isFinite, isTrue,
              reason: '$when body ${b.name} rail non-finite');
        }
      }
      for (final v in s.vessels) {
        expect(v.x.isFinite && v.y.isFinite, isTrue,
            reason: '$when vessel ${v.name} pos non-finite');
      }
    }

    checkFinite(snap(), 'frame 0');

    for (var i = 0; i < 2000; i++) {
      advance.execute(clock);
    }

    final s = snap();
    checkFinite(s, 'after 2000 ticks');

    // The focus vessel must stay near the screen origin (it's the camera lock).
    final focus = s.vessels.firstWhere((v) => v.name == 'Orbiter');
    expect(focus.x.abs(), lessThan(1e7), reason: 'focus drifted off-screen X');
    expect(focus.y.abs(), lessThan(1e7), reason: 'focus drifted off-screen Y');
  });
}
