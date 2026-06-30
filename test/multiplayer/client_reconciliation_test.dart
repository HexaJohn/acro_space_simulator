import 'package:acro_space_simulator/adapters/events/in_memory_event_bus.dart';
import 'package:acro_space_simulator/adapters/network/loopback_channel.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_world_repositories.dart';
import 'package:acro_space_simulator/application/ports/compute_port.dart';
import 'package:acro_space_simulator/application/usecases/advance_simulation_tick.dart';
import 'package:acro_space_simulator/application/usecases/apply_commands.dart';
import 'package:acro_space_simulator/application/usecases/authoritative_simulation.dart';
import 'package:acro_space_simulator/application/usecases/client_simulation.dart';
import 'package:acro_space_simulator/domain/multiplayer/command.dart';
import 'package:acro_space_simulator/domain/multiplayer/player.dart';
import 'package:acro_space_simulator/domain/multiplayer/session.dart';
import 'package:acro_space_simulator/domain/orbits/soi_transition_service.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/simulation/simulation_clock.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

AuthoritativeSimulation buildServer() {
  final system = SampleWorld.realSystem();
  final base = SampleWorld.buildVessel();
  final owned = Vessel(
    id: base.id,
    name: base.name,
    ownerId: 'alice',
    state: base.state,
    dominantBody: base.dominantBody,
    stages: base.stages,
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
    id: 's',
    players: [
      Player(id: const PlayerId('alice'), displayName: 'Alice', ownedAssetIds: {'demo-1'}),
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
  test('client predicts a throttle change before the server confirms it', () {
    final server = buildServer();
    final channel = LoopbackChannel(server);
    final client = ClientSimulation(channel: channel, localPlayer: const PlayerId('alice'));

    // Player throttles up; client predicts immediately.
    client.issue(const SetThrottleCommand(PlayerId('alice'), 0, 'demo-1', 1.0),
        at: Epoch.zero);
    expect(client.predictedThrottle('demo-1'), 1.0);
  });

  test('client reconciles to the authoritative snapshot', () {
    final server = buildServer();
    final channel = LoopbackChannel(server);
    final client = ClientSimulation(channel: channel, localPlayer: const PlayerId('alice'));

    client.issue(const SetThrottleCommand(PlayerId('alice'), 0, 'demo-1', 0.7),
        at: Epoch.zero);
    // Server ticks (applies the queued command) and publishes a snapshot.
    channel.serverStep();
    client.reconcile();

    expect(client.confirmedThrottle('demo-1'), closeTo(0.7, 1e-9));
  });

  test('a rejected command (unowned asset) does not survive reconciliation', () {
    final server = buildServer();
    final channel = LoopbackChannel(server);
    final intruder =
        ClientSimulation(channel: channel, localPlayer: const PlayerId('mallory'));

    // Mallory does not own demo-1; predicts locally but server rejects.
    intruder.issue(const SetThrottleCommand(PlayerId('mallory'), 0, 'demo-1', 1.0),
        at: Epoch.zero);
    channel.serverStep();
    intruder.reconcile();

    // Authoritative throttle stayed 0 -> reconciliation overrides the bad guess.
    expect(intruder.confirmedThrottle('demo-1'), 0.0);
  });
}
