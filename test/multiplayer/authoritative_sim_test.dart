import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/application/usecases/apply_commands.dart';
import 'package:acro_space_simulator/application/usecases/authoritative_simulation.dart';
import 'package:acro_space_simulator/domain/multiplayer/command.dart';
import 'package:acro_space_simulator/domain/multiplayer/player.dart';
import 'package:acro_space_simulator/domain/multiplayer/session.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

AuthoritativeSimulation buildSim({required String owner}) {
  final system = SampleWorld.realSystem();
  final vessel = SampleWorld.buildVessel(altitude: 200000);
  // Force ownership for the test.
  final owned = Vessel(
    id: vessel.id,
    name: vessel.name,
    ownerId: owner,
    state: vessel.state,
    dominantBody: vessel.dominantBody,
    stages: vessel.stages,
  );
  final vessels = InMemoryVesselRepository([owned]);
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
  final session = Session(
    id: 's1',
    players: [
      Player(id: PlayerId(owner), displayName: 'Owner', ownedAssetIds: {'demo-1'}),
      Player(id: const PlayerId('intruder'), displayName: 'Intruder'),
    ],
  );
  return AuthoritativeSimulation(
    session: session,
    applyCommands: ApplyCommands(vessels: vessels),
    advance: tick,
    clock: SimulationClock(warpFactor: 1, fixedStep: 1.0),
    vessels: vessels,
  );
}

void main() {
  test('applies an owner command then advances the authoritative tick', () {
    final sim = buildSim(owner: 'alice');
    sim.step([
      CommandBatch(Epoch.zero, [
        const SetThrottleCommand(PlayerId('alice'), 0, 'demo-1', 1.0),
      ]),
    ]);
    expect(sim.session.authoritativeTick, 1);
    expect(sim.snapshot().vessels['demo-1']!.throttle, 1.0);
  });

  test('rejects a command against an asset the player does not own', () {
    final sim = buildSim(owner: 'alice');
    sim.step([
      CommandBatch(Epoch.zero, [
        // Intruder tries to throttle Alice's ship.
        const SetThrottleCommand(PlayerId('intruder'), 0, 'demo-1', 1.0),
      ]),
    ]);
    expect(sim.snapshot().vessels['demo-1']!.throttle, 0.0);
  });

  test('determinism: identical command streams produce identical snapshots', () {
    final a = buildSim(owner: 'alice');
    final b = buildSim(owner: 'alice');

    List<CommandBatch> stream(int tick) => [
          CommandBatch(Epoch(tick.toDouble()), [
            SetThrottleCommand(const PlayerId('alice'), tick, 'demo-1',
                (tick % 2 == 0) ? 1.0 : 0.3),
          ]),
        ];

    for (var t = 0; t < 100; t++) {
      a.step(stream(t));
      b.step(stream(t));
    }

    expect(a.snapshot().fingerprint, equals(b.snapshot().fingerprint));
  });
}
