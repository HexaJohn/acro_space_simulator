// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Draws colonies in the 3D scene.
///
/// Buildings arrive as [BuildingSnapshot]s carrying their site size and kind,
/// so this builds a colony from the frame ALONE — it never reaches into the
/// authoritative `CitySim`, which a networked client could not do anyway.
///
/// Geometry is generated once per ARCHETYPE and drawn instanced, the same way
/// the scatter system draws forests: a city of ten thousand buildings resolves
/// to a few hundred meshes and a few hundred draws, not ten thousand of either.
library;

import 'dart:async' show unawaited;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../../application/snapshot/world_snapshot.dart';
import '../../../domain/architecture/building_generator.dart';
import '../../../domain/colony/city/city_building_spec.dart';
import '../../../domain/colony/city/parcel.dart';
import '../../../domain/scatter/prop_mesh.dart';
import '../../../domain/shared/quaternion.dart';
import '../../../domain/shared/vector3.dart';
import '../../../domain/architecture/city_lighting.dart';
import '../coord_convert.dart';
import 'city_materials.dart';
import 'city_textures.dart';

/// One generated archetype, uploaded.
class _CityMesh {
  _CityMesh(this.solid, this.glazing);
  final fs.MeshGeometry? solid;
  final fs.MeshGeometry? glazing;
}

class CityNodes {
  CityNodes(this._scene);

  final fs.Scene _scene;

  /// Off switch for profiling, matching the other node families.
  static bool enabled = true;

  /// Beyond this the whole colony is skipped — from far enough out a city is
  /// smaller than a pixel and the terrain's own texture carries it.
  static double maxRangeM = 400000;

  /// Distance at which buildings drop to their block silhouette.
  static double blockRangeM = 3500;

  /// Distance inside which interiors are generated.
  static double interiorRangeM = 600;

  static String debugLine = '';

  final BuildingLibrary _library = BuildingLibrary();
  final Map<BuildingArchetype, _CityMesh> _uploaded = {};

  /// Batches, each pinned to a body-fixed anchor. Instance transforms are
  /// stored RELATIVE to that anchor and never touched again; only the node's
  /// own matrix moves per frame. That is what lets a spinning planet carry a
  /// city without re-uploading a single buffer — and it is the same anchoring
  /// the scatter batches use, for the same reason.
  final List<_CityBatch> _batches = [];

  /// What the last rebuild was keyed on, so a static colony costs nothing.
  String _builtKey = '';
  int _drawCalls = 0;

  /// Instances above this in one draw overflow the engine's per-frame transient
  /// block — the same 1 MiB / 16,384-mat4 ceiling the scatter batches hit.
  static const int _maxPerDraw = 14000;

  void update(
    WorldSnapshot snap,
    FloatingOrigin origin, {
    required Vector3 focusWorld,
  }) {
    if (!enabled || snap.buildings.isEmpty) {
      if (_batches.isNotEmpty) _clear();
      debugLine = '';
      return;
    }

    // Group by body so each colony can use its own body transform.
    final byBody = <String, List<BuildingSnapshot>>{};
    for (final b in snap.buildings.values) {
      byBody.putIfAbsent(b.body, () => []).add(b);
    }

    // Range gate off the nearest colony, and pick a detail tier from it. The
    // whole city shares one tier: a per-building tier would pop visibly along
    // the boundary as the camera drifts, and the saving is small because the
    // expensive part is the interior, which is all-or-nothing anyway.
    var nearest = double.infinity;
    for (final entry in byBody.entries) {
      final body = snap.bodies[entry.key];
      if (body == null) continue;
      final bodyWorld = Vector3(body.px, body.py, body.pz);
      final quat = Quaternion(body.qw, body.qx, body.qy, body.qz);
      for (final b in entry.value) {
        final world = bodyWorld + quat.rotate(Vector3(b.px, b.py, b.pz));
        final d = (world - focusWorld).length;
        if (d < nearest) nearest = d;
      }
    }
    if (nearest > maxRangeM) {
      if (_batches.isNotEmpty) _clear();
      debugLine = 'city: out of range';
      return;
    }

    // Textures load once, off the first frame that needs them; until they
    // land the materials draw against the engine's white placeholder rather
    // than blocking the frame.
    if (!CityTextures.ready) unawaited(CityTextures.load());
    CityMaterials.nightFactor = _nightFactorAt(snap, byBody);

    final detail = nearest > blockRangeM
        ? BuildingDetail.block
        : (nearest > interiorRangeM
            ? BuildingDetail.exterior
            : BuildingDetail.full);

    // Rebuild only when something the geometry depends on actually changed.
    // Colonies are static between construction events, so this is normally a
    // string compare per frame rather than a scene rebuild.
    final key = '${snap.buildings.length}|${detail.index}|'
        '${byBody.keys.join(",")}';
    if (_builtKey != key || _batches.isEmpty) {
      _builtKey = key;
      _rebuild(snap, byBody, detail);
    }
    // Every frame: re-place the anchors. A planet spins, so even a completely
    // static colony needs new node matrices — but only the matrices.
    _placeAnchors(snap, origin);
    debugLine =
        'city: ${snap.buildings.length} bldg, $_drawCalls draws (${detail.name}), '
        'meshes ${_uploaded.length}';
  }

  /// How dark it is over the colony, from the frame's own sun.
  ///
  /// Uses the same ramp the colony sim lights its windows by — a second copy
  /// of the curve here would drift from the domain's the first time either was
  /// tuned.
  double _nightFactorAt(
    WorldSnapshot snap,
    Map<String, List<BuildingSnapshot>> byBody,
  ) {
    // The star is the light source. A frame carries no "is a star" flag on the
    // body itself (descriptors are sticky and often absent), so it is found by
    // being the biggest thing present — which on any real system it is, by
    // orders of magnitude.
    BodySnapshot? star;
    for (final b in snap.bodies.values) {
      if (star == null || b.radius > star.radius) star = b;
    }
    if (star == null) return 0;
    final entry = byBody.entries.first;
    final body = snap.bodies[entry.key];
    if (body == null) return 0;
    final bodyWorld = Vector3(body.px, body.py, body.pz);
    final quat = Quaternion(body.qw, body.qx, body.qy, body.qz);
    final first = entry.value.first;
    final siteWorld =
        bodyWorld + quat.rotate(Vector3(first.px, first.py, first.pz));
    final up = quat.rotate(Vector3(first.px, first.py, first.pz)).normalized;
    final toSun = (Vector3(star.px, star.py, star.pz) - siteWorld).normalized;
    return const CityLighting().nightFactor(
      up.x * toSun.x + up.y * toSun.y + up.z * toSun.z,
    );
  }

  void _rebuild(
    WorldSnapshot snap,
    Map<String, List<BuildingSnapshot>> byBody,
    BuildingDetail detail,
  ) {
    _clear();

    for (final entry in byBody.entries) {
      if (snap.bodies[entry.key] == null) continue;
      // Anchor at the colony's centroid, so instance offsets stay small and
      // keep their precision even on a body millions of metres across.
      var sum = Vector3.zero;
      for (final b in entry.value) {
        sum = sum + Vector3(b.px, b.py, b.pz);
      }
      final anchorBF = sum * (1.0 / entry.value.length);

      final groups = <BuildingArchetype, List<vm.Matrix4>>{};
      for (final b in entry.value) {
        final spec = specOf(b);
        final parcel = parcelOf(b);
        final seed = b.id.hashCode;
        final key = BuildingArchetype.of(spec, parcel,
            detail: detail, seed: seed, bucketM: _library.bucketM,
            variants: _library.variants);
        _uploaded.putIfAbsent(key, () {
          final built = _library.get(spec, parcel, seed: seed, detail: detail);
          return _CityMesh(
            _geometryOf(built.model.solid),
            _geometryOf(built.model.foliage),
          );
        });
        groups.putIfAbsent(key, () => []).add(instanceTransform(anchorBF, b));
      }
      _emit(groups, bodyId: entry.key, anchorBF: anchorBF);
    }
  }

  void _emit(
    Map<BuildingArchetype, List<vm.Matrix4>> groups, {
    required String bodyId,
    required Vector3 anchorBF,
  }) {
    groups.forEach((key, transforms) {
      final mesh = _uploaded[key];
      if (mesh == null) return;
      // Walls take the stone material (concrete is closer to rock than bark);
      // glazing takes the foliage one, which is the alpha-capable pass and is
      // where the night lighting hooks in.
      for (final (geometry, material) in [
        (mesh.solid, CityMaterials.facade),
        (mesh.glazing, CityMaterials.glazing),
      ]) {
        if (geometry == null) continue;
        for (var start = 0; start < transforms.length; start += _maxPerDraw) {
          final end = math.min(start + _maxPerDraw, transforms.length);
          final instanced =
              fs.InstancedMesh(geometry: geometry, material: material);
          for (var i = start; i < end; i++) {
            instanced.addInstance(transforms[i]);
          }
          final node = fs.Node()
            ..addComponent(fs.InstancedMeshComponent(instanced));
          _scene.add(node);
          _batches.add(_CityBatch(node, bodyId, anchorBF));
          _drawCalls++;
        }
      }
    });
  }

  /// Per-frame: put each batch's anchor where its body currently is.
  void _placeAnchors(WorldSnapshot snap, FloatingOrigin origin) {
    for (final batch in _batches) {
      final body = snap.bodies[batch.bodyId];
      if (body == null) continue;
      final bodyWorld = Vector3(body.px, body.py, body.pz);
      final bodyQuat = Quaternion(body.qw, body.qx, body.qy, body.qz);
      batch.node.localTransform = vm.Matrix4.compose(
        origin.worldToScene(bodyWorld + bodyQuat.rotate(batch.anchorBF)),
        quatToScene(bodyQuat),
        vm.Vector3.all(1.0),
      );
    }
  }

  /// Reconstruct enough of a spec for the massing rules from the wire fields.
  ///
  /// Only the geometry-relevant parts are needed — the economy never runs on
  /// the client — so this is deliberately a shell rather than a catalogue
  /// lookup, which would break the moment a server ran a modded catalogue.
  /// Static and snapshot-explicit so the wire-to-geometry mapping is testable
  /// without a live scene — the same arrangement `ScatterNodes` uses for its
  /// frame maths.
  static CityBuildingSpec specOf(BuildingSnapshot b) => CityBuildingSpec(
        type: b.type,
        label: b.type,
        colorArgb: b.colorArgb,
        group: _groupFor(b),
        siteWidthM: b.siteWidthM,
        siteDepthM: b.siteDepthM,
        siteKind: SiteKind.values[
            b.siteKindIndex.clamp(0, SiteKind.values.length - 1)],
        // Massing needs SOMETHING to size floor area from. Site area is the
        // honest proxy available on the wire: a big site implies a big
        // programme, which is what the rules would have derived anyway.
        jobs: (b.siteWidthM * b.siteDepthM / 90).round().clamp(0, 4000),
      );

  static String _groupFor(BuildingSnapshot b) => switch (b.type) {
        'r-low' || 'r-med' || 'r-high' => 'res',
        'c-low' || 'c-med' || 'c-high' => 'com',
        'i-low' || 'i-med' || 'i-high' => 'ind',
        _ => 'svc',
      };

  /// The lot a building stands on, in its own frontage-aligned frame.
  static Parcel parcelOf(BuildingSnapshot b) {
    final w = b.siteWidthM, d = b.siteDepthM;
    return Parcel(
      id: b.id,
      polygon: [
        Vec2(-w / 2, 0),
        Vec2(w / 2, 0),
        Vec2(w / 2, d),
        Vec2(-w / 2, d),
      ],
      frontage: (Vec2(-w / 2, 0), Vec2(w / 2, 0)),
    );
  }

  /// Model transform for one building.
  ///
  /// The snapshot's orientation already carries the surface basis (local +X
  /// east, +Y north, +Z radial up), and generated buildings are authored Z-up
  /// with their origin at the base — so the two compose directly, and a
  /// building lands standing on its pad rather than buried or lying down.
  static vm.Matrix4 instanceTransform(Vector3 anchorBF, BuildingSnapshot b) {
    final offset = Vector3(b.px, b.py, b.pz) - anchorBF;
    final surface = Quaternion(b.qw, b.qx, b.qy, b.qz);
    return vm.Matrix4.compose(
      vm.Vector3(lengthToScene(offset.x), lengthToScene(offset.y),
          lengthToScene(offset.z)),
      quatToScene(surface),
      vm.Vector3.all(lengthToScene(1.0)),
    );
  }

  static fs.MeshGeometry? _geometryOf(PropMesh mesh) {
    if (mesh.isEmpty) return null;
    return fs.MeshGeometry.fromArrays(
      positions: mesh.positions,
      normals: mesh.normals,
      texCoords: mesh.texCoords,
      indices: mesh.indices,
    );
  }

  void _clear() {
    for (final batch in _batches) {
      _scene.remove(batch.node);
    }
    _batches.clear();
    _drawCalls = 0;
  }

  void dispose() {
    _clear();
    _uploaded.clear();
    _library.clear();
    if (debugLine.isNotEmpty) debugPrint('cityNodes disposed');
  }
}

/// One instanced draw, pinned to a body-fixed anchor.
class _CityBatch {
  _CityBatch(this.node, this.bodyId, this.anchorBF);
  final fs.Node node;
  final String bodyId;
  final Vector3 anchorBF;
}
