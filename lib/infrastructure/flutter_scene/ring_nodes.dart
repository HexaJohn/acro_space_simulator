import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/vector3.dart';
import 'coord_convert.dart';

/// Planetary ring systems as flat translucent annulus meshes in each ringed
/// body's ring plane.
///
/// Ring geometry (radius multipliers, plane tilt, colour, opacity) mirrors
/// the software renderer's tables in `TopDownSnapshotPresenter` — that
/// presenter is the source of truth; keep the two in sync. The ring plane
/// tilts about the +X axis by the body's ring inclination, matching the
/// presenter's convention (Uranus ~98°: rings stand nearly polar).
///
/// V1 parity: flat colour band, no radial banding shader, no planet-shadow
/// chord. Blend + premultiplied + doubleSided (visible from below the
/// plane).
class RingNodes {
  RingNodes(this._scene);

  final fs.Scene _scene;

  final Map<String, fs.Node> _nodes = {};

  /// (innerMult, outerMult, tiltRad, argb) — multipliers of body radius.
  /// MIRRORS TopDownSnapshotPresenter._rings.
  static const Map<String, (double, double, double, int)> _rings = {
    'saturn': (1.2, 2.3, 0.466, 0xFFE3D2A8),
    'uranus': (1.6, 2.1, 1.706, 0xFF6E6A74),
    'neptune': (1.7, 2.4, 0.494, 0xFF5A6E86),
    'jupiter': (1.4, 1.8, 0.055, 0xFFB08A6A),
  };

  /// MIRRORS TopDownSnapshotPresenter._ringIntensity.
  static const Map<String, double> _intensity = {
    'saturn': 0.7,
    'jupiter': 0.18,
    'uranus': 0.22,
    'neptune': 0.2,
  };

  void update(WorldSnapshot snap, FloatingOrigin origin) {
    final seen = <String>{};
    for (final b in snap.bodies.values) {
      final spec = _rings[b.id];
      if (spec == null) continue;
      seen.add(b.id);

      final node = _nodes.putIfAbsent(b.id, () {
        final n = fs.Node(
          mesh: fs.Mesh(
            _annulus(spec.$1, spec.$2),
            fs.UnlitMaterial()
              ..baseColorFactor = _premul(spec.$4, _intensity[b.id] ?? 0.3)
              ..alphaMode = fs.AlphaMode.blend
              ..doubleSided = true,
          ),
        );
        _scene.add(n);
        return n;
      });

      // Body position + ring-plane tilt about +X; scale = body radius (the
      // annulus is built in radius multiples).
      node.localTransform = vm.Matrix4.compose(
        origin.worldToScene(Vector3(b.px, b.py, b.pz)),
        vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), spec.$3),
        vm.Vector3.all(lengthToScene(b.radius)),
      );
    }

    _nodes.removeWhere((id, node) {
      if (seen.contains(id)) return false;
      _scene.remove(node);
      return true;
    });
  }

  static vm.Vector4 _premul(int argb, double intensity) {
    final a = ((argb >> 24) & 0xff) / 255.0 * intensity;
    return vm.Vector4(
      ((argb >> 16) & 0xff) / 255.0 * a,
      ((argb >> 8) & 0xff) / 255.0 * a,
      (argb & 0xff) / 255.0 * a,
      a,
    );
  }

  /// Flat annulus in the local XY plane (Z = ring normal), radii in body-
  /// radius multiples. BOTH triangle windings are emitted: translucent
  /// materials always backface-cull (Material.bind:
  /// `cullBackFace = !doubleSided || !isOpaque()`), so a single-winding
  /// flat ring vanishes from one side of the ring plane — doubleSided
  /// cannot save a blended material.
  static fs.MeshGeometry _annulus(double inner, double outer,
      {int segments = 96}) {
    final positions = <double>[];
    final indices = <int>[];
    for (var s = 0; s <= segments; s++) {
      final a = 2 * math.pi * s / segments;
      final c = math.cos(a), si = math.sin(a);
      positions.addAll([inner * c, inner * si, 0.0]); // 2s
      positions.addAll([outer * c, outer * si, 0.0]); // 2s+1
    }
    for (var s = 0; s < segments; s++) {
      final i0 = 2 * s, o0 = 2 * s + 1, i1 = 2 * (s + 1), o1 = 2 * (s + 1) + 1;
      indices.addAll([i0, o0, i1, i1, o0, o1]); // top face
      indices.addAll([i0, i1, o0, o0, i1, o1]); // bottom face (reversed)
    }
    return fs.MeshGeometry.fromArrays(
      positions: Float32List.fromList(positions),
      indices: indices,
    );
  }
}
