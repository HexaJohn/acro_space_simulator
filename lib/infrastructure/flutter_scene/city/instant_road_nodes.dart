// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The roads just edited, drawn the frame they change.
///
/// A tile is meshed on a worker and lands seconds after the frame that
/// changed it — nearest first, a few a frame, twenty or thirty seconds for a
/// colony's worth after a regrade. For a road the player has just drawn or
/// upgraded that reads as the tool doing nothing. So the renderer draws
/// every road whose content changed since the last cut straight away, on the
/// UI thread, through the same road pipeline the tiles use — one node per
/// body, a few centimetres over the tile surface so it wins over the road it
/// replaces — and retires each one when the tile that owns it shows a build
/// of its current structure, which has the road in it.
///
/// What this does not do is take anything AWAY. A removed road, or the old
/// shape of a changed one, stays in its tile's old mesh until that tile
/// swaps its new build in — seconds. Hiding it would mean cutting into the
/// tile's merged geometry, which the UI thread does not hold; the new road
/// drawn over the old is what the player is looking at, and the tile catches
/// up behind it.
///
/// Plain Dart except for what `CityNodes` does with the geometry: the
/// tracker and the meshing are tested without a scene.
library;

import 'dart:typed_data';

import '../../../application/snapshot/world_snapshot.dart';
import '../../../domain/colony/city/parcel.dart';
import '../../../domain/colony/city/road_elevation.dart';
import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/shared/vector3.dart';
import 'city_tile_bucketing.dart';
import 'city_tile_mesher.dart' show CityMaterialKind;
import 'road_mesher.dart';

/// A road's deck above its drape, one value per polyline point, read by arc
/// length the way the road pipeline's `liftAt` asks for it.
///
/// The pipeline walks one station per point and measures arc as the sum of
/// the point-to-point distances; this measures it the same way, so at every
/// station the answer is that point's own lift exactly, and between them
/// (a pier, a wall panel's middle) it is the straight line between the two.
class RoadLiftProfile {
  RoadLiftProfile(List<Vector3> pts, this._lifts)
      : assert(pts.length == _lifts.length),
        _s = Float64List(pts.length) {
    for (var i = 1; i < pts.length; i++) {
      _s[i] = _s[i - 1] + (pts[i] - pts[i - 1]).length;
    }
  }

  final Float64List _s;
  final List<double> _lifts;

  /// The lift at arc [s] from the first point.
  double at(double s) {
    final n = _lifts.length;
    if (n == 0) return 0;
    if (s <= _s[0]) return _lifts[0];
    if (s >= _s[n - 1]) return _lifts[n - 1];
    // The last station at or before s.
    var lo = 0, hi = n - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (_s[mid] <= s) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final span = _s[hi] - _s[lo];
    if (span <= 1e-12) return _lifts[lo];
    return _lifts[lo] + (_lifts[hi] - _lifts[lo]) * ((s - _s[lo]) / span);
  }
}

/// A run of a polyline's points, [from] to [to] inclusive, all above ground
/// or all in a [tunnel].
typedef LiftRun = ({int from, int to, bool tunnel});

/// The polyline of [n] points cut into runs above ground and in tunnels,
/// by SEGMENT: a segment is in a tunnel when its middle — the mean of its
/// two points' [liftOf] — is below `-RoadElevation.tunnelCoverM`. Adjacent
/// runs share their boundary point, so what is drawn above ground meets the
/// portal it goes in at.
List<LiftRun> tunnelRuns(int n, double Function(int i) liftOf) {
  if (n < 2) return const [];
  bool tunnelAt(int seg) =>
      (liftOf(seg) + liftOf(seg + 1)) / 2 < -RoadElevation.tunnelCoverM;
  final out = <LiftRun>[];
  var from = 0;
  var tunnel = tunnelAt(0);
  for (var seg = 1; seg < n - 1; seg++) {
    final t = tunnelAt(seg);
    if (t == tunnel) continue;
    out.add((from: from, to: seg, tunnel: tunnel));
    from = seg;
    tunnel = t;
  }
  out.add((from: from, to: n - 1, tunnel: tunnel));
  return out;
}

/// One road waiting for its tile: the snapshot to draw, the body it is on,
/// and the tile whose new build will have it.
class InstantRoad {
  const InstantRoad(this.bodyId, this.road, this.tileKey);
  final String bodyId;
  final RoadSnapshot road;
  final String tileKey;
}

/// Which roads the instant path draws: those whose content is new since the
/// last cut, until their tiles catch up.
///
/// A road is known by its id AND its content ([contentKey]): an upgraded
/// road keeps its id and changes its content, a road split by a new
/// crossing keeps its content in pieces with new ids, and either way what
/// the tile shows is not what the frame says.
class InstantRoadTracker {
  /// Edited roads a single cut may hand the instant path. A player's edit
  /// is a road and the pieces it split; a cut past this — a colony loaded,
  /// a plan laid, a city generated — is the tiles' to bring in, not the UI
  /// thread's to mesh in one frame.
  static int maxEditedPerCut = 96;

  /// Per body, every road's content key as of the last cut.
  final Map<String, Set<int>> _seen = {};
  final Map<int, InstantRoad> _pending = {};
  final Map<String, int> _revision = {};

  /// A road's identity for the tracker: its content hash
  /// ([CityTileBucketer.roadHash]) and its id.
  static int contentKey(int roadHash, String? id) {
    final x = (roadHash ^ (id?.hashCode ?? 0x5bd1e995)) * 0x5851F42D4C957F2D;
    return x ^ (x >>> 31);
  }

  /// Note a new cut: its roads whose content is new join the pending set,
  /// and pending roads the cut no longer has (removed, or changed again)
  /// leave it.
  ///
  /// A body's FIRST cut counts every road as new when there are few enough
  /// of them: a new colony's first road is drawn the frame it is laid like
  /// every other, and a small colony loaded is drawn at once, as well as
  /// by its tiles a moment later.
  void noteCut(Iterable<CityTileBucket> tiles) {
    final now = <String, Map<int, InstantRoad>>{};
    for (final t in tiles) {
      final roads = now[t.bodyId] ??= {};
      for (var i = 0; i < t.roads.length; i++) {
        final road = t.roads[i];
        roads[contentKey(t.roadHashes[i], road.id)] =
            InstantRoad(t.bodyId, road, t.key);
      }
    }
    final touched = <String>{};
    _pending.removeWhere((k, e) {
      final gone = !(now[e.bodyId]?.containsKey(k) ?? false);
      if (gone) touched.add(e.bodyId);
      return gone;
    });
    for (final entry in now.entries) {
      final body = entry.key;
      final roads = entry.value;
      final seen = _seen[body];
      final edited = seen == null
          ? roads.keys.toList()
          : [
              for (final k in roads.keys)
                if (!seen.contains(k)) k,
            ];
      _seen[body] = roads.keys.toSet();
      if (edited.isEmpty || edited.length > maxEditedPerCut) continue;
      for (final k in edited) {
        if (_pending.containsKey(k)) continue;
        _pending[k] = roads[k]!;
        touched.add(body);
      }
    }
    _seen.removeWhere((body, _) => !now.containsKey(body));
    for (final body in touched) {
      _revision[body] = (_revision[body] ?? 0) + 1;
    }
  }

  /// Drop every pending road whose tile [showsCurrent] — shows a build of
  /// its current structure, or is gone. True when any went.
  bool retire(bool Function(String tileKey) showsCurrent) {
    if (_pending.isEmpty) return false;
    final touched = <String>{};
    _pending.removeWhere((_, e) {
      final done = showsCurrent(e.tileKey);
      if (done) touched.add(e.bodyId);
      return done;
    });
    for (final body in touched) {
      _revision[body] = (_revision[body] ?? 0) + 1;
    }
    return touched.isNotEmpty;
  }

  /// Bodies with roads pending.
  Set<String> get bodies => {for (final e in _pending.values) e.bodyId};

  bool hasPendingOn(String bodyId) =>
      _pending.values.any((e) => e.bodyId == bodyId);

  Iterable<InstantRoad> pendingOn(String bodyId) =>
      _pending.values.where((e) => e.bodyId == bodyId);

  int get pendingCount => _pending.length;

  /// Moves whenever [bodyId]'s pending set does: what its node is keyed on.
  int revisionOf(String bodyId) => _revision[bodyId] ?? 0;

  /// Forget everything — the renderer dropped its tiles, so the next cut is
  /// every body's first.
  void reset() {
    _seen.clear();
    _pending.clear();
    for (final body in _revision.keys.toList()) {
      _revision[body] = _revision[body]! + 1;
    }
  }
}

/// The instant roads of one body, as geometry by material.
class InstantRoadGeometry {
  final MeshBuilder road = MeshBuilder();
  final MeshBuilder dirt = MeshBuilder();
  final MeshBuilder alley = MeshBuilder();

  /// Piers, and a barrier median's blocks.
  final MeshBuilder solid = MeshBuilder();

  /// Roads drawn.
  int roads = 0;

  List<(MeshBuilder, CityMaterialKind)> get parts => [
        (road, CityMaterialKind.road),
        (dirt, CityMaterialKind.dirt),
        (alley, CityMaterialKind.alley),
        (solid, CityMaterialKind.facade),
      ];
}

/// One road into [InstantRoadGeometry], relative to a body root's anchor.
class InstantRoadMesher {
  const InstantRoadMesher._();

  /// How far over the tile surface an instant road rides: enough to win the
  /// depth test against the road it replaces, not enough to read as a step.
  static const double overTileM = 0.05;

  /// Draw [road] into [g] anchored at [anchorBF]: the carriageway (or the
  /// gravel or alley ribbon) on its deck, and piers under whatever of it
  /// stands clear of the ground. Tunnel stretches are skipped — the
  /// ground is over them. A structure of its own (the viaduct, the line)
  /// and the railway are the tiles' alone; nothing the road tool edits.
  /// Returns whether anything was drawn.
  static bool emit(InstantRoadGeometry g, RoadSnapshot road, Vector3 anchorBF) {
    final p = road.points;
    final n = p.length ~/ 3;
    if (n < 2) return false;
    final cls = RoadClass
        .values[road.roadClassIndex.clamp(0, RoadClass.values.length - 1)];
    if (cls.isElevated || cls == RoadClass.rail) return false;
    final pts = <Vector3>[
      for (var i = 0; i + 2 < p.length; i += 3)
        Vector3(p[i] - anchorBF.x, p[i + 1] - anchorBF.y, p[i + 2] - anchorBF.z),
    ];
    final lifts = road.lifts.length == n ? road.lifts : const <double>[];
    final ranges = <(double, double)>[
      for (var i = 0; i + 1 < road.bridges.length; i += 2)
        (road.bridges[i], road.bridges[i + 1]),
    ];
    // Each point's arc from the road's start, so a run's bridges are where
    // the whole road's are.
    final arc = Float64List(n);
    for (var i = 1; i < n; i++) {
      arc[i] = arc[i - 1] + (pts[i] - pts[i - 1]).length;
    }
    const liftM = RoadMesher.ribbonLiftM + overTileM;
    var drew = false;
    for (final run in tunnelRuns(n, (i) => lifts.isEmpty ? 0.0 : lifts[i])) {
      if (run.tunnel) continue;
      final runPts = pts.sublist(run.from, run.to + 1);
      final profile = lifts.isEmpty
          ? null
          : RoadLiftProfile(runPts, lifts.sublist(run.from, run.to + 1));
      final s0 = arc[run.from];
      double liftAt(double s) =>
          (profile?.at(s) ?? 0.0) +
          (ranges.isEmpty ? 0.0 : RoadMesher.bridgeLiftAt(s0 + s, ranges));
      final lifted = profile != null || ranges.isNotEmpty;
      if (cls == RoadClass.alley) {
        RoadMesher.ribbon(g.alley, runPts, anchorBF, road.halfWidthM,
            liftM: liftM, liftAt: lifted ? liftAt : null);
      } else if (!cls.paved) {
        RoadMesher.ribbon(g.dirt, runPts, anchorBF, road.halfWidthM,
            liftM: liftM, liftAt: lifted ? liftAt : null);
      } else {
        // A taper belongs to the road's own ends, not to a portal's.
        RoadMesher.carriageway(g.road, runPts, anchorBF, cls,
            halfWidthM: road.halfWidthM,
            startHalfWidthM: run.from == 0 ? road.startHalfWidthM : null,
            endHalfWidthM: run.to == n - 1 ? road.endHalfWidthM : null,
            liftM: liftM,
            liftAt: lifted ? liftAt : null,
            solid: g.solid);
      }
      if (lifted) {
        RoadMesher.piers(g.solid, runPts, anchorBF, road.halfWidthM, (s) {
          final l = liftAt(s);
          return l > RoadElevation.structureClearM ? l : 0.0;
        });
      }
      drew = true;
    }
    if (drew) g.roads++;
    return drew;
  }
}
