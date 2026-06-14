import '../../domain/multiplayer/command.dart';
import '../../domain/multiplayer/session.dart';
import '../../domain/shared/vector3.dart';
import '../../domain/vessel/vessel.dart';
import '../ports/repositories.dart';

/// Applies a validated batch of player commands to the authoritative state.
///
/// Multiplayer determinism rule: commands are validated against ownership by
/// the [Session], then applied in a fixed order so every client that processes
/// the same batch reaches the same state. The exhaustive switch over the sealed
/// [SimCommand] guarantees every command type is handled.
class ApplyCommands {
  final VesselRepository vessels;
  ApplyCommands({required this.vessels});

  void execute(Session session, CommandBatch batch) {
    final allowed = session.validate(batch);
    for (final cmd in allowed) {
      switch (cmd) {
        case SetThrottleCommand(:final vesselId, :final throttle):
          final v = vessels.byId(VesselId(vesselId));
          v?.setThrottle(throttle);
          if (v != null) vessels.save(v);

        case SeparateStageCommand(:final vesselId):
          final v = vessels.byId(VesselId(vesselId));
          if (v != null && v.separateStage()) vessels.save(v);

        case SetAttitudeCommand(
            :final vesselId,
            :final headingX,
            :final headingY,
            :final headingZ
          ):
          final v = vessels.byId(VesselId(vesselId));
          if (v != null) {
            v.targetFacing = Vector3(headingX, headingY, headingZ);
            vessels.save(v);
          }

        case PlaceBuildingCommand():
          // Routed to the colony use case (not wired in this pass).
          break;
      }
    }
  }
}
