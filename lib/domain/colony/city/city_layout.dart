// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'parcel.dart';

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

  List<Parcel> get autoParcels => List.unmodifiable(_auto);
  List<Parcel> get manualParcels => List.unmodifiable(_manual);

  /// Raw insert: no splitting, no snapping. The LOAD path — a save stores
  /// roads already split at their junctions, and re-splitting on restore
  /// would double every cut. The editor goes through [commitRoad].
  void addRoad(RoadSpline road) {
    _roads[road.id] = road;
    final m = RegExp(r'^r(\d+)').firstMatch(road.id);
    if (m != null) {
      final n = int.parse(m.group(1)!);
      if (n >= _commitSeq) _commitSeq = n + 1;
    }
    regenerate();
  }

  int _commitSeq = 0;

  List<({RoadSpline road, List<Vec2> pts})> _obstacles = const [];

  /// The nearest point on any road within [withinM] of [p], for endpoint
  /// snapping — drawing toward an existing street should join it, not stop a
  /// metre short of it.
  ({String roadId, Vec2 point})? nearestRoadPoint(Vec2 p, {double withinM = 15}) {
    String? bestId;
    Vec2? bestPt;
    var best = withinM;
    for (final road in _roads.values) {
      final pts = road.sample(stepM: 4);
      for (var i = 1; i < pts.length; i++) {
        final a = pts[i - 1], b = pts[i];
        final ab = b - a;
        final len2 = ab.dot(ab);
        final t = len2 <= 1e-12
            ? 0.0
            : ((p - a).dot(ab) / len2).clamp(0.0, 1.0);
        final q = a + ab * t;
        final d = p.distanceTo(q);
        if (d < best) {
          best = d;
          bestId = road.id;
          bestPt = q;
        }
      }
    }
    return bestId == null ? null : (roadId: bestId, point: bestPt!);
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
  ({String roadId, Map<String, String> renamedLots}) commitRoad({
    required List<Vec2> controls,
    RoadClass roadClass = RoadClass.street,
    double snapM = 15,
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
    for (final endIndex in [0, pts.length - 1]) {
      final hit = nearestRoadPoint(pts[endIndex], withinM: snapM);
      if (hit != null) pts[endIndex] = hit.point;
    }

    // Crossings with every existing road, in both parametrisations.
    final newCuts = <double>{};
    final existingCuts = <String, Set<double>>{};
    final newCum = _cumulative(pts);
    for (final other in _roads.values.toList()) {
      final opts = other.sample(stepM: 2);
      final ocum = _cumulative(opts);
      for (var i = 1; i < pts.length; i++) {
        for (var j = 1; j < opts.length; j++) {
          final hit =
              segmentSegment(pts[i - 1], pts[i], opts[j - 1], opts[j]);
          if (hit == null) continue;
          final sNew = newCum[i - 1] +
              (newCum[i] - newCum[i - 1]) * hit.$1;
          final sOld =
              ocum[j - 1] + (ocum[j] - ocum[j - 1]) * hit.$2;
          // Ends meeting a road are junctions, not cuts of the new road.
          if (sNew > 6 && sNew < newCum.last - 6) newCuts.add(sNew);
          if (sOld > 6 && sOld < ocum.last - 6) {
            existingCuts.putIfAbsent(other.id, () => {}).add(sOld);
          }
        }
      }
    }

    // Split the crossed roads.
    existingCuts.forEach((rid, cuts) {
      final road = _roads.remove(rid)!;
      final pieces = _splitPolyline(road.sample(stepM: 2), cuts.toList());
      for (var i = 0; i < pieces.length; i++) {
        _roads['${rid}x$i'] = RoadSpline(
          id: '${rid}x$i',
          roadClass: road.roadClass,
          controls: _decimate(pieces[i]),
        );
      }
    });

    // And the new one.
    final pieces = _splitPolyline(pts, newCuts.toList());
    for (var i = 0; i < pieces.length; i++) {
      final pid = pieces.length == 1 ? id : '${id}x$i';
      _roads[pid] = RoadSpline(
        id: pid,
        roadClass: roadClass,
        controls: _decimate(pieces[i]),
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

    return (roadId: id, renamedLots: renamed);
  }

  static List<double> _cumulative(List<Vec2> pts) {
    final cum = <double>[0];
    for (var i = 1; i < pts.length; i++) {
      cum.add(cum[i - 1] + pts[i].distanceTo(pts[i - 1]));
    }
    return cum;
  }

  /// Cut a polyline at the given arc positions (deduped, sorted).
  static List<List<Vec2>> _splitPolyline(List<Vec2> pts, List<double> cuts) {
    if (cuts.isEmpty) return [pts];
    final cum = _cumulative(pts);
    // Dedupe near-coincident cuts: a crossing found by two sample pairs is
    // one junction, not two.
    final sorted = cuts.toList()..sort();
    final unique = <double>[];
    for (final c in sorted) {
      if (unique.isEmpty || c - unique.last > 2.0) unique.add(c);
    }
    final out = <List<Vec2>>[];
    var piece = <Vec2>[pts.first];
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
        out.add(piece);
        piece = <Vec2>[cut];
        next++;
      }
      piece.add(pts[i]);
    }
    out.add(piece);
    return [
      for (final p in out)
        if (_cumulative(p).last > 8) p // drop slivers shorter than a car
    ];
  }

  /// Thin a 2 m-sampled polyline back to control points every ~16 m. The
  /// spline through them reproduces the original curve to well under a lane
  /// width, and a road stored as 400 controls would make every regenerate pay
  /// for the editor's sampling rate forever.
  static List<Vec2> _decimate(List<Vec2> pts) {
    if (pts.length <= 2) return List.of(pts);
    final out = <Vec2>[pts.first];
    var since = 0.0;
    for (var i = 1; i < pts.length - 1; i++) {
      since += pts[i].distanceTo(pts[i - 1]);
      if (since >= 16) {
        out.add(pts[i]);
        since = 0;
      }
    }
    out.add(pts.last);
    return out;
  }

  void removeRoad(String id) {
    _roads.remove(id);
    regenerate();
  }

  /// Add a hand-drawn lot. Returns null (and adds nothing) if it would sit on a
  /// carriageway or overlap an existing manual lot — the caller shows that as a
  /// blocked placement.
  Parcel? addManualParcel(List<Vec2> polygon, {ParcelUse use = ParcelUse.unzoned}) {
    final p = Parcel(
      id: 'lot-m${_nextId++}',
      polygon: polygon,
      use: use,
      manual: true,
    );
    if (_hitsRoad(p)) return null;
    for (final other in _manual) {
      if (p.overlaps(other)) return null;
    }
    _manual.add(p);
    if (use != ParcelUse.unzoned) _uses[p.id] = use;
    regenerate();
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
    var found = false;
    for (var i = 0; i < _manual.length; i++) {
      if (_manual[i].id == id) {
        _manual[i] = _manual[i].copyWith(use: use);
        found = true;
      }
    }
    if (!found) {
      final auto = List.of(_auto);
      for (var i = 0; i < auto.length; i++) {
        if (auto[i].id == id) {
          auto[i] = auto[i].copyWith(use: use);
          _auto = auto;
          found = true;
        }
      }
    }
    if (!found) return false;
    if (use == ParcelUse.unzoned) {
      _uses.remove(id);
    } else {
      _uses[id] = use;
    }
    return true;
  }

  /// The parcel under a point, or null. Manual lots win.
  Parcel? parcelAt(Vec2 p) {
    for (final parcel in parcels) {
      if (parcel.contains(p)) return parcel;
    }
    return null;
  }

  /// Re-cut every auto parcel from the current roads and settings.
  void regenerate() {
    version++;
    // Coarse samples of every road, shared by all the ray casts below. Without
    // the cache each lot's depth probe would re-sample the whole network.
    _obstacles = [
      for (final r in _roads.values) (road: r, pts: r.sample(stepM: 6)),
    ];
    final out = <Parcel>[];
    for (final road in _roads.values) {
      out.addAll(_subdivide(road, out));
    }
    // Re-apply zoning: the fresh lots carry the same deterministic ids their
    // predecessors did, so the district survives its own street being redrawn.
    _auto = [
      for (final p in out)
        _uses.containsKey(p.id) ? p.copyWith(use: _uses[p.id]!) : p,
    ];
  }

  /// Lay lots along one road, the way a surveyor actually plats a block.
  ///
  /// Frontages are still cut at even arc-length intervals — that part of real
  /// subdivision IS regular — but each lot's DEPTH is found by casting rays
  /// into the block: a lot runs back until it meets the lots of the facing
  /// street at the block's midline, or reaches the maximum depth where the
  /// block is open. Corners are then clipped against the crossing street's
  /// setback. The result is what plat maps look like: even fronts, ragged
  /// backs, angled corner lots — and no dead ground between facing streets.
  List<Parcel> _subdivide(RoadSpline road, List<Parcel> soFar) {
    final pts = road.sample(stepM: 2.0);
    if (pts.length < 2) return const [];
    final cum = _cumulative(pts);
    final total = cum.last;
    final start = _settings.cornerClearM;
    final end = total - _settings.cornerClearM;
    if (end - start < _settings.frontageM * _settings.minFrontageFraction) {
      return const [];
    }

    final out = <Parcel>[];
    final sides = _settings.bothSides ? [1.0, -1.0] : [1.0];
    final setback = road.halfWidth + _settings.sidewalkM;

    for (final side in sides) {
      var s = start;
      var index = 0;
      while (s < end - 1e-6) {
        var s1 = s + _settings.frontageM;
        if (s1 > end) {
          if (end - s < _settings.frontageM * _settings.minFrontageFraction) {
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
        final dA = _depthAt(frontA, outA, road);
        final dB = _depthAt(frontB, outB, road);
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
        );
        if (parcel.area < 30) continue;
        if (!_clashes(parcel, [...soFar, ...out, ..._manual])) {
          out.add(parcel);
        }
      }
    }
    return out;
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
  double _depthAt(Vec2 front, Vec2 outward, RoadSpline own) {
    final probe = _settings.depthM * 3;
    var nearest = double.infinity;
    for (final ob in _obstacles) {
      if (identical(ob.road, own) || ob.road.id == own.id) continue;
      for (var i = 1; i < ob.pts.length; i++) {
        final t = raySegment(front, outward, ob.pts[i - 1], ob.pts[i]);
        if (t == null || t > probe) continue;
        final gap = t - (ob.road.halfWidth + _settings.sidewalkM);
        if (gap < nearest) nearest = gap;
      }
    }
    if (nearest == double.infinity) return _settings.depthM;
    return math.min(_settings.depthM, nearest / 2);
  }

  /// Clip a lot against every foreign carriageway it strays near, so corner
  /// lots end at the crossing street's setback instead of poking into the
  /// junction. Local straight-line approximation of the other road — lots are
  /// small against any road's curvature.
  List<Vec2> _clipAgainstRoads(List<Vec2> poly, RoadSpline own) {
    var clipped = poly;
    for (final ob in _obstacles) {
      if (clipped.length < 3) return clipped;
      if (identical(ob.road, own) || ob.road.id == own.id) continue;
      final margin = ob.road.halfWidth + _settings.sidewalkM;
      // Broad phase: any vertex near this road?
      var near = false;
      for (final v in clipped) {
        if (ob.road.distanceTo(v) < margin) {
          near = true;
          break;
        }
      }
      if (!near) continue;
      // Local line: the obstacle's nearest sample pair to the lot.
      var c = const Vec2(0, 0);
      for (final v in clipped) {
        c = c + v;
      }
      c = c * (1.0 / clipped.length);
      var bi = 1;
      var best = double.infinity;
      for (var i = 1; i < ob.pts.length; i++) {
        final m = (ob.pts[i - 1] + ob.pts[i]) * 0.5;
        final d = c.distanceTo(m);
        if (d < best) {
          best = d;
          bi = i;
        }
      }
      final p = ob.pts[bi - 1];
      final along = (ob.pts[bi] - p);
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
    for (final road in _roads.values) {
      final clearance = road.halfWidth + _settings.sidewalkM * 0.5;
      for (final v in p.polygon) {
        if (road.distanceTo(v) < clearance) {
          // Its own frontage edge sits exactly at the setback, which is outside
          // the carriageway — only a genuine incursion counts.
          if (road.id == exclude &&
              road.distanceTo(v) >= road.halfWidth + _settings.sidewalkM - 0.5) {
            continue;
          }
          return true;
        }
      }
      // A long thin lot can straddle a road without any corner being close to
      // it, so also check the centre.
      if (road.distanceTo(p.centroid) < clearance) return true;
    }
    return false;
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
