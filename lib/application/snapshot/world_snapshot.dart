import '../../domain/vessel/vessel.dart';
import '../ports/repositories.dart';

/// Serializable per-vessel state for network sync, save/load, and determinism
/// checks. Plain numbers only — no domain objects — so it round-trips over the
/// wire trivially.
class VesselSnapshot {
  final String id;
  final String ownerId;
  final String body;
  final double px, py, pz;
  final double vx, vy, vz;
  final double throttle;
  final bool onRails;

  const VesselSnapshot({
    required this.id,
    required this.ownerId,
    required this.body,
    required this.px,
    required this.py,
    required this.pz,
    required this.vx,
    required this.vy,
    required this.vz,
    required this.throttle,
    required this.onRails,
  });

  factory VesselSnapshot.of(Vessel v) => VesselSnapshot(
        id: v.id.value,
        ownerId: v.ownerId,
        body: v.dominantBody.value,
        px: v.state.position.x,
        py: v.state.position.y,
        pz: v.state.position.z,
        vx: v.state.velocity.x,
        vy: v.state.velocity.y,
        vz: v.state.velocity.z,
        throttle: v.throttle,
        onRails: v.mode == PropagationMode.onRails,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'ownerId': ownerId,
        'body': body,
        'p': [px, py, pz],
        'v': [vx, vy, vz],
        'throttle': throttle,
        'onRails': onRails,
      };
}

/// Full authoritative world state for one tick. Sent to clients for
/// reconciliation; compared between runs to verify deterministic simulation.
class WorldSnapshot {
  final int tick;
  final Map<String, VesselSnapshot> vessels;

  const WorldSnapshot({required this.tick, required this.vessels});

  factory WorldSnapshot.capture(int tick, VesselRepository vessels) =>
      WorldSnapshot(
        tick: tick,
        vessels: {
          for (final v in vessels.all()) v.id.value: VesselSnapshot.of(v),
        },
      );

  /// A stable hash of the world state. Two deterministic runs fed identical
  /// commands must yield the same fingerprint. Rounds floats to a tolerance so
  /// the check is robust to non-meaningful ULP noise while still catching real
  /// divergence.
  String get fingerprint {
    final ids = vessels.keys.toList()..sort();
    final buf = StringBuffer();
    for (final id in ids) {
      final s = vessels[id]!;
      buf
        ..write(id)
        ..write(':')
        ..write(s.body)
        ..write(':')
        ..write(_q(s.px))
        ..write(',')
        ..write(_q(s.py))
        ..write(',')
        ..write(_q(s.pz))
        ..write('|')
        ..write(_q(s.vx))
        ..write(',')
        ..write(_q(s.vy))
        ..write(',')
        ..write(_q(s.vz))
        ..write('@')
        ..write(_q(s.throttle))
        ..write(';');
    }
    return buf.toString();
  }

  // Quantize to 1e-3 to ignore meaningless float noise across runs.
  String _q(double x) => (x * 1000).roundToDouble().toStringAsFixed(0);
}
