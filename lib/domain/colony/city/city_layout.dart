// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:collection' show UnmodifiableListView;
import 'dart:math' as math;

import 'parcel.dart';
import 'spatial_index.dart';

/// Player-facing knobs for how land is cut up.
///
/// These are the settings the parcels are "dynamically drawn" from: change the
/// frontage and the same road re-subdivides into wider or narrower lots on the
/// next regeneration, without any of the fixed-cell rounding a grid imposes.
class ParcelSettings {
  /// Street frontage per lot, in metres. Narrow (10 m) gives terraced housing;
  /// wide (60 m) gives suburban plots or industrial units.
  final double frontageM;

  /// How far a lot extends back from the street.
  final double depthM;

  /// Verge + footway between the carriageway edge and the property line.
  final double sidewalkM;

  /// Lots shorter than this fraction of [frontageM] are dropped rather than
  /// left as slivers at the end of a run.
  final double minFrontageFraction;

  /// Keep-clear distance around a junction, so lots do not get cut across the
  /// mouth of an intersection.
  final double cornerClearM;

  /// Subdivide both sides of a road, or only the left.
  final bool bothSides;

  const ParcelSettings({
    this.frontageM = 24,
    this.depthM = 32,
    this.sidewalkM = 3,
    this.minFrontageFraction = 0.6,
    this.cornerClearM = 12,
    this.bothSides = true,
  });

  ParcelSettings copyWith({
    double? frontageM,
    double? depthM,
    double? sidewalkM,
    double? minFrontageFraction,
    double? cornerClearM,
    bool? bothSides,
  }) =>
      ParcelSettings(
        frontageM: frontageM ?? this.frontageM,
        depthM: depthM ?? this.depthM,
        sidewalkM: sidewalkM ?? this.sidewalkM,
        minFrontageFraction: minFrontageFraction ?? this.minFrontageFraction,
        cornerClearM: cornerClearM ?? this.cornerClearM,
        bothSides: bothSides ?? this.bothSides,
      );
}

/// The colony's roads, its parcels, and the rule that derives one from the
/// other.
///
/// Auto parcels are regenerated wholesale whenever the network or the settings
/// change; manual parcels are never touched, and auto parcels that would clash
/// with them (or with a carriageway) are simply not emitted. That combination
/// is what lets a street grid and a two-kilometre solar farm share a colony.
///
/// Every "what is near this?" the plat asks goes through the road index
/// (see `spatial_index.dart`), so the cost of a lot is the roads around
/// it, not the roads in the city. That is what lets the twenty-mile sprawl
/// be platted like the downtown instead of described.
/// Where a committed road met an existing one: [sNew] along the new road,
/// [sOld] along [otherId] — as they were before either was cut — and
/// whether one passed over the other rather than meeting it.
class RoadCrossing {
  const RoadCrossing(this.otherId, this.sNew, this.sOld, this.at,
      {this.bridged = false});
  final String otherId;
  final double sNew, sOld;
  final Vec2 at;
  final bool bridged;
}

class CityLayout {
  CityLayout({ParcelSettings settings = const ParcelSettings()})
      : _settings = settings;

  final Map<String, RoadSpline> _roads = {};
  final List<Parcel> _manual = [];
  List<Parcel> _auto = const [];
  ParcelSettings _settings;
  int _nextId = 0;

  /// Bumped on every [regenerate], which every mutation goes through.
  /// The connectivity cache is keyed on it, so the graph walk runs when a
  /// road is drawn, not every tick.
  int version = 0;

  ParcelSettings get settings => _settings;

  set settings(ParcelSettings value) {
    _settings = value;
    regenerate();
  }

  Iterable<RoadSpline> get roads => _roads.values;

  /// Every parcel, manual first so an override wins any ambiguous hit test.
  List<Parcel> get parcels => [..._manual, ..._auto];

  /// Views, not copies: a colony of half a million lots cannot afford a
  /// list allocation per look.
  List<Parcel> get autoParcels => UnmodifiableListView(_auto);
  List<Parcel> get manualParcels => UnmodifiableListView(_manual);

  /// Every parcel by id, and every parcel by where it is. Rebuilt with the
  /// plat; the lookups the sim makes per lot per tick go through these
  /// rather than a scan of the list.
  final Map<String, Parcel> _byId = {};
  BoxIndex<Parcel> _lotIndex = BoxIndex<Parcel>();

  Parcel? parcelById(String id) => _byId[id];

  void _reindex() {
    _byId.clear();
    _lotIndex = BoxIndex<Parcel>();
    for (final p in _manual) {
      _byId[p.id] = p;
      _lotIndex.add(p, _boxOf(p));
    }
    for (final p in _auto) {
      _byId[p.id] = p;
      _lotIndex.add(p, _boxOf(p));
    }
  }

  /// Raw insert: no splitting, no snapping. The LOAD path — a save stores
  /// roads already split at their junctions, and re-splitting on restore
  /// would double every cut. The editor goes through [commitRoad].
  void addRoad(RoadSpline road) {
    _roads[road.id] = road;
    _index.add(road);
    final m = RegExp(r'^r(\d+)').firstMatch(road.id);
    if (m != null) {
      final n = int.parse(m.group(1)!);
      if (n >= _commitSeq) _commitSeq = n + 1;
    }
    regenerate();
  }

  int _commitSeq = 0;

  /// Every road's samples, indexed by where they are.
  ///
  /// `RoadSpline.distanceTo` re-samples the entire spline on every call, and
  /// a scan of every road for every lot corner is quadratic in the city.
  /// Held here at the crossing test's own 2 m and kept in step with
  /// [_roads] on every add, split and removal, so each question the plat
  /// asks — a lot's depth ray, a corner's side street, a new road's
  /// crossings, the nearest curb — costs what is near it.
  final SegmentIndex _index = SegmentIndex();

  /// Read access for the connectivity walk, which asks the same questions.
  SegmentIndex get roadIndex => _index;

  /// The widest half width any class has: how far out a query must reach
  /// to be sure of every road that could matter to it.
  static final double _maxHalfWidth =
      RoadClass.values.fold(0.0, (m, c) => math.max(m, c.halfWidth));

  static Box2 _boxOf(Parcel p) {
    final b = p.bounds;
    return Box2(b.minE, b.minN, b.maxE, b.maxN);
  }

  /// Distance from [p] to the nearest of the given segments of [rec].
  static double _nearestOf(IndexedRoad rec, List<int> segs, Vec2 p) {
    var best = double.infinity;
    for (final s in segs) {
      final d = s == 0
          ? p.distanceTo(rec.sampleAt(0))
          : rec.distanceToSegment(p, s);
      if (d < best) best = d;
    }
    return best;
  }

  /// The nearest point on any road within [withinM] of [p], for endpoint
  /// snapping — drawing toward an existing street should join it, not stop a
  /// metre short of it.
  ({String roadId, Vec2 point})? nearestRoadPoint(Vec2 p, {double withinM = 15}) {
    String? bestId;
    Vec2? bestPt;
    var best = withinM;
    _index.visit(Box2.around(p, withinM), 0, (_, rec, seg) {
      final (q, d) = seg == 0
          ? (rec.sampleAt(0), p.distanceTo(rec.sampleAt(0)))
          : rec.nearestOnSegment(p, seg);
      if (d < best) {
        best = d;
        bestId = rec.road.id;
        bestPt = q;
      }
    });
    return bestId == null ? null : (roadId: bestId!, point: bestPt!);
  }

  /// Add a road THE EDITOR way: split it and everything it crosses at the
  /// junctions, so intersections are real topology rather than two ribbons
  /// overlapping.
  ///
  /// Splitting renames the cut roads' segments, which renames their LOTS —
  /// and buildings are keyed by lot id. The returned map (old lot id -> new
  /// lot id, matched by centroid containment) is how the caller carries its
  /// buildings across the rename; without it, crossing a road through a built
  /// district would orphan every building on it.
  /// How far a bridge reaches either side of the crossing it carries an
  /// expressway over, and how close to an expressway's end there is no
  /// room to climb to one.
  static const double bridgeHalfM = 190;
  static const double bridgeEndClearM = 260;

  ({
    String roadId,
    Map<String, String> renamedLots,
    List<RoadCrossing> crossings,
  }) commitRoad({
    required List<Vec2> controls,
    RoadClass roadClass = RoadClass.street,
    double snapM = 15,
    // Whether each end may snap onto a road it is drawn near. A ramp's
    // merge lands on an expressway's EDGE, a lane out from the centreline,
    // and must not be pulled onto it.
    bool snapStart = true,
    bool snapEnd = true,
    // Where the road rides a bridge, as arc ranges from its start; and its
    // width at either end where it tapers into what it meets. See
    // [RoadSpline.bridges], [RoadSpline.startHalfWidthM].
    List<(double, double)> bridges = const [],
    double? startHalfWidthM,
    double? endHalfWidthM,
    // How near each of this road's ends nothing is bridged: an expressway
    // has no room to climb within [bridgeEndClearM] of where it ends —
    // but a piece laid to meet another end to end (the seam where its
    // lanes drop) ends nowhere, and passes zero.
    double bridgeClearStartM = bridgeEndClearM,
    double bridgeClearEndM = bridgeEndClearM,
    // Laid in vacuum: pedestrians get a sealed tube, not a pavement. Captured
    // here because it is a property of when the road was BUILT.
    bool sealed = false,
    // Built as the walled variant: sound barriers along both edges.
    bool soundWalls = false,
    // How this road plats: its own lot frontage and depth in place of the
    // colony's settings, whether it fronts lots at all (null: by class),
    // and whether it is a collector — a subdivision's through street,
    // which crosses another collector at a roundabout.
    double? lotFrontageM,
    double? lotDepthM,
    bool? frontsLots,
    bool collector = false,
    // Whether the ground is graded for it and its lots; see
    // [RoadSpline.graded].
    bool graded = true,
    // Skip the lot re-subdivision. For laying a WHOLE network at once: every
    // commit otherwise re-cuts every lot in the colony, which is quadratic in
    // roads and was most of the cost of generating a city. The caller must
    // call [regenerate] itself afterwards, and gets no rename map — safe only
    // when nothing is built yet.
    bool regenerateLots = true,
  }) {
    // Where every keyed thing stood, before the ground moves.
    final before = <String, Vec2>{
      for (final p in autoParcels) p.id: p.centroid,
    };

    final id = 'r${_commitSeq++}';
    var pts =
        RoadSpline(id: id, controls: controls, roadClass: roadClass)
            .sample(stepM: 2);

    // Endpoint snap: an end drawn near an existing road lands ON it.
    for (final (endIndex, allowed) in [(0, snapStart), (pts.length - 1, snapEnd)]) {
      if (!allowed) continue;
      final hit = nearestRoadPoint(pts[endIndex], withinM: snapM);
      if (hit != null) pts[endIndex] = hit.point;
    }

    // Crossings with every existing road, in both parametrisations.
    final newCuts = <double>{};
    final existingCuts = <String, Set<double>>{};
    final newBridges = List<(double, double)>.of(bridges);
    final bridgeExisting = <String, List<(double, double)>>{};
    final crossings = <RoadCrossing>[];
    final newCum = _cumulative(pts);
    // Roads are sampled every 2 m, so a kilometre of street is five hundred
    // segments. The index hands each new segment only the existing segments
    // in its own cell, so a road crossing a city of sixty thousand streets
    // tests the dozen it actually passes — laying a network used to be the
    // single most expensive thing the colony did.
    for (var i = 1; i < pts.length; i++) {
      final a = pts[i - 1], b = pts[i];
      _index.visit(Box2.of([a, b]), 1.0, (_, rec, j) {
        if (j == 0) return;
        final hit = segmentSegment(a, b, rec.sampleAt(j - 1), rec.sampleAt(j));
        if (hit == null) return;
        final sNew = newCum[i - 1] + (newCum[i] - newCum[i - 1]) * hit.$1;
        final sOld = rec.arcAt(j, hit.$2);
        final other = rec.road;
        final at = a + (b - a) * hit.$1;
        // One already passes over the other: no junction.
        if (_inRanges(sNew, newBridges) || other.bridgedAt(sOld)) {
          crossings.add(RoadCrossing(other.id, sNew, sOld, at, bridged: true));
          return;
        }
        // An expressway meets nothing at grade. Where an ordinary road
        // crosses one, the expressway is carried over it on a bridge and
        // neither is cut; two expressways, the one already laid goes over.
        // A ramp is the exception — it is how an expressway meets the rest
        // of the network — and within an expressway's last stretch there
        // is no room to climb, so nothing is bridged there.
        final ramp = roadClass == RoadClass.ramp ||
            other.roadClass == RoadClass.ramp;
        final newX = roadClass.isExpressway, oldX = other.roadClass.isExpressway;
        if (!ramp && (newX || oldX)) {
          crossings.add(RoadCrossing(other.id, sNew, sOld, at, bridged: true));
          if (oldX) {
            // The existing expressway's ends: only a TRUE end — one no
            // other road ends on — needs the clearance. A piece cut at a
            // merge or a lane drop carries on past its own end.
            final clearA = _isFreeEnd(rec, true) ? bridgeEndClearM : 0.0;
            final clearB = _isFreeEnd(rec, false) ? bridgeEndClearM : 0.0;
            if (sOld > clearA && sOld < rec.lengthM - clearB) {
              (bridgeExisting[other.id] ??= [])
                  .add((sOld - bridgeHalfM, sOld + bridgeHalfM));
            }
          } else if (sNew > bridgeClearStartM &&
              sNew < newCum.last - bridgeClearEndM) {
            newBridges.add((sNew - bridgeHalfM, sNew + bridgeHalfM));
          }
          return;
        }
        crossings.add(RoadCrossing(other.id, sNew, sOld, at));
        // Ends meeting a road are junctions, not cuts of the new road.
        if (sNew > 6 && sNew < newCum.last - 6) newCuts.add(sNew);
        if (sOld > 6 && sOld < rec.lengthM - 6) {
          existingCuts.putIfAbsent(other.id, () => {}).add(sOld);
        }
      });
    }
    // A crossing found by two sample pairs is one crossing.
    crossings.sort((p, q) => p.sNew.compareTo(q.sNew));
    final distinct = <RoadCrossing>[];
    for (final c in crossings) {
      if (distinct.isNotEmpty &&
          distinct.last.otherId == c.otherId &&
          (distinct.last.sNew - c.sNew).abs() < 2.0) {
        continue;
      }
      distinct.add(c);
    }

    // The expressways this road passes under get their bridges first, so
    // the pieces they are cut into carry them.
    bridgeExisting.forEach((rid, ranges) {
      final road = _roads[rid]!;
      final updated =
          road.copyWith(bridges: mergeRanges([...road.bridges, ...ranges]));
      _roads[rid] = updated;
      _index.replace(updated);
    });

    // Split the crossed roads.
    existingCuts.forEach((rid, cuts) {
      final road = _roads.remove(rid)!;
      final samples = _index.byId(rid)!.samples;
      _index.remove(rid);
      final pieces = _splitPolyline(samples, cuts.toList());
      for (var i = 0; i < pieces.length; i++) {
        final (piecePts, s0) = pieces[i];
        final piece = RoadSpline(
          id: '${rid}x$i',
          roadClass: road.roadClass,
          controls: _decimate(piecePts),
          // A split keeps what the original was built as.
          sealed: road.sealed,
          soundWalls: road.soundWalls,
          lotFrontageM: road.lotFrontageM,
          lotDepthM: road.lotDepthM,
          frontsLots: road.frontsLots,
          collector: road.collector,
          graded: road.graded,
          bridges: shiftBridges(road.bridges, s0, _cumulative(piecePts).last),
          startHalfWidthM: i == 0 ? road.startHalfWidthM : null,
          endHalfWidthM: i == pieces.length - 1 ? road.endHalfWidthM : null,
        );
        _roads[piece.id] = piece;
        _indexPiece(piece, piecePts);
      }
    });

    // And the new one.
    final pieces = _splitPolyline(pts, newCuts.toList());
    final merged = mergeRanges(newBridges);
    for (var i = 0; i < pieces.length; i++) {
      final (piecePts, s0) = pieces[i];
      final pid = pieces.length == 1 ? id : '${id}x$i';
      final piece = RoadSpline(
        id: pid,
        roadClass: roadClass,
        controls: _decimate(piecePts),
        sealed: sealed,
        soundWalls: soundWalls && roadClass.canHaveSoundWalls,
        lotFrontageM: lotFrontageM,
        lotDepthM: lotDepthM,
        frontsLots: frontsLots,
        collector: collector,
        graded: graded,
        bridges: shiftBridges(merged, s0, _cumulative(piecePts).last),
        startHalfWidthM: i == 0 ? startHalfWidthM : null,
        endHalfWidthM: i == pieces.length - 1 ? endHalfWidthM : null,
      );
      _roads[pid] = piece;
      _indexPiece(piece, piecePts);
    }
    _index.compact();
    if (!regenerateLots) {
      // Batch mode: the caller re-cuts once, when the whole network is in.
      // No lots were re-cut, so nothing was renamed.
      return (
        roadId: id,
        renamedLots: const <String, String>{},
        crossings: distinct
      );
    }
    regenerate();

    // Old lot -> the new lot standing on the same ground.
    final renamed = <String, String>{};
    final newIds = {for (final p in autoParcels) p.id};
    before.forEach((oldId, centroid) {
      if (newIds.contains(oldId)) return; // survived the cut untouched
      final now = parcelAt(centroid);
      if (now != null && !now.manual) renamed[oldId] = now.id;
    });
    // Zoning rides along.
    for (final e in renamed.entries) {
      final use = _uses.remove(e.key);
      if (use != null) {
        _uses[e.value] = use;
      }
    }
    if (renamed.isNotEmpty) regenerate(); // re-apply the moved zoning

    return (roadId: id, renamedLots: renamed, crossings: distinct);
  }

  /// Whether the [start] or the end of [rec] is a free end: no other road
  /// ends within a couple of metres of it.
  bool _isFreeEnd(IndexedRoad rec, bool start) {
    if (rec.sampleCount == 0) return true;
    final p = rec.sampleAt(start ? 0 : rec.sampleCount - 1);
    var free = true;
    _index.visit(Box2.around(p, 3), 0, (slot, other, seg) {
      if (!free || identical(other, rec) || other.sampleCount == 0) return;
      if (other.sampleAt(0).distanceTo(p) < 3 ||
          other.sampleAt(other.sampleCount - 1).distanceTo(p) < 3) {
        free = false;
      }
    });
    return free;
  }

  static bool _inRanges(double s, List<(double, double)> ranges) {
    for (final (a, b) in ranges) {
      if (s >= a && s <= b) return true;
    }
    return false;
  }

  /// Overlapping ranges joined, in order.
  static List<(double, double)> mergeRanges(List<(double, double)> ranges) {
    final sorted = ranges.toList()..sort((p, q) => p.$1.compareTo(q.$1));
    final out = <(double, double)>[];
    for (final r in sorted) {
      if (out.isNotEmpty && r.$1 <= out.last.$2) {
        out[out.length - 1] = (out.last.$1, math.max(out.last.$2, r.$2));
      } else {
        out.add(r);
      }
    }
    return out;
  }

  /// A road's bridge ranges as a piece of it starting [s0] along sees
  /// them: shifted, and kept whole — never clipped to the piece — so a
  /// deck does not ramp down at a split.
  static List<(double, double)> shiftBridges(
          List<(double, double)> bridges, double s0, double lengthM) =>
      [
        for (final (a, b) in bridges)
          if (b > s0 && a < s0 + lengthM) (a - s0, b - s0),
      ];

  /// Cut the road [id] at [sM] metres along it into two pieces, for a
  /// junction that is not a crossing — a ramp's merge on an expressway's
  /// edge, a change of class mid-run. Returns the two ids, or null when
  /// the cut would fall within a car's length of an end. No lots are
  /// re-cut and no buildings carried: for laying a network, not editing a
  /// built one.
  List<String>? splitRoadAt(String id, double sM) {
    final rec = _index.byId(id);
    final road = _roads[id];
    if (rec == null || road == null) return null;
    if (sM <= 8 || sM >= rec.lengthM - 8) return null;
    final samples = rec.samples;
    _roads.remove(id);
    _index.remove(id);
    final pieces = _splitPolyline(samples, [sM]);
    final ids = <String>[];
    for (var i = 0; i < pieces.length; i++) {
      final (pts, s0) = pieces[i];
      final piece = RoadSpline(
        id: '${id}x$i',
        roadClass: road.roadClass,
        controls: _decimate(pts),
        sealed: road.sealed,
        soundWalls: road.soundWalls,
        lotFrontageM: road.lotFrontageM,
        lotDepthM: road.lotDepthM,
        frontsLots: road.frontsLots,
        collector: road.collector,
        graded: road.graded,
        bridges: shiftBridges(road.bridges, s0, _cumulative(pts).last),
        startHalfWidthM: i == 0 ? road.startHalfWidthM : null,
        endHalfWidthM: i == pieces.length - 1 ? road.endHalfWidthM : null,
      );
      _roads[piece.id] = piece;
      _indexPiece(piece, pts);
      ids.add(piece.id);
    }
    return ids;
  }

  /// Replace a road's ATTRIBUTES — walls, bridges, a taper, its class —
  /// keeping its geometry. The controls must be the ones it has; nothing
  /// is re-cut.
  bool updateRoad(RoadSpline road) {
    if (!_roads.containsKey(road.id)) return false;
    _roads[road.id] = road;
    _index.replace(road);
    return true;
  }

  RoadSpline? roadById(String id) => _roads[id];

  static List<double> _cumulative(List<Vec2> pts) {
    final cum = <double>[0];
    for (var i = 1; i < pts.length; i++) {
      cum.add(cum[i - 1] + pts[i].distanceTo(pts[i - 1]));
    }
    return cum;
  }

  /// Cut a polyline at the given arc positions (deduped, sorted). Each
  /// piece comes back with the arc length it starts at on the original.
  static List<(List<Vec2>, double)> _splitPolyline(
      List<Vec2> pts, List<double> cuts) {
    if (cuts.isEmpty) return [(pts, 0.0)];
    final cum = _cumulative(pts);
    // Dedupe near-coincident cuts: a crossing found by two sample pairs is
    // one junction, not two.
    final sorted = cuts.toList()..sort();
    final unique = <double>[];
    for (final c in sorted) {
      if (unique.isEmpty || c - unique.last > 2.0) unique.add(c);
    }
    final out = <(List<Vec2>, double)>[];
    var piece = <Vec2>[pts.first];
    var pieceStart = 0.0;
    var next = 0;
    for (var i = 1; i < pts.length; i++) {
      while (next < unique.length &&
          unique[next] <= cum[i] &&
          unique[next] > cum[i - 1]) {
        final segLen = cum[i] - cum[i - 1];
        final t = segLen <= 1e-9
            ? 0.0
            : (unique[next] - cum[i - 1]) / segLen;
        final cut = pts[i - 1] + (pts[i] - pts[i - 1]) * t;
        piece.add(cut);
        out.add((piece, pieceStart));
        piece = <Vec2>[cut];
        pieceStart = unique[next];
        next++;
      }
      piece.add(pts[i]);
    }
    out.add((piece, pieceStart));
    return [
      for (final p in out)
        if (_cumulative(p.$1).last > 8) p // drop slivers shorter than a car
    ];
  }

  /// Thin a 2 m-sampled polyline back to control points: the fewest that
  /// keep every sample within [toleranceM] of the polyline through them
  /// (Douglas-Peucker). A straight street comes back as its two ends — so
  /// the index holds it as one segment and the spline through it is the
  /// line — and a bend keeps a control wherever it turns. The old rule kept
  /// a point every 16 m whatever the shape, so a straight kilometre was
  /// sixty collinear controls that every sample of it paid for forever.
  static List<Vec2> _decimate(List<Vec2> pts, {double toleranceM = 0.15}) {
    if (pts.length <= 2) return List.of(pts);
    final keep = List<bool>.filled(pts.length, false);
    keep[0] = true;
    keep[pts.length - 1] = true;
    final stack = <(int, int)>[(0, pts.length - 1)];
    while (stack.isNotEmpty) {
      final (a, b) = stack.removeLast();
      if (b - a < 2) continue;
      final pa = pts[a], pb = pts[b];
      final ab = pb - pa;
      final len2 = ab.dot(ab);
      var worst = -1.0;
      var at = -1;
      for (var i = a + 1; i < b; i++) {
        final d = len2 <= 1e-12
            ? pts[i].distanceTo(pa)
            : ((pts[i] - pa).cross(ab)).abs() / math.sqrt(len2);
        if (d > worst) {
          worst = d;
          at = i;
        }
      }
      if (worst > toleranceM) {
        keep[at] = true;
        stack.add((a, at));
        stack.add((at, b));
      }
    }
    return [
      for (var i = 0; i < pts.length; i++)
        if (keep[i]) pts[i],
    ];
  }

  /// Index a committed piece: a straight one as its two ends, a bent one
  /// at the crossing test's own samples, which the piece was cut from.
  void _indexPiece(RoadSpline piece, List<Vec2> samples) {
    _index.add(piece, samples: piece.controls.length == 2 ? null : samples);
  }

  /// Remove a road. [regenerateLots] defers the re-cut exactly as
  /// [addManualParcel] can — the megatower placer vacates a block's alley
  /// and stakes its plot in one batch, and re-cutting per removal would be
  /// the quadratic cost the generator's deferral exists to avoid.
  void removeRoad(String id, {bool regenerateLots = true}) {
    _roads.remove(id);
    _index.remove(id);
    if (regenerateLots) regenerate();
  }

  /// Add a hand-drawn lot. Returns null (and adds nothing) if it would sit on a
  /// carriageway or overlap an existing manual lot — the caller shows that as a
  /// blocked placement.
  /// Whether [polygon] could be added as a manual lot — the accept test of
  /// [addManualParcel] without the side effect, so a preview can ask.
  bool canAddManualParcel(List<Vec2> polygon) {
    final p = Parcel(id: '__probe', polygon: polygon, manual: true);
    if (_hitsRoad(p)) return false;
    for (final other in _manual) {
      if (p.overlaps(other)) return false;
    }
    return true;
  }

  Parcel? addManualParcel(List<Vec2> polygon,
      {ParcelUse use = ParcelUse.unzoned,
      bool regenerateLots = true,
      (Vec2, Vec2)? frontage,
      bool graded = true}) {
    final p = Parcel(
      id: 'lot-m${_nextId++}',
      polygon: polygon,
      use: use,
      manual: true,
      frontage: frontage,
      graded: graded,
    );
    if (_hitsRoad(p)) return null;
    for (final other in _manual) {
      if (p.overlaps(other)) return null;
    }
    _manual.add(p);
    if (use != ParcelUse.unzoned) _uses[p.id] = use;
    // Re-cutting the automatic lots is the expensive half — over two seconds
    // on a thousand-lot colony — so staking a run of plots can defer it and
    // re-cut once. The caller then owns calling [regenerate], and gets no
    // chance to carry buildings across renames, which is safe only while
    // nothing is built.
    if (regenerateLots) {
      regenerate();
    } else {
      // Findable by id and by place straight away, plat or no plat: the
      // generator stakes hundreds of plots between two re-cuts and looks
      // them up by id as it goes.
      _byId[p.id] = p;
      _lotIndex.add(p, _boxOf(p));
    }
    return p;
  }

  /// Re-insert a saved manual lot AS IS, preserving its id.
  ///
  /// [addManualParcel] assigns fresh ids from a counter, which is correct for
  /// a new lot and wrong for a loaded one — the save's buildings are keyed by
  /// the old id. The counter is bumped past the restored id so the next new
  /// lot cannot collide with it.
  void restoreManualParcel(Parcel p) {
    _manual.add(p);
    if (p.use != ParcelUse.unzoned) _uses[p.id] = p.use;
    final m = RegExp(r'^lot-m(\d+)$').firstMatch(p.id);
    if (m != null) {
      final n = int.parse(m.group(1)!);
      if (n >= _nextId) _nextId = n + 1;
    }
    regenerate();
  }

  void removeParcel(String id) {
    _manual.removeWhere((p) => p.id == id);
    _byId.remove(id);
    regenerate();
  }

  /// Zoning by lot id — the SOURCE OF TRUTH, not the [Parcel.use] fields.
  ///
  /// Auto lots are re-cut from scratch on every [regenerate], so zoning kept
  /// only on the parcel objects evaporated whenever a road was drawn: the
  /// player laid a second street and the whole town silently unzoned, and
  /// every grown building on it began to decay. The map survives because lot
  /// ids are deterministic; [regenerate] re-applies it to the fresh cut.
  final Map<String, ParcelUse> _uses = {};

  /// Zone a parcel. Returns false for an unknown id.
  bool setUse(String id, ParcelUse use) {
    final p = _byId[id];
    if (p == null) return false;
    final updated = p.copyWith(use: use);
    if (p.manual) {
      final i = _manual.indexOf(p);
      if (i < 0) return false;
      _manual[i] = updated;
    } else {
      final i = _autoIndex[id];
      if (i == null || i >= _auto.length || !identical(_auto[i], p)) {
        return false;
      }
      // In place: the element changes, the list does not, so a loop over
      // [autoParcels] that zones as it goes is not disturbed. Zoning half a
      // million lots by copying the list per lot was the square of that.
      _auto[i] = updated;
    }
    _byId[id] = updated;
    if (use == ParcelUse.unzoned) {
      _uses.remove(id);
    } else {
      _uses[id] = use;
    }
    return true;
  }

  /// The parcel under a point, or null. Manual lots win: they were indexed
  /// first, and the index answers in insertion order.
  Parcel? parcelAt(Vec2 p) {
    for (final parcel in _lotIndex.near(Box2.around(p, 0.01))) {
      if (parcel.contains(p)) return parcel;
    }
    return null;
  }

  /// Re-cut every auto parcel from the current roads and settings.
  void regenerate() {
    // Drains the stepped form. ONE implementation: a second copy of the
    // subdivision loop that only the progress path used would drift from this
    // one, and the two would quietly plat different cities.
    for (final _ in regenerateSteps()) {}
  }

  /// [regenerate], one road at a time, reporting 0..1 as it goes.
  ///
  /// This is the long pole in building a colony — a 435-road network takes
  /// about seven seconds to plat, and a generated city pays it twice — so it
  /// is the only place a progress bar can come from. Exposed as a synchronous
  /// generator rather than as a `Future` so the caller chooses: drain it in a
  /// loop for the old blocking behaviour, or step it from an async loop that
  /// yields to the event loop, which is what lets the UI paint while it works.
  ///
  /// Nothing is published until the last step: [autoParcels] keeps the
  /// PREVIOUS plat throughout, so a half-driven regeneration cannot be
  /// observed as a half-built city.
  Iterable<double> regenerateSteps() sync* {
    version++;
    // Every lot cut so far, by where it is: the clash test asks it for the
    // lots a candidate could touch. Manual lots go in first, so they win.
    final placed = BoxIndex<Parcel>();
    for (final p in _manual) {
      placed.add(p, _boxOf(p));
    }
    final out = <Parcel>[];
    // Alleys and anything on piers serve lots, they do not front them.
    final platting = _roads.values.where((r) => r.platsLots).toList();
    for (var i = 0; i < platting.length; i++) {
      out.addAll(_subdivide(platting[i], placed));
      yield (i + 1) / platting.length;
    }
    // Re-apply zoning: the fresh lots carry the same deterministic ids their
    // predecessors did, so the district survives its own street being redrawn.
    _auto = [
      for (final p in out)
        _uses.containsKey(p.id) ? p.copyWith(use: _uses[p.id]!) : p,
    ];
    _autoIndex
      ..clear()
      ..addEntries([for (var i = 0; i < _auto.length; i++) MapEntry(_auto[i].id, i)]);
    _reindex();
    yield 1.0;
  }

  /// Position of each auto lot in [_auto], for in-place zoning.
  final Map<String, int> _autoIndex = {};

  /// Lay lots along one road, the way a surveyor actually plats a block.
  ///
  /// Frontages are still cut at even arc-length intervals — that part of real
  /// subdivision IS regular — but each lot's DEPTH is found by casting rays
  /// into the block: a lot runs back until it meets the lots of the facing
  /// street at the block's midline, or reaches the maximum depth where the
  /// block is open. Corners are then clipped against the crossing street's
  /// setback. The result is what plat maps look like: even fronts, ragged
  /// backs, angled corner lots — and no dead ground between facing streets.
  List<Parcel> _subdivide(RoadSpline road, BoxIndex<Parcel> placed) {
    // The index already holds the road's samples: one segment for a
    // straight street, 2 m for a bent one.
    final pts = _index.byId(road.id)?.samples ?? road.sample(stepM: 2.0);
    if (pts.length < 2) return const [];
    final cum = _cumulative(pts);
    final total = cum.last;
    final frontageM = road.lotFrontageM ?? _settings.frontageM;
    final depthM = road.lotDepthM ?? _settings.depthM;
    final start = _settings.cornerClearM;
    final end = total - _settings.cornerClearM;
    if (end - start < frontageM * _settings.minFrontageFraction) {
      return const [];
    }

    final out = <Parcel>[];
    final sides = _settings.bothSides ? [1.0, -1.0] : [1.0];
    final setback = road.halfWidth + _settings.sidewalkM;

    for (final side in sides) {
      var s = start;
      var index = 0;
      while (s < end - 1e-6) {
        var s1 = s + frontageM;
        if (s1 > end) {
          if (end - s < frontageM * _settings.minFrontageFraction) {
            break;
          }
          s1 = end;
        }
        final a = _pointAt(pts, cum, s);
        final b = _pointAt(pts, cum, s1);
        final outA = _outwardAt(pts, cum, s) * side;
        final outB = _outwardAt(pts, cum, s1) * side;
        final frontA = a + outA * setback;
        final frontB = b + outB * setback;

        // Depth per corner: to the block midline against whatever the ray
        // hits, or the configured depth where the block is open.
        final dA = _depthAt(frontA, outA, road, depthM);
        final dB = _depthAt(frontB, outB, road, depthM);
        final lotIndex = index++;
        s = s1;
        if (math.min(dA, dB) < 8) continue; // an alley, not a lot

        var poly = <Vec2>[
          frontA,
          frontB,
          frontB + outB * dB,
          frontA + outA * dA,
        ];
        poly = _clipAgainstRoads(poly, road);
        if (poly.length < 3) continue;

        final parcel = Parcel(
          id: 'lot-${road.id}-${side > 0 ? 'r' : 'l'}$lotIndex',
          polygon: poly,
          roadId: road.id,
          frontage: (frontA, frontB),
          sideStreet: _sideStreetOf(poly, (frontA, frontB), road),
          graded: road.graded,
        );
        if (parcel.area < 30) continue;
        final box = _boxOf(parcel);
        if (!_clashes(parcel, placed.near(box))) {
          out.add(parcel);
          placed.add(parcel, box);
        }
      }
    }
    return out;
  }

  /// The OTHER street a lot touches, if it is on a corner.
  ///
  /// Found by asking each of the lot's edges — the frontage excepted — whether
  /// it lies along some other road's setback line. That is what a corner lot
  /// physically IS after `_clipAgainstRoads` has cut it: an edge parallel to a
  /// crossing street, at exactly that street's setback. Detecting it here,
  /// while the plat is being cut, is far cheaper and far more reliable than
  /// having the renderer re-derive it from a polygon later.
  (Vec2, Vec2)? _sideStreetOf(
      List<Vec2> poly, (Vec2, Vec2) frontage, RoadSpline own) {
    // Generous, and it has to be. A lot's side edge does NOT land exactly on
    // the crossing street's setback: the plat holds `cornerClearM` back from
    // the junction, and the clip pass works off a straight-line approximation
    // of a curved road. Measured on a generated colony, a 2 m tolerance found
    // 5% of lots — a grid of this shape has nearer a fifth — because it was
    // testing for an exactness the geometry never had.
    final tol = _settings.cornerClearM + 4;
    (Vec2, Vec2)? best;
    var bestD = double.infinity;
    for (var i = 0; i < poly.length; i++) {
      final a = poly[i], b = poly[(i + 1) % poly.length];
      // Skip the frontage itself.
      if ((a.distanceTo(frontage.$1) < 0.5 && b.distanceTo(frontage.$2) < 0.5) ||
          (a.distanceTo(frontage.$2) < 0.5 && b.distanceTo(frontage.$1) < 0.5)) {
        continue;
      }
      final mid = (a + b) * 0.5;
      if (a.distanceTo(b) < 6) continue; // a chamfer, not a frontage
      // Any road that could qualify has its nearest point within its own
      // setback plus the tolerance of the midpoint, and no setback is wider
      // than the widest class's.
      final reach = _maxHalfWidth + _settings.sidewalkM + tol + 1;
      final near = _index.segmentsNear(Box2.around(mid, reach));
      for (final entry in near.entries) {
        final rec = _index.bySlot(entry.key)!;
        final ob = rec.road;
        if (identical(ob, own) || ob.id == own.id) continue;
        // An alley is a back, not a street, and nothing in the air is either.
        if (!ob.roadClass.platsLots) continue;
        final margin = ob.halfWidth + _settings.sidewalkM;
        final d = (_nearestOf(rec, entry.value, mid) - margin).abs();
        if (d < tol && d < bestD) {
          bestD = d;
          best = (a, b);
        }
      }
    }
    return best;
  }

  /// Outward unit normal of the centreline at arc position [s] (left side;
  /// the caller flips it for the right).
  Vec2 _outwardAt(List<Vec2> pts, List<double> cum, double s) {
    final ahead = _pointAt(pts, cum, math.min(s + 2, cum.last));
    final behind = _pointAt(pts, cum, math.max(s - 2, 0));
    final along = (ahead - behind);
    return along.length <= 1e-9 ? const Vec2(1, 0) : along.normalized.perp;
  }

  /// How deep a lot may run from [front] along [outward].
  ///
  /// Rays at every OTHER road: the nearest hit, less that road's own setback,
  /// is the gap across the block — and the lot takes half of it, which is the
  /// planning rule that makes facing streets' lots meet at the midline with
  /// no sliver of dead ground between them. An open block runs to the
  /// configured depth.
  double _depthAt(Vec2 front, Vec2 outward, RoadSpline own, double depthM) {
    final probe = depthM * 3;
    // Broad phase against the ray's own box. Without it this walked every
    // sample of every road in the colony for every lot corner — O(roads x
    // lots), which is fine at a hundred roads and is most of the build time
    // once alleys and elevated lines have tripled the network.
    final tip = front + outward * probe;
    var nearest = double.infinity;
    var nearestIsAlley = false;
    _index.visit(Box2.of([front, tip]), 1.0, (_, rec, i) {
      final ob = rec.road;
      if (i == 0 || identical(ob, own) || ob.id == own.id) return;
      // A structure on piers casts no shadow on the plat: lots run underneath
      // an elevated line, which is what the arches and the parking under the
      // L actually are.
      if (ob.roadClass.isElevated) return;
      final t =
          raySegment(front, outward, rec.sampleAt(i - 1), rec.sampleAt(i));
      if (t == null || t > probe) return;
      final gap = t -
          (ob.halfWidth +
              (ob.roadClass.hasPavement ? _settings.sidewalkM : 0.6));
      if (gap < nearest) {
        nearest = gap;
        nearestIsAlley = ob.roadClass == RoadClass.alley;
      }
    });
    if (nearest == double.infinity) return depthM;
    // Halved because the usual obstacle is the FACING street, and its lots are
    // coming the other way to meet these at the block midline. An alley is
    // different: it IS the midline, it is already a road with its own
    // setback, and nothing is platted off it — so a lot runs all the way to
    // it. Halving there would leave a strip of dead ground behind every
    // building, which is exactly the gap the alley exists to remove.
    return math.min(depthM, nearestIsAlley ? nearest : nearest / 2);
  }

  /// Clip a lot against every foreign carriageway it strays near, so corner
  /// lots end at the crossing street's setback instead of poking into the
  /// junction. Local straight-line approximation of the other road — lots are
  /// small against any road's curvature.
  List<Vec2> _clipAgainstRoads(List<Vec2> poly, RoadSpline own) {
    var clipped = poly;
    // Every road with a piece within the widest possible margin of the
    // lot, in the order the roads were laid — the order the scan clipped
    // in, since each clip works off the polygon the last one left.
    final maxMargin = _maxHalfWidth + _settings.sidewalkM;
    final near = _index.segmentsNear(Box2.of(poly), maxMargin + 1);
    for (final entry in near.entries) {
      if (clipped.length < 3) return clipped;
      final rec = _index.bySlot(entry.key)!;
      final ob = rec.road;
      if (identical(ob, own) || ob.id == own.id) continue;
      // Nothing clips against a deck in the air — the lot runs on underneath.
      if (ob.roadClass.isElevated) continue;
      final margin = ob.halfWidth +
          (ob.roadClass.hasPavement ? _settings.sidewalkM : 0.6);
      // Broad phase: any vertex near this road?
      var isNear = false;
      for (final v in clipped) {
        if (_nearestOf(rec, entry.value, v) < margin) {
          isNear = true;
          break;
        }
      }
      if (!isNear) continue;
      // Local line: the obstacle's nearest sample pair to the lot. Looked
      // for within the lot's own reach of its centre plus the margin, which
      // is as far as the road's nearest point can be once some corner is
      // inside the margin.
      var c = const Vec2(0, 0);
      for (final v in clipped) {
        c = c + v;
      }
      c = c * (1.0 / clipped.length);
      var reach = 0.0;
      for (final v in clipped) {
        reach = math.max(reach, c.distanceTo(v));
      }
      final local = _index.segmentsNear(
          Box2.around(c, reach + margin + _index.sampleM + 1))[entry.key];
      if (local == null) continue;
      var bi = 0;
      var best = double.infinity;
      for (final i in local) {
        if (i == 0) continue;
        final m = (rec.sampleAt(i - 1) + rec.sampleAt(i)) * 0.5;
        final d = c.distanceTo(m);
        if (d < best) {
          best = d;
          bi = i;
        }
      }
      if (bi == 0) continue;
      final p = rec.sampleAt(bi - 1);
      final along = rec.sampleAt(bi) - p;
      if (along.length <= 1e-9) continue;
      var n = along.normalized.perp;
      if (n.dot(c - p) < 0) n = n * -1.0; // keep the lot's own side
      clipped = clipHalfPlane(clipped, p, n, margin);
    }
    return clipped;
  }

  /// Point at arc length [s] along the sampled polyline.
  static Vec2 _pointAt(List<Vec2> pts, List<double> cum, double s) {
    if (s <= 0) return pts.first;
    if (s >= cum.last) return pts.last;
    // Linear scan: roads have a few hundred samples and this runs only on
    // regeneration, so a binary search buys nothing worth the complexity.
    for (var i = 1; i < pts.length; i++) {
      if (cum[i] >= s) {
        final segLen = cum[i] - cum[i - 1];
        final t = segLen <= 1e-9 ? 0.0 : (s - cum[i - 1]) / segLen;
        return pts[i - 1] + (pts[i] - pts[i - 1]) * t;
      }
    }
    return pts.last;
  }

  /// Does this parcel sit on any carriageway? Tested against the road centre
  /// lines so a lot can never be cut across the road it fronts.
  bool _hitsRoad(Parcel p, {String? exclude}) {
    final probes = [...p.polygon, p.centroid];
    final pBox = Box2.of(p.polygon);
    final near =
        _index.segmentsNear(pBox, _maxHalfWidth + _settings.sidewalkM * 0.5);
    for (final entry in near.entries) {
      final rec = _index.bySlot(entry.key)!;
      final road = rec.road;
      final clearance = road.halfWidth + _settings.sidewalkM * 0.5;
      // Nowhere near: no point loop.
      if (!rec.box.within(pBox, clearance)) continue;
      for (final v in probes) {
        final d = _nearestOf(rec, entry.value, v);
        if (d >= clearance) continue;
        // Its own frontage edge sits exactly at the setback, which is outside
        // the carriageway — only a genuine incursion counts.
        if (road.id == exclude &&
            d >= road.halfWidth + _settings.sidewalkM - 0.5) {
          continue;
        }
        return true;
      }
      // The other way round: a road running clean THROUGH a plot. Corner
      // probes miss it whenever the plot is wide and the road is long — a
      // 780 m solar farm was staked straddling the railway, its four corners
      // and its centre all comfortably clear of the track between them.
      if (road.id == exclude) continue;
      for (final i in entry.value) {
        if (p.contains(rec.sampleAt(i)) ||
            (i > 0 && p.contains(rec.sampleAt(i - 1)))) {
          return true;
        }
      }
    }
    return false;
  }

  /// Distance from [v] to the nearest ROAD in the network, minus that road's
  /// half width — i.e. to the curb. Infinite when there are no roads.
  ///
  /// Uses the cached samples, so a placement probe costs a scan rather than a
  /// re-evaluation of every spline in the colony.
  double distanceToCurb(Vec2 v) {
    if (_roads.isEmpty) return double.infinity;
    // Outward in doubling rings: a road outside the ring can only beat the
    // best so far if its centreline is within the widest half width of it.
    var r = 64.0;
    while (true) {
      var best = double.infinity;
      _index.visit(Box2.around(v, r), 0, (_, rec, seg) {
        final d = seg == 0
            ? v.distanceTo(rec.sampleAt(0))
            : rec.distanceToSegment(v, seg);
        final curb = d - rec.road.halfWidth;
        if (curb < best) best = curb;
      });
      if (best + _maxHalfWidth <= r || r > 1e7) return best;
      r *= 2;
    }
  }

  bool _clashes(Parcel p, List<Parcel> others) {
    for (final o in others) {
      if (p.overlaps(o)) return true;
    }
    return false;
  }

  /// Total buildable land, in m².
  double get totalArea =>
      parcels.fold(0.0, (s, p) => s + p.area);

  /// Furthest extent of the built area from the colony centre, in metres —
  /// what the renderer uses to size the terrain pad under the city.
  double get radius {
    var r = 0.0;
    for (final p in parcels) {
      for (final v in p.polygon) {
        r = math.max(r, v.length);
      }
    }
    for (final road in _roads.values) {
      for (final v in road.sample(stepM: 8)) {
        r = math.max(r, v.length + road.halfWidth);
      }
    }
    return r;
  }
}
