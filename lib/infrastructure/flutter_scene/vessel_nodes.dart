import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_scene/fscene.dart' as fsb;
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';
import 'coord_convert.dart';

/// Maintains one scene node per vessel: a parent node placed at the
/// vessel's world position (dominant-body position + body-relative vessel
/// position) carrying the attitude quaternion, with one child node per part
/// at its body-frame offset.
///
/// Part meshes are procedural primitives from a type-key registry —
/// matching the software renderer's cone/pyramid fidelity — with a cuboid
/// placeholder for unknown keys. Real art can replace registry entries
/// whenever without touching the sync. Sizes are in METRES (converted);
/// vessel body frame is Z-up like everything else.
class VesselNodes {
  VesselNodes(this._scene);

  final fs.Scene _scene;

  final Map<String, fs.Node> _nodes = {};
  // Part-list fingerprint per vessel; rebuild children only when it changes
  // (staging events), not every frame.
  final Map<String, String> _partsKey = {};

  /// Craft model: the Apollo CSM replaces the procedural part composition
  /// once decoded (87 MB — async; primitives show until then). Loaded per
  /// vessel: a Node can't be parented twice.
  ///
  /// `.fsceneb` baked from the licensed .glb by `tool/import_mesh.dart`;
  /// neither format is committed (license bars redistribution), so clones
  /// without the asset stay procedural via [_glbFailed].
  static const String _craftModel = 'assets/mesh/apollo.fsceneb';

  /// Web bundles a SMALLER, lower-res bake: the full 86 MB model breaks the
  /// GitHub Pages server-side build (over an effective size threshold), and
  /// GitHub Release assets aren't CORS-enabled so it can't be fetched at
  /// runtime either. The web bake is fetched into the Pages build by the
  /// release workflow's web job; absent (e.g. not yet published) the craft
  /// stays procedural via [_glbFailed].
  static const String _craftModelWeb = 'assets/mesh/apollo-web.fsceneb';

  /// The model asset for this platform.
  static String get _craftModelAsset => kIsWeb ? _craftModelWeb : _craftModel;

  /// Model-unit -> metre factor for [_craftModel]. Live-tunable via
  /// `ext.acro.camera?glbScale=` while calibrating a new export; the
  /// transform reapplies every frame so changes land immediately.
  /// (apollo.glb calibrated by screenshot: 0.0002 -> ~11 m craft.)
  static double glbUnitScale = 0.02;
  final Map<String, fs.Node> _glbModels = {};
  final Set<String> _glbLoading = {};
  final Set<String> _glbApplied = {};
  static bool _glbFailed = false; // missing/corrupt asset: stay procedural

  /// Per-vessel eclipse of the sun on the craft (dims its materials when it
  /// is in the body's umbra). Applied HERE, not on the scene's global
  /// directional light, so other bodies stay sunlit. Toggle for A/B.
  static bool eclipseCraft = true;

  /// Original baseColorFactor per craft material, captured on first sight so
  /// the eclipse dim can be re-scaled from the true base every frame rather
  /// than accumulating.
  final Map<fs.PhysicallyBasedMaterial, vm.Vector4> _baseColor = {};

  void update(WorldSnapshot snap, FloatingOrigin origin, {Vector3? starWorld}) {
    final seen = <String>{};
    for (final v in snap.vessels.values) {
      final body = snap.bodies[v.body];
      if (body == null) continue; // body not in snapshot: skip this frame
      seen.add(v.id);

      final world = Vector3(body.px + v.px, body.py + v.py, body.pz + v.pz);
      final pos = origin.worldToScene(world);
      final rot = quatToScene(Quaternion(v.qw, v.qx, v.qy, v.qz));

      final node = _nodes.putIfAbsent(v.id, () {
        final n = fs.Node();
        _scene.add(n);
        return n;
      });
      _ensureCraftModel(v.id, node);
      final partsKey = v.parts.map((p) => '${p.type}@${p.ox},${p.oy},${p.oz}').join('|');
      if (!_glbApplied.contains(v.id) && _partsKey[v.id] != partsKey) {
        _partsKey[v.id] = partsKey;
        _rebuildParts(node, v);
      }
      node.localTransform = vm.Matrix4.compose(pos, rot, vm.Vector3.all(1.0));
      _applyEclipse(node, _eclipseFactor(body, v, starWorld));

      // glTF is Y-up; the vessel body frame is Z-up with the nose on +Z.
      // Model units differ per export — [glbUnitScale] converts model
      // units to METRES (sleuthed by screenshot at a known range), then
      // metres to scene km. Reapplied per frame so live calibration via
      // the dev extension takes effect immediately.
      _glbModels[v.id]?.localTransform = vm.Matrix4.compose(
        vm.Vector3.zero(),
        vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), math.pi / 2),
        vm.Vector3.all(lengthToScene(glbUnitScale)),
      );
    }

    _nodes.removeWhere((id, node) {
      if (seen.contains(id)) return false;
      _scene.remove(node);
      _partsKey.remove(id);
      _glbApplied.remove(id);
      _glbModels.remove(id);
      return true;
    });
  }

  /// 1 = full sun, 0 = the craft is deep in [body]'s umbra. The sun is at
  /// infinity and the body is near+huge (71 deg radius in low lunar orbit),
  /// so the craft is shadowed whenever the sun direction falls inside the
  /// body's disc as seen from the craft; fades over the last ~3 deg to the
  /// limb (a soft penumbra).
  double _eclipseFactor(BodySnapshot body, VesselSnapshot v, Vector3? star) {
    if (!eclipseCraft || star == null) return 1.0;
    final pv = Vector3(body.px + v.px, body.py + v.py, body.pz + v.pz);
    final toBody = Vector3(body.px, body.py, body.pz) - pv;
    final dist = toBody.length;
    if (dist <= body.radius) return 1.0; // on/inside the surface
    final ang = math.asin((body.radius / dist).clamp(0.0, 1.0));
    final sunAng = math.acos(
        (star - pv).normalized.dot(toBody / dist).clamp(-1.0, 1.0));
    return ((sunAng - ang) / 0.05).clamp(0.0, 1.0);
  }

  /// Scale every PBR material's base colour under [node] by the eclipse
  /// factor (RGB only; alpha kept), re-derived from the captured original so
  /// it never drifts. Floored so a shadowed craft is very dark but not a
  /// pure-black silhouette (a little earthshine/ambient survives). Metallic
  /// hulls lose their sun highlight this way (F0 = base colour); a dielectric
  /// part keeps a faint ~4% highlight, which reads fine.
  void _applyEclipse(fs.Node node, double e) {
    final mesh = node.mesh;
    if (mesh != null) {
      for (final prim in mesh.primitives) {
        final m = prim.material;
        if (m is fs.PhysicallyBasedMaterial) {
          final base = _baseColor.putIfAbsent(m, () => m.baseColorFactor);
          final f = e >= 1.0 ? 1.0 : e.clamp(0.05, 1.0);
          m.baseColorFactor =
              vm.Vector4(base.r * f, base.g * f, base.b * f, base.a);
        }
      }
    }
    for (final child in node.children) {
      _applyEclipse(child, e);
    }
  }

  void _ensureCraftModel(String vesselId, fs.Node parent) {
    if (_glbFailed || _glbApplied.contains(vesselId) || _glbLoading.contains(vesselId)) {
      return;
    }
    _glbLoading.add(vesselId);
    fsb.loadFscenebAsset(_craftModelAsset)
        .then((model) {
          _glbLoading.remove(vesselId);
          final node = _nodes[vesselId];
          if (node == null) return; // vessel vanished while decoding
          for (final child in List.of(node.children)) {
            node.remove(child);
          }
          node.add(model);
          _glbModels[vesselId] = model;
          _glbApplied.add(vesselId);
        })
        .catchError((Object e) {
          _glbLoading.remove(vesselId);
          _glbFailed = true; // don't hammer a broken asset for every vessel
          // ignore: avoid_print
          print('craft model load failed: $e');
        });
  }

  void _rebuildParts(fs.Node vesselNode, VesselSnapshot v) {
    for (final child in List.of(vesselNode.children)) {
      vesselNode.remove(child);
    }
    // The craft is represented by the Apollo model ([_craftModelAsset]); the
    // procedural stand-in is the same Apollo CSM silhouette, used wherever
    // that model isn't available (no asset, or the web build before its bake
    // decodes). We don't render the raw part list — a generic vessel would
    // need its own registry, but every craft here is the Apollo, so the
    // silhouette reads as the real ship instead of a cluster of grey blocks.
    _addApolloFallback(vesselNode);
  }

  /// A rough Apollo Command + Service Module built from primitives, nose on
  /// +Z: a blunt conical Command Module, a cylindrical Service Module, a
  /// flared SPS engine bell, and a stub high-gain antenna dish — ~11 m, the
  /// same scale as the baked model so the two are interchangeable. Stands in
  /// wherever the .fsceneb isn't available (no asset, or the web build before
  /// its bake decodes).
  void _addApolloFallback(fs.Node vesselNode) {
    void add(fs.MeshGeometry g, fs.Material m, double z, double dia, double len) {
      vesselNode.add(
        fs.Node(mesh: fs.Mesh(g, m))
          ..localTransform = vm.Matrix4.compose(
            vm.Vector3(0, 0, lengthToScene(z)),
            vm.Quaternion.identity(),
            vm.Vector3(lengthToScene(dia), lengthToScene(dia), lengthToScene(len)),
          ),
      );
    }

    // Command Module: blunt cone, apex = nose (wide base mates the SM).
    add(PartPrimitives.cone(), PartPrimitives.hull(), 3.75, 3.9, 3.5);
    // Service Module: cylinder body, same diameter as the CM base.
    add(PartPrimitives.cylinder(), PartPrimitives.hull(), -1.5, 3.9, 7.0);
    // SPS engine bell: flared cone at the aft.
    add(PartPrimitives.cone(flip: true), PartPrimitives.dark(), -5.7, 2.4, 1.8);
    // High-gain antenna: a small dish on a boom off the aft quarter.
    vesselNode.add(
      fs.Node(mesh: fs.Mesh(PartPrimitives.cone(), PartPrimitives.panel()))
        ..localTransform = vm.Matrix4.compose(
          vm.Vector3(lengthToScene(3.0), 0, lengthToScene(-4.0)),
          vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), math.pi / 2),
          vm.Vector3.all(lengthToScene(1.6)),
        ),
    );
  }

}

/// Procedural primitive meshes for part type keys. All geometry is unit
/// scale (1 m before the node's scale), Z-up, centred on the part origin.
class PartPrimitives {
  static final Map<String, fs.Mesh Function()> _registry = {
    'capsule': () => fs.Mesh(cone(), hull()),
    'pod': () => fs.Mesh(cone(), hull()),
    'fuselage': () => fs.Mesh(cylinder(), hull()),
    'tank': () => fs.Mesh(cylinder(), hull()),
    'engine': () => fs.Mesh(cone(flip: true), dark()),
    'wing': () => fs.Mesh(slab(), hull()),
    'panel': () => fs.Mesh(slab(), panel()),
  };

  /// Mesh for a part type key; longest matching registry key wins (so
  /// 'fuselage_mk2' hits 'fuselage'), cuboid placeholder otherwise.
  static fs.Mesh forType(String type) {
    final t = type.toLowerCase();
    for (final e in _registry.entries) {
      if (t.contains(e.key)) return e.value();
    }
    return fs.Mesh(fs.CuboidGeometry(vm.Vector3(1.0, 1.0, 1.0)), hull());
  }

  static fs.Material hull() => fs.PhysicallyBasedMaterial()
    ..baseColorFactor = vm.Vector4(0.75, 0.76, 0.78, 1.0)
    ..roughnessFactor = 0.45
    ..metallicFactor = 0.85;

  static fs.Material dark() => fs.PhysicallyBasedMaterial()
    ..baseColorFactor = vm.Vector4(0.2, 0.2, 0.22, 1.0)
    ..roughnessFactor = 0.6
    ..metallicFactor = 0.9;

  static fs.Material panel() => fs.PhysicallyBasedMaterial()
    ..baseColorFactor = vm.Vector4(0.12, 0.18, 0.45, 1.0)
    ..roughnessFactor = 0.3
    ..metallicFactor = 0.4;

  /// Cone: apex +Z (nose), unit height, unit base diameter. [flip] points
  /// the apex -Z (engine bell).
  static fs.MeshGeometry cone({int segments = 12, bool flip = false}) {
    final s = flip ? -1.0 : 1.0;
    final positions = <double>[];
    final indices = <int>[];
    // Apex + base ring + base centre.
    positions.addAll([0, 0, 0.5 * s]);
    for (var i = 0; i < segments; i++) {
      final a = 2 * math.pi * i / segments;
      positions.addAll([0.5 * math.cos(a), 0.5 * math.sin(a), -0.5 * s]);
    }
    positions.addAll([0, 0, -0.5 * s]);
    final centre = segments + 1;
    for (var i = 0; i < segments; i++) {
      final b0 = 1 + i, b1 = 1 + (i + 1) % segments;
      // Side + base cap; winding flips with s so faces stay outward.
      if (flip) {
        indices.addAll([0, b1, b0, centre, b0, b1]);
      } else {
        indices.addAll([0, b0, b1, centre, b1, b0]);
      }
    }
    return fs.MeshGeometry.fromArrays(positions: Float32List.fromList(positions), indices: indices);
  }

  /// Cylinder along Z: unit height, unit diameter.
  static fs.MeshGeometry cylinder({int segments = 12}) {
    final positions = <double>[];
    final indices = <int>[];
    for (var i = 0; i < segments; i++) {
      final a = 2 * math.pi * i / segments;
      final x = 0.5 * math.cos(a), y = 0.5 * math.sin(a);
      positions.addAll([x, y, 0.5]); // top ring: 2i
      positions.addAll([x, y, -0.5]); // bottom ring: 2i+1
    }
    final top = segments * 2, bottom = segments * 2 + 1;
    positions.addAll([0, 0, 0.5]);
    positions.addAll([0, 0, -0.5]);
    for (var i = 0; i < segments; i++) {
      final j = (i + 1) % segments;
      final t0 = 2 * i, b0 = 2 * i + 1, t1 = 2 * j, b1 = 2 * j + 1;
      indices.addAll([t0, b0, t1, t1, b0, b1]); // side quad
      indices.addAll([top, t0, t1]); // top cap
      indices.addAll([bottom, b1, b0]); // bottom cap
    }
    return fs.MeshGeometry.fromArrays(positions: Float32List.fromList(positions), indices: indices);
  }

  /// Thin slab (wing/panel): 1 x 0.4 x 0.06.
  static fs.MeshGeometry slab() {
    // CuboidGeometry is already a MeshGeometry; non-uniform extents.
    return fs.CuboidGeometry(vm.Vector3(1.0, 0.4, 0.06));
  }
}
