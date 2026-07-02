/// Domain ↔ flutter_scene value conversions.
///
/// The scene graph KEEPS the domain frame: right-handed, +Z up, exactly as
/// documented in `wire/sim.fbs`. flutter_scene's camera takes an arbitrary
/// `up` vector, so no axis remap is needed anywhere — unlike the Unreal
/// ingest, which must flip handedness. Procedural meshes (parts, lines) are
/// authored Z-up so they need no correction either. Only two representation
/// gaps remain, and both live here:
///
///  1. PRECISION. Domain positions are doubles in metres (bodies sit ~1e8 m
///     or more from the system root); vector_math stores float32. Casting an
///     absolute position would quantise to ~10 m steps. So positions MUST be
///     rebased to the floating origin (the camera focus — see
///     [FloatingOrigin]) while still in doubles, and only then cast.
///  2. SCALE. The scene renders in KILOMETRES ([kRenderScale]) so float32
///     comfortably spans a whole SOI after the rebase.
///
/// Quaternions: domain is Hamilton scalar-FIRST (w,x,y,z); vector_math is
/// scalar-LAST (x,y,z,w). Same handedness, same axes — argument order only.
library;

import 'package:vector_math/vector_math.dart' as vm;

import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';

/// Metres → scene units (kilometres). Applied after the double-precision
/// rebase, before the float32 cast.
const double kRenderScale = 1e-3;

/// A focus-relative position (already rebased, metres, still doubles) → scene
/// units. The input must be SMALL (relative to the floating origin); asserts
/// guard against absolute world positions sneaking through and silently
/// losing precision in the cast.
vm.Vector3 relToScene(Vector3 rel) {
  // Focus-relative positions are legitimately up to ~1e13 m (an outer
  // planet's orbit ring viewed from the inner system). The guard exists to
  // catch UNREBASED absolutes and double-scaling bugs, which overshoot this
  // by orders of magnitude.
  assert(
    rel.x.abs() < 1e14 && rel.y.abs() < 1e14 && rel.z.abs() < 1e14,
    'relToScene() expects a focus-relative position, got $rel — '
    'rebase against the FloatingOrigin first.',
  );
  return vm.Vector3(
    rel.x * kRenderScale,
    rel.y * kRenderScale,
    rel.z * kRenderScale,
  );
}

/// Scene units → focus-relative metres (doubles). Inverse of [relToScene]
/// modulo the float32 round-trip.
Vector3 sceneToRel(vm.Vector3 scene) => Vector3(
      scene.x / kRenderScale,
      scene.y / kRenderScale,
      scene.z / kRenderScale,
    );

/// A length in metres → scene units (for radii, ranges, near/far planes).
double lengthToScene(double metres) => metres * kRenderScale;

/// Domain quaternion (Hamilton, scalar-first w,x,y,z) → vector_math
/// (scalar-last x,y,z,w). No axis change: the scene keeps the domain frame.
///
/// TRAP: `vm.Quaternion.rotate()` applies the INVERSE rotation (vector_math
/// convention quirk) — the matrix path (`asRotationMatrix`, Matrix4.compose,
/// i.e. everything flutter_scene node transforms use) is standard Hamilton
/// and matches the domain `Quaternion.rotate`. Never call vm rotate().
vm.Quaternion quatToScene(Quaternion q) => vm.Quaternion(q.x, q.y, q.z, q.w);

/// vector_math quaternion → domain. Inverse of [quatToScene].
Quaternion sceneToQuat(vm.Quaternion q) => Quaternion(q.w, q.x, q.y, q.z);

/// Tracks the double-precision world position of the render origin (the
/// camera focus) and rebases absolute world positions against it.
///
/// This is the floating-origin scheme: every node transform handed to
/// flutter_scene is `world - focus`, computed in doubles, THEN scaled and
/// cast to float32. The focus follows the camera target each frame, so
/// geometry near the camera always has small coordinates — the same
/// convention `PerspectiveCamera.projectPx` already uses for the software
/// renderer (its inputs are pre-recentred on the focus).
class FloatingOrigin {
  /// Absolute world position of the render origin, metres, doubles.
  Vector3 focusWorld = Vector3.zero;

  /// Rebase an absolute world position (metres, doubles) to scene units.
  vm.Vector3 worldToScene(Vector3 world) => relToScene(world - focusWorld);

  /// Rebase, keeping metres and double precision (for intermediate math).
  Vector3 worldToRel(Vector3 world) => world - focusWorld;
}
