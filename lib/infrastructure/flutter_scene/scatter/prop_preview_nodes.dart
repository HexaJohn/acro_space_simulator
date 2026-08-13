// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../../domain/scatter/prop_catalog.dart';
import '../../../domain/scatter/prop_model.dart';
import '../coord_convert.dart';
import 'scatter_prop_library.dart';

/// What the preview should draw.
class PropPreviewRequest {
  const PropPreviewRequest({
    required this.kind,
    required this.seed,
    required this.gridSide,
    required this.lod,
    required this.autoLod,
    this.sizeM,
    this.varySeeds = true,
  });

  final PropKind kind;
  final int seed;

  /// Instances per side of the square grid. 1 draws a single hero prop.
  final int gridSide;

  /// The level to force when [autoLod] is false.
  final PropLod lod;

  /// Pick the level from the prop's on-screen size, exactly as the real scatter
  /// system will — this is what the preview exists to let you judge.
  final bool autoLod;

  final double? sizeM;

  /// Give each grid cell its own seed. Off shows one individual repeated, which
  /// is how you inspect a single prop from every angle; on shows the variety
  /// the species actually produces.
  final bool varySeeds;

  int get instanceCount => gridSide * gridSide;

  @override
  bool operator ==(Object other) =>
      other is PropPreviewRequest &&
      other.kind == kind &&
      other.seed == seed &&
      other.gridSide == gridSide &&
      other.lod == lod &&
      other.autoLod == autoLod &&
      other.sizeM == sizeM &&
      other.varySeeds == varySeeds;

  @override
  int get hashCode =>
      Object.hash(kind, seed, gridSide, lod, autoLod, sizeM, varySeeds);
}

/// Live statistics for the preview HUD.
class PropPreviewStats {
  const PropPreviewStats({
    required this.instances,
    required this.triangles,
    required this.drawCalls,
    required this.drawnLod,
    required this.byLod,
    required this.heightM,
    required this.radiusM,
    required this.lodTriangles,
    required this.imposterReady,
  });

  final int instances;

  /// Triangles submitted this frame across every instance.
  final int triangles;

  /// Instanced draws issued: solid, foliage, and the billboard batch.
  final int drawCalls;

  /// The mesh level actually bound (see [PropPreviewNodes] on why the preview
  /// draws one level at a time).
  final PropLod drawnLod;

  /// How many instances each level was SELECTED for.
  final Map<PropLod, int> byLod;

  final double heightM;
  final double radiusM;

  /// Per-instance triangle count at each mesh level.
  final Map<PropLod, int> lodTriangles;

  final bool imposterReady;

  static const empty = PropPreviewStats(
    instances: 0,
    triangles: 0,
    drawCalls: 0,
    drawnLod: PropLod.lod0,
    byLod: {},
    heightM: 0,
    radiusM: 0,
    lodTriangles: {},
    imposterReady: false,
  );
}

/// Builds and maintains the scene nodes for the prop preview.
///
/// Deliberately uses the SAME draw path the real scatter system will: one
/// [fs.InstancedMesh] per material for the mesh levels, plus one
/// [fs.BillboardGeometry] batch for every instance that has fallen back to its
/// imposter. Previewing through a simpler path — a node per prop, say — would
/// look fine and tell you nothing about whether a field of them is affordable.
class PropPreviewNodes {
  PropPreviewNodes(this._scene, {this.onChanged});

  /// Called when something landed asynchronously (an imposter bake) that the
  /// owner must rebuild for. Clearing the cached request alone is not enough:
  /// [update] only runs from the widget's build, so without a repaint the
  /// freshly-baked billboard would never be picked up and the HUD would sit on
  /// "baking..." forever.
  final void Function()? onChanged;

  final fs.Scene _scene;
  final ScatterPropLibrary _library = ScatterPropLibrary.instance;

  fs.Node? _solidNode;
  fs.Node? _foliageNode;
  fs.Node? _imposterNode;
  fs.BillboardGeometry? _imposterGeometry;
  PropKind? _imposterKind;

  PropPreviewRequest? _built;
  double _builtCameraDistance = double.nan;
  PropPreviewStats stats = PropPreviewStats.empty;

  /// The world-space radius (m) the current layout occupies, so the screen can
  /// frame it on a species change.
  double layoutRadiusM = 1.0;

  /// Rebuild if anything affecting placement or level selection changed.
  ///
  /// [cameraDistanceM] moves every frame while orbiting, so the automatic-level
  /// path is gated on a RELATIVE change rather than on equality — otherwise the
  /// whole instance set would be rewritten on every frame of a slow zoom, which
  /// is exactly the per-frame instance churn the ring debris field was
  /// carefully built to avoid.
  void update(
    PropPreviewRequest request, {
    required double cameraDistanceM,
    required double fovY,
    required double viewportHeightPx,
  }) {
    if (!ScatterPropLibrary.texturesReady) return;
    final zoomed = _builtCameraDistance.isNaN ||
        (cameraDistanceM - _builtCameraDistance).abs() >
            _builtCameraDistance * 0.02;
    if (_built == request && !(request.autoLod && zoomed)) return;
    _built = request;
    _builtCameraDistance = cameraDistanceM;
    _rebuild(
      request,
      cameraDistanceM: cameraDistanceM,
      fovY: fovY,
      viewportHeightPx: viewportHeightPx,
    );
  }

  /// Force the next [update] to rebuild, and ask the owner to repaint.
  void invalidate() {
    _built = null;
    onChanged?.call();
  }

  void _rebuild(
    PropPreviewRequest request, {
    required double cameraDistanceM,
    required double fovY,
    required double viewportHeightPx,
  }) {
    final side = request.gridSide;
    final props = <ScatterProp>[
      for (var i = 0; i < side * side; i++)
        _library.get(
          request.kind,
          seed: request.varySeeds ? request.seed + i : request.seed,
          sizeM: request.sizeM,
        ),
    ];

    // Spacing comes from what was actually GROWN, not the nominal size, so a
    // tall seed cannot overlap its neighbours.
    final spacing = math.max(
      request.kind.previewSpacingM,
      props.fold<double>(0, (m, p) => math.max(m, p.radiusM)) * 2.2,
    );
    final extent = (side - 1) * spacing;
    layoutRadiusM = math.max(extent * 0.71, props.first.heightM) + spacing;

    // Which level each instance resolves to.
    final counts = <PropLod, int>{};
    final chosen = <PropLod>[];
    for (final p in props) {
      final lod = request.autoLod
          ? PropLodSet.lodForApparentPx(p.lodSet.apparentPx(
              math.max(cameraDistanceM, 1e-3),
              fovY: fovY,
              viewportHeightPx: viewportHeightPx,
            ))
          : request.lod;
      chosen.add(lod);
      counts[lod] = (counts[lod] ?? 0) + 1;
    }

    // An InstancedMesh binds ONE geometry, so a genuinely mixed-level field
    // needs one mesh per level. The preview keeps a single mesh per material
    // and draws every non-imposter instance at the level the majority
    // resolved to: the point here is to judge how a level LOOKS and what it
    // costs, and one grid at one level answers that far more legibly than a
    // grid silently mixing two. The shipping scatter system will instead keep
    // an InstancedMesh per (material, level) pair.
    var drawnLod = request.autoLod ? PropLod.lod0 : request.lod;
    var best = -1;
    counts.forEach((lod, n) {
      if (n > best && lod != PropLod.billboard) {
        best = n;
        drawnLod = lod;
      }
    });
    if (best < 0) drawnLod = PropLod.lod2; // everything went to imposters

    final template = props.first;
    final solidGeom = template.solidFor(drawnLod);
    final foliageGeom = template.foliageFor(drawnLod);

    final transforms = <vm.Matrix4>[];
    final cards = <_ImposterCard>[];
    final scale = lengthToScene(1.0);

    for (var i = 0; i < props.length; i++) {
      final gx = i % side, gy = i ~/ side;
      final x = gx * spacing - extent * 0.5;
      final y = gy * spacing - extent * 0.5;
      final p = props[i];

      if (chosen[i] == PropLod.billboard) {
        final tex = p.imposterTexture;
        if (tex != null) {
          cards.add(_ImposterCard(
            centre: vm.Vector3(
              lengthToScene(x),
              lengthToScene(y),
              // BillboardGeometry places a quad by its CENTRE, but a prop's
              // origin is its base, so the card is lifted half its height.
              lengthToScene(p.lodSet.imposter.heightM * 0.5),
            ),
            width: lengthToScene(p.lodSet.imposter.widthM),
            height: lengthToScene(p.lodSet.imposter.heightM),
          ));
        }
        continue;
      }

      // A per-instance yaw so a grid of one seed still reads as a stand rather
      // than a row of clones.
      transforms.add(vm.Matrix4.compose(
        vm.Vector3(lengthToScene(x), lengthToScene(y), 0),
        vm.Quaternion.axisAngle(vm.Vector3(0, 0, 1), _yawFor(i, request.seed)),
        // Meshes are generated in METRES; the scene renders in kilometres
        // (kRenderScale), so the per-instance transform carries the conversion
        // and the geometry itself stays scale-agnostic.
        vm.Vector3.all(scale),
      ));
    }

    _solidNode = _swapInstanced(
      _solidNode,
      geometry: solidGeom,
      material: request.kind.family == PropFamily.rock
          ? _library.stoneMaterial
          : _library.barkMaterial,
      transforms: transforms,
    );
    _foliageNode = _swapInstanced(
      _foliageNode,
      geometry: foliageGeom,
      material: _library.foliageMaterial,
      transforms: transforms,
    );
    _syncImposters(cards, request.kind);

    final perInstance = template.lodSet[drawnLod].triangleCount;
    var draws = 0;
    if (solidGeom != null && transforms.isNotEmpty) draws++;
    if (foliageGeom != null && transforms.isNotEmpty) draws++;
    if (cards.isNotEmpty) draws++;

    stats = PropPreviewStats(
      instances: props.length,
      triangles: perInstance * transforms.length + cards.length * 2,
      drawCalls: draws,
      drawnLod: drawnLod,
      byLod: counts,
      heightM: template.heightM,
      radiusM: template.radiusM,
      lodTriangles: {
        for (final lod in [PropLod.lod0, PropLod.lod1, PropLod.lod2])
          lod: template.lodSet[lod].triangleCount,
      },
      imposterReady: template.imposterTexture != null,
    );
  }

  /// Replace one instanced node wholesale, returning the new node (or null when
  /// there is nothing to draw).
  ///
  /// A fresh [fs.InstancedMesh] every rebuild rather than mutating the live
  /// one: the engine's standing rule in this renderer is never to touch a
  /// buffer that may still be in flight, and swapping whole objects is the
  /// discipline the terrain and ring layers already follow.
  fs.Node? _swapInstanced(
    fs.Node? existing, {
    required fs.MeshGeometry? geometry,
    required fs.Material material,
    required List<vm.Matrix4> transforms,
  }) {
    if (existing != null) _scene.remove(existing);
    if (geometry == null || transforms.isEmpty) return null;
    final mesh = fs.InstancedMesh(geometry: geometry, material: material);
    for (final t in transforms) {
      mesh.addInstance(t);
    }
    final node = fs.Node()..addComponent(fs.InstancedMeshComponent(mesh));
    _scene.add(node);
    return node;
  }

  void _syncImposters(List<_ImposterCard> cards, PropKind kind) {
    if (cards.isEmpty) {
      if (_imposterNode != null) {
        _scene.remove(_imposterNode!);
        _imposterNode = null;
      }
      return;
    }
    final geometry = _imposterGeometry ??= fs.BillboardGeometry(capacity: 4096)
      // Ground props stand up: locking the card's up axis to the world pole and
      // letting it yaw is what keeps a distant tree vertical. Spherical facing
      // would tip the whole forest over as the camera climbed.
      ..facing = fs.BillboardFacing.axisLocked
      ..worldUp = vm.Vector3(0, 0, 1);

    final count = math.min(cards.length, geometry.capacity);
    for (var i = 0; i < count; i++) {
      geometry.setInstance(
        i,
        center: cards[i].centre,
        width: cards[i].width,
        height: cards[i].height,
      );
    }
    geometry.commit(count);

    // The sprite material is per kind, so a species change needs a new node.
    if (_imposterNode != null && _imposterKind != kind) {
      _scene.remove(_imposterNode!);
      _imposterNode = null;
    }
    if (_imposterNode == null) {
      final node =
          fs.Node(mesh: fs.Mesh(geometry, _library.imposterMaterial(kind)));
      _scene.add(node);
      _imposterNode = node;
      _imposterKind = kind;
    }
  }

  /// Remove every node this owns.
  void dispose() {
    for (final n in [_solidNode, _foliageNode, _imposterNode]) {
      if (n != null) _scene.remove(n);
    }
    _solidNode = null;
    _foliageNode = null;
    _imposterNode = null;
    _built = null;
  }

  /// A stable pseudo-random yaw per grid cell.
  static double _yawFor(int index, int seed) {
    var h = (index * 374761393 + seed * 668265263) & 0x7fffffff;
    h = ((h ^ (h >> 13)) * 1274126177) & 0x7fffffff;
    return (h & 0xffff) / 0xffff * 2 * math.pi;
  }
}

class _ImposterCard {
  const _ImposterCard({
    required this.centre,
    required this.width,
    required this.height,
  });
  final vm.Vector3 centre;
  final double width, height;
}
