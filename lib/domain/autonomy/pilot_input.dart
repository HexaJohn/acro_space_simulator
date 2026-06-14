import '../shared/quaternion.dart';
import '../shared/vector3.dart';
import '../vessel/vessel.dart';

/// Manual flight-control inputs for a single tick.
///
/// Pure value object: a snapshot of what the pilot is commanding right now.
/// Rotation axes are normalized command magnitudes in `[-1, 1]`:
///   * [pitch] — nose up/down, about the body +X axis;
///   * [yaw]   — nose left/right, about the body +Y axis;
///   * [roll]  — bank, about the body +Z (forward) axis.
/// [throttle] is the engine command in `[0, 1]`. [action] is a momentary
/// trigger for stage/fire/use (the meaning is the caller's; here it's just
/// carried through).
class PilotInput {
  /// Pitch command, about body +X. `[-1, 1]`.
  final double pitch;

  /// Yaw command, about body +Y. `[-1, 1]`.
  final double yaw;

  /// Roll command, about body +Z (forward). `[-1, 1]`.
  final double roll;

  /// Throttle command. `[0, 1]`.
  final double throttle;

  /// Momentary action button (e.g. stage / fire). Carried, not interpreted.
  final bool action;

  const PilotInput({
    this.pitch = 0,
    this.yaw = 0,
    this.roll = 0,
    this.throttle = 0,
    this.action = false,
  });

  /// True when no control surface is being commanded (within [epsilon]).
  bool isNeutral({double epsilon = 1e-12}) =>
      pitch.abs() < epsilon &&
      yaw.abs() < epsilon &&
      roll.abs() < epsilon;

  PilotInput copyWith({
    double? pitch,
    double? yaw,
    double? roll,
    double? throttle,
    bool? action,
  }) =>
      PilotInput(
        pitch: pitch ?? this.pitch,
        yaw: yaw ?? this.yaw,
        roll: roll ?? this.roll,
        throttle: throttle ?? this.throttle,
        action: action ?? this.action,
      );

  @override
  bool operator ==(Object other) =>
      other is PilotInput &&
      other.pitch == pitch &&
      other.yaw == yaw &&
      other.roll == roll &&
      other.throttle == throttle &&
      other.action == action;

  @override
  int get hashCode => Object.hash(pitch, yaw, roll, throttle, action);

  @override
  String toString() =>
      'PilotInput(pitch: $pitch, yaw: $yaw, roll: $roll, '
      'throttle: $throttle, action: $action)';
}

/// Domain service that applies [PilotInput] to a [Vessel] for one tick.
///
/// Manual ("fly-by-wire") counterpart to the autopilot: it sets the throttle
/// and rotates the vessel's attitude directly about its body axes, with no
/// reference to a target facing. Pure aside from mutating the vessel.
class PilotController {
  /// Maximum rotation rate at full deflection (rad/s), per axis.
  final double maxRateRadPerSec;

  const PilotController({this.maxRateRadPerSec = 1.0});

  /// Apply [input] to [vessel] over [dt] seconds.
  ///
  /// Sets the throttle (the vessel clamps it to `[0, 1]`) and integrates the
  /// commanded body-rates into the attitude. Rotation is applied in the body
  /// frame, so the delta multiplies on the right of the current attitude and
  /// the result is re-normalized to stay a unit quaternion.
  void apply(Vessel vessel, PilotInput input, {required double dt}) {
    vessel.setThrottle(input.throttle);

    if (input.isNeutral()) return;

    // Body-frame angular step (rad) this tick, per axis.
    final omega = Vector3(
      input.pitch * maxRateRadPerSec, // about +X
      input.yaw * maxRateRadPerSec, // about +Y
      input.roll * maxRateRadPerSec, // about +Z
    );
    final angle = omega.length * dt;
    if (angle == 0) return;

    // Single rotation about the combined body axis composes pitch/yaw/roll.
    final delta = Quaternion.axisAngle(omega, angle);

    // Right-multiply: delta is expressed in the vessel's own body frame.
    final newAttitude = (vessel.state.attitude * delta).normalized;
    vessel.updateState(vessel.state.copyWith(attitude: newAttitude));
  }
}
