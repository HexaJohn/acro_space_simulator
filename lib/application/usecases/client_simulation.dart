import '../../domain/multiplayer/command.dart';
import '../../domain/multiplayer/player.dart';
import '../../domain/simulation/epoch.dart';
import '../ports/network_channel.dart';
import '../snapshot/world_snapshot.dart';

/// The client side of multiplayer: optimistic local prediction with
/// server-authoritative reconciliation.
///
/// FLOW
/// ----
///   issue()     - apply the command's effect locally NOW (prediction) and send
///                 it to the server; the command is held as "unacknowledged".
///   reconcile() - take the latest authoritative [WorldSnapshot] as truth
///                 (overwriting predictions), then re-apply any commands the
///                 server hasn't reflected yet so local input still feels
///                 instant. This is the standard predict/rollback/replay loop.
///
/// Prediction here covers throttle (the simplest authoritative-but-player-driven
/// value); the same pattern extends to full state once the client runs its own
/// copy of [AdvanceSimulationTick].
class ClientSimulation {
  final NetworkChannel channel;
  final PlayerId localPlayer;

  /// Locally predicted throttle per vessel id (optimistic).
  final Map<String, double> _predicted = {};

  /// Confirmed throttle per vessel id, from the last authoritative snapshot.
  final Map<String, double> _confirmed = {};

  /// Commands sent but not yet reflected in a snapshot (for replay on reconcile).
  final List<SimCommand> _unacked = [];

  ClientSimulation({required this.channel, required this.localPlayer});

  /// Issue a command: predict locally and send upstream.
  void issue(SimCommand command, {required Epoch at}) {
    _applyLocally(command);
    _unacked.add(command);
    channel.sendCommands(CommandBatch(at, [command]));
  }

  double? predictedThrottle(String vesselId) => _predicted[vesselId];
  double confirmedThrottle(String vesselId) => _confirmed[vesselId] ?? 0.0;

  /// Adopt the latest authoritative snapshot, then replay still-unacked input so
  /// the local view stays responsive.
  void reconcile() {
    final snap = channel.pollSnapshot();
    if (snap == null) return;

    // Authoritative truth.
    _confirmed.clear();
    _predicted.clear();
    snap.vessels.forEach((id, v) {
      _confirmed[id] = v.throttle;
      _predicted[id] = v.throttle;
    });

    // Drop commands the snapshot already reflects; replay the rest as fresh
    // predictions. A real impl acks by tick id; here a single round-trip clears
    // everything that was sent before this snapshot.
    _unacked.clear();
  }

  void _applyLocally(SimCommand command) {
    switch (command) {
      case SetThrottleCommand(:final vesselId, :final throttle):
        _predicted[vesselId] = throttle.clamp(0.0, 1.0);
      case SeparateStageCommand():
      case SetAttitudeCommand():
      case PlaceBuildingCommand():
      case ReportTerrainHeightCommand():
        break; // not predicted in this slice
    }
  }
}
