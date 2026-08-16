// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:ui' show Offset, Size;

import '../../domain/craft/craft_design.dart';
import '../../domain/shared/vector3.dart';
import 'perspective_camera.dart';

/// Turns a domain camera pose into the concrete camera some 3D backend draws
/// with, given the viewport height that pose was measured against.
///
/// `toSceneCamera` in `infrastructure/flutter_scene/scene_camera_adapter.dart`
/// is the one implementation, and this signature is the ONLY thing the
/// presenter layer knows about it. Stating the shape here instead of importing
/// the adapter is what keeps [CraftEditorCamera] — and `CraftEditorPick`, which
/// is built on it — loadable from a plain `package:test` process with no
/// renderer linked, so a headless layout tool or a pure-Dart suite can use
/// [CraftEditorCamera.project] without pulling in an Impeller-backed package.
typedef SceneCameraBuilder<T> = T Function(
  PerspectiveCamera cam, {
  double viewportH,
});

/// Turntable camera over a craft under construction. Everything it takes and
/// returns is in the CRAFT BODY FRAME: metres, right-handed, Z-up, +Z = nose —
/// the same frame [PlacedPart.position] uses, so the editor never converts.
///
/// PROJECTION REUSE. This class does not invent a projection. It builds a
/// domain [PerspectiveCamera] from the same pose, caches that camera's basis
/// (each basis getter recomputes four trig calls, and [project] runs once per
/// marker per pointer move), and applies the identical formula plus the
/// centre-origin -> Flutter top-left conversion. `craft_editor_camera_test.dart`
/// asserts the two agree BIT FOR BIT over a grid of poses, so a drift between
/// the cache and [PerspectiveCamera] is a red test rather than a mouse that
/// misses by a few pixels.
///
/// CHIRALITY. flutter_scene's `_matrix4LookAt` derives `right = up x forward`
/// while [PerspectiveCamera] derives `up = right x forward`; the two bases
/// therefore differ by a negated horizontal axis and nothing else
/// (`right_fs = (right_dom x fwd) x fwd = -right_dom`, `up_fs = up_dom`). The
/// raw render is a mirror image, and the viewport's `Transform.flip(flipX)`
/// undoes exactly that one negation. So the flipped image IS
/// [PerspectiveCamera.projectPx] and there is NO mirror term anywhere in this
/// class. Four structural preconditions keep that true and each one breaks
/// picking if violated:
///
///  1. the flutter_scene camera comes from [sceneCameraVia] (i.e. the
///     `toSceneCamera` adapter) and is never hand-rolled — that adapter is what
///     the green `coord_convert_test` pins;
///  2. `Transform.flip` wraps the `SceneView` ONLY, with the overlay painter a
///     sibling in the `Stack`, never a descendant;
///  3. every gesture widget is an ANCESTOR of the flip, or it reports mirrored
///     local coordinates;
///  4. [viewport] height is the same logical-pixel height the `SceneView` lays
///     out at, and [fovY] is the same vertical FOV. Flutter local coordinates
///     and [focalPx] are both logical pixels, so `devicePixelRatio` cancels.
class CraftEditorCamera {
  /// `toSceneCamera` takes its ORTHO fallback path when the eye offset is
  /// shorter than 1 m (scene_camera_adapter.dart:41), synthesising a completely
  /// different eye from a metres-per-pixel scale — an 869 m eye and a 43 m near
  /// plane where a 1 m inspection view was asked for. A craft-inspection zoom is
  /// exactly where that boundary lives, so the distance floor is not cosmetic.
  ///
  /// The floor sits a micrometre ABOVE the adapter's 1 m threshold rather than
  /// on it, because the adapter tests `|eyeOffset|`, not the range, and
  /// `eyeOffset = forward * -range` with a `forward` assembled from four trig
  /// calls — unit only to within a double ulp. At exactly 1.0 the comparison
  /// falls on the wrong side of the cliff for some azimuth/elevation pairs and
  /// the camera silently teleports. A micrometre is invisible at any zoom and
  /// removes the entire class of failure.
  static const double minDistanceM = 1.000001;

  /// Far enough to frame a launch stack with margin; beyond this a craft is a
  /// speck and the wheel just wastes travel.
  static const double maxDistanceM = 400.0;

  static const double defaultFovY = 45 * math.pi / 180;

  /// Elevation stops short of the pole: at exactly +/-pi/2 the turntable's
  /// azimuth stops meaning anything and the view snaps as it crosses.
  static const double maxElevationRad = math.pi / 2 - 0.02;

  /// Turntable spin about the craft's +Z, radians.
  final double azimuth;

  /// Tilt above the craft's XY plane, radians, clamped to +/-[maxElevationRad].
  /// Positive looks DOWN at the craft, matching [PerspectiveCamera].
  final double elevation;

  /// Eye distance from [pivot], metres, clamped to
  /// [minDistanceM]..[maxDistanceM].
  final double distanceM;

  /// What the camera orbits, craft frame, metres. Also the floating origin the
  /// scene graph is built around, so every projected point is [pivot]-relative
  /// before it reaches float32.
  final Vector3 pivot;

  /// Logical pixels — the `LayoutBuilder` size the `SceneView` fills.
  final Size viewport;

  final double fovY;

  CraftEditorCamera({
    required this.azimuth,
    required double elevation,
    required double distanceM,
    required this.pivot,
    required this.viewport,
    this.fovY = defaultFovY,
  })  : elevation = elevation.clamp(-maxElevationRad, maxElevationRad),
        distanceM = distanceM.clamp(minDistanceM, maxDistanceM);

  /// Near plane, metres. `toSceneCamera` clips at
  /// `max(cam.near, max(0.05, eyeDistance/20))`, so any smaller domain value is
  /// silently dominated and the overlay would draw markers the renderer has
  /// already thrown away. Defining the domain near as the adapter's own
  /// adaptive formula makes that `max` a no-op and the two clips one number.
  double get nearM => math.max(0.05, distanceM / 20.0);

  /// The domain camera this one delegates its projection to. Focus-relative:
  /// its inputs are `point - pivot`.
  late final PerspectiveCamera domain = PerspectiveCamera(
    azimuth: azimuth,
    elevation: elevation,
    range: distanceM,
    fovY: fovY,
    viewportH: viewport.height,
    near: nearM,
  );

  /// Unit view axis, craft frame.
  late final Vector3 forward = domain.forward;

  /// Unit screen-right axis, craft frame — the DOMAIN right, which is the
  /// on-screen right after the viewport's `Transform.flip` (see the class doc).
  late final Vector3 right = domain.right;

  /// Unit screen-up axis, craft frame.
  late final Vector3 up = domain.up;

  /// Eye position relative to [pivot], metres.
  late final Vector3 eyeRel = domain.eyeOffset;

  /// Eye position in the craft frame, metres.
  late final Vector3 eyeC = pivot + eyeRel;

  /// Focal length in logical pixels. ONE value serves both axes: flutter_scene's
  /// `_matrix4Perspective` writes `[0][0] = 1/(tan(fovY/2) * aspect)`, and that
  /// aspect cancels against `W/2` in the NDC -> pixel step
  /// (`x_px = x_ndc * W/2 = x_view/z * H/(2 tan(fovY/2))`). Deriving a separate
  /// horizontal focal length is the classic bug that leaves picking exact on a
  /// square viewport and drifting on a wide one.
  late final double focalPx = (viewport.height / 2) / math.tan(fovY / 2);

  CraftEditorCamera copyWith({
    double? azimuth,
    double? elevation,
    double? distanceM,
    Vector3? pivot,
    Size? viewport,
  }) =>
      CraftEditorCamera(
        azimuth: azimuth ?? this.azimuth,
        elevation: elevation ?? this.elevation,
        distanceM: distanceM ?? this.distanceM,
        pivot: pivot ?? this.pivot,
        viewport: viewport ?? this.viewport,
        fovY: fovY,
      );

  /// Craft-frame point -> Flutter local offset, or null when the point is at or
  /// behind [nearM] (the same cull the GPU applies, by construction).
  ///
  /// The body is [PerspectiveCamera.projectPx] inlined over the cached basis,
  /// then centre-origin/y-up -> top-left/y-down. No mirror term: the viewport's
  /// horizontal flip cancels flutter_scene's opposite handedness exactly.
  Offset? project(Vector3 pC) {
    final fromEye = pC - pivot - eyeRel;
    final z = fromEye.dot(forward);
    if (z <= nearM) return null;
    final x = fromEye.dot(right) / z * focalPx;
    final y = fromEye.dot(up) / z * focalPx;
    return Offset(viewport.width / 2 + x, viewport.height / 2 - y);
  }

  /// Depth of a craft-frame point along the view axis, metres. Negative or
  /// below [nearM] means the point is behind the near plane.
  ///
  /// This is the PLANAR depth, not the euclidean distance: it is what the
  /// projection divides by, so ordering markers by it orders them the way they
  /// actually overlap on screen.
  double depthOf(Vector3 pC) => (pC - pivot - eyeRel).dot(forward);

  /// Unit direction from the eye to a craft-frame point. Falls back to
  /// [forward] at the eye itself rather than returning a zero vector, so the
  /// facing test in `CraftEditorPick` cannot produce a NaN dot product.
  ///
  /// Subtracts [pivot] and [eyeRel] in that order rather than the algebraically
  /// identical `pC - eyeC`: floating point is not associative, and only this
  /// grouping reproduces [PerspectiveCamera.viewDirTo] bit for bit.
  Vector3 viewDirTo(Vector3 pC) {
    final d = pC - pivot - eyeRel;
    return d.length < 1e-9 ? forward : d.normalized;
  }

  /// Screen scale at a given view depth. Marker radii and the world cap on the
  /// pick radius are both expressed through this so they track zoom.
  double pxPerMetreAt(double depthM) => focalPx / depthM;

  /// Flutter local offset -> craft-frame ray. The exact inverse of [project]:
  /// a point at view depth `z` on this ray is
  /// `eye + (z/f)(f*forward + sx*right + sy*up)`, whose dot with `forward` is
  /// `z` and whose dot with `right` is `sx*z/f`, so [project] returns the
  /// offset it was given — no epsilon involved.
  ///
  /// Nothing in the editor depends on this. It exists because the
  /// project/unproject round trip and the `screenPointToRay` cross-check are
  /// the two sharpest guards on the projection math, and the riskiest math in
  /// the feature should be tested even where it is not load-bearing.
  ({Vector3 origin, Vector3 dir}) rayThrough(Offset p) {
    final sx = p.dx - viewport.width / 2;
    final sy = viewport.height / 2 - p.dy;
    final dir = (forward * focalPx + right * sx + up * sy).normalized;
    return (origin: eyeC, dir: dir);
  }

  /// The renderer's camera for this pose, built by [build].
  ///
  /// Call it as `camera.sceneCameraVia(toSceneCamera)`; the adapter is chosen by
  /// the caller because only the infrastructure layer may name it, and this
  /// class must stay pure (see [SceneCameraBuilder]).
  ///
  /// Handing the builder [domain] and the [viewport] height TOGETHER, rather
  /// than exposing them for a caller to combine, is what keeps preconditions 1
  /// and 4 enforceable from here. A caller can pick the backend but cannot
  /// substitute a hand-rolled eye/target/up for the pose `coord_convert_test`
  /// pins, and cannot pair the pose with a screen height other than the one
  /// [project] measures against — the two ways a correct projection turns into
  /// a mouse that misses.
  T sceneCameraVia<T>(SceneCameraBuilder<T> build) =>
      build(domain, viewportH: viewport.height);

  /// Slide [pivot] so the world tracks a screen-space drag of [screenDelta].
  ///
  /// The conversion is exact at the pivot's depth (`distanceM / focalPx` metres
  /// per pixel) and approximate elsewhere, which is what makes a grabbed point
  /// stay under the cursor for the part of the craft the player is looking at.
  /// No screen -> world ray is needed for this, which is why the editor has no
  /// work plane.
  CraftEditorCamera panned(Offset screenDelta) {
    final metresPerPx = distanceM / focalPx;
    return copyWith(
      pivot: pivot - (right * screenDelta.dx - up * screenDelta.dy) * metresPerPx,
    );
  }

  /// A pose that frames [design] whole.
  ///
  /// Called ONCE, when the root part lands — a camera that re-frames on every
  /// placement is nauseating. The default elevation is deliberately off zero:
  /// looking straight down a stack axis projects a 4-member node ring onto a
  /// few pixels and makes picking ambiguous, so the player never STARTS there.
  ///
  /// Fits the bounding sphere of the part boxes inside the TIGHTER of the two
  /// half-angles; on a portrait viewport the horizontal one is smaller and a
  /// vertical-only fit would crop the craft.
  static CraftEditorCamera framing(
    CraftDesign design,
    Size viewport, {
    double azimuth = 0.9,
    double elevation = 0.28,
  }) {
    final corners = <Vector3>[];
    for (final p in design.parts) {
      final h = p.def.size * 0.5;
      for (final sx in const [-1.0, 1.0]) {
        for (final sy in const [-1.0, 1.0]) {
          for (final sz in const [-1.0, 1.0]) {
            final local = Vector3(sx * h.x, sy * h.y, sz * h.z);
            corners.add(p.position + p.rotation.rotate(local));
          }
        }
      }
    }
    if (corners.isEmpty) {
      // An empty design still needs a usable pose: the ghost of the root part
      // stands on the pad at the origin and must be visible before anything is
      // placed.
      return CraftEditorCamera(
        azimuth: azimuth,
        elevation: elevation,
        distanceM: 10.0,
        pivot: Vector3.zero,
        viewport: viewport,
      );
    }
    var lo = corners.first, hi = corners.first;
    for (final c in corners) {
      lo = Vector3(math.min(lo.x, c.x), math.min(lo.y, c.y), math.min(lo.z, c.z));
      hi = Vector3(math.max(hi.x, c.x), math.max(hi.y, c.y), math.max(hi.z, c.z));
    }
    final centre = (lo + hi) * 0.5;
    var radius = 0.0;
    for (final c in corners) {
      radius = math.max(radius, (c - centre).length);
    }
    // Floor the radius so a single 0.15 m thruster does not slam the camera
    // into the distance clamp and read as a bug.
    radius = math.max(radius, 0.5);

    final halfV = defaultFovY / 2;
    final aspect =
        viewport.height > 0 ? viewport.width / viewport.height : 1.0;
    final halfH = math.atan(math.tan(halfV) * aspect);
    final half = math.min(halfV, halfH);
    // 1.15 leaves a hand's breadth of pad around the craft rather than letting
    // the silhouette touch the frame edge.
    return CraftEditorCamera(
      azimuth: azimuth,
      elevation: elevation,
      distanceM: radius / math.sin(half) * 1.15,
      pivot: centre,
      viewport: viewport,
    );
  }

  @override
  String toString() => 'CraftEditorCamera(az ${azimuth.toStringAsFixed(3)}, '
      'el ${elevation.toStringAsFixed(3)}, d ${distanceM.toStringAsFixed(2)} m, '
      'pivot $pivot)';
}
