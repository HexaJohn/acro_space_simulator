import 'dart:math' as math;

import 'package:acro_space_simulator/domain/autonomy/pilot_input.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const controller = PilotController();

  Vessel vessel() => Vessel(
        id: const VesselId('a'),
        name: 'A',
        ownerId: 'p',
        state: const StateVector(
          position: Vector3(700000, 0, 0),
          velocity: Vector3.zero,
          attitude: Quaternion.identity, // forward = +Z
        ),
        dominantBody: const BodyId('earth'),
        stages: const [],
      );

  test('throttle from input is applied to the vessel (clamped)', () {
    final v = vessel();
    controller.apply(v, const PilotInput(throttle: 0.6), dt: 0.1);
    expect(v.throttle, closeTo(0.6, 1e-9));

    controller.apply(v, const PilotInput(throttle: 5.0), dt: 0.1);
    expect(v.throttle, 1.0); // vessel clamps to [0,1]
  });

  test('zero input leaves attitude unchanged', () {
    final v = vessel();
    final q0 = v.state.attitude;
    controller.apply(v, const PilotInput(), dt: 0.1);
    expect(v.state.attitude.w, q0.w);
    expect(v.state.attitude.x, q0.x);
    expect(v.state.attitude.y, q0.y);
    expect(v.state.attitude.z, q0.z);
  });

  test('positive pitch rotates the nose (forward axis tilts)', () {
    final v = vessel();
    // Start facing +Z; positive pitch about body X should tilt the nose.
    for (var i = 0; i < 10; i++) {
      controller.apply(v, const PilotInput(pitch: 1.0), dt: 0.05);
    }
    final forward = v.state.attitude.rotate(Vector3.unitZ);
    // No longer purely +Z: it acquired a component off the Z axis.
    expect(forward.dot(Vector3.unitZ), lessThan(0.9999));
    // Pitch about +X rotates +Z toward -Y (right-hand rule).
    expect(forward.y, lessThan(0.0));
  });

  test('combined inputs compose into a rotation', () {
    final v = vessel();
    controller.apply(
      v,
      const PilotInput(pitch: 1.0, yaw: 1.0, roll: 1.0),
      dt: 0.1,
    );
    // Attitude moved away from identity.
    final q = v.state.attitude;
    final movedFromIdentity = (q.w - 1.0).abs() +
        q.x.abs() +
        q.y.abs() +
        q.z.abs();
    expect(movedFromIdentity, greaterThan(1e-3));
  });

  test('attitude stays unit-length after many steps', () {
    final v = vessel();
    for (var i = 0; i < 500; i++) {
      controller.apply(
        v,
        PilotInput(
          pitch: math.sin(i * 0.3),
          yaw: math.cos(i * 0.2),
          roll: math.sin(i * 0.1),
        ),
        dt: 0.1,
      );
    }
    expect(v.state.attitude.length, closeTo(1.0, 1e-9));
  });

  test('PilotInput is an immutable value object with equality', () {
    const a = PilotInput(pitch: 0.5, yaw: -0.5, roll: 0.1, throttle: 0.3);
    const b = PilotInput(pitch: 0.5, yaw: -0.5, roll: 0.1, throttle: 0.3);
    expect(a, equals(b));
    expect(a.hashCode, b.hashCode);
    expect(a.action, isFalse);
  });
}
