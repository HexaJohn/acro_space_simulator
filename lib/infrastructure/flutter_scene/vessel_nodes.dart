import 'dart:math' as math;
import 'dart:typed_data';

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

  /// Model-unit -> metre factor for [_craftModel]. Live-tunable via
  /// `ext.acro.camera?glbScale=` while calibrating a new export; the
  /// transform reapplies every frame so changes land immediately.
  /// (apollo.glb calibrated by screenshot: 0.0002 -> ~11 m craft.)
  static double glbUnitScale = 0.02;
  final Map<String, fs.Node> _glbModels = {};
  final Set<String> _glbLoading = {};
  final Set<String> _glbApplied = {};
  static bool _glbFailed = false; // missing/corrupt asset: stay procedural

  void update(WorldSnapshot snap, FloatingOrigin origin) {
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

  void _ensureCraftModel(String vesselId, fs.Node parent) {
    if (_glbFailed || _glbApplied.contains(vesselId) || _glbLoading.contains(vesselId)) {
      return;
    }
    _glbLoading.add(vesselId);
    fsb.loadFscenebAsset(_craftModel)
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
    if (v.parts.isEmpty) {
      // No part detail: a lone hull cone, like the software renderer's ship
      // glyph (~10 m).
      vesselNode.add(
        fs.Node(mesh: fs.Mesh(PartPrimitives.cone(), PartPrimitives.hull()))
          ..localTransform = _partTransform(0, 0, 0, 10.0),
      );
      return;
    }
    for (final p in v.parts) {
      // Primitives are unit-metre; real craft parts read better at a few
      // metres (a 1 m cube is sub-pixel at typical camera ranges).
      vesselNode.add(
        fs.Node(mesh: PartPrimitives.forType(p.type))..localTransform = _partTransform(p.ox, p.oy, p.oz, 3.0),
      );
    }
  }

  /// Part offset is metres in the vessel body frame; scene units are km.
  vm.Matrix4 _partTransform(double ox, double oy, double oz, double scaleM) => vm.Matrix4.compose(
    vm.Vector3(lengthToScene(ox), lengthToScene(oy), lengthToScene(oz)),
    vm.Quaternion.identity(),
    vm.Vector3.all(lengthToScene(scaleM)),
  );
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
