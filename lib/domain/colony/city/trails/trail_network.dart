// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A colony's desire paths as a whole (docs/plans/desire-paths.md §7): the
/// [TrailField], kept in step with the plat; the doors trips leave and
/// arrive by; the lots open ground serves; and the legs themselves.
///
/// The aggregate hands it the plat as plain shapes ([TrailSite], road
/// samples) and a ground sampler, so this package never reads `CitySim`.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../parcel.dart';
import 'trail_field.dart';
import 'trail_promotion.dart';
import 'trail_router.dart';

/// A site as the trails see it: what stands there, if anything, and where
/// its people come and go.
class TrailSite {
  const TrailSite(this.id, this.polygon, {required this.built});

  final String id;
  final List<Vec2> polygon;

  /// Whether a building stands on it. An empty lot can be walked across; a
  /// built one is crossed only at its door.
  final bool built;
}

/// Colony seconds between the shapes being laid again when nothing that
/// would change them has visibly moved: a lot that grows a building is not
/// announced, and this is how it gets noticed.
const double _shapeCadenceS = 10;

/// Colony seconds between fades: [TrailField.decay] walks every cell.
const double _decayCadenceS = 30;

/// Deposits a cached route survives before it is searched again: a trail is
/// a slow thing, and a route only changes when wear has.
const int _routeStaleWear = 40;

/// Colony seconds between looks for a trail beaten enough to be a road.
const double _promoteCadenceS = 120;

/// Routes remembered for that look: the most recently driven, by ends.
const int _takenCap = 128;

/// Legs drawn under way at once, at most.
const int _activeCap = 256;

/// A leg being driven: its route, and when it set off and for how long, in
/// agent µs.
class TrailLeg {
  const TrailLeg(this.route, this.startUs, this.durUs);
  final TrailRoute route;
  final int startUs, durUs;
}

class TrailNetwork {
  TrailNetwork({TrailField? field}) : _field = field;

  TrailField? _field;
  TrailRouter? _router;

  /// The field, or null before the first [sync].
  TrailField? get field => _field;

  /// Door point per site id, colony-local metres: a step outside the
  /// frontage, or outside the edge that faces the colony's root.
  final Map<String, Vec2> doors = {};

  /// Lot ids open ground reaches from the root (§7 "Service").
  Set<String> servedLots = const {};

  /// Moves whenever [servedLots] may have.
  int serviceRev = 0;

  /// Legs taken, and searches the route cache saved.
  int legs = 0, cacheHits = 0;

  final Map<int, (int, int, TrailRoute?)> _routes = {};
  int _shapeKey = 0x7fffffff;
  double _sinceShapes = 0, _sinceDecay = 0, _sincePromote = 0;

  /// The routes legs have taken lately, by (start, goal): what a beaten run
  /// is read off ([dueRoads]).
  final Map<int, TrailRoute> _taken = {};

  /// Dirt roads laid along trails so far ([dueRoads]' callers count them).
  int roadsLaid = 0;

  /// The routes driven lately, least recently first: what the scene
  /// draws a trail along (trail_capture.dart), and [dueRoads] reads.
  Iterable<TrailRoute> get takenRoutes => _taken.values;

  /// The legs under way, oldest first: what a rover is drawn driving.
  final List<TrailLeg> active = [];

  /// Metres driven across open ground so far: the crash model's off-road
  /// distance (desire-paths.md §8).
  double offRoadM = 0;

  /// Keeps the field in step with the plat. [shapeKey] names the plat as it
  /// stands — when it moves, or every [_shapeCadenceS] regardless, the
  /// footprints, doors and roads are laid again, and the field regrown when
  /// the plat has outgrown it. [heightAt] samples the natural ground,
  /// metres above the datum; it is asked only when cells are new.
  void sync({
    required int shapeKey,
    required double dtS,
    required Iterable<TrailSite> Function() sites,
    required Iterable<(List<Vec2>, double)> Function() roads,
    required double Function(double e, double n) heightAt,
    Vec2 root = const Vec2(0, 0),
  }) {
    _sinceShapes += dtS;
    _sinceDecay += dtS;
    _sincePromote += dtS;
    final f0 = _field;
    if (f0 != null && _sinceDecay >= _decayCadenceS) {
      f0.decay(_sinceDecay);
      _sinceDecay = 0;
    }
    if (f0 != null &&
        f0.heightsReady &&
        shapeKey == _shapeKey &&
        _sinceShapes < _shapeCadenceS) {
      return;
    }
    _shapeKey = shapeKey;
    _sinceShapes = 0;

    final all = sites().toList();
    var lo = Vec2(root.e, root.n), hi = Vec2(root.e, root.n);
    for (final s in all) {
      for (final v in s.polygon) {
        lo = Vec2(math.min(lo.e, v.e), math.min(lo.n, v.n));
        hi = Vec2(math.max(hi.e, v.e), math.max(hi.n, v.n));
      }
    }
    var f = f0;
    // Regrown when the plat comes within half a margin of the edge.
    const slack = kTrailMarginM / 2;
    if (f == null ||
        !f.covers(lo.e - slack, lo.n - slack) ||
        !f.covers(hi.e + slack, hi.n + slack)) {
      final next = TrailField.covering(lo.e, lo.n, hi.e, hi.n);
      if (f != null) next.adoptWear(f);
      f = _field = next;
      _router = TrailRouter(next);
      _routes.clear();
      // Their cells were the old field's.
      _taken.clear();
    }
    if (!f.heightsReady) f.fillHeights(heightAt);
    // A field loaded from a save comes without its router.
    final router = _router ??= TrailRouter(f);

    doors.clear();
    for (final s in all) {
      doors[s.id] = _doorOf(s.polygon, root, f.cellM);
    }
    f.layShapes(
      footprints: [
        for (final s in all)
          if (s.built) s.polygon
      ],
      doors: [
        for (final s in all)
          if (s.built) doors[s.id]!
      ],
      roads: roads(),
    );

    // Service: a lot is reached when the cell at its door is, or any cell
    // just outside one of its edges.
    final reach = router.reach(_openNear(f, root));
    final served = <String>{};
    for (final s in all) {
      if (_reaches(f, reach, s)) served.add(s.id);
    }
    if (!_sameSet(served, servedLots)) {
      servedLots = served;
      serviceRev++;
    }
  }

  /// The leg from site [from] to site [to] over open ground, or null when
  /// either has no door here or the ground between cannot be crossed.
  TrailRoute? leg(String from, String to) {
    final f = _field, router = _router;
    if (f == null || router == null) return null;
    final a = doors[from], b = doors[to];
    if (a == null || b == null) return null;
    final i = f.cellAt(a.e, a.n), j = f.cellAt(b.e, b.n);
    if (i < 0 || j < 0) return null;
    final key = i * f.length + j;
    final hit = _routes[key];
    if (hit != null &&
        hit.$1 == f.shapeRev &&
        f.wearRev - hit.$2 <= _routeStaleWear) {
      cacheHits++;
      return hit.$3;
    }
    final r = router.route(i, j);
    _routes[key] = (f.shapeRev, f.wearRev, r);
    return r;
  }

  /// [route] was taken: its cells take the wear of one leg.
  void lay(TrailRoute route, {int startUs = 0}) {
    legs++;
    offRoadM += route.lengthM;
    // A leg is drawn while it is driven; the oldest go first once a town
    // has more out at once than anyone would count.
    active.add(TrailLeg(route, startUs, (route.timeS * 1e6).round()));
    if (active.length > _activeCap) active.removeAt(0);
    final f = _field;
    if (f == null || route.cells.isEmpty) return;
    f.lay(route.cells);
    final key = route.cells.first * f.length + route.cells.last;
    // Re-inserted, so the map's order is the order they were last driven.
    _taken.remove(key);
    _taken[key] = route;
    if (_taken.length > _takenCap) _taken.remove(_taken.keys.first);
  }

  /// Where each leg under way at agent time [nowUs] has got to: colony
  /// metres and heading, `[e, n, dirE, dirN, …]`. Legs that have arrived
  /// are dropped.
  List<double> roversAt(int nowUs) {
    final f = _field;
    active.removeWhere((l) => nowUs >= l.startUs + l.durUs || nowUs < l.startUs);
    if (f == null) return const [];
    final out = <double>[];
    for (final l in active) {
      final cells = l.route.cells;
      if (cells.length < 2 || l.durUs <= 0) continue;
      // Even pace along the cells: a leg's time is spread over its length.
      final t = (nowUs - l.startUs) / l.durUs * (cells.length - 1);
      final k = t.floor().clamp(0, cells.length - 2);
      final u = t - k;
      final a = cells[k], b = cells[k + 1];
      final ae = f.centreE(a), an = f.centreN(a);
      final be = f.centreE(b), bn = f.centreN(b);
      final de = be - ae, dn = bn - an;
      final dl = math.sqrt(de * de + dn * dn);
      out
        ..add(ae + de * u)
        ..add(an + dn * u)
        ..add(dl > 0 ? de / dl : 1)
        ..add(dl > 0 ? dn / dl : 0);
    }
    return out;
  }

  /// The trails beaten enough to be roads, as polylines to lay a dirt road
  /// along, longest first — every [_promoteCadenceS] of colony time, and
  /// empty in between (docs/plans/desire-paths.md §5 phase 2).
  List<List<Vec2>> dueRoads() {
    final f = _field;
    if (f == null || _sincePromote < _promoteCadenceS) return const [];
    _sincePromote = 0;
    return beatenRuns(f, _taken.values);
  }

  /// The door of [polygon]: the midpoint of its edge nearest [root], stepped
  /// most of a cell outside it. A lot's frontage is the edge facing the way
  /// in, and with no road the way in is the colony itself.
  static Vec2 _doorOf(List<Vec2> polygon, Vec2 root, double cellM) {
    if (polygon.length < 2) {
      return polygon.isEmpty ? root : polygon.first;
    }
    var ce = 0.0, cn = 0.0;
    for (final v in polygon) {
      ce += v.e;
      cn += v.n;
    }
    ce /= polygon.length;
    cn /= polygon.length;
    var best = double.infinity;
    var door = polygon.first;
    for (var k = 0; k < polygon.length; k++) {
      final a = polygon[k], b = polygon[(k + 1) % polygon.length];
      final mid = Vec2((a.e + b.e) / 2, (a.n + b.n) / 2);
      final d = mid.distanceTo(root);
      if (d >= best) continue;
      best = d;
      // Outward: the edge's normal pointing away from the centroid.
      var ne = b.n - a.n, nn = -(b.e - a.e);
      final l = math.sqrt(ne * ne + nn * nn);
      if (l <= 1e-9) continue;
      ne /= l;
      nn /= l;
      if (ne * (mid.e - ce) + nn * (mid.n - cn) < 0) {
        ne = -ne;
        nn = -nn;
      }
      door = Vec2(mid.e + ne * cellM * 0.75, mid.n + nn * cellM * 0.75);
    }
    return door;
  }

  /// The open cell nearest [p], searched outward ring by ring: the root may
  /// stand on a building's footprint.
  static int _openNear(TrailField f, Vec2 p) {
    final i = f.cellAt(p.e, p.n);
    if (i >= 0 && !f.blocked(i)) return i;
    final c0 = ((p.e - f.originE) / f.cellM).floor().clamp(0, f.cols - 1);
    final r0 = ((p.n - f.originN) / f.cellM).floor().clamp(0, f.rows - 1);
    for (var ring = 1; ring < math.max(f.cols, f.rows); ring++) {
      for (var dr = -ring; dr <= ring; dr++) {
        for (var dc = -ring; dc <= ring; dc++) {
          if (dr.abs() != ring && dc.abs() != ring) continue;
          final c = c0 + dc, r = r0 + dr;
          if (c < 0 || r < 0 || c >= f.cols || r >= f.rows) continue;
          final j = r * f.cols + c;
          if (!f.blocked(j)) return j;
        }
      }
    }
    return -1;
  }

  bool _reaches(TrailField f, Uint8List reach, TrailSite s) {
    bool at(Vec2 p) {
      final i = f.cellAt(p.e, p.n);
      return i >= 0 && reach[i] != 0;
    }

    final door = doors[s.id];
    if (door != null && at(door)) return true;
    final poly = s.polygon;
    if (poly.length < 3) return false;
    var ce = 0.0, cn = 0.0;
    for (final v in poly) {
      ce += v.e;
      cn += v.n;
    }
    ce /= poly.length;
    cn /= poly.length;
    // An empty lot is reached if open ground inside it is.
    if (!s.built && at(Vec2(ce, cn))) return true;
    for (var k = 0; k < poly.length; k++) {
      final a = poly[k], b = poly[(k + 1) % poly.length];
      final mid = Vec2((a.e + b.e) / 2, (a.n + b.n) / 2);
      final out = Vec2(mid.e - ce, mid.n - cn).normalized;
      if (at(Vec2(mid.e + out.e * f.cellM, mid.n + out.n * f.cellM))) {
        return true;
      }
    }
    return false;
  }

  static bool _sameSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  Map<String, dynamic>? toJson() => _field?.toJson();

  static TrailNetwork fromJson(Map<String, dynamic> j) =>
      TrailNetwork(field: TrailField.fromJson(j));
}
