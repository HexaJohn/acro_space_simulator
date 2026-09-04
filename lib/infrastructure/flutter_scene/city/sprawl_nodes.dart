// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The sprawl plan's roads, drawn: the county highways, the interstates and
/// their ramps, the railway carried on past the plat, and the junctions of
/// the plan — at a level of detail set by how far away each is.
///
/// The sections that used to be grown here are plat now: their streets,
/// lots and houses ride the frame's own roads and buildings and are drawn
/// with the downtown's. What is left here is the mile-scale network the
/// plat does not lay yet, tiered by distance the way it always was: far, an
/// expressway is an asphalt ribbon; mid, its lanes are painted; near, it
/// has its barrier, and the county highway beside it has sidewalks, lamps,
/// and signals where the subdivisions' collectors meet it.
///
/// Roads are grouped by where their middles fall on a two-mile grid, and
/// each group is one node per material, rebuilt only when its tier changes,
/// a little per frame, nearest first, so the camera can move without the
/// frame stopping.
library;

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../../application/snapshot/world_snapshot.dart';
import '../../../domain/colony/city/parcel.dart';
import '../../../domain/colony/city/road_junction.dart';
import '../../../domain/colony/city/sprawl_plan.dart';
import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/shared/quaternion.dart';
import '../../../domain/shared/vector3.dart';
import '../coord_convert.dart';
import 'city_materials.dart';
import 'city_nodes.dart';
import 'railway.dart';
import 'road_mesher.dart';

/// How much of a road is drawn, nearest first.
enum SprawlTier { close, near, mid, far }

class SprawlNodes {
  SprawlNodes(this._scene);

  final fs.Scene _scene;

  static bool enabled = true;

  /// Nearer than this, roads get their sidewalks, lamps and junction
  /// furniture.
  static double nearRangeM = 2800;

  /// Nearer than this, lanes are painted; beyond, bare ribbons.
  static double midRangeM = 7500;

  /// Kept for the studio's slider: the close tier is the near tier's look
  /// for a road.
  static double closeRangeM = 700;

  /// The grid the plan's roads are grouped on, metres.
  static double groupM = 2 * kMileM;

  /// Milliseconds of building the frame will spend before deferring the
  /// rest of the queue.
  static double buildBudgetMs = 9;

  static final Map<String, double> phaseMs = {};
  static final Map<String, int> counts = {};
  static String debugLine = '';

  List<SprawlRoadSnapshot>? _roadsSource;
  List<SprawlNodeSnapshot>? _nodesSource;
  final List<_Batch> _railBatches = [];
  final Map<String, _Group> _groups = {};
  final List<_Group> _queue = [];
  final Map<String, (Vector3, Quaternion, Vector3)> _placedPose = {};

  void update(
    WorldSnapshot snap,
    FloatingOrigin origin, {
    required Vector3 focusWorld,
    double Function(Vector3 dirBF)? groundRadiusAt,
  }) {
    if (!enabled || snap.sprawlRoads.isEmpty) {
      if (_groups.isNotEmpty || _railBatches.isNotEmpty) _clear();
      debugLine = '';
      return;
    }
    final sw = Stopwatch()..start();
    final moved = _bodyMotion(snap, origin);

    final changed = !identical(_roadsSource, snap.sprawlRoads) ||
        !identical(_nodesSource, snap.sprawlNodes);
    if (changed) {
      _roadsSource = snap.sprawlRoads;
      _nodesSource = snap.sprawlNodes;
      _rebuildRails(snap, groundRadiusAt);
      _regroup(snap);
    }
    phaseMs['sprawl.roads'] = sw.elapsedMicroseconds / 1000;
    sw.reset();

    // Tiers, from the focus. A group's tier is its nearest road's.
    var close = 0, near = 0, mid = 0, far = 0;
    for (final g in _groups.values) {
      final body = snap.bodies[g.bodyId];
      if (body == null) continue;
      final bodyWorld = Vector3(body.px, body.py, body.pz);
      final quat = Quaternion(body.qw, body.qx, body.qy, body.qz);
      var best = double.infinity;
      for (final c in g.centres) {
        final world = bodyWorld + quat.rotate(c);
        final d = (world - focusWorld).length;
        if (d < best) best = d;
      }
      g.distanceM = best;
      final tier = best < closeRangeM
          ? SprawlTier.close
          : best < nearRangeM
              ? SprawlTier.near
              : (best < midRangeM ? SprawlTier.mid : SprawlTier.far);
      switch (tier) {
        case SprawlTier.close:
          close++;
        case SprawlTier.near:
          near++;
        case SprawlTier.mid:
          mid++;
        case SprawlTier.far:
          far++;
      }
      if (g.wantTier != tier) {
        g.wantTier = tier;
        if (!g.queued) {
          g.queued = true;
          _queue.add(g);
        }
      }
    }
    phaseMs['sprawl.tier'] = sw.elapsedMicroseconds / 1000;
    sw.reset();

    // Build, nearest first, within the budget: a road at a time.
    if (_queue.isNotEmpty) {
      _queue.sort((a, b) => a.distanceM.compareTo(b.distanceM));
      while (_queue.isNotEmpty && sw.elapsedMilliseconds < buildBudgetMs) {
        final g = _queue.first;
        if (_stepBuild(g, snap)) {
          _queue.removeAt(0);
          g.queued = false;
        }
      }
    }
    phaseMs['sprawl.build'] = sw.elapsedMicroseconds / 1000;
    sw.reset();

    // Anchors, for the bodies that moved and the batches not yet placed.
    var draws = 0;
    for (final b in [..._railBatches, for (final g in _groups.values) ...g.batches]) {
      draws++;
      if (b.placed && !(moved[b.bodyId] ?? true)) continue;
      final body = snap.bodies[b.bodyId];
      if (body == null) continue;
      b.node.localTransform = _anchorTransform(body, b.anchorBF, origin);
      b.placed = true;
    }
    phaseMs['sprawl.anchors'] = sw.elapsedMicroseconds / 1000;
    counts['draws'] = draws;
    counts['close'] = close;
    counts['near'] = near;
    counts['mid'] = mid;
    counts['far'] = far;
    counts['queued'] = _queue.length;
    debugLine = 'sprawl: ${_groups.length} groups ($close close, $near near, '
        '$mid mid, $far far), $draws draws, ${_queue.length} queued';
  }

  // ---- Roads ----------------------------------------------------------------

  /// The railway, per body: track is the same at every distance, and a
  /// line is one long thing rather than a run of pieces.
  void _rebuildRails(
      WorldSnapshot snap, double Function(Vector3)? groundRadiusAt) {
    for (final b in _railBatches) {
      _scene.remove(b.node);
    }
    _railBatches.clear();
    final byBody = <String, List<SprawlRoadSnapshot>>{};
    for (final r in snap.sprawlRoads) {
      if (r.kind != SprawlRoadKind.rail.index) continue;
      (byBody[r.body] ??= []).add(r);
    }
    byBody.forEach((bodyId, roads) {
      final first = roads.first;
      final anchorBF = Vector3(first.points[0], first.points[1], first.points[2]);
      final ballast = MeshBuilder();
      final sleepers = MeshBuilder();
      final steel = MeshBuilder();
      for (final r in roads) {
        final pts = _relative(r.points, anchorBF);
        if (pts.length < 2) continue;
        Railway.emit(ballast, sleepers, steel,
            pts: pts, anchorBF: anchorBF, halfWidthM: r.halfWidthM);
      }
      for (final (builder, material) in [
        (ballast, CityMaterials.dirt),
        (sleepers, CityMaterials.sidewalk),
        (steel, CityMaterials.alley),
      ]) {
        _upload(builder, material, bodyId, anchorBF, _railBatches);
      }
    });
  }

  /// Every road and node of the plan goes to the group of the two-mile
  /// cell its middle falls in, and every group is marked to rebuild.
  void _regroup(WorldSnapshot snap) {
    final keep = <String>{};
    String keyOf(String body, Vector3 p) =>
        '$body/${(p.x / groupM).round()}/${(p.y / groupM).round()}/'
        '${(p.z / groupM).round()}';
    _Group groupFor(String body, Vector3 p) {
      final key = keyOf(body, p);
      keep.add(key);
      return _groups.putIfAbsent(key, () => _Group(key, body));
    }

    for (final g in _groups.values) {
      g.roads.clear();
      g.nodes.clear();
      g.centres.clear();
    }
    for (final r in snap.sprawlRoads) {
      final kind = SprawlRoadKind
          .values[r.kind.clamp(0, SprawlRoadKind.values.length - 1)];
      // The plat draws its own rights-of-way; they are on the plan only
      // so the sections keep off them. The railway is drawn per body.
      if (kind == SprawlRoadKind.corridor || kind == SprawlRoadKind.rail) {
        continue;
      }
      final n = r.points.length ~/ 3;
      if (n < 2) continue;
      final m = (n ~/ 2) * 3;
      final mid = Vector3(r.points[m], r.points[m + 1], r.points[m + 2]);
      groupFor(r.body, mid)
        ..roads.add(r)
        ..centres.add(mid);
    }
    for (final nd in snap.sprawlNodes) {
      final at = Vector3(nd.px, nd.py, nd.pz);
      groupFor(nd.body, at).nodes.add(nd);
    }
    for (final key in _groups.keys.toList()) {
      if (keep.contains(key)) continue;
      _dropGroup(_groups.remove(key)!);
    }
    // Everything rebuilds: the tier loop re-queues a group whose want is
    // unset.
    for (final g in _groups.values) {
      g.wantTier = null;
      g.job = null;
    }
  }

  static List<Vector3> _relative(List<double> flat, Vector3 anchorBF) => [
        for (var i = 0; i + 2 < flat.length; i += 3)
          Vector3(flat[i] - anchorBF.x, flat[i + 1] - anchorBF.y,
              flat[i + 2] - anchorBF.z),
      ];

  /// The build step for one road of the plan at [tier].
  static void _roadStep(_BuildJob job, SprawlRoadSnapshot r) {
    final pts = _relative(r.points, job.anchorBF);
    if (pts.length < 2) return;
    final cls = RoadClass
        .values[r.roadClassIndex.clamp(0, RoadClass.values.length - 1)];
    final ranges = <(double, double)>[
      for (var i = 0; i + 1 < r.overpasses.length; i += 2)
        (r.overpasses[i], r.overpasses[i + 1]),
    ];
    final liftAt = ranges.isEmpty
        ? null
        : (double s) => RoadMesher.bridgeLiftAt(s, ranges);
    final detailed = job.tier == SprawlTier.near || job.tier == SprawlTier.close;
    RoadMesher.carriageway(
      job.road,
      pts,
      job.anchorBF,
      cls,
      halfWidthM: r.halfWidthM,
      startHalfWidthM: r.startHalfWidthM,
      endHalfWidthM: r.endHalfWidthM,
      liftAt: liftAt,
      paint: job.tier != SprawlTier.far,
      solid: detailed ? job.solid : null,
    );
    if (liftAt != null) {
      RoadMesher.piers(job.solid, pts, job.anchorBF, r.halfWidthM, liftAt);
    }
    // The walled variant: barriers from mid range, their posts near.
    if (r.soundWalls && cls.canHaveSoundWalls && job.tier != SprawlTier.far) {
      RoadMesher.soundWalls(job.solid, pts, job.anchorBF, r.halfWidthM,
          startHalfWidthM: r.startHalfWidthM,
          endHalfWidthM: r.endHalfWidthM,
          liftAt: liftAt,
          posts: detailed);
    }
    if (!detailed || !cls.hasPavement) return;
    // The plan's roads are split at their junctions, so nearly every end
    // is one: the pavement stops short of the plate and its zebra.
    final pull = r.halfWidthM * 1.45 + 5.5;
    RoadMesher.sidewalks(job.walk, pts, r.halfWidthM, 2.0, job.anchorBF,
        pullStart: pull, pullEnd: pull);
    RoadMesher.lamps(job.solid, job.glass, pts, job.anchorBF, r.halfWidthM, cls,
        liftM: RoadMesher.walkTopLiftM);
  }

  /// The build step for the plan's junctions in a group.
  static void _nodeStep(_BuildJob job, double epoch) {
    if (job.tier == SprawlTier.far) return;
    final detailed = job.tier == SprawlTier.near || job.tier == SprawlTier.close;
    final junctions = <RoadJunction>[];
    for (final n in job.nodes) {
      final legs = <RoadLeg>[];
      for (var i = 0; i + 4 < n.legs.length; i += 5) {
        final cls = RoadClass.values[
            n.legs[i + 4].round().clamp(0, RoadClass.values.length - 1)];
        legs.add(RoadLeg(
            Vector3(n.legs[i], n.legs[i + 1], n.legs[i + 2]).normalized,
            n.legs[i + 3],
            cls));
      }
      junctions.add(RoadJunction(
        Vector3(n.px, n.py, n.pz) - job.anchorBF,
        legs,
        JunctionControl
            .values[n.control.clamp(0, JunctionControl.values.length - 1)],
        liftM: n.liftM,
      ));
    }
    RoadMesher.junctions(job.road, job.solid, job.glass, junctions,
        job.anchorBF, epoch,
        furniture: detailed);
  }

  // ---- Groups -----------------------------------------------------------------

  void _dropGroup(_Group g) {
    for (final b in g.batches) {
      _scene.remove(b.node);
    }
    g.batches.clear();
    _queue.remove(g);
    g.queued = false;
  }

  /// One step of a group's build: the next road into the group's builders,
  /// or — when everything is in — the upload that swaps the group's nodes.
  /// Returns true when the group is done.
  bool _stepBuild(_Group g, WorldSnapshot snap) {
    var job = g.job;
    if (job == null || job.tier != (g.wantTier ?? SprawlTier.far)) {
      final tier = g.wantTier ?? SprawlTier.far;
      if (g.centres.isEmpty) return true;
      // Anchor at the group's mean centre.
      var sum = Vector3.zero;
      for (final c in g.centres) {
        sum = sum + c;
      }
      final anchorBF = sum * (1.0 / g.centres.length);
      job = g.job = _BuildJob(tier, anchorBF, List.of(g.nodes));
      final j = job;
      final epoch = snap.epoch;
      job.steps.add(() => _nodeStep(j, epoch));
      for (final r in g.roads) {
        job.steps.add(() => _roadStep(j, r));
      }
    }
    if (job.steps.isNotEmpty) {
      job.steps.removeLast()();
      return false;
    }
    // Everything is in: swap the nodes.
    for (final b in g.batches) {
      _scene.remove(b.node);
    }
    g.batches.clear();
    for (final (builder, material) in [
      (job.road, CityMaterials.road),
      (job.walk, CityMaterials.sidewalk),
      (job.solid, CityMaterials.facade),
      (job.glass, CityMaterials.glazing),
    ]) {
      _upload(builder, material, g.bodyId, job.anchorBF, g.batches);
    }
    g.builtTier = job.tier;
    g.job = null;
    return true;
  }

  void _upload(MeshBuilder builder, fs.Material material, String bodyId,
      Vector3 anchorBF, List<_Batch> into) {
    final mesh = builder.build();
    if (mesh.isEmpty) return;
    final geometry = CityNodes.geometryOf(mesh);
    if (geometry == null) return;
    final node = fs.Node(
      mesh: fs.Mesh.primitives(primitives: [fs.MeshPrimitive(geometry, material)]),
    );
    _scene.add(node);
    into.add(_Batch(node, bodyId, anchorBF));
  }

  // ---- Frames -----------------------------------------------------------------

  Map<String, bool> _bodyMotion(WorldSnapshot snap, FloatingOrigin origin) {
    final moved = <String, bool>{};
    for (final entry in snap.bodies.entries) {
      final body = entry.value;
      final pose = (
        Vector3(body.px, body.py, body.pz),
        Quaternion(body.qw, body.qx, body.qy, body.qz),
        origin.focusWorld,
      );
      final last = _placedPose[entry.key];
      final same = last != null &&
          last.$1 == pose.$1 &&
          last.$2 == pose.$2 &&
          last.$3 == pose.$3;
      moved[entry.key] = !same;
      if (!same) _placedPose[entry.key] = pose;
    }
    return moved;
  }

  static vm.Matrix4 _anchorTransform(
      BodySnapshot body, Vector3 anchorBF, FloatingOrigin origin) {
    final bodyWorld = Vector3(body.px, body.py, body.pz);
    final bodyQuat = Quaternion(body.qw, body.qx, body.qy, body.qz);
    return vm.Matrix4.compose(
      origin.worldToScene(bodyWorld + bodyQuat.rotate(anchorBF)),
      quatToScene(bodyQuat),
      vm.Vector3.all(1.0),
    );
  }

  void _clear() {
    for (final b in _railBatches) {
      _scene.remove(b.node);
    }
    _railBatches.clear();
    _roadsSource = null;
    _nodesSource = null;
    for (final g in _groups.values) {
      _dropGroup(g);
    }
    _groups.clear();
    _queue.clear();
  }

  void dispose() => _clear();
}

/// One draw, pinned to a body-fixed anchor.
class _Batch {
  _Batch(this.node, this.bodyId, this.anchorBF);
  final fs.Node node;
  final String bodyId;
  final Vector3 anchorBF;
  bool placed = false;
}

/// The plan's roads and junctions in one two-mile cell, sharing their nodes.
class _Group {
  _Group(this.key, this.bodyId);
  final String key;
  final String bodyId;
  final List<SprawlRoadSnapshot> roads = [];
  final List<SprawlNodeSnapshot> nodes = [];

  /// The roads' middles, body-fixed: what the tier is measured from.
  final List<Vector3> centres = [];
  final List<_Batch> batches = [];
  SprawlTier? builtTier;
  SprawlTier? wantTier;
  bool queued = false;
  double distanceM = double.infinity;
  _BuildJob? job;
}

/// A group build in progress: its builders, and the parts still to run.
class _BuildJob {
  _BuildJob(this.tier, this.anchorBF, this.nodes);
  final SprawlTier tier;
  final Vector3 anchorBF;

  /// The plan's junctions this group draws.
  final List<SprawlNodeSnapshot> nodes;

  /// The parts of the build, run one per call from the end.
  final List<void Function()> steps = [];
  final MeshBuilder road = MeshBuilder();
  final MeshBuilder walk = MeshBuilder();
  final MeshBuilder solid = MeshBuilder();
  final MeshBuilder glass = MeshBuilder();
}
