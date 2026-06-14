import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/domain/parts/vessel_assembler.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an assembled jet aircraft accelerates under jet thrust in atmosphere', () {
    final system = RealSolarSystem.build();
    final earth = system.require(const BodyId('earth'));
    final catalog = PartCatalog.standard();
    const assembler = VesselAssembler();

    PlacedPart p(String id, String inst, Vector3 pos) =>
        PlacedPart(def: catalog.byId(id)!, instanceId: inst, position: pos);

    // Flying low (10 km) and level at 150 m/s.
    final plane = assembler.assemble(
      id: 'jet',
      name: 'Jet',
      ownerId: 'p',
      parts: [
        p('cockpit-mk1', 'cockpit', Vector3.zero),
        p('swept-wing', 'wingL', const Vector3(-2, 0, 0)),
        p('swept-wing', 'wingR', const Vector3(2, 0, 0)),
        p('ram-intake', 'intake', const Vector3(0, 0, 1)),
        p('turbojet-j85', 'jet', const Vector3(0, 0, -2)),
        p('jet-fuel-tank', 'tank', const Vector3(0, 0, -1)),
      ],
      state: StateVector(
        position: Vector3(earth.radius + 10000, 0, 0),
        velocity: Vector3(0, 150, 0),
      ),
      dominantBody: const BodyId('earth'),
    );
    plane.setThrottle(1.0);

    final vessels = InMemoryVesselRepository([plane]);
    final tick = AdvanceSimulationTick(
      vessels: vessels,
      universe: StaticUniverseRepository(system),
      compute: DartCompute(),
      soi: const SoiTransitionService(),
      events: InMemoryEventBus(),
      colonies: InMemoryColonyRepository(),
      deposits: InMemoryDepositRepository(),
      weather: const NullWeatherRepository(),
      // High structural limit so the test isolates jet/lift behaviour.
      maxDynamicPressure: double.infinity,
    );

    final speed0 = plane.state.velocity.length;
    final clock = SimulationClock(warpFactor: 1, fixedStep: 0.1);
    for (var i = 0; i < 50; i++) {
      tick.execute(clock);
    }
    final after = vessels.byId(const VesselId('jet'));
    expect(after, isNotNull); // survived
    // Jet thrust > drag at this speed -> it sped up, and burned fuel.
    expect(after!.state.velocity.length, greaterThan(speed0));
    final fuel = after.allParts
        .expand((p) => p.resources)
        .where((r) => r.type.name == 'liquidFuel')
        .fold(0.0, (s, r) => s + r.amount);
    expect(fuel, lessThan(400)); // consumed jet fuel
  });
}
