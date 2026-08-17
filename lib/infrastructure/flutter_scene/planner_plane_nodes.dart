// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../application/snapshot/planner_overlay.dart';
import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/vector3.dart';
import 'coord_convert.dart';
import 'depth_materials.dart';

/// The encounter-planner plane: a translucent disc aligned with the planned
/// orbit's plane, centred on the planning body, with a brighter rim and
/// quarter-radius guide rings. Gives transfers a surface to read against —
/// the planned trajectory, the target's orbit, and the AN/DN line all relate
/// to THIS plane.
///
/// Geometry is authored as a unit annulus in the XY plane (+Z normal — the
/// scene keeps the domain's Z-up frame) and two-sided (translucent draws are
/// back-face culled unconditionally; see the craft editor's pad ring). The
/// node scales to the plane radius and rotates +Z onto the plan's normal.
class PlannerPlaneNodes {
  PlannerPlaneNodes(this._scene);

  final fs.Scene _scene;

  fs.Node? _root;
  bool _attached = false;
  double _builtInnerFrac = -1;

  /// Replaced meshes held by wall clock before the last reference drops —
  /// same GPU discipline as LineNodes (in-flight frames may still read them).
  final List<(int, List<fs.Mesh>)> _retired = [];
  static const int _retireAfterMs = 400;

  static const int _segments = 128;

  void update(WorldSnapshot snap, FloatingOrigin origin,
      PlannerOverlay? planner) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _retired.removeWhere((e) => now - e.$1 > _retireAfterMs);

    final body = planner == null ? null : snap.bodies[planner.frameBody];
    if (planner == null || body == null || planner.planeRadiusM <= 0) {
      _detach();
      return;
    }

    // Hole in the middle where the body sits: the fill under the planet reads
    // as a colour cast on the surface, not as a plane.
    final innerFrac =
        (body.radius * 1.05 / planner.planeRadiusM).clamp(0.01, 0.6).toDouble();
    var root = _root;
    if (root == null || (innerFrac - _builtInnerFrac).abs() > 0.1 * _builtInnerFrac) {
      if (root != null) {
        _retired.add((
          now,
          [
            for (final c in root.children)
              if (c.mesh != null) c.mesh!,
          ],
        ));
        if (_attached) _scene.remove(root);
        _attached = false;
      }
      root = _buildPlane(innerFrac);
      _root = root;
      _builtInnerFrac = innerFrac;
    }
    if (!_attached) {
      _scene.add(root);
      _attached = true;
    }

    final n = planner.planeNormal;
    final nvm = vm.Vector3(n.x, n.y, n.z)..normalize();
    // The plane is centred on the body.
    root.localTransform = vm.Matrix4.compose(
      origin.worldToScene(Vector3(body.px, body.py, body.pz)),
      _rotationZTo(nvm),
      vm.Vector3.all(lengthToScene(planner.planeRadiusM)),
    );
  }

  void _detach() {
    final root = _root;
    if (root != null && _attached) {
      _scene.remove(root);
      _attached = false;
    }
  }

  /// Quaternion rotating +Z onto [n] (unit).
  static vm.Quaternion _rotationZTo(vm.Vector3 n) {
    final z = vm.Vector3(0, 0, 1);
    final axis = z.cross(n);
    final s = axis.length;
    final c = z.dot(n);
    if (s < 1e-9) {
      // Parallel or anti-parallel: identity, or a half-turn about X.
      return c > 0
          ? vm.Quaternion.identity()
          : vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), math.pi);
    }
    return vm.Quaternion.axisAngle(axis..scale(1.0 / s), math.atan2(s, c));
  }

  fs.Node _buildPlane(double innerFrac) {
    final root = fs.Node();
    // Faint fill across the whole plane.
    root.add(fs.Node(
      mesh: fs.Mesh(
        _annulus(innerFrac, 1.0),
        _material(0.35, 0.62, 0.95, 0.055),
      ),
    ));
    // Bright rim so the plane's extent reads at a glance.
    root.add(fs.Node(
      mesh: fs.Mesh(
        _annulus(0.992, 1.0),
        _material(0.45, 0.72, 1.0, 0.4),
      ),
    ));
    // Quarter-radius guide rings: the plane doubles as a range ruler.
    for (final f in const [0.25, 0.5, 0.75]) {
      if (f <= innerFrac) continue;
      root.add(fs.Node(
        mesh: fs.Mesh(
          _annulus(f - 0.0015, f + 0.0015),
          _material(0.45, 0.72, 1.0, 0.16),
        ),
      ));
    }
    return root;
  }

  static fs.Material _material(double r, double g, double b, double a) =>
      DepthSafeUnlitMaterial()
        // Premultiplied: the translucent pass blends premultiplied colour.
        ..baseColorFactor = vm.Vector4(r * a, g * a, b * a, a)
        ..alphaMode = fs.AlphaMode.blend;

  /// Two-sided flat annulus in the XY plane (unit outer radius = 1 pre-scale).
  /// Both windings are emitted: translucent materials are back-face culled
  /// unconditionally, so two-sidedness must live in the mesh.
  static fs.MeshGeometry _annulus(double innerRadius, double outerRadius) {
    final positions = <double>[];
    final normals = <double>[];
    final indices = <int>[];
    for (var s = 0; s < _segments; s++) {
      final a = 2 * math.pi * s / _segments;
      final c = math.cos(a), sn = math.sin(a);
      positions.addAll([outerRadius * c, outerRadius * sn, 0]); // 2s
      positions.addAll([innerRadius * c, innerRadius * sn, 0]); // 2s + 1
      normals.addAll([0, 0, 1, 0, 0, 1]);
    }
    for (var s = 0; s < _segments; s++) {
      final t = (s + 1) % _segments;
      final o0 = 2 * s, i0 = 2 * s + 1, o1 = 2 * t, i1 = 2 * t + 1;
      indices
        ..addAll([o0, o1, i1]) // +Z face
        ..addAll([o0, i1, i0])
        ..addAll([o0, i1, o1]) // -Z face, the same quad reversed
        ..addAll([o0, i0, i1]);
    }
    return fs.MeshGeometry.fromArrays(
      positions: Float32List.fromList(positions),
      normals: Float32List.fromList(normals),
      indices: indices,
    );
  }
}
