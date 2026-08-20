// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Renders halo-ring megastructures from `WorldSnapshot.megastructures`.
///
/// Each ring is four procedural layers plus streamed voxel terrain cells, and
/// the CONSTRUCTION STAGE is the renderer's whole job: the economy sim decides
/// phase progress, this file turns it into geometry —
///
///   phase 1: truss skeleton arcs reach around the circle
///   phase 2: the hull band skins over the truss
///   phase 3: terrain pours across the bare deck (far strip + near voxels)
///   phase 4: crest lights fade in
///
/// Procedural layers are rebuilt only when a stage's arc coverage crosses a
/// quantisation bucket (1/256 of the circle), not per frame. Voxel cells use
/// the domain mesher (`meshHaloRingCell`) with a per-cell anchor + rotation so
/// float32 vertex buffers stay jitter-free at megastructure scale — same trick
/// as planetary terrain chunks.
library;

import 'dart:math' as math;

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../application/snapshot/world_snapshot.dart';
import '../../domain/megastructure/halo_ring.dart';
import '../../domain/megastructure/halo_ring_mesher.dart';
import '../../domain/megastructure/halo_ring_meshes.dart';
import '../../domain/megastructure/megastructure.dart';
import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';
import '../../domain/terrain/surface_nets.dart';
import 'coord_convert.dart';

class HaloRingNodes {
  HaloRingNodes(this._scene);

  final fs.Scene _scene;

  /// Runtime kill switch (debug panel / dev ext).
  static bool enabled = true;

  /// How close (m) the eye must be to the terrain floor before voxel cells
  /// stream in around it; beyond this the far strip carries the look.
  static const double cellStreamRangeM = 8.0e4;

  /// Resident voxel-cell cap per ring, evicted farthest-first.
  static const int maxResidentCells = 96;

  /// Voxel cells meshed per frame per ring (synchronous v1 — one 32^3 sample
  /// grid per frame keeps the main thread comfortably under a millisecond
  /// budget hiccup; the isolate pool is the follow-up if this ever shows).
  static const int cellMeshBudget = 1;

  final Map<String, _RingEntry> _entries = {};

  void update(
    WorldSnapshot snap,
    FloatingOrigin origin, {
    Vector3? cameraEye, // focus-relative metres
  }) {
    if (!enabled) {
      for (final e in _entries.values) {
        e.dispose(_scene);
      }
      _entries.clear();
      return;
    }
    final eyeWorld =
        cameraEye == null ? null : origin.focusWorld + cameraEye;
    final seen = <String>{};
    for (final m in snap.megastructures) {
      if (m.type != MegastructureType.haloRing.index) continue;
      seen.add(m.id);
      _entries
          .putIfAbsent(m.id, () => _RingEntry(m.toRingSpec()))
          .update(_scene, m, origin, eyeWorld: eyeWorld);
    }
    _entries.removeWhere((id, e) {
      if (seen.contains(id)) return false;
      e.dispose(_scene);
      return true;
    });
  }
}

class _RingEntry {
  _RingEntry(this.spec)
      : field = spec.field(),
        grid = HaloRingGrid(spec);

  final HaloRingSpec spec;
  final HaloRingField field;
  final HaloRingGrid grid;

  fs.Node? _truss, _hull, _strip, _lights;
  int _trussBucket = -1, _hullBucket = -1, _stripBucket = -1;
  double _lightsLevel = -1;
  fs.UnlitMaterial? _lightsMaterial;

  final Map<RingCellKey, fs.Node> _cells = {};

  /// Arc coverage quantisation — one bucket is 1/256 of the circle (~123 km of
  /// arc at 5,000 km radius), so a build in progress visibly creeps without
  /// rebuilding geometry every frame.
  static int _bucket(double arc) => (arc.clamp(0.0, 1.0) * 256).floor();

  static fs.EnvironmentMap? _matteEnv;

  /// Same rationale as BodyNodes: kill IBL specular so big matte/metal
  /// surfaces don't pick up a sheen from the baked planet environment; keep a
  /// tiny constant diffuse term so night sides read as dim shapes, not voids.
  static fs.EnvironmentMap _matteEnvironment() =>
      _matteEnv ??= fs.EnvironmentMap.fromGpuTextures(
        prefilteredRadiance: fs.Material.getBlackPlaceholderTexture(),
        diffuseSphericalHarmonics: [
          vm.Vector3.all(0.012),
          for (var i = 1; i < 9; i++) vm.Vector3.zero(),
        ],
      );

  static fs.Material _pbr(double r, double g, double b,
      {double metallic = 0, double roughness = 1}) {
    return fs.PhysicallyBasedMaterial()
      ..baseColorFactor = vm.Vector4(r, g, b, 1)
      ..metallicFactor = metallic
      ..roughnessFactor = roughness
      // Every layer is a thin open surface somewhere (truss faces, the hull's
      // U cross-section, the strip); double-sided sidesteps winding entirely.
      ..doubleSided = true
      ..environment = _matteEnvironment();
  }

  late final fs.Material _trussMat =
      _pbr(0.34, 0.35, 0.38, metallic: 0.8, roughness: 0.55);
  late final fs.Material _hullMat =
      _pbr(0.58, 0.61, 0.66, metallic: 0.85, roughness: 0.4);
  late final fs.Material _terrainMat =
      _pbr(0.42, 0.38, 0.31, roughness: 1.0);

  void update(
    fs.Scene scene,
    MegastructureSnapshot m,
    FloatingOrigin origin, {
    Vector3? eyeWorld,
  }) {
    final build = m.buildState();
    final ringWorld = Vector3(m.px, m.py, m.pz);
    final ringQuat = Quaternion(m.qw, m.qx, m.qy, m.qz);

    _rebuildLayers(scene, build);

    // Whole-ring layers share one transform: vertices are ring-frame metres.
    final xf = vm.Matrix4.compose(
      origin.worldToScene(ringWorld),
      quatToScene(ringQuat),
      vm.Vector3.all(lengthToScene(1.0)),
    );
    for (final n in [_truss, _hull, _strip, _lights]) {
      n?.localTransform = xf;
    }

    // Lights ride a material colour, not a geometry rebuild.
    if (build.lightsLevel != _lightsLevel) {
      _lightsLevel = build.lightsLevel;
      final l = _lightsLevel;
      _lightsMaterial?.baseColorFactor =
          vm.Vector4(1.0 * l, 0.92 * l, 0.75 * l, 1.0);
    }

    _streamCells(scene, build, ringWorld, ringQuat, origin, eyeWorld);
  }

  void _rebuildLayers(fs.Scene scene, HaloRingBuildState build) {
    final tb = _bucket(build.trussArc);
    if (tb != _trussBucket) {
      _trussBucket = tb;
      _truss = _swap(scene, _truss,
          trussMesh(spec, arcCoverage: tb / 256), _trussMat);
    }
    // Hull depends on BOTH its own arc and the terrain arc (the deck recedes
    // as soil pours over it), so bucket on the pair.
    final hb = _bucket(build.hullArc) * 512 + _bucket(build.terrainArc);
    if (hb != _hullBucket) {
      _hullBucket = hb;
      _hull = _swap(
          scene,
          _hull,
          hullBandMesh(spec,
              arcCoverage: _bucket(build.hullArc) / 256,
              deckArcStart: _bucket(build.terrainArc) / 256),
          _hullMat);
    }
    final sb = _bucket(build.terrainArc);
    if (sb != _stripBucket) {
      _stripBucket = sb;
      _strip = _swap(scene, _strip,
          terrainStripMesh(field, arcCoverage: sb / 256), _terrainMat);
      // Cells beyond the (rare, shrinking-never) pour front are impossible;
      // cheaper to let distance eviction handle stale ones than to scan.
    }
    if (_lights == null && build.lightsLevel > 0) {
      _lightsMaterial = fs.UnlitMaterial()
        ..baseColorFactor = vm.Vector4.zero()
        ..doubleSided = true;
      _lights = _swap(scene, _lights, crestLightsMesh(spec), _lightsMaterial!);
    }
  }

  fs.Node? _swap(
      fs.Scene scene, fs.Node? old, SurfaceMesh mesh, fs.Material material) {
    if (old != null) scene.remove(old);
    if (mesh.isEmpty) return null;
    final node = fs.Node(
        mesh: fs.Mesh(
            fs.MeshGeometry.fromArrays(
              positions: mesh.positions,
              normals: mesh.normals,
              indices: mesh.indices,
            ),
            material));
    scene.add(node);
    return node;
  }

  void _streamCells(
    fs.Scene scene,
    HaloRingBuildState build,
    Vector3 ringWorld,
    Quaternion ringQuat,
    FloatingOrigin origin,
    Vector3? eyeWorld,
  ) {
    // Position every resident cell (they are ring-fixed, so they co-rotate).
    void place(RingCellKey key, fs.Node node, Vector3 anchorRF, Quaternion q) {
      node.localTransform = vm.Matrix4.compose(
        origin.worldToScene(ringWorld + ringQuat.rotate(anchorRF)),
        quatToScene(ringQuat * q),
        vm.Vector3.all(lengthToScene(1.0)),
      );
    }

    // Anchors/rotations are cheap pure functions; recompute rather than store.
    for (final e in _cells.entries) {
      final phi = grid.phiOf(e.key.i);
      final anchor = Vector3(math.cos(phi) * spec.radiusM,
          math.sin(phi) * spec.radiusM, grid.zOf(e.key.j));
      place(e.key, e.value, anchor, _cellQuat(phi));
    }

    if (eyeWorld == null || build.terrainArc <= 0) return;
    final eyeRF = ringQuat.conjugate.rotate(eyeWorld - ringWorld);
    final rho = math.sqrt(eyeRF.x * eyeRF.x + eyeRF.y * eyeRF.y);
    final nearBand = (rho - spec.radiusM).abs() <
            HaloRingNodes.cellStreamRangeM &&
        eyeRF.z.abs() < spec.halfWidthM + HaloRingNodes.cellStreamRangeM;
    if (!nearBand) {
      _evictFar(scene, eyeRF, keep: 0);
      return;
    }

    var phi = math.atan2(eyeRF.y, eyeRF.x);
    if (phi < 0) phi += 2 * math.pi;
    final z = eyeRF.z.clamp(-spec.interiorHalfWidthM, spec.interiorHalfWidthM);
    final centre = grid.cellAt(phi, z);
    final pourFront = build.terrainArc * 2 * math.pi;

    var budget = HaloRingNodes.cellMeshBudget;
    for (var di = -2; di <= 2 && budget > 0; di++) {
      for (var dj = -1; dj <= 1 && budget > 0; dj++) {
        final j = centre.j + dj;
        if (j < 0 || j >= grid.cellsAcross) continue;
        final key = RingCellKey(grid.wrapI(centre.i + di), j);
        // Only terrain that has actually been poured exists to mesh.
        if (grid.phiOf(key.i) > pourFront) continue;
        if (_cells.containsKey(key)) continue;
        final cell = meshHaloRingCell(field, grid, key);
        budget--;
        if (cell.mesh.isEmpty) continue;
        final node = fs.Node(
            mesh: fs.Mesh(
                fs.MeshGeometry.fromArrays(
                  positions: cell.mesh.positions,
                  normals: cell.mesh.normals,
                  indices: cell.mesh.indices,
                ),
                _terrainMat));
        scene.add(node);
        _cells[key] = node;
        place(key, node, cell.anchorRF, cell.localToRing);
      }
    }
    _evictFar(scene, eyeRF, keep: HaloRingNodes.maxResidentCells);
  }

  Quaternion _cellQuat(double phi) =>
      Quaternion.axisAngle(Vector3.unitZ, phi + math.pi / 2) *
      Quaternion.axisAngle(Vector3.unitX, -math.pi / 2);

  void _evictFar(fs.Scene scene, Vector3 eyeRF, {required int keep}) {
    if (_cells.length <= keep) return;
    final keys = _cells.keys.toList()
      ..sort((a, b) {
        double d2(RingCellKey k) {
          final phi = grid.phiOf(k.i);
          final p = Vector3(math.cos(phi) * spec.radiusM,
              math.sin(phi) * spec.radiusM, grid.zOf(k.j));
          return (p - eyeRF).lengthSquared;
        }

        return d2(a).compareTo(d2(b));
      });
    for (final k in keys.sublist(keep)) {
      final n = _cells.remove(k);
      if (n != null) scene.remove(n);
    }
  }

  void dispose(fs.Scene scene) {
    for (final n in [_truss, _hull, _strip, _lights]) {
      if (n != null) scene.remove(n);
    }
    _truss = _hull = _strip = _lights = null;
    for (final n in _cells.values) {
      scene.remove(n);
    }
    _cells.clear();
  }
}
