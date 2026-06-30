import 'package:acro_space_simulator/domain/autonomy/attitude_controller.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const controller = AttitudeController();

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

  test('vessel rotates its forward axis toward the commanded facing', () {
    final v = vessel()..targetFacing = Vector3.unitX; // want to face +X
    final before = v.state.attitude.rotate(Vector3.unitZ).dot(Vector3.unitX);

    for (var i = 0; i < 400; i++) {
      controller.update(v, dt: 0.1);
    }

    final after = v.state.attitude.rotate(Vector3.unitX.normalized);
    final alignment = v.state.attitude.rotate(Vector3.unitZ).dot(Vector3.unitX);
    expect(alignment, greaterThan(before));
    expect(alignment, greaterThan(0.9)); // nearly aligned
    expect(after.length, closeTo(1.0, 1e-6)); // attitude stays unit
  });

  test('no target facing leaves attitude unchanged', () {
    final v = vessel();
    final q0 = v.state.attitude;
    controller.update(v, dt: 0.1);
    expect(v.state.attitude.w, q0.w);
    expect(v.state.attitude.x, q0.x);
  });

  test('already aligned vessel stays put (no overshoot wobble)', () {
    final v = vessel()..targetFacing = Vector3.unitZ; // already facing +Z
    for (var i = 0; i < 50; i++) {
      controller.update(v, dt: 0.1);
    }
    final alignment = v.state.attitude.rotate(Vector3.unitZ).dot(Vector3.unitZ);
    expect(alignment, greaterThan(0.999));
  });
}
