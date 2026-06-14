import 'dart:math' as math;

/// Immutable 3D vector. Right-handed frame, Z is "up" by project convention.
///
/// Pure value object: no identity, no mutation. All physics math in the domain
/// operates on these in a *local* (small-magnitude) frame to avoid floating
/// point precision loss; absolute world positions use [PreciseVector3].
class Vector3 {
  final double x;
  final double y;
  final double z;

  const Vector3(this.x, this.y, this.z);

  static const Vector3 zero = Vector3(0, 0, 0);
  static const Vector3 unitX = Vector3(1, 0, 0);
  static const Vector3 unitY = Vector3(0, 1, 0);
  static const Vector3 unitZ = Vector3(0, 0, 1);

  Vector3 operator +(Vector3 o) => Vector3(x + o.x, y + o.y, z + o.z);
  Vector3 operator -(Vector3 o) => Vector3(x - o.x, y - o.y, z - o.z);
  Vector3 operator -() => Vector3(-x, -y, -z);
  Vector3 operator *(double s) => Vector3(x * s, y * s, z * s);
  Vector3 operator /(double s) => Vector3(x / s, y / s, z / s);

  double dot(Vector3 o) => x * o.x + y * o.y + z * o.z;

  Vector3 cross(Vector3 o) => Vector3(
        y * o.z - z * o.y,
        z * o.x - x * o.z,
        x * o.y - y * o.x,
      );

  double get lengthSquared => x * x + y * y + z * z;
  double get length => math.sqrt(lengthSquared);

  Vector3 get normalized {
    final l = length;
    return l == 0 ? zero : this * (1.0 / l);
  }

  /// Linear interpolation; [t] is not clamped.
  Vector3 lerp(Vector3 o, double t) => this + (o - this) * t;

  double distanceTo(Vector3 o) => (this - o).length;

  @override
  bool operator ==(Object other) =>
      other is Vector3 && other.x == x && other.y == y && other.z == z;

  @override
  int get hashCode => Object.hash(x, y, z);

  @override
  String toString() =>
      'Vector3(${x.toStringAsFixed(3)}, ${y.toStringAsFixed(3)}, ${z.toStringAsFixed(3)})';
}
