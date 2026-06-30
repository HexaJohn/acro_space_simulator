import 'dart:math' as math;

import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/orbits/state_vector_converter.dart';
import 'package:acro_space_simulator/domain/shared/precise_vector3.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PreciseVector3 granularity lattice', () {
    test('round-trips a large position without losing centimetre precision', () {
      // A point ~1 AU out, plus a 7 cm offset. With a plain double the offset
      // would be swallowed; the lattice keeps it.
      final base = PreciseVector3.fromMeters(
        const Vector3(1.496e11, 0, 0),
        granularity: 3, // 1 km cells
      );
      final moved = base + const Vector3(0.07, 0, 0); // 7 cm
      final back = base.vectorTo(moved);
      expect(back.x, closeTo(0.07, 1e-6));
    });

    test('rebasing across granularities preserves the world point', () {
      final p = PreciseVector3.fromMeters(
        const Vector3(12345678.0, -987654.0, 42.0),
        granularity: 2, // 100 m cells
      );
      final coarse = p.rebase(6); // 1000 km cells
      final delta = p.vectorTo(coarse);
      expect(delta.length, closeTo(0, 1e-3));
    });
  });

  group('Keplerian conversion', () {
    test('circular orbit: state -> elements -> state preserves radius & speed',
        () {
      final body = SampleWorld.realSystem().require(SampleWorld.earth);
      final r = body.radius + 100000;
      final v = math.sqrt(body.mu / r);
      const converter = StateVectorOrbitConverter();

      final orbit = converter.toOrbit(
        position: Vector3(r, 0, 0),
        velocity: Vector3(0, v, 0),
        body: body,
        epoch: Epoch.zero,
      );

      // Near-circular.
      expect(orbit.elements.eccentricity, closeTo(0, 1e-3));

      // Propagate a quarter period; radius and speed must be conserved.
      final quarter = orbit.period / 4;
      final later = converter.toStateVector(orbit, Epoch(quarter));
      expect(later.position.length, closeTo(r, r * 1e-3));
      expect(later.velocity.length, closeTo(v, v * 1e-3));
    });
  });

  group('AdvanceSimulationTick', () {
    test('on-rails vessel stays in a bound orbit over many ticks', () {
      final system = SampleWorld.realSystem();
      final vessel = SampleWorld.buildVessel(altitude: 200000);
      final r0 = vessel.state.position.length;

      final vessels = InMemoryVesselRepository([vessel]);
      final advance = AdvanceSimulationTick(
        vessels: vessels,
        universe: StaticUniverseRepository(system),
        compute: DartCompute(),
        soi: const SoiTransitionService(),
        events: InMemoryEventBus(),
        colonies: InMemoryColonyRepository(),
        deposits: InMemoryDepositRepository(),
        weather: const NullWeatherRepository(),
      );
      // High warp -> on-rails analytic propagation.
      final clock = SimulationClock(warpFactor: 100, fixedStep: 0.5);

      for (var i = 0; i < 2000; i++) {
        advance.execute(clock);
      }

      final r1 = vessels.byId(vessel.id)!.state.position.length;
      // Bound circular orbit: radius should not drift more than ~1%.
      expect((r1 - r0).abs() / r0, lessThan(0.01));
    });
  });
}
