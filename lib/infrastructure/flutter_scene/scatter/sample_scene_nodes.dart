// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../../domain/scatter/prop_catalog.dart';
import '../../../domain/scatter/prop_model.dart';
import '../../../domain/scatter/sample_scene_layout.dart';
import '../../../domain/scatter/scatter_instance.dart';
import '../../../domain/shared/quaternion.dart';
import '../../../domain/shared/vector3.dart';
import '../coord_convert.dart';
import 'scatter_prop_library.dart';
import 'scatter_textures.dart';

/// Stats for the sample scene HUD.
class SampleSceneStats {
  const SampleSceneStats({
    required this.instances,
    required this.byLayer,
    required this.drawCalls,
    required this.triangles,
    required this.biome,
  });

  final int instances;
  final Map<String, int> byLayer;
  final int drawCalls;
  final int triangles;
  final String biome;

  static const empty = SampleSceneStats(
      instances: 0, byLayer: {}, drawCalls: 0, triangles: 0, biome: '-');
}

/// Renders the scatter lab's sample-scene diorama: the [SampleSceneLayout]'s
/// terrain patch, meshed, with every placed prop drawn through the same
/// instanced path the flight scene uses.
///
/// The species grid answers "what does one prop look like"; this answers
/// "what does the SYSTEM produce": how a forest clumps, where the rocks go,
/// how ground cover fills between trees — all emergent from the placement
/// rules, nothing arranged by hand.
class SampleSceneNodes {
  SampleSceneNodes(this._scene);

  final fs.Scene _scene;
  final ScatterPropLibrary _library = ScatterPropLibrary.instance;

  final List<fs.Node> _nodes = [];
  SampleSceneLayout? _layout;
  bool _built = false;
  double _builtCameraDistance = double.nan;
  SampleSceneStats stats = SampleSceneStats.empty;

  /// Build (once) and refresh LOD selection on meaningful zoom changes.
  void update({
    required double cameraDistanceM,
    required double fovY,
    required double viewportHeightPx,
  }) {
    if (!ScatterPropLibrary.texturesReady) return;
    final zoomed = _builtCameraDistance.isNaN ||
        (cameraDistanceM - _builtCameraDistance).abs() >
            _builtCameraDistance * 0.05;
    if (_built && !zoomed) return;
    _builtCameraDistance = cameraDistanceM;
    final layout = _layout ??= SampleSceneLayout.resolve();
    _rebuild(
      layout,
      cameraDistanceM: cameraDistanceM,
      fovY: fovY,
      viewportHeightPx: viewportHeightPx,
    );
    _built = true;
  }

  void invalidate() => _built = false;

  void _rebuild(
    SampleSceneLayout layout, {
    required double cameraDistanceM,
    required double fovY,
    required double viewportHeightPx,
  }) {
    _clearNodes();
    _addGround(layout);

    // Group instances by (kind, variant seed, level): an InstancedMesh binds
    // one geometry. Level per KIND from the camera distance — the whole patch
    // is one distance band, so per-instance selection would split batches for
    // no visible difference. Clamped at LOD2: the demo is a close-range
    // diorama and card imposters here would only demonstrate the pop.
    final groups = <(PropKind, int, PropLod), List<ScatterInstance>>{};
    final byLayer = <String, int>{};
    for (final p in layout.instances) {
      final prop = _library.variantFor(p);
      var lod = PropLodSet.lodForApparentPx(prop.lodSet.apparentPx(
        math.max(cameraDistanceM, 1e-3),
        fovY: fovY,
        viewportHeightPx: viewportHeightPx,
      ));
      if (lod == PropLod.billboard) lod = PropLod.lod2;
      groups.putIfAbsent((p.kind, prop.seed, lod), () => []).add(p);
      final layer = SampleSceneLayout.layerOf(p.kind);
      byLayer[layer] = (byLayer[layer] ?? 0) + 1;
    }

    var draws = 1; // the ground
    var triangles = 0;
    groups.forEach((key, list) {
      final (kind, seed, lod) = key;
      final prop = _library.get(kind, seed: seed);
      final transforms = [for (final p in list) _transformOf(layout, p)];
      triangles += prop.lodSet[lod].triangleCount * list.length;
      final solid = prop.solidFor(lod);
      if (solid != null) {
        _addInstanced(
            solid,
            kind.family == PropFamily.rock
                ? _library.stoneMaterial
                : _library.barkMaterial,
            transforms);
        draws++;
      }
      final foliage = prop.foliageFor(lod);
      if (foliage != null) {
        _addInstanced(foliage, _library.foliageMaterial, transforms);
        draws++;
      }
    });

    stats = SampleSceneStats(
      instances: layout.instances.length,
      byLayer: byLayer,
      drawCalls: draws,
      triangles: triangles,
      biome: layout.biomeName,
    );
  }

  /// Patch-local model transform. Unit-scale node discipline: the scene node
  /// carries no scale, so metre-to-scene lives here (see ScatterNodes'
  /// double-scale lesson).
  vm.Matrix4 _transformOf(SampleSceneLayout layout, ScatterInstance p) {
    final local = layout.toLocal(p.positionBF);
    final upLocal = Vector3(
      p.upBF.dot(layout.east),
      p.upBF.dot(layout.north),
      p.upBF.dot(layout.centreDir),
    ).normalized;
    final tilt = _alignZTo(upLocal);
    final spin = Quaternion.axisAngle(Vector3.unitZ, p.yaw);
    final q = tilt * spin;
    return vm.Matrix4.compose(
      vm.Vector3(lengthToScene(local.x), lengthToScene(local.y),
          lengthToScene(local.z)),
      vm.Quaternion(q.x, q.y, q.z, q.w),
      vm.Vector3.all(lengthToScene(p.scale)),
    );
  }

  static Quaternion _alignZTo(Vector3 up) {
    final axis = Vector3.unitZ.cross(up);
    final sin = axis.length;
    if (sin < 1e-9) {
      return up.z >= 0
          ? Quaternion.identity
          : Quaternion.axisAngle(Vector3.unitX, math.pi);
    }
    return Quaternion.axisAngle(axis, math.atan2(sin, up.z));
  }

  /// The terrain patch itself: a height-field grid sampled from the SAME
  /// field the props were placed on, so every prop base meets the ground it
  /// was seated against.
  void _addGround(SampleSceneLayout layout) {
    const n = 48; // vertices per side
    const extent = SampleSceneLayout.patchHalfM * 2.2; // skirt past the props

    final heights = List<double>.filled(n * n, 0);
    for (var j = 0; j < n; j++) {
      for (var i = 0; i < n; i++) {
        final x = (i / (n - 1) - 0.5) * extent;
        final y = (j / (n - 1) - 0.5) * extent;
        heights[j * n + i] = layout.groundHeightAt(x, y);
      }
    }

    final positions = Float32List(n * n * 3);
    final normals = Float32List(n * n * 3);
    final texCoords = Float32List(n * n * 2);
    const step = extent / (n - 1);
    for (var j = 0; j < n; j++) {
      for (var i = 0; i < n; i++) {
        final k = j * n + i;
        final x = (i / (n - 1) - 0.5) * extent;
        final y = (j / (n - 1) - 0.5) * extent;
        positions[k * 3] = lengthToScene(x);
        positions[k * 3 + 1] = lengthToScene(y);
        positions[k * 3 + 2] = lengthToScene(heights[k]);
        // Central-difference normal off the height grid.
        final hxm = heights[j * n + math.max(i - 1, 0)];
        final hxp = heights[j * n + math.min(i + 1, n - 1)];
        final hym = heights[math.max(j - 1, 0) * n + i];
        final hyp = heights[math.min(j + 1, n - 1) * n + i];
        final nv =
            Vector3(-(hxp - hxm) / (2 * step), -(hyp - hym) / (2 * step), 1)
                .normalized;
        normals[k * 3] = nv.x;
        normals[k * 3 + 1] = nv.y;
        normals[k * 3 + 2] = nv.z;
        // ~4 m texture tiles, repeat-sampled by PropSurfaceMaterial.
        texCoords[k * 2] = x / 4.0;
        texCoords[k * 2 + 1] = y / 4.0;
      }
    }
    final indices = Uint16List((n - 1) * (n - 1) * 6);
    var w = 0;
    for (var j = 0; j < n - 1; j++) {
      for (var i = 0; i < n - 1; i++) {
        final a = j * n + i, b = a + 1, c = a + n, d = c + 1;
        // CCW seen from +Z (the engine culls back faces).
        indices[w++] = a;
        indices[w++] = b;
        indices[w++] = c;
        indices[w++] = b;
        indices[w++] = d;
        indices[w++] = c;
      }
    }

    final geometry = fs.MeshGeometry.fromArrays(
      positions: positions,
      normals: normals,
      texCoords: texCoords,
      indices: indices,
    );
    final material = PropSurfaceMaterial()
      ..baseColorTexture = ScatterTextures.stone
      // Earthy tint over the grey stone tile so the ground reads as soil.
      ..baseColorFactor = vm.Vector4(0.62, 0.60, 0.42, 1.0)
      ..roughnessFactor = 1.0
      ..metallicFactor = 0.0;
    final node = fs.Node(mesh: fs.Mesh(geometry, material));
    _scene.add(node);
    _nodes.add(node);
  }

  void _addInstanced(
      fs.MeshGeometry geometry, fs.Material material, List<vm.Matrix4> t) {
    final mesh = fs.InstancedMesh(geometry: geometry, material: material);
    for (final m in t) {
      mesh.addInstance(m);
    }
    final node = fs.Node()..addComponent(fs.InstancedMeshComponent(mesh));
    _scene.add(node);
    _nodes.add(node);
  }

  void _clearNodes() {
    for (final n in _nodes) {
      _scene.remove(n);
    }
    _nodes.clear();
  }

  void dispose() {
    _clearNodes();
    _built = false;
  }
}
