// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

import '../shared/quaternion.dart';
import '../shared/vector3.dart';

/// Full 6-DOF kinematic state of a rigid body, expressed in the inertial frame
/// of its dominant celestial body (so magnitudes stay small).
///
/// Value object. [position]/[velocity] are translational; [attitude]/
/// [angularVelocity] are rotational. Integrators map an old state + forces to a
/// new state; the orbit is just an alternative (analytic) representation of the
/// translational part.
class StateVector {
  final Vector3 position; // m, body-centred inertial
  final Vector3 velocity; // m/s
  final Quaternion attitude; // body orientation
  final Vector3 angularVelocity; // rad/s, body frame

  const StateVector({
    required this.position,
    required this.velocity,
    this.attitude = Quaternion.identity,
    this.angularVelocity = Vector3.zero,
  });

  StateVector copyWith({
    Vector3? position,
    Vector3? velocity,
    Quaternion? attitude,
    Vector3? angularVelocity,
  }) =>
      StateVector(
        position: position ?? this.position,
        velocity: velocity ?? this.velocity,
        attitude: attitude ?? this.attitude,
        angularVelocity: angularVelocity ?? this.angularVelocity,
      );

  @override
  String toString() =>
      'StateVector(pos:$position vel:$velocity |v|:${velocity.length.toStringAsFixed(1)})';
}
