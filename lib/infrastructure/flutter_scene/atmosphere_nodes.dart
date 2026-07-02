import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/vector3.dart';
import 'coord_convert.dart';

/// Atmosphere limb glow: a translucent shell just above each atmospheric
/// body whose per-vertex alpha is recomputed each frame from the view
/// direction — bright at the limb (grazing angles), fading to nothing at
/// the sub-camera point, tinted by the body's Rayleigh scatter colour from
/// its [BodyDescriptorSnapshot]. Approximates the software renderer's
/// screen-space halo without a custom shader: the shell is a low-tess
/// sphere with [fs.GeometryStorage.updatable] colours (a few thousand
/// vertices per atmospheric body — trivial CPU cost).
///
/// Colours are PREMULTIPLIED (the pipeline blends premultiplied output).
class AtmosphereNodes {
  AtmosphereNodes(this._scene);

  final fs.Scene _scene;

  final Map<String, _Shell> _shells = {};

  void update(WorldSnapshot snap, FloatingOrigin origin) {
    final seen = <String>{};
    for (final b in snap.bodies.values) {
      final d = snap.descriptors[b.id];
      if (d == null || !d.atmoPresent || d.atmoThickness <= 0) continue;
      // Stars: their "atmosphere" is a corona, not a limb-scatter shell —
      // and a star shell is big enough to swallow the camera whole.
      if (d.kind == BodyKind.star) continue;
      seen.add(b.id);

      final shell = _shells.putIfAbsent(b.id, () {
        final s = _Shell(d.atmoScatterColorArgb);
        _scene.add(s.node);
        return s;
      });

      // Shell sits at the top of the atmosphere. Positions/scale follow the
      // body; spin is irrelevant (the shell is view-dependent, not surface-
      // locked).
      final world = Vector3(b.px, b.py, b.pz);
      final rel = origin.worldToRel(world);
      final radius = lengthToScene(b.radius + d.atmoThickness);
      shell.node.localTransform = vm.Matrix4.compose(
        relToScene(rel),
        vm.Quaternion.identity(),
        vm.Vector3.all(radius),
      );

      // View-dependent limb alpha, computed in body-local unit space: the
      // camera position relative to the shell centre, unscaled. Inside the
      // shell the limb model is meaningless — hide it (the surface-view
      // sky is a future refinement).
      final camLocal = (Vector3.zero - rel) / (b.radius + d.atmoThickness);
      final inside = camLocal.length <= 1.02;
      shell.node.visible = !inside;
      if (!inside) shell.updateColors(camLocal);
    }

    _shells.removeWhere((id, shell) {
      if (seen.contains(id)) return false;
      _scene.remove(shell.node);
      return true;
    });
  }
}

class _Shell {
  _Shell(int scatterArgb) {
    _tint = _tintFromArgb(scatterArgb);
    _buildSphereArrays();
    node = fs.Node();
    _swapMesh();
  }

  /// Rebuild the mesh with FRESH GPU buffers. In-place updateColors() on a
  /// persistent geometry tears against in-flight frames (black shards over
  /// the planet); a new geometry's buffers can't be referenced by any
  /// frame already recording. A few KB per change, throttled by
  /// [updateColors]' view-delta check.
  void _swapMesh() {
    node.mesh = fs.Mesh(
      fs.MeshGeometry.fromArrays(
        positions: _positions,
        colors: _colors,
        indices: _indices,
      ),
      fs.UnlitMaterial()
        // Vertex colours carry all the shading; the factor stays white.
        // CRITICAL: AlphaMode.opaque (the default) IGNORES alpha — the
        // shell would draw as a solid ball. Blend routes it through the
        // depth-sorted translucent pass.
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
        ..alphaMode = fs.AlphaMode.blend,
    );
  }

  static const int _segments = 48;
  static const int _rings = 24;

  late final fs.Node node;
  late final vm.Vector3 _tint;
  late final Float32List _positions;
  late final List<int> _indices;
  late final Float32List _colors =
      Float32List(_vertexCount(_segments, _rings) * 4);

  // Unit-sphere vertex directions (== normals), retained for the colour
  // pass.
  late final List<vm.Vector3> _dirs;

  // View state of the last colour bake, for the update throttle.
  vm.Vector3? _lastCam;

  static int _vertexCount(int segments, int rings) =>
      (rings + 1) * (segments + 1);

  /// Rayleigh tint from the descriptor's packed 0xAARRGGBB, defaulting to a
  /// blue sky when the composition model gives none.
  static vm.Vector3 _tintFromArgb(int argb) {
    if (argb == 0) return vm.Vector3(0.45, 0.65, 1.0);
    return vm.Vector3(
      ((argb >> 16) & 0xff) / 255.0,
      ((argb >> 8) & 0xff) / 255.0,
      (argb & 0xff) / 255.0,
    );
  }

  void _buildSphereArrays() {
    final positions = <double>[];
    final dirs = <vm.Vector3>[];
    final indices = <int>[];
    for (var r = 0; r <= _rings; r++) {
      final phi = math.pi * r / _rings; // 0..pi from +Z pole
      for (var s = 0; s <= _segments; s++) {
        final theta = 2 * math.pi * s / _segments;
        final d = vm.Vector3(
          math.sin(phi) * math.cos(theta),
          math.sin(phi) * math.sin(theta),
          math.cos(phi),
        );
        dirs.add(d);
        positions.addAll([d.x, d.y, d.z]);
      }
    }
    for (var r = 0; r < _rings; r++) {
      for (var s = 0; s < _segments; s++) {
        final a = r * (_segments + 1) + s;
        final b = a + _segments + 1;
        indices.addAll([a, b, a + 1, a + 1, b, b + 1]);
      }
    }
    _dirs = dirs;
    _positions = Float32List.fromList(positions);
    _indices = indices;
  }

  /// Recompute per-vertex premultiplied colours for the camera at
  /// [camLocal] (shell-local unit space) and swap in a fresh mesh. Caller
  /// guarantees the camera is outside the shell. Throttled: the limb
  /// pattern only shifts with the VIEW DIRECTION to the body, so a small
  /// angular/radial delta skips the rebake entirely.
  void updateColors(Vector3 camLocal) {
    final cam = vm.Vector3(
        camLocal.x.toDouble(), camLocal.y.toDouble(), camLocal.z.toDouble());
    final last = _lastCam;
    if (last != null) {
      final angleSmall = last.normalized().dot(cam.normalized()) > 0.99997;
      final radiusSimilar = last.length > 0 &&
          ((cam.length / last.length) - 1.0).abs() < 0.01;
      if (angleSmall && radiusSimilar) return;
    }
    _lastCam = cam.clone();
    for (var i = 0; i < _dirs.length; i++) {
      final n = _dirs[i];
      double alpha;
      {
        final toCam = (cam - n)..normalize();
        final facing = n.dot(toCam); // 1 at sub-camera point, 0 at limb
        if (facing <= 0) {
          alpha = 0; // back hemisphere
        } else {
          // Peak at the limb, like the 0.2.0 halo. Quadratic falloff + a
          // high cap: the software halo is bold, not a faint rim.
          alpha = math.pow(1.0 - facing, 2.0).toDouble();
        }
      }
      final o = i * 4;
      _colors[o] = _tint.x * alpha;
      _colors[o + 1] = _tint.y * alpha;
      _colors[o + 2] = _tint.z * alpha;
      _colors[o + 3] = alpha;
    }
    _swapMesh(); // fresh buffers — never mutate in-flight geometry
  }
}
