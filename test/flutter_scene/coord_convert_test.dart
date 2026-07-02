import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:acro_space_simulator/adapters/presenters/camera_view.dart';
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
      // only the argument order differs; the chirality mirror lives at the
      // image level, not in the frame). Compare through the MATRIX path:
      // that is what flutter_scene node transforms use (Matrix4.compose).
      // vm.Quaternion.rotate() is NOT equivalent — it applies the inverse
      // rotation (vector_math quirk).
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

      // Recovered forward matches the domain forward (same frame).
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

    test('screen chirality matches the software projection after the '
        'image flip', () {
      // THE mirror-image regression test. The domain basis satisfies
      // right x up = -forward while fs lookAt derives right = up x forward:
      // the RAW flutter_scene render is horizontally mirrored, and
      // SceneRenderView corrects it with a final Transform.flip(flipX).
      // So a point to the camera's RIGHT must land at NEGATIVE raw NDC x
      // (the flip then puts it on the right half of the screen, matching
      // the software renderer); vertical must match WITHOUT flipping.
      const cam = PerspectiveCamera(
        azimuth: 0.7,
        elevation: 0.3,
        roll: 0.0,
        range: 2.0e7,
        viewportH: 800,
      );
      const d = 5.0e6; // m, well inside the view
      final domainRight = cam.right * d;
      final domainUp = cam.up * d;

      // Software backend: projectPx x+ is screen right, y+ is screen up.
      expect(cam.projectPx(domainRight)!.x, greaterThan(0));
      expect(cam.projectPx(domainUp)!.y, greaterThan(0));

      // flutter_scene: full view transform to raw NDC (pre image flip).
      final scene = toSceneCamera(cam, viewportH: 800);
      final vp = scene.getViewTransform(const Size(1280, 720));
      vm.Vector4 ndc(Vector3 rel) {
        final p = relToScene(rel);
        final clip = vp.transformed(vm.Vector4(p.x, p.y, p.z, 1.0));
        return clip / clip.w;
      }

      expect(ndc(domainRight).x, lessThan(0),
          reason: 'raw render is mirrored; Transform.flip(flipX) in '
              'SceneRenderView puts this on screen-right');
      expect(ndc(domainUp).y, greaterThan(0),
          reason: 'vertical is NOT mirrored — a point above the focus '
              'renders above centre before and after the flip');
    });

    test('projection scale matches the software projectPx (label overlay '
        'alignment)', () {
      // The HUD overlay places labels with the SOFTWARE projection while
      // bodies render through the flutter_scene projection: any scale
      // mismatch makes labels drift from their bodies, growing with
      // distance from the screen centre (field report: the Moon's label
      // floats far from it when viewed from other bodies).
      const w = 1280.0, h = 720.0;
      const cam = PerspectiveCamera(
        azimuth: 0.4,
        elevation: 0.2,
        range: 2.0e7,
        viewportH: h,
      );
      final scene = toSceneCamera(cam, viewportH: h);
      final vp = scene.getViewTransform(const Size(w, h));

      for (final rel in [
        cam.right * 3.0e6 + cam.up * 1.0e6,
        cam.right * -8.0e6 + cam.up * 4.0e6, // far off-centre
        cam.up * -6.0e6,
      ]) {
        final sw = cam.projectPx(rel)!;
        final p = relToScene(rel);
        final clip = vp.transformed(vm.Vector4(p.x, p.y, p.z, 1.0));
        final ndcX = clip.x / clip.w, ndcY = clip.y / clip.w;
        // Raw scene px (centre-origin, y up), then undo the image flipX.
        final fsX = -(ndcX * w / 2);
        final fsY = ndcY * h / 2;
        expect(fsX, closeTo(sw.x, 1.5),
            reason: 'horizontal projection scale mismatch at $rel');
        expect(fsY, closeTo(sw.y, 1.5),
            reason: 'vertical projection scale mismatch at $rel');
      }
    });

    test('ortho camera gets a finite synthetic eye (no singular lookAt)', () {
      // OrthoCamera.eyeOffset is ZERO (parallel rays). Feeding that through
      // lookAt made position == target -> singular view matrix ->
      // "Matrix cannot be inverted" downstream (polyline expansion) when
      // switching to the map view. The adapter must synthesize an eye at
      // the perspective-equivalent distance instead.
      const ortho = OrthoCamera(CameraOrbit.top, 25000 /* m per px */);
      final scene = toSceneCamera(ortho, viewportH: 800);

      final eyeDistance = (scene.position - scene.target).length;
      expect(eyeDistance, greaterThan(0.0));

      // Perspective scale matches the ortho scale at the focus:
      // d = focal_px * mpp (in scene km here).
      final focalPx = (800 / 2) / math.tan(scene.fovRadiansY / 2);
      expect(eyeDistance, closeTo(focalPx * 25000 * 1e-3, 1.0));

      // The full view transform must be invertible (what the polyline
      // screen-space expansion does every frame).
      final vp = scene.getViewTransform(const Size(1280, 720));
      expect(vp.determinant().abs(), greaterThan(1e-20));
      // Throws if singular:
      vm.Matrix4.inverted(vp);
    });
  });
}
