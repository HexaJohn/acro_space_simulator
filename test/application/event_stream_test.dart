import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/application/usecases/apply_commands.dart';
import 'package:acro_space_simulator/application/usecases/authoritative_simulation.dart';
import 'package:acro_space_simulator/domain/multiplayer/player.dart';
import 'package:acro_space_simulator/domain/multiplayer/session.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/simulation/domain_event.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

({AuthoritativeSimulation sim, InMemoryEventBus bus}) buildSim() {
  final system = SampleWorld.buildSystem();
  final vessel = SampleWorld.buildVessel();
  final vessels = InMemoryVesselRepository([vessel]);
  final bus = InMemoryEventBus();
  final tick = AdvanceSimulationTick(
    vessels: vessels,
    universe: StaticUniverseRepository(system),
    compute: DartCompute(),
    soi: const SoiTransitionService(),
    events: bus,
    colonies: InMemoryColonyRepository(),
    deposits: InMemoryDepositRepository(),
    weather: const NullWeatherRepository(),
  );
  final session = Session(
    id: 's',
    players: [
      Player(id: const PlayerId('p'), displayName: 'P', ownedAssetIds: {'demo-1'}),
    ],
  );
  final sim = AuthoritativeSimulation(
    session: session,
    applyCommands: ApplyCommands(vessels: vessels),
    advance: tick,
    clock: SimulationClock(warpFactor: 1, fixedStep: 1.0),
    vessels: vessels,
  );
  return (sim: sim, bus: bus);
}

void main() {
  test('EventSnapshot.of flattens domain events', () {
    final s = EventSnapshot.of(Impact(const VesselId('v'), const BodyId('b'), 99.0));
    expect(s.kind, 'Impact');
    expect(s.subject, 'v');
    expect(s.target, 'b');
    expect(s.magnitude, 99.0);

    final c = EventSnapshot.of(CrewLost(const VesselId('v'), 'oxygen'));
    expect(c.kind, 'CrewLost');
    expect(c.info, 'oxygen');
  });

  test('snapshot folds in the tick events and drains the bus', () {
    final (:sim, :bus) = buildSim();

    bus.publish(StageSeparation(const VesselId('demo-1'), 0));
    bus.publish(Impact(const VesselId('demo-1'), const BodyId('kerbin'), 250.0));

    final snap = sim.snapshot();
    expect(snap.events.map((e) => e.kind), ['StageSeparation', 'Impact']);
    expect(snap.events[1].magnitude, 250.0);

    // Drained — a second snapshot with no new events is empty.
    expect(sim.snapshot().events, isEmpty);
  });
}
