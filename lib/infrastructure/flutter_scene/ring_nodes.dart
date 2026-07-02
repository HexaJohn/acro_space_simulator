import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../adapters/presenters/camera_view.dart';
import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';
import 'coord_convert.dart';
import 'depth_materials.dart';
import 'sphere_geometry_util.dart';

/// A radial ring band: [t0, t1] normalised across the annulus (0 = inner
/// edge, 1 = outer edge), with an opacity multiplier on the ring's base
/// colour and an optional hue override. Bands also gate the asteroid field:
/// rock density follows band opacity, so divisions read as real gaps.
class RingBand {
  const RingBand(this.t0, this.t1, this.alpha, [this.argb]);
  final double t0, t1, alpha;
  final int? argb;
}

/// Planetary ring systems: a banded translucent annulus (per-vertex colours
/// from real ring-structure profiles — Cassini division, Encke gap...) plus
/// a GPU-instanced asteroid field that fades in when the camera flies into
/// the ring plane.
///
/// Ring extents/colour mirror the software renderer's tables in
/// `TopDownSnapshotPresenter` (source of truth for extents; the banding and
/// rocks are 3D-backend-only).
class RingNodes {
  RingNodes(this._scene);

  final fs.Scene _scene;

  final Map<String, fs.Node> _nodes = {};
  final Map<String, _RockField> _rocks = {};

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

  /// Radial opacity profiles, normalised across each ring's [inner, outer]
  /// span. Saturn maps the real structure (C/B rings, Cassini division at
  /// 1.95-2.03 R, A ring with the Encke gap, F ring thread); Uranus is
  /// narrow threads on a near-empty base (epsilon ring brightest); Jupiter
  /// a faint halo climbing to its main ring; Neptune the Galle sheet plus
  /// the Le Verrier and Adams ringlets.
  static const Map<String, List<RingBand>> _bands = {
    // Saturn: inner 1.2 R, outer 2.3 R  ->  t = (r/R - 1.2) / 1.1
    'saturn': [
      RingBand(0.000, 0.036, 0.05), // D ring haze
      RingBand(0.036, 0.300, 0.30, 0xFFC9B491), // C ring (dimmer, browner)
      RingBand(0.300, 0.480, 0.95), // B ring inner (brightest)
      RingBand(0.480, 0.560, 0.75), // B ring mid lane
      RingBand(0.560, 0.682, 1.00), // B ring outer
      RingBand(0.682, 0.755, 0.07), // Cassini division
      RingBand(0.755, 0.918, 0.62), // A ring
      RingBand(0.918, 0.925, 0.06), // Encke gap
      RingBand(0.925, 0.972, 0.55), // A ring outer
      RingBand(0.972, 0.990, 0.03), // Roche division
      RingBand(0.990, 1.000, 0.35), // F ring thread
    ],
    // Uranus: inner 1.6 R, outer 2.1 R
    'uranus': [
      RingBand(0.000, 0.100, 0.05),
      RingBand(0.100, 0.115, 0.55), // 6/5/4 group
      RingBand(0.115, 0.300, 0.05),
      RingBand(0.300, 0.320, 0.60), // alpha + beta
      RingBand(0.320, 0.550, 0.05),
      RingBand(0.550, 0.570, 0.55), // eta/gamma/delta
      RingBand(0.570, 0.790, 0.05),
      RingBand(0.790, 0.830, 1.00), // epsilon (dominant)
      RingBand(0.830, 1.000, 0.03),
    ],
    // Jupiter: inner 1.4 R, outer 1.8 R
    'jupiter': [
      RingBand(0.000, 0.700, 0.30), // halo
      RingBand(0.700, 0.950, 1.00), // main ring
      RingBand(0.950, 1.000, 0.45), // gossamer edge
    ],
    // Neptune: inner 1.7 R, outer 2.4 R
    'neptune': [
      RingBand(0.000, 0.210, 0.30), // Galle (broad, faint)
      RingBand(0.210, 0.620, 0.06),
      RingBand(0.620, 0.650, 0.80), // Le Verrier
      RingBand(0.650, 0.960, 0.10), // Lassell/Arago sheet
      RingBand(0.960, 1.000, 1.00), // Adams (arcs, drawn full)
    ],
  };

  void update(WorldSnapshot snap, FloatingOrigin origin,
      {SceneCamera? camera}) {
    final seen = <String>{};
    for (final b in snap.bodies.values) {
      final spec = _rings[b.id];
      if (spec == null) continue;
      seen.add(b.id);

      final bands = _bands[b.id] ?? const [RingBand(0, 1, 1)];
      final node = _nodes.putIfAbsent(b.id, () {
        final n = fs.Node(
          mesh: fs.Mesh(
            _bandedAnnulus(spec.$1, spec.$2, bands,
                _premul(spec.$4, _intensity[b.id] ?? 0.3)),
            // Vertex colours carry the banding; material stays white.
            DepthSafeUnlitMaterial()
              ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
              ..alphaMode = fs.AlphaMode.blend
              ..doubleSided = true,
          ),
        );
        _scene.add(n);
        return n;
      });

      // Rings live in the body's EQUATORIAL plane (real rings are orbiting
      // debris in the equator), so the ring plane comes straight from the
      // body's orientation quaternion — spin about the axis is invisible
      // for a flat annulus, and the axial tilt (now in the domain data for
      // the gas giants) tilts rings and equator together.
      final bodyQuat = Quaternion(b.qw, b.qx, b.qy, b.qz);
      node.localTransform = vm.Matrix4.compose(
        origin.worldToScene(Vector3(b.px, b.py, b.pz)),
        quatToScene(bodyQuat),
        vm.Vector3.all(lengthToScene(b.radius)),
      );

      // Asteroid field: spawn/refresh when the camera is near the ring
      // plane and radially inside the annulus (plus margin).
      final field = _rocks.putIfAbsent(
          b.id, () => _RockField(spec.$1, spec.$2, bands, spec.$4));
      field.update(
        parent: node,
        body: b,
        bodyQuat: bodyQuat,
        origin: origin,
        camera: camera,
      );
    }

    _nodes.removeWhere((id, node) {
      if (seen.contains(id)) return false;
      _scene.remove(node);
      _rocks.remove(id);
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
  /// radius multiples, one quad strip per [RingBand] with premultiplied
  /// vertex colours (base colour x band alpha; hard edges by duplicated
  /// rows). BOTH triangle windings are emitted: translucent materials
  /// always backface-cull (Material.bind:
  /// `cullBackFace = !doubleSided || !isOpaque()`), so a single-winding
  /// flat ring vanishes from one side of the ring plane — doubleSided
  /// cannot save a blended material.
  static fs.MeshGeometry _bandedAnnulus(
    double inner,
    double outer,
    List<RingBand> bands,
    vm.Vector4 base, {
    int segments = 96,
  }) {
    final positions = <double>[];
    final colors = <double>[];
    final indices = <int>[];

    void ring(double t, vm.Vector4 c) {
      final r = inner + t * (outer - inner);
      for (var s = 0; s <= segments; s++) {
        final a = 2 * math.pi * s / segments;
        positions.addAll([r * math.cos(a), r * math.sin(a), 0.0]);
        colors.addAll([c.x, c.y, c.z, c.w]);
      }
    }

    for (final band in bands) {
      final c = band.argb == null
          ? vm.Vector4(base.x * band.alpha, base.y * band.alpha,
              base.z * band.alpha, base.w * band.alpha)
          : () {
              final argb = band.argb!;
              final a = base.w * band.alpha;
              return vm.Vector4(((argb >> 16) & 0xff) / 255.0 * a,
                  ((argb >> 8) & 0xff) / 255.0 * a, (argb & 0xff) / 255.0 * a, a);
            }();
      final row0 = positions.length ~/ 3;
      ring(band.t0, c);
      ring(band.t1, c);
      final rowN = row0 + segments + 1;
      for (var s = 0; s < segments; s++) {
        final i0 = row0 + s, i1 = row0 + s + 1;
        final o0 = rowN + s, o1 = rowN + s + 1;
        indices.addAll([i0, o0, i1, i1, o0, o1]); // top face
        indices.addAll([i0, i1, o0, o0, i1, o1]); // bottom face (reversed)
      }
    }
    return fs.MeshGeometry.fromArrays(
      positions: Float32List.fromList(positions),
      colors: Float32List.fromList(colors),
      indices: indices,
    );
  }
}

/// The fly-through asteroid layer for one ring: a hardware-instanced set of
/// low-poly rocks scattered deterministically in the ring plane around the
/// camera. OPAQUE by constraint — the translucent pass explodes instanced
/// items into one draw call per instance, while the opaque path is 1-2
/// calls total. The distance fade is therefore a SCALE fade: rocks shrink
/// to nothing toward the visibility radius and the 2D annulus underneath
/// carries the far field.
///
/// Placement is a seeded hash over ring-plane grid cells, so the field is
/// stable frame to frame and only REBUILDS when the camera has moved half a
/// cell (copy-on-write discipline: no per-frame instance churn while
/// coasting). Rock density follows the band profile — the Cassini division
/// is genuinely empty.
class _RockField {
  _RockField(this.inner, this.outer, this.bands, this.argb);

  final double inner, outer;
  final List<RingBand> bands;
  final int argb;

  fs.Node? _node;
  fs.InstancedMesh? _mesh;
  // Camera position (ring-local, body radii) at the last rebuild.
  vm.Vector3? _builtAt;

  // All lengths in BODY RADII (the ring node's scale maps them to scene
  // units). ~0.05 R visibility on Saturn = ~2900 km of rock field. Rock
  // sizes are game-scaled (tens of km — physical ring debris is metres and
  // would be invisible at any flyable speed).
  static const double _visR = 0.05;
  static const double _cell = 0.01;
  static const int _rocksPerCell = 12;
  static const double _thickness = 0.004; // +/- around the plane
  static const double _rockMin = 0.0008, _rockMax = 0.003;

  void update({
    required fs.Node parent,
    required BodySnapshot body,
    required Quaternion bodyQuat,
    required FloatingOrigin origin,
    SceneCamera? camera,
  }) {
    // Camera in the ring's LOCAL frame (body radii), double precision:
    // eye is focus-relative; re-base to the body, un-rotate, normalise.
    if (camera == null) {
      _despawn(parent);
      return;
    }
    final eyeRelBody = camera.eyeOffset -
        origin.worldToRel(Vector3(body.px, body.py, body.pz));
    final local = bodyQuat.conjugate.rotate(eyeRelBody) * (1.0 / body.radius);
    final radial = math.sqrt(local.x * local.x + local.y * local.y);

    final active = local.z.abs() < 0.06 &&
        radial > inner - 0.1 &&
        radial < outer + 0.1;
    if (!active) {
      _despawn(parent);
      return;
    }

    final eye = vm.Vector3(local.x, local.y, local.z);
    if (_builtAt != null && (_builtAt! - eye).length < _cell * 0.5) {
      return; // field still valid — zero work while coasting
    }
    _builtAt = eye;

    // Climbing out of the ring plane shrinks the whole field smoothly
    // instead of popping at the activation edge.
    final vFade = (1.0 - local.z.abs() / 0.06).clamp(0.0, 1.0);

    final mesh = _mesh ??= fs.InstancedMesh(
      geometry: uvSphereZUp(segments: 6, rings: 4),
      material: fs.PhysicallyBasedMaterial()
        ..baseColorFactor = _rockColor()
        ..roughnessFactor = 1.0
        ..metallicFactor = 0.0,
    );
    if (_node == null) {
      final n = fs.Node()..addComponent(fs.InstancedMeshComponent(mesh));
      parent.add(n);
      _node = n;
    }

    mesh.clearInstances();
    final cells = (_visR / _cell).ceil();
    final cx = (local.x / _cell).floor(), cy = (local.y / _cell).floor();
    for (var gx = cx - cells; gx <= cx + cells; gx++) {
      for (var gy = cy - cells; gy <= cy + cells; gy++) {
        for (var k = 0; k < _rocksPerCell; k++) {
          final h1 = _hash(gx, gy, k * 4);
          final h2 = _hash(gx, gy, k * 4 + 1);
          final h3 = _hash(gx, gy, k * 4 + 2);
          final h4 = _hash(gx, gy, k * 4 + 3);
          final px = (gx + h1) * _cell;
          final py = (gy + h2) * _cell;
          final r = math.sqrt(px * px + py * py);
          if (r < inner || r > outer) continue;
          // Density follows the band profile: gaps stay empty.
          final t = (r - inner) / (outer - inner);
          if (h3 > _bandAlpha(t) * 1.15 + 0.02) continue;

          final dx = px - local.x, dy = py - local.y;
          final pz = (h4 - 0.5) * 2.0 * _thickness;
          final dz = pz - local.z;
          final dist = math.sqrt(dx * dx + dy * dy + dz * dz);
          // Scale fade toward the visibility edge (the "2D ring takes
          // over" transition — per-instance alpha doesn't exist for the
          // hardware-instanced path, scale does).
          final fade = (1.0 - dist / _visR).clamp(0.0, 1.0) * vFade;
          if (fade <= 0.01) continue;
          final size = (_rockMin + h1 * h2 * (_rockMax - _rockMin)) *
              (fade * (2.0 - fade)); // smooth ease-out
          // Potato rocks: irregular non-uniform scale + arbitrary spin.
          final m = vm.Matrix4.compose(
            vm.Vector3(px, py, pz),
            vm.Quaternion.axisAngle(
                vm.Vector3(h2 - 0.5, h3 - 0.5, h4 - 0.5).normalized(),
                h1 * math.pi * 2),
            vm.Vector3(size * (0.6 + h3 * 0.8), size * (0.6 + h4 * 0.8),
                size * (0.6 + h1 * 0.8)),
          );
          mesh.addInstance(m);
        }
      }
    }
  }

  void _despawn(fs.Node parent) {
    final n = _node;
    if (n != null) {
      parent.remove(n);
      _node = null;
      _mesh = null;
      _builtAt = null;
    }
  }

  double _bandAlpha(double t) {
    for (final b in bands) {
      if (t >= b.t0 && t < b.t1) return b.alpha;
    }
    return 0.0;
  }

  vm.Vector4 _rockColor() {
    // Rocks in the ring's hue, darkened (they are lit by the sun via PBR).
    return vm.Vector4(((argb >> 16) & 0xff) / 255.0 * 0.75,
        ((argb >> 8) & 0xff) / 255.0 * 0.75, (argb & 0xff) / 255.0 * 0.75, 1);
  }

  /// Deterministic cell hash -> [0, 1). Stable across frames and camera
  /// moves, so rocks never pop or teleport within the visibility radius.
  static double _hash(int x, int y, int k) {
    var h = x * 374761393 + y * 668265263 + k * 2147483647;
    h = (h ^ (h >> 13)) * 1274126177;
    h = h ^ (h >> 16);
    return (h & 0xFFFFFF) / 16777216.0;
  }
}
