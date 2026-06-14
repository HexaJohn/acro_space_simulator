import 'dart:math' as math;

import '../shared/quaternion.dart';
import '../shared/vector3.dart';
import '../vessel/resource_container.dart';
import '../vessel/vessel.dart';

/// Attitude control: rotates a vessel so its forward (+Z body) axis points along
/// [Vessel.targetFacing]. Domain service.
///
/// Two modes:
///   * reaction wheels (default) — free, electricity-only (unmodelled), slews up
///     to [maxRateRadPerSec];
///   * RCS ([useRcs]) — consumes [monopropPerRadian] units of monopropellant per
///     radian turned; with no monoprop the vessel can't rotate.
///
/// Pure aside from mutating the vessel state and (for RCS) its monoprop store.
class AttitudeController {
  /// Maximum slew rate (rad/s).
  final double maxRateRadPerSec;

  /// When true, slewing consumes monopropellant instead of being free.
  final bool useRcs;

  /// Monopropellant units consumed per radian of rotation (RCS only).
  final double monopropPerRadian;

  const AttitudeController({
    this.maxRateRadPerSec = 0.5,
    this.useRcs = false,
    this.monopropPerRadian = 0,
  });

  void update(Vessel vessel, {required double dt}) {
    final target = vessel.targetFacing;
    if (target == null) return;

    final tgt = target.normalized;
    final forward = vessel.state.attitude.rotate(Vector3.unitZ);

    final dot = forward.dot(tgt).clamp(-1.0, 1.0);
    final angle = math.acos(dot);
    if (angle < 1e-4) return; // already aligned

    // Rotation axis = forward × target (perpendicular to both).
    var axis = forward.cross(tgt);
    if (axis.length < 1e-9) {
      // Anti-parallel: pick any perpendicular axis to start the flip.
      axis = forward.cross(Vector3.unitX);
      if (axis.length < 1e-9) axis = forward.cross(Vector3.unitY);
    }

    var step = math.min(angle, maxRateRadPerSec * dt);

    // RCS: gate the step by available monopropellant.
    if (useRcs && monopropPerRadian > 0) {
      final available = _monopropAvailable(vessel);
      final affordableRad = available / monopropPerRadian;
      if (affordableRad <= 0) return; // no propellant -> no rotation
      step = math.min(step, affordableRad);
      _drawMonoprop(vessel, step * monopropPerRadian);
    }

    final delta = Quaternion.axisAngle(axis, step);
    final newAttitude = (delta * vessel.state.attitude).normalized;
    vessel.updateState(vessel.state.copyWith(attitude: newAttitude));
  }

  double _monopropAvailable(Vessel vessel) {
    var total = 0.0;
    for (final p in vessel.allParts) {
      for (final c in p.resources) {
        if (c.type == ResourceType.monopropellant) total += c.amount;
      }
    }
    return total;
  }

  void _drawMonoprop(Vessel vessel, double units) {
    var remaining = units;
    for (final p in vessel.allParts) {
      if (remaining <= 0) break;
      for (final c in p.resources) {
        if (c.type != ResourceType.monopropellant) continue;
        remaining -= c.draw(remaining);
        if (remaining <= 0) break;
      }
    }
  }
}
