// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:acro_space_simulator/adapters/presenters/craft_editor_camera.dart';
import 'package:acro_space_simulator/domain/craft/craft_design.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/coord_convert.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/scene_camera_adapter.dart';

const Size kWide = Size(1280, 720);

CraftEditorCamera _cam({
  double azimuth = 0.9,
  double elevation = 0.28,
  double distanceM = 14.0,
  Vector3 pivot = Vector3.zero,
  Size viewport = kWide,
  double fovY = CraftEditorCamera.defaultFovY,
}) =>
    CraftEditorCamera(
      azimuth: azimuth,
      elevation: elevation,
      distanceM: distanceM,
      pivot: pivot,
      viewport: viewport,
      fovY: fovY,
    );

/// A spread of turntable poses wide enough that a sign error in any one basis
/// axis shows up somewhere: both hemispheres of elevation, azimuth in all four
/// quadrants, an inspection distance and a whole-stack distance, and an
/// off-origin pivot (the pan case, where pivot and eye no longer cancel).
List<CraftEditorCamera> _poses({Size viewport = kWide}) => [
      for (final az in const [0.0, 0.9, 2.4, -1.3])
        for (final el in const [-0.9, 0.0, 0.28, 1.2])
          for (final d in const [1.0, 14.0, 120.0])
            for (final pivot in const [
              Vector3.zero,
              Vector3(0.4, -1.2, 3.0),
            ])
              _cam(
                azimuth: az,
                elevation: el,
                distanceM: d,
                pivot: pivot,
                viewport: viewport,
              ),
    ];

/// Craft-frame sample points, pivot-relative offsets applied by the caller.
const List<Vector3> _offsets = [
  Vector3.zero,
  Vector3(1.0, 0, 0),
  Vector3(0, 1.0, 0),
  Vector3(0, 0, 1.0),
  Vector3(2.11, 0, 0.9),
  Vector3(-2.05, 1.45, -0.6),
  Vector3(0, 0, 4.2),
  Vector3(0, 0, -4.2),
  Vector3(5.0, -5.0, 5.0),
];

void main() {
  group('projection reuse', () {
    test('project() is PerspectiveCamera.projectPx, bit for bit', () {
      // The cached basis exists because each PerspectiveCamera basis getter
      // recomputes trig and project() runs once per marker per pointer move.
      // A cache that drifts from the class it caches is the worst kind of bug â€”
      // correct in the unit test of the original, wrong on screen. So this is
      // exact equality, not closeTo: any divergence at all is a failure.
      var checked = 0;
      for (final c in _poses()) {
        for (final o in _offsets) {
          final p = c.pivot + o;
          final r = c.domain.projectPx(p - c.pivot);
          final got = c.project(p);
          if (r == null) {
            expect(got, isNull,
                reason: 'near-plane cull must agree with the domain camera');
            continue;
          }
          expect(got, isNotNull);
          expect(got!.dx, equals(c.viewport.width / 2 + r.x));
          expect(got.dy, equals(c.viewport.height / 2 - r.y));
          checked++;
        }
      }
      expect(checked, greaterThan(500), reason: 'the grid must actually run');
    });

    test('depthOf and viewDirTo agree with the domain camera', () {
      for (final c in _poses()) {
        for (final o in _offsets) {
          final p = c.pivot + o;
          expect(c.depthOf(p), equals(c.domain.depth(p - c.pivot)));
          final d = c.viewDirTo(p);
          final dd = c.domain.viewDirTo(p - c.pivot);
          expect(d.x, equals(dd.x));
          expect(d.y, equals(dd.y));
          expect(d.z, equals(dd.z));
        }
      }
    });

    test('focalPx is the domain focal length', () {
      for (final c in _poses()) {
        expect(c.focalPx, equals(c.domain.focalPx));
        expect(c.pxPerMetreAt(c.distanceM),
            equals(c.focalPx / c.distanceM));
      }
    });
  });

  group('project / unproject round trip', () {
    test('project(rayThrough(o) at any depth) == o', () {
      // rayThrough is the exact algebraic inverse of project, so this holds
      // without an epsilon in real arithmetic; the tolerance is floating point
      // slack only. It is the single cheapest guard on the whole projection:
      // a sign error in ANY basis axis breaks it.
      final screenPoints = <Offset>[
        const Offset(640, 360), // centre
        const Offset(0, 0), // top-left corner
        const Offset(1280, 720), // bottom-right corner
        const Offset(1279, 1),
        const Offset(3, 700),
        const Offset(900, 120),
      ];
      var checked = 0;
      for (final c in _poses()) {
        for (final o in screenPoints) {
          final ray = c.rayThrough(o);
          final cosine = ray.dir.dot(c.forward);
          for (final k in const [1.2, 5.0, 40.0, 300.0]) {
            // Place the sample at a chosen VIEW DEPTH so it is always in front
            // of the near plane regardless of how far off-axis o is.
            final z = c.nearM * k;
            final t = z / cosine;
            final back = c.project(ray.origin + ray.dir * t);
            expect(back, isNotNull, reason: 'depth $z is in front of nearM');
            expect(back!.dx, closeTo(o.dx, 1e-6));
            expect(back.dy, closeTo(o.dy, 1e-6));
            checked++;
          }
        }
      }
      expect(checked, greaterThan(500));
    });

    test('rayThrough origin is the eye and points into the scene', () {
      for (final c in _poses()) {
        final ray = c.rayThrough(Offset(c.viewport.width / 2, c.viewport.height / 2));
        expect((ray.origin - (c.pivot + c.eyeRel)).length, closeTo(0, 1e-12));
        // Down the middle of the screen the ray IS the view axis.
        expect(ray.dir.dot(c.forward), closeTo(1.0, 1e-12));
      }
    });
  });

  group('chirality (R2 â€” a sign error here looks almost right)', () {
    test('at azimuth 0 a point on +X projects to the RIGHT of centre', () {
      // At azimuth 0 / elevation 0 the domain basis is forward +Y, right +X,
      // up +Z. Everything on a rocket is symmetric about its axis, so a
      // mirrored x is invisible on a bare stack and on a 4-way RCS ring; this
      // asymmetric case is where it shows.
      final c = _cam(azimuth: 0, elevation: 0, distanceM: 20, pivot: Vector3.zero);
      expect(c.forward.y, closeTo(1.0, 1e-12));
      expect(c.right.x, closeTo(1.0, 1e-12));
      expect(c.up.z, closeTo(1.0, 1e-12));

      final right = c.project(const Vector3(2.0, 0, 0))!;
      final left = c.project(const Vector3(-2.0, 0, 0))!;
      final above = c.project(const Vector3(0, 0, 2.0))!;
      final below = c.project(const Vector3(0, 0, -2.0))!;

      expect(right.dx, greaterThan(c.viewport.width / 2));
      expect(left.dx, lessThan(c.viewport.width / 2));
      // Flutter y grows DOWNWARD: a point above the pivot must have a smaller
      // dy, which is the half of the transform the image flip does not touch.
      expect(above.dy, lessThan(c.viewport.height / 2));
      expect(below.dy, greaterThan(c.viewport.height / 2));
    });

    test('matches the flipped flutter_scene image within 1.5 px', () {
      // The same assertion shape as the green coord_convert_test, at CRAFT
      // scale. Raw scene NDC -> px, then undo Transform.flip(flipX) with
      // x' = W - x_raw; the result must be project(). If a flutter_scene bump
      // ever changes _matrix4LookAt's handedness, this fails in CI instead of
      // in the player's mouse.
      var checked = 0;
      for (final c in _poses()) {
        final scene = c.sceneCameraVia(toSceneCamera);
        final vp = scene.getViewTransform(c.viewport);
        for (final o in _offsets) {
          final p = c.pivot + o;
          final got = c.project(p);
          if (got == null) continue;
          final s = relToScene(p - c.pivot);
          final clip = vp.transformed(vm.Vector4(s.x, s.y, s.z, 1.0));
          if (clip.w <= 0) continue;
          final ndcX = clip.x / clip.w, ndcY = clip.y / clip.w;
          final rawX = c.viewport.width / 2 + ndcX * c.viewport.width / 2;
          final flippedX = c.viewport.width - rawX;
          final screenY = c.viewport.height / 2 - ndcY * c.viewport.height / 2;
          expect(got.dx, closeTo(flippedX, 1.5), reason: 'x at $p from $c');
          expect(got.dy, closeTo(screenY, 1.5), reason: 'y at $p from $c');
          checked++;
        }
      }
      expect(checked, greaterThan(300));
    });

    test('rayThrough matches Camera.screenPointToRay through the flip', () {
      // V16 cross-check against flutter_scene's own unprojection. The screen
      // point must be un-flipped first (x_raw = W - x_screen) because
      // screenPointToRay works in the RAW render's coordinates, upstream of
      // Transform.flip.
      //
      // FAR PLANE OVERRIDE, and it is not cosmetic. In production toSceneCamera
      // sets fovFar = 5e9 scene-km against a fovNear of 7e-4 â€” a 7.1e12 : 1
      // frustum. Matrix4 stores float32, so zFar/(zFar-zNear) = 1 + 1.4e-13
      // rounds to EXACTLY 1.0, the far-plane unprojection inside
      // screenPointToRay divides by w == 0, and it returns
      // `direction = [Infinity, Infinity, -Infinity]` (measured, not inferred).
      // flutter_scene's ray/raycast API is therefore unusable at the depth
      // range this app actually renders at â€” one more reason the editor keeps
      // raycasting off the critical path and picks by projection instead. The
      // override restores a sane ratio so the CHIRALITY claim, which is what
      // this test is for, can still be cross-checked against their unprojection.
      SceneCameraDebug.farOverrideM = 2000.0;
      addTearDown(() => SceneCameraDebug.farOverrideM = null);

      final screenPoints = <Offset>[
        const Offset(640, 360),
        const Offset(180, 90),
        const Offset(1100, 640),
        const Offset(20, 700),
      ];
      var worst = 0.0;
      var checked = 0;
      for (final c in _poses()) {
        final scene = c.sceneCameraVia(toSceneCamera);
        for (final o in screenPoints) {
          final mine = c.rayThrough(o).dir;
          final raw = Offset(c.viewport.width - o.dx, o.dy);
          final theirs = scene.screenPointToRay(raw, c.viewport).direction
              .normalized();
          final d = math.sqrt(math.pow(mine.x - theirs.x, 2) +
              math.pow(mine.y - theirs.y, 2) +
              math.pow(mine.z - theirs.z, 2));
          worst = math.max(worst, d);
          checked++;
        }
      }
      expect(checked, greaterThan(300));
      // float32 Matrix4 storage plus a copyInverse of a 3e6:1 far/near frustum;
      // a handedness change would be O(1), not O(1e-3).
      expect(worst, lessThan(2e-3), reason: 'worst direction error $worst');
    });
  });

  group('one focal length serves both axes (V4)', () {
    test('widening the viewport does not move a point relative to centre', () {
      // The classic wide-viewport picking-drift bug: deriving a separate
      // horizontal focal length from the aspect ratio leaves picking exact on a
      // square viewport and drifting on a wide one. flutter_scene's
      // _matrix4Perspective puts the aspect in [0][0] where it cancels against
      // W/2, so ONE focal length is correct for both axes.
      const p = Vector3(2.0, 0.5, 3.0);
      final square = _cam(viewport: const Size(720, 720));
      final wide = _cam(viewport: const Size(1920, 720));
      final narrow = _cam(viewport: const Size(320, 720));

      final a = square.project(p)!;
      final b = wide.project(p)!;
      final c = narrow.project(p)!;
      expect(b.dx - 1920 / 2, closeTo(a.dx - 720 / 2, 1e-12));
      expect(c.dx - 320 / 2, closeTo(a.dx - 720 / 2, 1e-12));
      expect(b.dy, closeTo(a.dy, 1e-12));
      expect(c.dy, closeTo(a.dy, 1e-12));
      expect(square.focalPx, equals(wide.focalPx));
    });

    test('agrees with flutter_scene on a portrait viewport too', () {
      // The same 1.5 px assertion at aspect 0.44, where a horizontal focal
      // length derived from the aspect would be off by more than a factor of
      // two and would still pass every square-viewport test.
      for (final c in _poses(viewport: const Size(400, 900))) {
        final vp = c.sceneCameraVia(toSceneCamera).getViewTransform(c.viewport);
        for (final o in _offsets) {
          final p = c.pivot + o;
          final got = c.project(p);
          if (got == null) continue;
          final s = relToScene(p - c.pivot);
          final clip = vp.transformed(vm.Vector4(s.x, s.y, s.z, 1.0));
          if (clip.w <= 0) continue;
          final flippedX =
              c.viewport.width / 2 - (clip.x / clip.w) * c.viewport.width / 2;
          final screenY =
              c.viewport.height / 2 - (clip.y / clip.w) * c.viewport.height / 2;
          expect(got.dx, closeTo(flippedX, 1.5));
          expect(got.dy, closeTo(screenY, 1.5));
        }
      }
    });
  });

  group('clamps and the near plane', () {
    test('distance never drops below the ortho fallback threshold (V7)', () {
      // toSceneCamera switches to a synthesised ortho-equivalent eye below
      // 1 m of eye offset, which would silently move the camera somewhere else
      // entirely at exactly the zoom a craft inspection wants.
      for (final d in const [-5.0, 0.0, 0.01, 0.999, 1.0, 400.0, 1e6]) {
        final c = _cam(distanceM: d);
        expect(c.distanceM, greaterThanOrEqualTo(CraftEditorCamera.minDistanceM));
        expect(c.distanceM, lessThanOrEqualTo(CraftEditorCamera.maxDistanceM));
        expect(c.eyeRel.length, greaterThanOrEqualTo(1.0));
        // And the adapter must consequently NOT take the ortho path: the eye it
        // publishes is the pose's own eye.
        final scene = c.sceneCameraVia(toSceneCamera);
        final expected = relToScene(c.eyeRel);
        expect(scene.position.x, closeTo(expected.x, 1e-9));
        expect(scene.position.y, closeTo(expected.y, 1e-9));
        expect(scene.position.z, closeTo(expected.z, 1e-9));
      }
      expect(_cam(distanceM: 0.5).distanceM,
          equals(CraftEditorCamera.minDistanceM));
      // The floor must sit ABOVE the adapter's threshold, not on it: at exactly
      // 1.0 the |eyeOffset| comparison lands on the wrong side of the cliff for
      // some poses because `forward` is unit only to within an ulp.
      expect(CraftEditorCamera.minDistanceM, greaterThan(1.0));
    });

    test('elevation is clamped short of the pole', () {
      expect(_cam(elevation: 3.0).elevation,
          closeTo(CraftEditorCamera.maxElevationRad, 1e-12));
      expect(_cam(elevation: -3.0).elevation,
          closeTo(-CraftEditorCamera.maxElevationRad, 1e-12));
    });

    test('nearM is exactly the adapter adaptive near, so both clips agree', () {
      // If projectPx culls at a different depth from the GPU, the overlay draws
      // markers on geometry the renderer has already clipped away.
      for (final c in _poses()) {
        expect(c.nearM, equals(math.max(0.05, c.distanceM / 20.0)));
        expect(c.sceneCameraVia(toSceneCamera).fovNear, closeTo(lengthToScene(c.nearM), 1e-12));
        expect(c.domain.near, equals(c.nearM));
      }
    });

    test('a point at or behind the near plane does not project', () {
      final c = _cam(distanceM: 20); // nearM == 1.0 m
      final justBehind = c.eyeC + c.forward * (c.nearM * 0.5);
      final justInFront = c.eyeC + c.forward * (c.nearM * 2.0);
      expect(c.project(justBehind), isNull);
      expect(c.project(justInFront), isNotNull);
      expect(c.project(c.eyeC), isNull);
    });
  });

  group('copyWith, pan and framing', () {
    test('copyWith carries the untouched fields and re-applies the clamps', () {
      final c = _cam(azimuth: 0.3, elevation: 0.2, distanceM: 30);
      final d = c.copyWith(azimuth: 1.1, distanceM: 0.2);
      expect(d.azimuth, 1.1);
      expect(d.elevation, c.elevation);
      expect(d.distanceM, CraftEditorCamera.minDistanceM);
      expect(d.pivot, c.pivot);
      expect(d.viewport, c.viewport);
      expect(d.fovY, c.fovY);
    });

    test('pan moves the world with the cursor at pivot depth', () {
      final c = _cam(distanceM: 20, pivot: Vector3.zero);
      // A point sitting at the pivot projects to the screen centre; after a
      // 100 px pan it must sit 100 px from centre in the same direction the
      // drag went, or the world slides the wrong way under the finger.
      const drag = Offset(100, -40);
      final p = c.panned(drag);
      final before = c.project(Vector3.zero)!;
      final after = p.project(Vector3.zero)!;
      expect(after.dx - before.dx, closeTo(drag.dx, 1e-6));
      expect(after.dy - before.dy, closeTo(drag.dy, 1e-6));
      // Only the pivot moved.
      expect(p.azimuth, c.azimuth);
      expect(p.distanceM, c.distanceM);
    });

    test('framing puts the whole craft on screen with margin', () {
      final design = CraftDesign(name: 'framing');
      design.addPart(def: _box('a', const Vector3(4.2, 4.2, 3.0)), instanceId: 'a');
      design.addPart(
          def: _box('b', const Vector3(4.2, 4.2, 3.2)),
          instanceId: 'b',
          position: const Vector3(0, 0, -3.1));
      final c = CraftEditorCamera.framing(design, kWide);

      var minX = double.infinity, maxX = -double.infinity;
      var minY = double.infinity, maxY = -double.infinity;
      for (final p in design.parts) {
        final h = p.def.size * 0.5;
        for (final sx in const [-1.0, 1.0]) {
          for (final sy in const [-1.0, 1.0]) {
            for (final sz in const [-1.0, 1.0]) {
              final s = c.project(
                  p.position + Vector3(sx * h.x, sy * h.y, sz * h.z))!;
              minX = math.min(minX, s.dx);
              maxX = math.max(maxX, s.dx);
              minY = math.min(minY, s.dy);
              maxY = math.max(maxY, s.dy);
            }
          }
        }
      }
      expect(minX, greaterThan(0));
      expect(maxX, lessThan(kWide.width));
      expect(minY, greaterThan(0));
      expect(maxY, lessThan(kWide.height));
      // ...and actually fills the frame rather than framing a dot.
      expect(maxY - minY, greaterThan(kWide.height * 0.5));
      // R1: never start looking down the stack axis, where a 4-node ring
      // collapses to a few pixels.
      expect(c.elevation.abs(), greaterThan(0.05));
    });

    test('framing an empty design is still a usable pose', () {
      final c = CraftEditorCamera.framing(CraftDesign(name: 'empty'), kWide);
      expect(c.distanceM, greaterThanOrEqualTo(CraftEditorCamera.minDistanceM));
      expect(c.pivot, Vector3.zero);
      expect(c.project(Vector3.zero), isNotNull);
    });

    test('framing fits horizontally on a portrait viewport', () {
      // A vertical-only fit crops a wide craft when the horizontal half-angle
      // is the tighter of the two.
      final design = CraftDesign(name: 'wide');
      design.addPart(
          def: _box('w', const Vector3(9.0, 9.0, 1.0)), instanceId: 'w');
      final c = CraftEditorCamera.framing(design, const Size(400, 900),
          azimuth: 0, elevation: 0.1);
      for (final sx in const [-1.0, 1.0]) {
        for (final sy in const [-1.0, 1.0]) {
          final s = c.project(Vector3(sx * 4.5, sy * 4.5, 0.5))!;
          expect(s.dx, inInclusiveRange(0, 400));
        }
      }
    });
  });
}

PartDef _box(String id, Vector3 size) => PartDef(
      id: id,
      name: id,
      category: PartCategory.structural,
      dryMass: 100,
      size: size,
      modelRotation: Quaternion.identity,
    );
