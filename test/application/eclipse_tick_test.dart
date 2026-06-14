import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/thermal/thermal_state.dart';
import 'package:acro_space_simulator/domain/vessel/part.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

Vessel _coldSat(String id, Vector3 pos) {
  return Vessel(
    id: VesselId(id),
    name: id,
    ownerId: 'p',
    state: StateVector(position: pos, velocity: Vector3.zero),
    dominantBody: SampleWorld.kerbin,
    stages: const [],
    landed: true, // pin position so the test isolates the eclipse effect
    thermal: [
      PartThermalState(
        part: const PartId('panel'),
        temperature: 250,
        heatCapacity: 500,
        maxTemperature: 2000,
        emissivity: 0.9,
        surfaceArea: 30,
      ),
    ],
  );
}

void main() {
  test('sunlit satellite heats more than an eclipsed one', () {
    final system = SampleWorld.buildSystem();
    // Sun direction in the tick for the root body Kerbin is +X.
    final sunlit = _coldSat('lit', const Vector3(3000000, 0, 0)); // +X, sunward
    final eclipsed = _coldSat('dark', const Vector3(-3000000, 0, 0)); // -X, shadow

    final vessels = InMemoryVesselRepository([sunlit, eclipsed]);
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

    // Pinned positions (landed) isolate the eclipse effect from orbital motion.
    final clock = SimulationClock(warpFactor: 1, fixedStep: 1.0);
    for (var i = 0; i < 200; i++) {
      tick.execute(clock);
    }

    final litTemp = vessels.byId(const VesselId('lit'))!
        .thermalOf(const PartId('panel'))!
        .temperature;
    final darkTemp = vessels.byId(const VesselId('dark'))!
        .thermalOf(const PartId('panel'))!
        .temperature;

    expect(litTemp, greaterThan(darkTemp));
  });
}
