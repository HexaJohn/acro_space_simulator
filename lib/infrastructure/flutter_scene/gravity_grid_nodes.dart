// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../adapters/presenters/camera_view.dart';
import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/vector3.dart';
import 'coord_convert.dart';
import 'depth_materials.dart';

/// The "spacetime distortion" grid: a translucent polar graticule floating
/// under every planet and moon, bowed into a gravity-well funnel whose depth
/// and opacity key on the body's surface gravity (g = mu/r^2, from the
/// descriptor's [BodyDescriptorSnapshot.mu]).
///
/// The sheet always reads as a FLOOR: its plane normal follows the camera's
/// up-ALIGNMENT reference every frame ([SceneCamera.referenceUp] — ecliptic
/// +Z in free mode, the body's spin axis in axis mode, the local radial in
/// gravity mode), hugging the body's underside: the sheet plane sits a
/// fraction of a radius below the centre with a body-sized hole, and the
/// funnel dips from the hole's rim.
///
/// The funnel DEPTH is baked into each sheet's own geometry (depth is a
/// per-body constant — gravity doesn't change frame to frame), so the node
/// transform stays a uniform scale + pure rotation, exactly the shape the
/// ring sheets use. An earlier draft scaled a shared unit funnel per axis
/// through a hand-built matrix; keeping the proven compose(translation,
/// rotation, uniform scale) path costs one small mesh per body and removes
/// the only structural difference from the known-good translucent draws.
///
/// Stars are skipped — the grid is a navigation aid for the bodies you
/// orbit, and the sun's funnel would swallow the whole inner system.
class GravityGridNodes {
  GravityGridNodes(this._scene);

  final fs.Scene _scene;
  final Map<String, _GridSheet> _sheets = {};

  /// Panel toggle (3D backend only, like CloudNodes.hidden and friends).
  static bool enabled = true;

  /// Grid rim radius in body radii. The hole the body sits over is exactly
  /// one body radius, so the mesh's normalised hole is 1/extent.
  static const double extentRadii = 4.0;
  static const double _r0 = 1.0 / extentRadii;

  /// Sheet plane offset below the body centre, in body radii. Shallow on
  /// purpose: the hole rim hugs the body's lower limb (classic rubber-sheet
  /// framing) instead of floating a full diameter beneath it.
  static const double _planeOffsetRadii = 0.35;

  /// Surface gravity (m/s^2) → well depth in body radii. sqrt keeps the
  /// Moon (1.6 m/s^2) visibly shallow and Jupiter (24.8) visibly deep
  /// without either degenerating; clamped so weird bodies stay sane.
  static double _depthRadii(double g) =>
      (0.55 * math.sqrt(g / _gEarth)).clamp(0.15, 2.5);

  /// Surface gravity → base opacity: saturating g/(g+g_earth) so Earth sits
  /// mid-scale (~0.65), the Moon faint (~0.44), Jupiter strong (~0.78).
  /// Floor high enough that the weakest moons still read against space.
  static double _alphaFor(double g) => 0.35 + 0.6 * g / (g + _gEarth);

  static const double _gEarth = 9.80665;

  /// The compiled grid fragment shader (same bundle as the rings). Sheets
  /// don't spawn until it's loaded.
  static Object? _shader;
  static Future<void>? _loading;

  static Future<void> loadShader() => _loading ??= () async {
        final library = await gpu.loadShaderLibraryAsync(
          'build/shaderbundles/acro.shaderbundle',
        );
        _shader = library?['GravityGridFragment'];
        if (_shader == null) {
          throw StateError(
            'GravityGridFragment missing from acro.shaderbundle — the '
            'hook/build.dart shader compile should have produced it.',
          );
        }
      }();

  void update(WorldSnapshot snap, FloatingOrigin origin,
      {SceneCamera? camera}) {
    final shader = _shader;
    if (!enabled || shader == null || camera == null) {
      _removeAll();
      return;
    }

    // Up-alignment basis for the sheet plane, shared by every body this
    // frame. The MODE's reference (not the screen-space up basis): the grid
    // must stay a floor when the camera tilts to look down at it. In-plane
    // spoke direction anchors to the WORLD axes (projected), not the camera
    // basis — otherwise orbiting the camera visibly spins the spokes.
    final up = camera.referenceUp.normalized;
    var ex = Vector3.unitX - up * up.dot(Vector3.unitX);
    if (ex.length < 0.1) ex = Vector3.unitY - up * up.dot(Vector3.unitY);
    ex = ex.normalized;
    final ey = up.cross(ex); // ex × ey = up: right-handed, no reflection
    final rot = vm.Quaternion.fromRotation(vm.Matrix3(
      ex.x, ex.y, ex.z, // column 0 = image of local +X
      ey.x, ey.y, ey.z,
      up.x, up.y, up.z,
    ));

    final seen = <String>{};
    for (final b in snap.bodies.values) {
      final d = snap.descriptors[b.id];
      if (d == null || d.kind == BodyKind.star || d.mu <= 0) continue;

      // Apparent-size fade: below ~30 px of grid rim the sheet is subpixel
      // sparkle at system zoom — fade over 30..90 px and skip when gone.
      final rel = origin.worldToRel(Vector3(b.px, b.py, b.pz));
      final rimPx = camera.radiusPx(rel, extentRadii * b.radius);
      final sizeFade = ((rimPx - 30.0) / 60.0).clamp(0.0, 1.0);
      if (sizeFade <= 0.0) continue;
      seen.add(b.id);

      final g = d.mu / (b.radius * b.radius);
      final sheet = _sheets.putIfAbsent(b.id, () {
        // Funnel depth baked into this body's own mesh, normalised to the
        // rim radius so the node scale stays uniform.
        final s =
            _GridSheet(shader, zFrac: _depthRadii(g) / extentRadii);
        _scene.add(s.node);
        return s;
      });

      sheet.node.localTransform = vm.Matrix4.compose(
        origin.worldToScene(
            Vector3(b.px, b.py, b.pz) - up * (b.radius * _planeOffsetRadii)),
        rot,
        vm.Vector3.all(lengthToScene(b.radius * extentRadii)),
      );
      sheet.updateUniforms(alpha: _alphaFor(g) * sizeFade, rimPx: rimPx);
    }

    _sheets.removeWhere((id, sheet) {
      if (seen.contains(id)) return false;
      _scene.remove(sheet.node);
      return true;
    });
  }

  void _removeAll() {
    for (final sheet in _sheets.values) {
      _scene.remove(sheet.node);
    }
    _sheets.clear();
  }
}

/// One body's grid sheet: its own funnel mesh (depth baked in) under
/// gravity_grid.frag, with a per-body opacity uniform.
class _GridSheet {
  _GridSheet(Object shader, {required double zFrac}) {
    _material = DepthSafeShaderMaterial(fragmentShader: shader as gpu.Shader);
    node = fs.Node(mesh: fs.Mesh(_funnelDisc(zFrac: zFrac), _material));
  }

  late final fs.Node node;
  late final DepthSafeShaderMaterial _material;

  final Float32List _u = Float32List(12); // 3 x vec4, std140

  /// Line colour: pale spacetime-diagram cyan.
  static const double _rCol = 0.55, _gCol = 0.85, _bCol = 1.0;

  void updateUniforms({required double alpha, required double rimPx}) {
    _u[0] = _rCol;
    _u[1] = _gCol;
    _u[2] = _bCol;
    _u[3] = alpha;
    _u[4] = 12; // rings hole rim -> outer rim
    _u[5] = 24; // spokes
    _u[6] = GravityGridNodes._r0;
    _u[7] = 0.72; // rim fade start (normalised radius)
    // Apparent rim radius (px): the shader derives line widths from it in
    // uv space (fwidth is unusable on this backend — see gravity_grid.frag).
    _u[8] = rimPx;
    _material.setUniformBlockFromFloats('GridInfo', _u);
  }

  /// The funnel disc: unit planar radius, both windings (translucent
  /// materials backface-cull, and the bowed sheet shows its underside near
  /// the rim). z = 0 at the outer rim falling hyperbolically (1/r, the
  /// point-mass potential's shape) to -[zFrac] at the hole rim — depth in
  /// the same normalised units as the planar radius, so the node scale is
  /// UNIFORM. Radial sampling is biased toward the hole (t^2) where the
  /// curvature lives; uv carries (angle/2pi, planar radius) for the
  /// fragment shader's graticule.
  static fs.MeshGeometry _funnelDisc(
      {required double zFrac, int radial = 48, int segments = 96}) {
    const r0 = GravityGridNodes._r0;
    final positions = <double>[];
    final texCoords = <double>[];
    final indices = <int>[];
    for (var ir = 0; ir <= radial; ir++) {
      final t = ir / radial;
      final r = r0 + (1.0 - r0) * t * t;
      final z = -zFrac * ((1.0 / r) - 1.0) / ((1.0 / r0) - 1.0);
      for (var s = 0; s <= segments; s++) {
        final a = 2 * math.pi * s / segments;
        positions.addAll([r * math.cos(a), r * math.sin(a), z]);
        texCoords.addAll([s / segments, r]);
      }
    }
    for (var ir = 0; ir < radial; ir++) {
      for (var s = 0; s < segments; s++) {
        final i0 = ir * (segments + 1) + s;
        final i1 = i0 + 1;
        final j0 = i0 + segments + 1;
        final j1 = j0 + 1;
        indices.addAll([i0, i1, j0, j0, i1, j1]); // top face
        indices.addAll([i0, j0, i1, i1, j0, j1]); // bottom face (reversed)
      }
    }
    return fs.MeshGeometry.fromArrays(
      positions: Float32List.fromList(positions),
      texCoords: Float32List.fromList(texCoords),
      indices: indices,
    );
  }
}
