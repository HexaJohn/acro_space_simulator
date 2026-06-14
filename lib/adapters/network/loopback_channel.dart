import '../../application/ports/network_channel.dart';
import '../../application/snapshot/world_snapshot.dart';
import '../../application/usecases/authoritative_simulation.dart';
import '../../domain/multiplayer/command.dart';

/// In-process [NetworkChannel] that wires a client straight to an
/// [AuthoritativeSimulation] — no real network. Useful for single-process
/// multiplayer, integration tests, and as the reference adapter a real
/// WebSocket/UDP transport mirrors.
///
/// Commands the client sends are queued; [serverStep] drains them into the
/// authoritative simulation, advances one tick, and caches the resulting
/// snapshot for the client to poll.
class LoopbackChannel implements NetworkChannel {
  final AuthoritativeSimulation server;
  final List<CommandBatch> _inbox = [];
  WorldSnapshot? _latest;

  LoopbackChannel(this.server);

  @override
  void sendCommands(CommandBatch batch) => _inbox.add(batch);

  @override
  WorldSnapshot? pollSnapshot() => _latest;

  /// Advance the authoritative server one tick using all queued commands, then
  /// cache the snapshot. A real server runs this on its own clock; the loopback
  /// exposes it so tests/single-process loops can drive it explicitly.
  void serverStep() {
    final batches = List<CommandBatch>.of(_inbox);
    _inbox.clear();
    server.step(batches);
    _latest = server.snapshot();
  }
}
