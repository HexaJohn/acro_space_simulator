// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The sprawl, drawn: the roads of the plan, and every mile-square section
/// grown from its seed at a level of detail set by how far away it is.
///
/// Four tiers — close, near, mid, far — described with the section builder
/// in `sprawl_section.dart`. Far, a section is the silhouettes of its rows
/// of roofs, the way the plat's block tier is one merged skyline; close, it
/// is a street with mailboxes and a car in every other driveway.
///
/// Sections are grouped two by two and each group is one node per material,
/// so a twenty-mile city is a hundred-odd draws rather than a thousand; a
/// group is rebuilt only when its tier changes, a little per frame, nearest
/// first, so the camera can move without the frame stopping.
///
/// The plan's ROADS are tiered with the groups: every road and every
/// junction of the plan belongs to the group nearest its middle and is
/// drawn at that group's tier, through the same [RoadMesher] the platted
/// core draws through. Far, an expressway is an asphalt ribbon; mid, its
/// lanes are painted; near, it has its barrier, and the county highway
/// beside it has sidewalks, lamps, and signals where the subdivision's
/// collectors meet it.
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
import 'sprawl_section.dart';

class SprawlNodes {
  SprawlNodes(this._scene);

  final fs.Scene _scene;

  static bool enabled = true;

  /// Sections nearer than this get the street's clutter: driveways and
  /// their cars, mailboxes, fences, pools, hydrants.
  static double closeRangeM = 700;

  /// Sections nearer than this get houses with roofs and windows, trees,
  /// poles and wires — and their roads get sidewalks, lamps and junction
  /// furniture.
  static double nearRangeM = 2800;

  /// Nearer than this, houses as flat blocks and lanes painted on the
  /// roads; beyond, block slabs and bare ribbons.
  static double midRangeM = 7500;

  /// Milliseconds of building the frame will spend before deferring the
  /// rest of the queue.
  static double buildBudgetMs = 9;

  static final Map<String, double> phaseMs = {};
  static final Map<String, int> counts = {};
  static String debugLine = '';

  List<SprawlRoadSnapshot>? _roadsSource;
  List<SprawlNodeSnapshot>? _nodesSource;
  final List<_Batch> _railBatches = [];
  List<SprawlSectionSnapshot>? _sectionsSource;
  final Map<String, _Group> _groups = {};
  final List<_Group> _queue = [];
  final Map<String, (Vector3, Quaternion, Vector3)> _placedPose = {};

  void update(
    WorldSnapshot snap,
    FloatingOrigin origin, {
    required Vector3 focusWorld,
    double Function(Vector3 dirBF)? groundRadiusAt,
  }) {
    if (!enabled || snap.sprawlSections.isEmpty) {
      if (_groups.isNotEmpty || _railBatches.isNotEmpty) _clear();
      debugLine = '';
      return;
    }
    final sw = Stopwatch()..start();
    final moved = _bodyMotion(snap, origin);

    final sectionsChanged = !identical(_sectionsSource, snap.sprawlSections);
    final roadsChanged = !identical(_roadsSource, snap.sprawlRoads) ||
        !identical(_nodesSource, snap.sprawlNodes);
    if (sectionsChanged) {
      _sectionsSource = snap.sprawlSections;
      _regroup(snap);
    }
    if (sectionsChanged || roadsChanged) {
      _roadsSource = snap.sprawlRoads;
      _nodesSource = snap.sprawlNodes;
      _rebuildRails(snap, groundRadiusAt);
      _assignRoads(snap);
    }
    phaseMs['sprawl.roads'] = sw.elapsedMicroseconds / 1000;
    sw.reset();

    // Tiers, from the focus. A group's tier is its nearest section's.
    var close = 0, near = 0, mid = 0, far = 0;
    for (final g in _groups.values) {
      final body = snap.bodies[g.bodyId];
      if (body == null) continue;
      final bodyWorld = Vector3(body.px, body.py, body.pz);
      final quat = Quaternion(body.qw, body.qx, body.qy, body.qz);
      var best = double.infinity;
      for (final s in g.sections) {
        final world = bodyWorld + quat.rotate(Vector3(s.px, s.py, s.pz));
        final d = (world - focusWorld).length - s.sizeM * 0.5;
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

    // Build, nearest first, within the budget: a section at a time, so a
    // near group of four never takes the whole frame.
    if (_queue.isNotEmpty) {
      _queue.sort((a, b) => a.distanceM.compareTo(b.distanceM));
      while (_queue.isNotEmpty && sw.elapsedMilliseconds < buildBudgetMs) {
        final g = _queue.first;
        if (_stepBuild(g, snap, groundRadiusAt)) {
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
      // Anchor at the first section of this body, so offsets stay small.
      final first = snap.sprawlSections.firstWhere((s) => s.body == bodyId,
          orElse: () => snap.sprawlSections.first);
      final anchorBF = Vector3(first.px, first.py, first.pz);
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

  /// Every road and node of the plan goes to the group nearest its middle,
  /// and every group is marked to rebuild with what it was given.
  void _assignRoads(WorldSnapshot snap) {
    final centres = <(Vector3, _Group)>[];
    for (final g in _groups.values) {
      g.roads.clear();
      g.nodes.clear();
      for (final s in g.sections) {
        centres.add((Vector3(s.px, s.py, s.pz), g));
      }
    }
    if (centres.isEmpty) return;
    _Group? nearest(String bodyId, Vector3 p) {
      _Group? best;
      var bestD = double.infinity;
      for (final (c, g) in centres) {
        if (g.bodyId != bodyId) continue;
        final d = (c - p).lengthSquared;
        if (d < bestD) {
          bestD = d;
          best = g;
        }
      }
      return best;
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
      nearest(r.body, Vector3(r.points[m], r.points[m + 1], r.points[m + 2]))
          ?.roads
          .add(r);
    }
    for (final nd in snap.sprawlNodes) {
      nearest(nd.body, Vector3(nd.px, nd.py, nd.pz))?.nodes.add(nd);
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

  /// The build steps for one road of the plan at [tier].
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

  // ---- Sections -------------------------------------------------------------

  void _regroup(WorldSnapshot snap) {
    final keep = <String>{};
    for (final s in snap.sprawlSections) {
      // Group index from the section's centre in its own frame is not on
      // the wire; the seed carries i and j (seed = base + i*1009 + j*31),
      // but a spatial key is simpler: body plus a coarse quantised centre.
      final key = '${s.body}/${(s.px / (s.sizeM * 2)).round()}/'
          '${(s.py / (s.sizeM * 2)).round()}/${(s.pz / (s.sizeM * 2)).round()}';
      keep.add(key);
      final g = _groups.putIfAbsent(
          key, () => _Group(key, s.body, snap.sprawlSections.first.colonyId));
      if (!g.sections.contains(s)) g.sections.add(s);
    }
    for (final key in _groups.keys.toList()) {
      if (keep.contains(key)) continue;
      final g = _groups.remove(key)!;
      _dropGroup(g);
    }
  }

  void _dropGroup(_Group g) {
    for (final b in g.batches) {
      _scene.remove(b.node);
    }
    g.batches.clear();
    _queue.remove(g);
    g.queued = false;
  }

  /// One step of a group's build: the next section into the group's
  /// builders, then its roads and junctions, or — when everything is in —
  /// the upload that swaps the group's nodes. Returns true when the group
  /// is done.
  bool _stepBuild(_Group g, WorldSnapshot snap,
      double Function(Vector3)? groundRadiusAt) {
    var job = g.job;
    if (job == null || job.tier != (g.wantTier ?? SprawlTier.far)) {
      final tier = g.wantTier ?? SprawlTier.far;
      if (g.sections.isEmpty) return true;
      // Anchor at the group's mean centre.
      var sum = Vector3.zero;
      for (final s in g.sections) {
        sum = sum + Vector3(s.px, s.py, s.pz);
      }
      final anchorBF = sum * (1.0 / g.sections.length);
      // Interstates and ramps of this body, for the corridor the houses
      // keep clear of.
      final corridors = <List<Vector3>>[];
      for (final r in snap.sprawlRoads) {
        if (r.body != g.bodyId) continue;
        final kind = SprawlRoadKind
            .values[r.kind.clamp(0, SprawlRoadKind.values.length - 1)];
        if (kind == SprawlRoadKind.countyHighway) continue;
        corridors.add(_relative(r.points, Vector3.zero));
      }
      // Where the plan's junctions are: a section runs its collector out
      // to the county highway only where the plan put a node for it.
      final nodePoints = <Vector3>[
        for (final n in snap.sprawlNodes)
          if (n.body == g.bodyId) Vector3(n.px, n.py, n.pz),
      ];
      job = g.job = _BuildJob(tier, anchorBF, corridors,
          snap.sprawlClearings[g.colonyId] ?? const [], List.of(g.sections),
          List.of(g.roads), List.of(g.nodes), nodePoints);
    }
    // A section is a list of parts — a street's worth of houses, a row of
    // slabs — and one call runs one part: a near section alone is a hundred
    // milliseconds of ground samples, far more than a frame has to spare.
    if (job.steps.isEmpty && job.pending.isNotEmpty) {
      final s = job.pending.removeLast();
      job.steps.addAll(SprawlSectionBuilder(
              s, job.anchorBF, groundRadiusAt, job.corridors,
              clearings: job.clearings, nodePoints: job.nodePoints)
          .steps(job.tier, job.ground, job.road, job.walk, job.solid,
              job.glass));
    }
    // Then the plan's roads, one part each, and its junctions in one.
    if (job.steps.isEmpty && job.pending.isEmpty && !job.roadsQueued) {
      job.roadsQueued = true;
      final j = job;
      final epoch = snap.epoch;
      job.steps.add(() => _nodeStep(j, epoch));
      for (final r in job.roads) {
        job.steps.add(() => _roadStep(j, r));
      }
    }
    if (job.steps.isNotEmpty) {
      job.steps.removeLast()();
      return false;
    }
    // Every section is in: swap the nodes.
    for (final b in g.batches) {
      _scene.remove(b.node);
    }
    g.batches.clear();
    for (final (builder, material) in [
      (job.ground, CityMaterials.ground),
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
    _sectionsSource = null;
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

/// Two-by-two sections that share their nodes, and the plan's roads and
/// junctions nearest them.
class _Group {
  _Group(this.key, this.bodyId, this.colonyId);
  final String key;
  final String bodyId;
  final String colonyId;
  final List<SprawlSectionSnapshot> sections = [];
  final List<SprawlRoadSnapshot> roads = [];
  final List<SprawlNodeSnapshot> nodes = [];
  final List<_Batch> batches = [];
  SprawlTier? builtTier;
  SprawlTier? wantTier;
  bool queued = false;
  double distanceM = double.infinity;
  _BuildJob? job;
}

/// A group build in progress: its builders, and the sections still to go.
class _BuildJob {
  _BuildJob(this.tier, this.anchorBF, this.corridors, this.clearings,
      this.pending, this.roads, this.nodes, this.nodePoints);
  final SprawlTier tier;
  final Vector3 anchorBF;
  final List<List<Vector3>> corridors;

  /// The colony's staked plots, flat e/n polygons: nothing is built on them.
  final List<List<double>> clearings;
  final List<SprawlSectionSnapshot> pending;

  /// The plan's roads and junctions this group draws.
  final List<SprawlRoadSnapshot> roads;
  final List<SprawlNodeSnapshot> nodes;

  /// Every junction of the plan on this body, body-fixed.
  final List<Vector3> nodePoints;
  bool roadsQueued = false;

  /// The parts of the section being built, run one per call.
  final List<void Function()> steps = [];
  final MeshBuilder ground = MeshBuilder();
  final MeshBuilder road = MeshBuilder();
  final MeshBuilder walk = MeshBuilder();
  final MeshBuilder solid = MeshBuilder();
  final MeshBuilder glass = MeshBuilder();
}
