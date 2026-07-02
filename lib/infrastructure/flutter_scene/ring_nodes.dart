import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../adapters/presenters/camera_view.dart';
import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';
import 'coord_convert.dart';
import 'depth_materials.dart';
import 'scene_textures.dart';
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

/// Planetary ring systems: a flat annulus running shaders/ring.frag — the
/// radial band profile is evaluated PER FRAGMENT (fuzzy smoothstep edges,
/// resolution independent of tessellation) with a soft camera-centred hole
/// where the instanced asteroid field spawns, so sheet and rocks
/// cross-fade — plus the fly-through rock field itself.
///
/// Ring extents/colour mirror the software renderer's tables in
/// `TopDownSnapshotPresenter` (source of truth for extents; banding and
/// rocks are 3D-backend-only).
class RingNodes {
  RingNodes(this._scene, this._textures);

  final fs.Scene _scene;
  final SceneTextures _textures;

  final Map<String, _RingSheet> _sheets = {};
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
  /// the Le Verrier and Adams ringlets. Max 12 bands (shader array size).
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

  /// One-line diagnostic for the HUD (nearest ringed body's field state):
  /// "saturn z=1.2km r=1.65R fade=0.88 rocks=2116". Null when no ringed
  /// body is within diagnostic interest (camera > 3 body radii off-plane).
  static String? debugLine;

  /// The compiled ring fragment shader (same bundle as the atmosphere).
  /// Sheets don't spawn until it's loaded.
  static Object? _shader;
  static Future<void>? _loading;

  static Future<void> loadShader() => _loading ??= () async {
        final library = await gpu.loadShaderLibraryAsync(
          'build/shaderbundles/acro.shaderbundle',
        );
        _shader = library?['RingFragment'];
        if (_shader == null) {
          throw StateError(
            'RingFragment missing from acro.shaderbundle — the '
            'hook/build.dart shader compile should have produced it.',
          );
        }
      }();

  void update(WorldSnapshot snap, FloatingOrigin origin,
      {SceneCamera? camera, Vector3? starWorld}) {
    final shader = _shader;
    if (shader == null) return; // bundle still loading
    debugLine = null;
    var debugDist = double.infinity;
    final seen = <String>{};
    for (final b in snap.bodies.values) {
      final spec = _rings[b.id];
      if (spec == null) continue;
      seen.add(b.id);

      final bands = _bands[b.id] ?? const [RingBand(0, 1, 1)];
      final sheet = _sheets.putIfAbsent(b.id, () {
        final s = _RingSheet(shader, spec.$1, spec.$2);
        _scene.add(s.node);
        return s;
      });

      // Rings live in the body's EQUATORIAL plane (real rings are orbiting
      // debris in the equator), so the ring plane comes straight from the
      // body's orientation quaternion — spin about the axis is invisible
      // for a flat annulus, and the axial tilt (now in the domain data for
      // the gas giants) tilts rings and equator together.
      final bodyQuat = Quaternion(b.qw, b.qx, b.qy, b.qz);
      final centreScene = origin.worldToScene(Vector3(b.px, b.py, b.pz));
      sheet.node.localTransform = vm.Matrix4.compose(
        centreScene,
        quatToScene(bodyQuat),
        vm.Vector3.all(lengthToScene(b.radius)),
      );

      // Asteroid field first: its fade drives the sheet's camera hole.
      final field = _rocks.putIfAbsent(b.id,
          () => _RockField(spec.$1, spec.$2, bands, spec.$4, _textures));
      field.update(
        scene: _scene,
        body: b,
        bodyQuat: bodyQuat,
        origin: origin,
        camera: camera,
      );

      // Nearest ringed body wins the HUD diagnostic line.
      if (camera != null) {
        final d = (camera.eyeOffset -
                origin.worldToRel(Vector3(b.px, b.py, b.pz)))
            .length;
        if (d < debugDist && d < 3.5 * spec.$2 * b.radius) {
          debugDist = d;
          debugLine = '${b.id}  z=${(field.lastZM / 1000).toStringAsFixed(1)}km '
              'r=${(field.lastRadialM / b.radius).toStringAsFixed(2)}R '
              'fade=${field.fade.toStringAsFixed(2)} '
              'rocks=${field.instanceCount}';
        }
      }

      sheet.updateUniforms(
        centreScene: centreScene,
        axisU: bodyQuat.rotate(Vector3.unitX),
        axisV: bodyQuat.rotate(Vector3.unitY),
        innerScene: lengthToScene(spec.$1 * b.radius),
        outerScene: lengthToScene(spec.$2 * b.radius),
        eyeScene: camera == null
            ? vm.Vector3.zero()
            : relToScene(camera.eyeOffset),
        // The hole where the rocks live: many times the field radius so
        // the sheet never sits in your face while flying with the debris;
        // scaled by the field's vertical fade so sheet and rocks
        // cross-fade together when climbing out of the plane.
        holeScene: field.fade * lengthToScene(_RockField.visRM) * 10.0,
        bands: bands,
        baseArgb: spec.$4,
        intensity: _intensity[b.id] ?? 0.3,
        toSun: starWorld == null
            ? Vector3.unitX
            : (starWorld - Vector3(b.px, b.py, b.pz)).normalized,
        planetRadiusScene: lengthToScene(b.radius),
      );
    }

    _sheets.removeWhere((id, sheet) {
      if (seen.contains(id)) return false;
      _scene.remove(sheet.node);
      _rocks.remove(id);
      return true;
    });
  }
}

/// The shader-driven ring sheet node: a plain flat annulus (both windings —
/// translucent materials always backface-cull, so a single winding vanishes
/// from one side of the plane) whose banding lives entirely in
/// shaders/ring.frag via the RingInfo uniform block.
class _RingSheet {
  _RingSheet(Object shader, double inner, double outer) {
    _material = DepthSafeShaderMaterial(fragmentShader: shader as gpu.Shader);
    node = fs.Node(mesh: fs.Mesh(_annulus(inner, outer), _material));
  }

  late final fs.Node node;
  late final DepthSafeShaderMaterial _material;

  final Float32List _u = Float32List(124); // 31 x vec4, std140

  void updateUniforms({
    required vm.Vector3 centreScene,
    required Vector3 axisU,
    required Vector3 axisV,
    required double innerScene,
    required double outerScene,
    required vm.Vector3 eyeScene,
    required double holeScene,
    required List<RingBand> bands,
    required int baseArgb,
    required double intensity,
    required Vector3 toSun,
    required double planetRadiusScene,
  }) {
    _u[0] = centreScene.x;
    _u[1] = centreScene.y;
    _u[2] = centreScene.z;
    _u[3] = innerScene;
    _u[4] = axisU.x;
    _u[5] = axisU.y;
    _u[6] = axisU.z;
    _u[7] = outerScene;
    _u[8] = axisV.x;
    _u[9] = axisV.y;
    _u[10] = axisV.z;
    _u[11] = holeScene;
    _u[12] = eyeScene.x;
    _u[13] = eyeScene.y;
    _u[14] = eyeScene.z;
    _u[15] = 0.006; // band edge fuzz (t units)
    final n = math.min(bands.length, 12);
    for (var i = 0; i < 12; i++) {
      final o = 16 + i * 4;
      final co = 64 + i * 4;
      if (i < n) {
        final band = bands[i];
        _u[o] = band.t0;
        _u[o + 1] = band.t1;
        _u[o + 2] = band.alpha * intensity;
        _u[o + 3] = 0;
        final argb = band.argb ?? baseArgb;
        _u[co] = ((argb >> 16) & 0xff) / 255.0;
        _u[co + 1] = ((argb >> 8) & 0xff) / 255.0;
        _u[co + 2] = (argb & 0xff) / 255.0;
        _u[co + 3] = 0;
      } else {
        _u[o] = 0;
        _u[o + 1] = 0;
        _u[o + 2] = 0;
        _u[o + 3] = 0;
        _u[co] = 0;
        _u[co + 1] = 0;
        _u[co + 2] = 0;
        _u[co + 3] = 0;
      }
    }
    _u[112] = n.toDouble();
    _u[113] = 0;
    _u[114] = 0;
    _u[115] = 0;
    // vec4 sun_planet: toward-sun direction + shadow-caster radius.
    _u[116] = toSun.x;
    _u[117] = toSun.y;
    _u[118] = toSun.z;
    _u[119] = planetRadiusScene;
    _u[120] = 0;
    _u[121] = 0;
    _u[122] = 0;
    _u[123] = 0;
    _material.setUniformBlockFromFloats('RingInfo', _u);
  }

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

/// The fly-through asteroid layer for one ring: a hardware-instanced set of
/// low-poly rocks scattered deterministically in the ring plane around the
/// camera. OPAQUE by constraint — the translucent pass explodes instanced
/// items into one draw call per instance, while the opaque path is 1-2
/// calls total. The distance fade is therefore a SCALE fade: rocks shrink
/// to nothing toward the visibility radius, and the ring sheet opens a
/// matching camera hole (see ring.frag) so rocks REPLACE the sheet rather
/// than floating on top of it.
///
/// Placement is a seeded hash over ring-plane grid cells, so the field is
/// stable frame to frame and only REBUILDS when the camera has moved half a
/// cell (copy-on-write discipline: no per-frame instance churn while
/// coasting). Rock density follows the band profile — the Cassini division
/// is genuinely empty.
class _RockField {
  _RockField(this.inner, this.outer, this.bands, this.argb, this.textures);

  final double inner, outer;
  final List<RingBand> bands;
  final int argb;
  final SceneTextures textures;

  fs.Node? _node;
  fs.InstancedMesh? _mesh;
  fs.PhysicallyBasedMaterial? _rockMaterial;
  fs.Scene? _inScene;
  // Camera position (ring-local METRES) at the last rebuild.
  Vector3? _builtAt;
  // Ring-local anchor (metres) the node + instance offsets are built from.
  Vector3? _anchor;

  /// Current layer strength 0..1 (the vertical plane-exit fade); the ring
  /// sheet scales its camera hole by this so the two cross-fade.
  double fade = 0.0;

  /// Last-measured camera state in the ring frame (HUD diagnostics).
  double lastZM = double.nan;
  double lastRadialM = double.nan;
  int get instanceCount => _mesh?.instanceCount ?? 0;

  // All lengths in METRES, ring-local. Real ring debris tops out at a few
  // metres diameter, so the whole field lives within a couple of km of the
  // camera — far below float32 resolution in a planet-scaled frame. The
  // field therefore hangs off its OWN scene-root node anchored at the
  // camera's grid cell (double-precision anchor, metre-scale offsets).
  static const double visRM = 2200.0;
  static const double _cellM = 220.0;
  static const int _rocksPerCell = 7;
  static const double _thicknessM = 60.0; // +/- around the plane
  static const double _rockMinM = 0.4, _rockMaxM = 2.6; // radii (0.8-5 m)

  void update({
    required fs.Scene scene,
    required BodySnapshot body,
    required Quaternion bodyQuat,
    required FloatingOrigin origin,
    SceneCamera? camera,
  }) {
    // Camera in the ring's LOCAL frame (metres), double precision: eye is
    // focus-relative; re-base to the body, un-rotate.
    if (camera == null) {
      _despawn();
      return;
    }
    final bodyWorld = Vector3(body.px, body.py, body.pz);
    final eyeRelBody = camera.eyeOffset - origin.worldToRel(bodyWorld);
    final local = bodyQuat.conjugate.rotate(eyeRelBody);
    final radialM = math.sqrt(local.x * local.x + local.y * local.y);
    final innerM = inner * body.radius, outerM = outer * body.radius;
    lastZM = local.z;
    lastRadialM = radialM;

    // Wide vertical activation/fade band: approaching the plane eases the
    // rocks in (and the sheet's hole open) over tens of km, not a snap.
    const fadeBandM = 10000.0;
    final active = local.z.abs() < fadeBandM &&
        radialM > innerM - 50000 &&
        radialM < outerM + 50000;
    if (!active) {
      _despawn();
      return;
    }

    // Climbing out of the ring plane shrinks the whole field smoothly
    // instead of popping at the activation edge; the sheet's camera hole
    // follows the same fade.
    fade = (1.0 - local.z.abs() / fadeBandM).clamp(0.0, 1.0);

    // The anchor transform must refresh EVERY frame: the floating origin
    // follows the focus and the ring's body moves km/s along its orbit —
    // a coasting-frame skip left the field at a stale scene position
    // (kilometres off within a second; the rocks were simply never where
    // the camera was).
    final anchor = _anchor;
    if (_node != null && anchor != null) {
      _node!.localTransform = vm.Matrix4.compose(
        origin.worldToScene(bodyWorld + bodyQuat.rotate(anchor)),
        quatToScene(bodyQuat),
        vm.Vector3.all(1.0),
      );
    }

    if (_builtAt != null && (_builtAt! - local).length < _cellM * 0.5) {
      return; // field still valid — zero instance work while coasting
    }
    _builtAt = local;

    final mesh = _mesh ??= fs.InstancedMesh(
      geometry: uvSphereZUp(segments: 6, rings: 4),
      // A slice of the Moon's albedo gives the rocks cratered texture
      // instead of flat colour; the ring-hued base factor tints it. The
      // map may still be decoding on first spawn — retried on rebuilds.
      material: _rockMaterial ??= fs.PhysicallyBasedMaterial()
        ..baseColorTexture = textures.texture('moon')
        ..baseColorFactor = _rockColor()
        ..roughnessFactor = 1.0
        ..metallicFactor = 0.0,
    );
    final mat = _rockMaterial;
    if (mat != null && mat.baseColorTexture == null) {
      mat.baseColorTexture = textures.texture('moon');
    }
    if (_node == null) {
      final n = fs.Node()..addComponent(fs.InstancedMeshComponent(mesh));
      scene.add(n);
      _node = n;
      _inScene = scene;
    }

    // Anchor the node at the camera's grid cell centre, in the ring plane:
    // world position computed in doubles, instance offsets stay metre-
    // scale floats. (Per-frame transform refresh above uses this anchor.)
    final ax = ((local.x / _cellM).floor() + 0.5) * _cellM;
    final ay = ((local.y / _cellM).floor() + 0.5) * _cellM;
    _anchor = Vector3(ax, ay, 0);
    _node!.localTransform = vm.Matrix4.compose(
      origin.worldToScene(bodyWorld + bodyQuat.rotate(_anchor!)),
      quatToScene(bodyQuat),
      vm.Vector3.all(1.0),
    );

    mesh.clearInstances();
    final cells = (visRM / _cellM).ceil();
    final cx = (local.x / _cellM).floor(), cy = (local.y / _cellM).floor();
    for (var gx = cx - cells; gx <= cx + cells; gx++) {
      for (var gy = cy - cells; gy <= cy + cells; gy++) {
        for (var k = 0; k < _rocksPerCell; k++) {
          final h1 = _hash(gx, gy, k * 4);
          final h2 = _hash(gx, gy, k * 4 + 1);
          final h3 = _hash(gx, gy, k * 4 + 2);
          final h4 = _hash(gx, gy, k * 4 + 3);
          final pxM = (gx + h1) * _cellM;
          final pyM = (gy + h2) * _cellM;
          final rM = math.sqrt(pxM * pxM + pyM * pyM);
          if (rM < innerM || rM > outerM) continue;
          // Density follows the band profile: gaps stay empty.
          final t = (rM - innerM) / (outerM - innerM);
          if (h3 > _bandAlpha(t) * 1.15 + 0.02) continue;

          final pzM = (h4 - 0.5) * 2.0 * _thicknessM;
          final dx = pxM - local.x, dy = pyM - local.y, dz = pzM - local.z;
          final distM = math.sqrt(dx * dx + dy * dy + dz * dz);
          // Scale fade toward the visibility edge (the "2D ring takes
          // over" transition — per-instance alpha doesn't exist for the
          // hardware-instanced path, scale does).
          final f = (1.0 - distM / visRM).clamp(0.0, 1.0) * fade;
          if (f <= 0.01) continue;
          final sizeScene = lengthToScene(
              (_rockMinM + h1 * h2 * (_rockMaxM - _rockMinM)) *
                  (f * (2.0 - f))); // smooth ease-out
          // Potato rocks: irregular non-uniform scale + arbitrary spin.
          // Offsets are node-relative (anchor at the camera's cell).
          final m = vm.Matrix4.compose(
            vm.Vector3(lengthToScene(pxM - ax), lengthToScene(pyM - ay),
                lengthToScene(pzM)),
            vm.Quaternion.axisAngle(
                vm.Vector3(h2 - 0.5, h3 - 0.5, h4 - 0.5).normalized(),
                h1 * math.pi * 2),
            vm.Vector3(sizeScene * (0.6 + h3 * 0.8),
                sizeScene * (0.6 + h4 * 0.8), sizeScene * (0.6 + h1 * 0.8)),
          );
          mesh.addInstance(m);
        }
      }
    }
  }

  void _despawn() {
    fade = 0.0;
    final n = _node;
    if (n != null) {
      _inScene?.remove(n);
      _node = null;
      _mesh = null;
      _rockMaterial = null;
      _builtAt = null;
      _anchor = null;
      _inScene = null;
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
