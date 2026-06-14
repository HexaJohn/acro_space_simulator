import '../simulation/epoch.dart';
import 'player.dart';

/// A player-issued intent to change the simulation — the ONLY way the outside
/// world mutates authoritative state in multiplayer. Commands are validated
/// (ownership, legality), ordered by [tick], then applied deterministically so
/// every client converges (lockstep/command-stream model).
///
/// Sealed hierarchy so the command applier handles every case exhaustively.
sealed class SimCommand {
  final PlayerId issuedBy;
  final int tick; // simulation tick the command targets
  const SimCommand(this.issuedBy, this.tick);

  /// The asset this command acts on, for ownership checks.
  String get targetAssetId;
}

class SetThrottleCommand extends SimCommand {
  final String vesselId;
  final double throttle;
  const SetThrottleCommand(super.issuedBy, super.tick, this.vesselId, this.throttle);
  @override
  String get targetAssetId => vesselId;
}

class SeparateStageCommand extends SimCommand {
  final String vesselId;
  const SeparateStageCommand(super.issuedBy, super.tick, this.vesselId);
  @override
  String get targetAssetId => vesselId;
}

class SetAttitudeCommand extends SimCommand {
  final String vesselId;
  final double headingX, headingY, headingZ; // desired forward axis
  const SetAttitudeCommand(
    super.issuedBy,
    super.tick,
    this.vesselId,
    this.headingX,
    this.headingY,
    this.headingZ,
  );
  @override
  String get targetAssetId => vesselId;
}

class PlaceBuildingCommand extends SimCommand {
  final String colonyId;
  final String buildingType;
  final int gridX, gridY;
  const PlaceBuildingCommand(
    super.issuedBy,
    super.tick,
    this.colonyId,
    this.buildingType,
    this.gridX,
    this.gridY,
  );
  @override
  String get targetAssetId => colonyId;
}

/// A timestamped batch of commands for one tick, as received by the
/// authoritative simulation. The clock the batch was sealed at is kept for
/// ordering across clients.
class CommandBatch {
  final Epoch at;
  final List<SimCommand> commands;
  const CommandBatch(this.at, this.commands);
}
