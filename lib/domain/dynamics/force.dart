import '../shared/vector3.dart';

/// Net generalized force on a rigid body for one integration step: a linear
/// [force] (N, inertial frame) and a [torque] (N*m, body frame). Value object
/// produced by force contributors and summed by the [ForceModel].
class GeneralizedForce {
  final Vector3 force; // N, inertial
  final Vector3 torque; // N*m, body frame

  const GeneralizedForce(this.force, this.torque);

  static const GeneralizedForce zero =
      GeneralizedForce(Vector3.zero, Vector3.zero);

  GeneralizedForce operator +(GeneralizedForce o) =>
      GeneralizedForce(force + o.force, torque + o.torque);
}
