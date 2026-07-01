import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:acro_space_simulator/adapters/presenters/perspective_camera.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/coord_convert.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/scene_camera_adapter.dart';

void main() {
  group('floating origin precision at planetary distance', () {
    test('1 m separation survives rebase at 1.5e8 m from system root', () {
      // Two points 1 m apart, ~Earth's distance from the sun. A naive
      // float32 cast of the ABSOLUTE positions quantises to ~16 m steps and
      // the separation vanishes; the rebase must preserve it exactly.
      const a = Vector3(1.5e8 * 1000, 2.7e7 * 1000, -4.2e6 * 1000);
      final b = a + const Vector3(1.0, 0.0, 0.0);

      // Proof the naive path really loses it (guards the test's premise).
      final naiveA = vm.Vector3(a.x, a.y, a.z); // float32 storage
      final naiveB = vm.Vector3(b.x, b.y, b.z);
      expect(naiveB.x - naiveA.x, isNot(closeTo(1.0, 0.5)),
          reason: 'premise: float32 absolute positions cannot hold 1 m '
              'at 1.5e11 m — if this starts passing, raise the distance');

      final origin = FloatingOrigin()..focusWorld = a;
      final sceneA = origin.worldToScene(a);
      final sceneB = origin.worldToScene(b);
      // 1 m == 1e-3 scene units (km).
      expect(sceneA.x, 0.0);
      expect(sceneB.x - sceneA.x, closeTo(1e-3, 1e-9));
      expect(sceneB.y - sceneA.y, 0.0);
    });

    test('worldToScene maps a body offset to km', () {
      final origin = FloatingOrigin()
        ..focusWorld = const Vector3(1.5e11, 0, 0);
      final scene =
          origin.worldToScene(const Vector3(1.5e11 + 7.0e6, 0, 0));
      expect(scene.x, closeTo(7000.0, 1e-2)); // 7,000 km
    });
  });

  group('quaternion conversion', () {
    test('round-trips and preserves rotation action', () {
      final q = Quaternion.axisAngle(const Vector3(1, 2, 3), 0.73);
      final back = sceneToQuat(quatToScene(q));
      expect(back.w, closeTo(q.w, 1e-6));
      expect(back.x, closeTo(q.x, 1e-6));

      // Same rotation in both math libraries (same axes, same handedness —
      // only the argument order differs). Compare through the MATRIX path:
      // that is what flutter_scene node transforms use (Matrix4.compose).
      // vm.Quaternion.rotate() is NOT equivalent — it applies the inverse
      // rotation (long-standing vector_math convention quirk); never use it.
      const v = Vector3(0.3, -1.1, 2.0);
      final domainRotated = q.rotate(v);
      final sceneRotated =
          quatToScene(q).asRotationMatrix() * vm.Vector3(v.x, v.y, v.z)
              as vm.Vector3;
      expect(sceneRotated.x, closeTo(domainRotated.x, 1e-5));
      expect(sceneRotated.y, closeTo(domainRotated.y, 1e-5));
      expect(sceneRotated.z, closeTo(domainRotated.z, 1e-5));
    });
  });

  group('camera adapter', () {
    test('eye, target, and up reproduce the domain camera basis', () {
      const cam = PerspectiveCamera(
        azimuth: 0.7,
        elevation: 0.4,
        roll: 0.2,
        range: 2.0e7,
        viewportH: 800,
      );
      final scene = toSceneCamera(cam);

      // Looks at the focus (scene origin).
      expect(scene.target.length, closeTo(0.0, 1e-6));

      // Eye sits range metres back along -forward (in km).
      final eye = scene.position;
      final expectedEye = relToScene(cam.eyeOffset);
      expect(eye.x, closeTo(expectedEye.x, 1e-3));
      expect(eye.y, closeTo(expectedEye.y, 1e-3));
      expect(eye.z, closeTo(expectedEye.z, 1e-3));

      // Recovered forward matches the domain forward (unit, both frames).
      final fwd = (scene.target - scene.position).normalized();
      expect(fwd.x, closeTo(cam.forward.x, 1e-5));
      expect(fwd.y, closeTo(cam.forward.y, 1e-5));
      expect(fwd.z, closeTo(cam.forward.z, 1e-5));

      // Up carries the roll.
      final up = scene.up.normalized();
      expect(up.x, closeTo(cam.up.x, 1e-5));
      expect(up.y, closeTo(cam.up.y, 1e-5));
      expect(up.z, closeTo(cam.up.z, 1e-5));
    });
  });
}
