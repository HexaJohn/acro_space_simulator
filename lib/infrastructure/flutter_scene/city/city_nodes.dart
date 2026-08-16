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
import '../../../domain/scatter/mesh_builder.dart';
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

  /// The editor's ground cursor, in BODY-FIXED metres, or null when nothing is
  /// being pointed at.
  ///
  /// A static rather than snapshot state, deliberately: where the mouse is
  /// hovering is a property of the VIEW, not of the world. Putting it in the
  /// frame would replicate a cursor to every multiplayer client and make the
  /// snapshot change on every mouse move.
  static Vector3? cursorBF;
  static String cursorBodyId = '';
  static double cursorSizeM = 24;

  /// Cursor node, rebuilt every frame it is visible. One quad — cheap enough
  /// that tracking the mouse never touches the city's cached batches, which is
  /// the whole point of keeping it separate from them.
  fs.Node? _cursorNode;

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
    if (!enabled ||
        (snap.buildings.isEmpty &&
            snap.roads.isEmpty &&
            snap.patches.isEmpty)) {
      if (_batches.isNotEmpty) _clear();
      debugLine = 'city: frame carries none '
          '(b=${snap.buildings.length} r=${snap.roads.length} '
          'p=${snap.patches.length})';
      // The cursor still draws over bare ground: pointing at an empty site is
      // exactly when the player most needs to see where a building would go.
      _syncCursor(snap, origin);
      return;
    }

    // Group by body so each colony can use its own body transform. Patches
    // count too: a colony that has been zoned but not yet built is exactly the
    // case that used to render as nothing at all.
    final byBody = <String, List<BuildingSnapshot>>{};
    for (final b in snap.buildings.values) {
      byBody.putIfAbsent(b.body, () => []).add(b);
    }
    for (final p in snap.patches) {
      byBody.putIfAbsent(p.body, () => []);
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
      for (final p in snap.patches) {
        if (p.body != entry.key) continue;
        final world = bodyWorld + quat.rotate(Vector3(p.px, p.py, p.pz));
        final d = (world - focusWorld).length;
        if (d < nearest) nearest = d;
      }
    }
    if (nearest > maxRangeM) {
      if (_batches.isNotEmpty) _clear();
      debugLine = 'city: culled, nearest '
          '${(nearest / 1000).toStringAsFixed(1)}km > '
          '${(maxRangeM / 1000).toStringAsFixed(0)}km';
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
    final key = '${snap.buildings.length}|${snap.roads.length}|'
        '${snap.patches.length}|${detail.index}|${byBody.keys.join(",")}';
    if (_builtKey != key || _batches.isEmpty) {
      _builtKey = key;
      _rebuild(snap, byBody, detail);
    }
    // Every frame: re-place the anchors. A planet spins, so even a completely
    // static colony needs new node matrices — but only the matrices.
    _placeAnchors(snap, origin);
    _syncCursor(snap, origin);
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
      var count = 0;
      for (final b in entry.value) {
        sum = sum + Vector3(b.px, b.py, b.pz);
        count++;
      }
      for (final p in snap.patches) {
        if (p.body != entry.key) continue;
        sum = sum + Vector3(p.px, p.py, p.pz);
        count++;
      }
      if (count == 0) continue;
      final anchorBF = sum * (1.0 / count);

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
      _emitRoads(snap, bodyId: entry.key, anchorBF: anchorBF);
      _emitPatches(snap, bodyId: entry.key, anchorBF: anchorBF);
    }
  }

  /// Draw (or clear) the editor's ground cursor.
  void _syncCursor(WorldSnapshot snap, FloatingOrigin origin) {
    final existing = _cursorNode;
    if (existing != null) {
      _scene.remove(existing);
      _cursorNode = null;
    }
    final at = cursorBF;
    if (at == null) return;
    final body = snap.bodies[cursorBodyId];
    if (body == null) return;

    final up = at.normalized;
    // A stable tangent frame: any vector not parallel to up will do, and the
    // cursor is a square, so its spin about the normal does not matter.
    final east = (up.cross(Vector3.unitZ).lengthSquared > 1e-9
            ? up.cross(Vector3.unitZ)
            : up.cross(Vector3.unitX))
        .normalized;
    final north = up.cross(east);
    final h = cursorSizeM / 2;
    // Above every patch kind, so the cursor always reads on top of whatever it
    // is hovering over.
    final lift = up * 0.3;

    final m = MeshBuilder();
    const u = 5.5 / 6; // the cursor swatch
    final corners = [
      east * -h + north * -h + lift,
      east * h + north * -h + lift,
      east * h + north * h + lift,
      east * -h + north * h + lift,
    ];
    final idx = [for (final c in corners) m.vertex(c, up, u, 0.5)];
    m.quad(idx[0], idx[1], idx[2], idx[3]);

    final geometry = _geometryOf(m.build());
    if (geometry == null) return;
    final node = fs.Node(
      mesh: fs.Mesh.primitives(primitives: [
        fs.MeshPrimitive(geometry, CityMaterials.ground),
      ]),
    );
    final bodyWorld = Vector3(body.px, body.py, body.pz);
    final bodyQuat = Quaternion(body.qw, body.qx, body.qy, body.qz);
    node.localTransform = vm.Matrix4.compose(
      origin.worldToScene(bodyWorld + bodyQuat.rotate(at)),
      quatToScene(bodyQuat),
      vm.Vector3.all(1.0),
    );
    _scene.add(node);
    _cursorNode = node;
  }

  /// Flat ground patches: roads, zoned lots, support decks.
  ///
  /// One mesh for all of them, coloured by a UV into the ground palette. The
  /// mesh format has no vertex-colour channel, and a material per colour would
  /// be five draws for what is a single sheet of ground.
  void _emitPatches(
    WorldSnapshot snap, {
    required String bodyId,
    required Vector3 anchorBF,
  }) {
    final m = MeshBuilder();
    const kinds = 5;
    var any = false;
    for (final p in snap.patches) {
      if (p.body != bodyId) continue;
      any = true;
      final centre = Vector3(p.px, p.py, p.pz) - anchorBF;
      final up = (centre + anchorBF).normalized;
      final basis = Quaternion(p.qw, p.qx, p.qy, p.qz);
      final east = basis.rotate(Vector3.unitX);
      final north = basis.rotate(Vector3.unitY);
      final h = p.sizeM / 2;
      // Lifted clear of the levelled pad, and each kind by a different amount,
      // so a road drawn over a zoned lot does not z-fight it.
      final lift = up * (0.05 + p.kind * 0.01);
      // Every corner samples the CENTRE of its swatch: no filtering or mip
      // level can then bleed a neighbouring kind's colour in.
      final u = (p.kind + 0.5) / kinds;
      final c = [
        centre + east * -h + north * -h + lift,
        centre + east * h + north * -h + lift,
        centre + east * h + north * h + lift,
        centre + east * -h + north * h + lift,
      ];
      final idx = [for (final v in c) m.vertex(v, up, u, 0.5)];
      m.quad(idx[0], idx[1], idx[2], idx[3]);
    }
    if (!any) return;
    final geometry = _geometryOf(m.build());
    if (geometry == null) return;
    final node = fs.Node(
      mesh: fs.Mesh.primitives(primitives: [
        fs.MeshPrimitive(geometry, CityMaterials.ground),
      ]),
    );
    _scene.add(node);
    _batches.add(_CityBatch(node, bodyId, anchorBF));
    _drawCalls++;
  }

  /// Road ribbons and their street lamps.
  ///
  /// Built as one mesh per colony rather than instanced: a road is a unique
  /// polyline, so there is nothing to share between two of them, and one
  /// stretched ribbon is a single draw either way.
  void _emitRoads(
    WorldSnapshot snap, {
    required String bodyId,
    required Vector3 anchorBF,
  }) {
    final roads = snap.roads.where((r) => r.body == bodyId).toList();
    if (roads.isEmpty) return;

    final ribbon = MeshBuilder();
    final lampSolid = MeshBuilder();
    final lampGlow = MeshBuilder();

    for (final road in roads) {
      final pts = <Vector3>[];
      for (var i = 0; i + 2 < road.points.length; i += 3) {
        pts.add(Vector3(
          road.points[i] - anchorBF.x,
          road.points[i + 1] - anchorBF.y,
          road.points[i + 2] - anchorBF.z,
        ));
      }
      if (pts.length < 2) continue;
      _ribbonFor(ribbon, pts, road.halfWidthM, anchorBF);
      _lampsFor(lampSolid, lampGlow, pts, road, anchorBF);
    }

    for (final (builder, material) in [
      (ribbon, CityMaterials.facade),
      (lampSolid, CityMaterials.facade),
      (lampGlow, CityMaterials.glazing),
    ]) {
      final mesh = builder.build();
      if (mesh.isEmpty) continue;
      final geometry = _geometryOf(mesh);
      if (geometry == null) continue;
      final node = fs.Node(
        mesh: fs.Mesh.primitives(primitives: [
          fs.MeshPrimitive(geometry, material),
        ]),
      );
      _scene.add(node);
      _batches.add(_CityBatch(node, bodyId, anchorBF));
      _drawCalls++;
    }
  }

  /// A flat strip along the centreline, lifted a few centimetres so it wins the
  /// depth test against the graded corridor it sits in instead of z-fighting
  /// the terrain that was levelled for it.
  static void _ribbonFor(
    MeshBuilder m,
    List<Vector3> pts,
    double halfWidth,
    Vector3 anchorBF,
  ) {
    const lift = 0.12;
    var v = 0.0;
    int? prevL, prevR;
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i];
      // Local up is radial at the point itself, not at the anchor: a long road
      // curves with the body, and a single shared up would bury one end.
      final up = (p + anchorBF).normalized;
      final ahead = i + 1 < pts.length ? pts[i + 1] - p : p - pts[i - 1];
      final along = ahead.length > 1e-6 ? ahead.normalized : Vector3.unitX;
      final side = along.cross(up).normalized;
      if (i > 0) v += (p - pts[i - 1]).length / (halfWidth * 2);
      final l = m.vertex(p + side * -halfWidth + up * lift, up, 0, v);
      final r = m.vertex(p + side * halfWidth + up * lift, up, 1, v);
      if (prevL != null && prevR != null) {
        m.quad(prevL, prevR, r, l);
      }
      prevL = l;
      prevR = r;
    }
  }

  /// Lamp columns down the verge, spaced by road class.
  ///
  /// Derived on the client from the road itself rather than shipped: the rule
  /// is deterministic, and a thousand lamp positions per colony is a lot of
  /// wire for something both ends can compute.
  static void _lampsFor(
    MeshBuilder solid,
    MeshBuilder glow,
    List<Vector3> pts,
    RoadSnapshot road,
    Vector3 anchorBF,
  ) {
    final scale = road.halfWidthM / 4.0; // street half-width is 4 m
    final spacing = 34.0 * math.sqrt(math.max(scale, 0.25));
    final height = 9.0 * math.sqrt(math.max(scale, 0.25));
    final both = road.roadClassIndex > 0;
    var travelled = 0.0;
    var next = spacing * 0.5;
    var flip = 1.0;

    for (var i = 1; i < pts.length; i++) {
      travelled += (pts[i] - pts[i - 1]).length;
      if (travelled < next) continue;
      next += spacing;
      final p = pts[i];
      final up = (p + anchorBF).normalized;
      final along = (pts[i] - pts[i - 1]).normalized;
      final side = along.cross(up).normalized;
      final offset = road.halfWidthM + 1.2;
      for (final s in both ? const [1.0, -1.0] : [flip]) {
        final base = p + side * (offset * s) + up * 0.1;
        _column(solid, base, up, along, height);
        _head(glow, base + up * height, up, along);
      }
      flip = -flip;
    }
  }

  static void _column(
      MeshBuilder m, Vector3 base, Vector3 up, Vector3 along, double h) {
    final side = along.cross(up).normalized;
    const r = 0.14;
    final corners = [
      base + side * -r + along * -r,
      base + side * r + along * -r,
      base + side * r + along * r,
      base + side * -r + along * r,
    ];
    for (var i = 0; i < 4; i++) {
      final a = corners[i], b = corners[(i + 1) % 4];
      final n = ((a + b) * 0.5 - base).normalized;
      final i0 = m.vertex(a, n, 0, 1);
      final i1 = m.vertex(b, n, 1, 1);
      final i2 = m.vertex(b + up * h, n, 1, 0);
      final i3 = m.vertex(a + up * h, n, 0, 0);
      m.quad(i0, i1, i2, i3);
    }
  }

  static void _head(MeshBuilder m, Vector3 at, Vector3 up, Vector3 along) {
    final side = along.cross(up).normalized;
    const hw = 0.55, hd = 0.22;
    final a = at + side * -hw + along * -hd;
    final b = at + side * hw + along * -hd;
    final c = at + side * hw + along * hd;
    final d = at + side * -hw + along * hd;
    // Downward-facing lens: it is the lit surface, so it points at the road.
    final n = up * -1;
    final i0 = m.vertex(a, n, 0, 0);
    final i1 = m.vertex(b, n, 1, 0);
    final i2 = m.vertex(c, n, 1, 1);
    final i3 = m.vertex(d, n, 0, 1);
    m.quad(i0, i3, i2, i1);
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
