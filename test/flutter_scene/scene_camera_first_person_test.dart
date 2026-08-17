// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Cover for "walk mode renders from behind your own head": the scene adapter
// used to treat ANY eye within a metre of the focus as a degenerate ortho
// camera and synthesize an eye hundreds of metres back, which is exactly the
// case the on-foot camera (range 0, eye AT the anchor) lands in. The ortho
// fallback must still fire for the map camera.
import 'package:acro_space_simulator/adapters/presenters/camera_view.dart';
import 'package:acro_space_simulator/adapters/presenters/perspective_camera.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/coord_convert.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/scene_camera_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a range-0 perspective camera keeps its eye on the focus', () {
    const cam = PerspectiveCamera(
        azimuth: 0.7, elevation: 0.2, range: 0, near: 0.1, viewportH: 800);
    final scene = toSceneCamera(cam, viewportH: 800);

    expect(scene.position.length, 0,
        reason: 'the eye is the focus — no synthesized boom behind the head');
    // Looking down the camera's own forward axis, a kilometre out.
    final aim = relToScene(cam.forward * 1e3);
    expect(scene.target.x, closeTo(aim.x, 1e-9));
    expect(scene.target.y, closeTo(aim.y, 1e-9));
    expect(scene.target.z, closeTo(aim.z, 1e-9));
    expect(scene.target.length, greaterThan(0),
        reason: 'position == target would make the view matrix singular');
    // Near plane is the camera's own (0.1 m), so the ground 1.7 m below the
    // eye is comfortably inside the frustum.
    expect(scene.fovNear, closeTo(lengthToScene(0.1), 1e-12));
  });

  test('an orbit camera still looks at the focus from its range', () {
    const cam = PerspectiveCamera(
        azimuth: 0.7, elevation: 0.2, range: 500, near: 1.0, viewportH: 800);
    final scene = toSceneCamera(cam, viewportH: 800);
    expect(scene.target.length, 0);
    // Scene vectors are float32, so compare at single-precision tolerance.
    expect(scene.position.length, closeTo(lengthToScene(500), 1e-7));
  });

  test('the ortho map camera still gets its synthesized eye', () {
    const cam = OrthoCamera(CameraOrbit(azimuth: 0.3, elevation: 0.4), 25000);
    final scene = toSceneCamera(cam, viewportH: 800);
    expect(scene.target.length, 0);
    expect(scene.position.length, greaterThan(0),
        reason: 'ortho has no finite eye; one is synthesized to avoid a '
            'singular lookAt');
  });
}
