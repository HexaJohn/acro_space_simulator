// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'vector3.dart';

/// Unit quaternion for 3D orientation (Hamilton convention, w + xi + yj + zk).
///
/// Used for vessel attitude so we get singularity-free 6-DOF rotation. Keep
/// normalized; integration drift is corrected by [normalized].
class Quaternion {
  final double w;
  final double x;
  final double y;
  final double z;

  const Quaternion(this.w, this.x, this.y, this.z);

  static const Quaternion identity = Quaternion(1, 0, 0, 0);

  /// Rotation of [angle] radians about a (not necessarily unit) [axis].
  factory Quaternion.axisAngle(Vector3 axis, double angle) {
    final n = axis.normalized;
    final h = angle * 0.5;
    final s = math.sin(h);
    return Quaternion(math.cos(h), n.x * s, n.y * s, n.z * s);
  }

  /// Orientation from an orthonormal, right-handed basis: [xAxis]/[yAxis]/
  /// [zAxis] are where local +X/+Y/+Z end up. Shepperd's method on the rotation
  /// matrix R = [x|y|z]. Callers pass a frame they've already built (a craft's
  /// right/up/nose, a surface east/north/up) instead of chaining axis-angles.
  factory Quaternion.fromBasis(Vector3 xAxis, Vector3 yAxis, Vector3 zAxis) {
    final m00 = xAxis.x, m10 = xAxis.y, m20 = xAxis.z;
    final m01 = yAxis.x, m11 = yAxis.y, m21 = yAxis.z;
    final m02 = zAxis.x, m12 = zAxis.y, m22 = zAxis.z;
    final trace = m00 + m11 + m22;
    if (trace > 0) {
      final s = math.sqrt(trace + 1.0) * 2;
      return Quaternion(
              0.25 * s, (m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s)
          .normalized;
    } else if (m00 > m11 && m00 > m22) {
      final s = math.sqrt(1.0 + m00 - m11 - m22) * 2;
      return Quaternion(
              (m21 - m12) / s, 0.25 * s, (m01 + m10) / s, (m02 + m20) / s)
          .normalized;
    } else if (m11 > m22) {
      final s = math.sqrt(1.0 + m11 - m00 - m22) * 2;
      return Quaternion(
              (m02 - m20) / s, (m01 + m10) / s, 0.25 * s, (m12 + m21) / s)
          .normalized;
    } else {
      final s = math.sqrt(1.0 + m22 - m00 - m11) * 2;
      return Quaternion(
              (m10 - m01) / s, (m02 + m20) / s, (m12 + m21) / s, 0.25 * s)
          .normalized;
    }
  }

  Quaternion operator *(Quaternion q) => Quaternion(
        w * q.w - x * q.x - y * q.y - z * q.z,
        w * q.x + x * q.w + y * q.z - z * q.y,
        w * q.y - x * q.z + y * q.w + z * q.x,
        w * q.z + x * q.y - y * q.x + z * q.w,
      );

  Quaternion get conjugate => Quaternion(w, -x, -y, -z);

  double get lengthSquared => w * w + x * x + y * y + z * z;
  double get length => math.sqrt(lengthSquared);

  Quaternion get normalized {
    final l = length;
    if (l == 0) return identity;
    final inv = 1.0 / l;
    return Quaternion(w * inv, x * inv, y * inv, z * inv);
  }

  /// Rotate a vector by this orientation.
  Vector3 rotate(Vector3 v) {
    final qv = Vector3(x, y, z);
    final t = qv.cross(v) * 2.0;
    return v + t * w + qv.cross(t);
  }

  /// Quaternion derivative for angular velocity [omega] (rad/s, body frame).
  /// dq/dt = 0.5 * q * (0, omega). Used by integrators.
  Quaternion derivative(Vector3 omega) {
    final wq = Quaternion(0, omega.x, omega.y, omega.z);
    return (this * wq).scaled(0.5);
  }

  Quaternion operator +(Quaternion q) =>
      Quaternion(w + q.w, x + q.x, y + q.y, z + q.z);

  /// Component-wise scalar multiply (not a rotation — used by integrators).
  Quaternion scaled(double s) => Quaternion(w * s, x * s, y * s, z * s);

  @override
  String toString() => 'Quaternion($w, $x, $y, $z)';
}
