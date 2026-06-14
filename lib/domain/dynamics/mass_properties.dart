import '../shared/vector3.dart';

/// Rigid-body mass properties: total mass, centre of mass, and a (diagonal)
/// inertia tensor. Value object; parts aggregate into a vessel's properties.
///
/// The inertia tensor is kept diagonal (principal axes) for now — adequate for
/// gameplay and cheap to integrate. A full 3x3 tensor can replace it later.
class MassProperties {
  final double mass; // kg
  final Vector3 centerOfMass; // m, in vessel body frame
  final Vector3 inertia; // kg*m^2, diagonal (Ixx, Iyy, Izz)

  const MassProperties({
    required this.mass,
    required this.centerOfMass,
    required this.inertia,
  });

  static const MassProperties zero = MassProperties(
    mass: 0,
    centerOfMass: Vector3.zero,
    inertia: Vector3.zero,
  );

  /// Combine two bodies' mass properties (parallel-axis is approximated by
  /// summing inertias about the combined CoM offset — good enough at gameplay
  /// fidelity; refine if attitude control feels wrong).
  MassProperties operator +(MassProperties o) {
    final m = mass + o.mass;
    if (m == 0) return zero;
    final com = (centerOfMass * mass + o.centerOfMass * o.mass) / m;
    return MassProperties(
      mass: m,
      centerOfMass: com,
      inertia: inertia + o.inertia,
    );
  }

  /// Angular acceleration from a body-frame torque: alpha_i = tau_i / I_i.
  Vector3 angularAccel(Vector3 torque) => Vector3(
        inertia.x == 0 ? 0 : torque.x / inertia.x,
        inertia.y == 0 ? 0 : torque.y / inertia.y,
        inertia.z == 0 ? 0 : torque.z / inertia.z,
      );
}
