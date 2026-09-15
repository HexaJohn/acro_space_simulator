// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Kerb joins: where a lot meets its road (docs/plans/site-access.md §3.2,
/// §3.7a).
///
/// Three things live here, all tier L (inside `RoadGraph.of`) and none of
/// them reading a lot's use, a junction override, the ground or the clock:
///
/// - [nodeReserveM]: how much road next to a node no kerb cut may touch, for
///   ANY override the player can set — a crossing's pavement pull-back, its
///   stop bar, a roundabout's yield line, a street end's drawn cul-de-sac.
/// - [KerbWindows]: per road-graph piece, the stretches of road arc where a
///   cut may go (the reserves, bridges, deck stretches off the ground or off
///   grade, tunnels and tapers taken out).
/// - [SiteJoinPlacer]: a lot's join slots. Slot 0 is the lot's access, the one
///   `RoadGraph.lotPiece / lotS / lotDirs` report; slots 1 and 2 are offered
///   for a plan to pick. A lot set back from its road runs the access
///   corridor search, which may cross unbuilt auto lots (easements) but never
///   a manual parcel or another road.
///
/// Determinism (§3.9): no platform hash, no draw, no clock, no map iteration
/// and no trigonometry. Every tie is broken by an explicit total order.
///
/// Cost: every lot of a sprawl passes through the placer on every road
/// graph build, so the auto-lot path works in doubles on reused scratch and
/// writes typed columns; only the rare set-back corridor search allocates.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../parcel.dart';
import '../road_graph.dart' show RoadGraph, RoadNode;
import '../road_junction.dart';
import '../spatial_index.dart';
import 'site_access_constants.dart';
import 'site_frame.dart';

/// Metres of road beside [node] that no kerb cut may touch, whatever the
/// player overrides (§3.2).
///
/// - A dead end reserves the drawn cul-de-sac and its flare when its one leg
///   is a street (the tiles draw a turning circle at any street end nothing
///   else meets), else nothing.
/// - Anything else reserves the larger of the stop bar and the pavement
///   pull-back, over the widest leg: an override only toggles lights and
///   stops, and every control it can pick stops at the bar.
/// - A roundabout, which no override makes or unmakes, also reserves its
///   yield line.
double nodeReserveM(RoadNode node) {
  final legs = node.legs;
  if (legs.length <= 1) {
    if (legs.isNotEmpty && legs.first.roadClass == RoadClass.street) {
      return kCulDeSacRadiusM + kCutFlareM;
    }
    return 0;
  }
  var hw = 0.0;
  for (final l in legs) {
    final h = l.roadClass.halfWidth;
    if (h > hw) hw = h;
  }
  var r = math.max(
    hw * kReservePlatePerHalfWidth * kReserveStopBarAt,
    hw * kReservePlatePerHalfWidth + kReservePavementPullBackM,
  );
  if (node.plan.control == JunctionControl.roundabout) {
    final radius = math.max(
      kReserveRoundaboutMinRadiusM,
      hw * kReserveRoundaboutPerHalfWidth + kReserveRoundaboutExtraM,
    );
    r = math.max(r, radius * kReserveYieldLineAt);
  }
  return r;
}

/// The traffic directions (`RoadGraph.forwardBit` / `backwardBit`) a lot on
/// the [right] (or left) of [road], first point to last, is reached and left
/// by: the travel direction of a one-way road; its own side's only on a road
/// of two lanes or more each way; either way otherwise.
int joinDirsFor(RoadSpline road, bool right) {
  if (road.oneWay) {
    return road.reversed ? RoadGraph.backwardBit : RoadGraph.forwardBit;
  }
  if (road.roadClass.lanesEachWay >= 2) {
    return right ? RoadGraph.forwardBit : RoadGraph.backwardBit;
  }
  return RoadGraph.forwardBit | RoadGraph.backwardBit;
}

/// The segment (samples i−1 .. i) of [rec] that arc [s] falls on: the first
/// sample at or past [s], held to a real segment. The same rule as
/// `AccessPoints.rightOf`, so the two sides agree.
int _segmentAt(IndexedRoad rec, double s) {
  final cum = rec.cum;
  var lo = 0, hi = cum.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (cum[mid] < s) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  if (lo < 1) lo = 1;
  if (lo > rec.sampleCount - 1) lo = rec.sampleCount - 1;
  return lo;
}

/// Whether ([pe], [pn]) lies to the right of [rec] at arc [s], first point to
/// last.
bool _rightAt(IndexedRoad rec, double s, double pe, double pn) {
  final i = _segmentAt(rec, s);
  final ae = rec.e[i - 1], an = rec.n[i - 1];
  final ex = rec.e[i] - ae, en = rec.n[i] - an;
  final seg = rec.cum[i] - rec.cum[i - 1];
  final u = seg <= 1e-12 ? 0.0 : ((s - rec.cum[i - 1]) / seg).clamp(0.0, 1.0);
  final qe = ae + ex * u, qn = an + en * u;
  return ex * (pn - qn) - en * (pe - qe) < 0;
}

/// Whether [p] lies to the right of [rec] at arc [s], first point to last.
bool joinSideOf(IndexedRoad rec, double s, Vec2 p) =>
    _rightAt(rec, s, p.e, p.n);

/// Per road-graph piece, the stretches of road arc where a kerb cut may go
/// (§3.2): `[S0 + reserve(from) + 6, S1 − reserve(to) − 6]` less bridges
/// (± 3 m), deck stretches off the ground or off grade, tunnels and the 90 m at
/// a tapered end; nothing on a road that is no eligible join road.
///
/// A cut of half width `m` at `s` is legal when `[s − m, s + m]` lies in one
/// window. Both directed edges of a piece share it. It reads no override
/// (a roundabout is the warrant's, which no override changes), so a graph
/// under new overrides shares it.
class KerbWindows {
  KerbWindows._(this.start, this.lo, this.hi);

  /// Windows of piece p: `lo[start[p]] .. hi[start[p + 1] − 1]`, ascending.
  final Int32List start;
  final Float64List lo, hi;

  int get pieceCount => start.length - 1;

  /// How many windows piece [piece] has.
  int countOf(int piece) => start[piece + 1] - start[piece];

  /// The windows of every piece of the given road network.
  factory KerbWindows.of({
    required List<RoadNode> nodes,
    required List<RoadSpline> roads,
    required List<IndexedRoad> recs,
    required Int32List roadFirstPiece,
    required Float64List pieceS0,
    required Float64List pieceS1,
    required Int32List pieceFrom,
    required Int32List pieceTo,
  }) {
    final reserve = Float64List(nodes.length);
    for (var n = 0; n < nodes.length; n++) {
      reserve[n] = nodeReserveM(nodes[n]);
    }
    final nP = pieceS0.length;
    final start = Int32List(nP + 1);
    final lo = <double>[], hi = <double>[];
    for (var r = 0; r < roads.length; r++) {
      final p0 = roadFirstPiece[r], p1 = roadFirstPiece[r + 1];
      final road = roads[r];
      if (!isEligibleJoinRoad(road.roadClass)) {
        for (var p = p0; p < p1; p++) {
          start[p + 1] = lo.length;
        }
        continue;
      }
      final excl = _exclusionsOf(road, recs[r].lengthM);
      for (var p = p0; p < p1; p++) {
        final b0 = pieceS0[p] + reserve[pieceFrom[p]] + kJoinWindowClearM;
        final b1 = pieceS1[p] - reserve[pieceTo[p]] - kJoinWindowClearM;
        var cur = b0;
        for (var k = 0; k + 1 < excl.length; k += 2) {
          final a = excl[k], b = excl[k + 1];
          if (b <= cur) continue;
          if (a >= b1) break;
          if (a > cur) {
            lo.add(cur);
            hi.add(a);
          }
          if (b > cur) cur = b;
          if (cur >= b1) break;
        }
        if (cur < b1) {
          lo.add(cur);
          hi.add(b1);
        }
        start[p + 1] = lo.length;
      }
    }
    return KerbWindows._(
      start,
      Float64List.fromList(lo),
      Float64List.fromList(hi),
    );
  }

  /// The arcs of [road] (measured now, [lengthM] long) no cut may touch, as
  /// sorted, merged `[a, b]` pairs flattened.
  static List<double> _exclusionsOf(RoadSpline road, double lengthM) {
    final deck = road.deck;
    if (road.bridges.isEmpty &&
        deck == null &&
        road.startHalfWidthM == null &&
        road.endHalfWidthM == null) {
      return const [];
    }
    final ranges = <(double, double)>[];
    for (final (a, b) in road.bridges) {
      ranges.add((a - kJoinBridgeClearM, b + kJoinBridgeClearM));
    }
    if (deck != null) {
      final l = deck.rangeLengthM;
      final scale = l == null || l <= 1e-9 || lengthM <= 1e-9
          ? 1.0
          : lengthM / l;
      for (final (a, b) in deck.structures) {
        ranges.add((a * scale, b * scale));
      }
      for (final (a, b) in deck.tunnels) {
        ranges.add((a * scale, b * scale));
      }
      // Off grade: the elevation above the laid ground, linear between the
      // ends, is at least half a metre either way.
      final o0 = deck.startOffsetM, o1 = deck.endOffsetM;
      if (lengthM > 1e-9) {
        if (o1 == o0) {
          if (o0.abs() >= kJoinOffGradeM) ranges.add((0.0, lengthM));
        } else {
          final sUp = (kJoinOffGradeM - o0) / (o1 - o0) * lengthM;
          final sDown = (-kJoinOffGradeM - o0) / (o1 - o0) * lengthM;
          final gradeLo = math.min(sUp, sDown), gradeHi = math.max(sUp, sDown);
          if (gradeLo > 0) ranges.add((double.negativeInfinity, gradeLo));
          if (gradeHi < lengthM) ranges.add((gradeHi, double.infinity));
        }
      }
    }
    if (road.startHalfWidthM != null) {
      ranges.add((double.negativeInfinity, kJoinTaperM));
    }
    if (road.endHalfWidthM != null) {
      ranges.add((lengthM - kJoinTaperM, double.infinity));
    }
    ranges.sort((x, y) {
      final c = x.$1.compareTo(y.$1);
      return c != 0 ? c : x.$2.compareTo(y.$2);
    });
    final out = <double>[];
    for (final (a, b) in ranges) {
      if (out.isNotEmpty && a <= out.last) {
        if (b > out.last) out[out.length - 1] = b;
      } else {
        out
          ..add(a)
          ..add(b);
      }
    }
    return out;
  }

  /// The largest cut half width legal at [s] on [piece]: the distance to the
  /// nearer end of the window holding it, or 0 outside every window.
  double roomAt(int piece, double s) {
    for (var k = start[piece]; k < start[piece + 1]; k++) {
      if (s >= lo[k] && s <= hi[k]) return math.min(s - lo[k], hi[k] - s);
    }
    return 0;
  }
}

/// One join slot, as `RoadGraph.attachFootprintJoins` returns it and the
/// graph's join columns store it (§2.2).
class JoinSlot {
  const JoinSlot({
    required this.piece,
    required this.s,
    required this.dirs,
    required this.right,
    required this.flags,
    required this.roomM,
    required this.kerbE,
    required this.kerbN,
    required this.normE,
    required this.normN,
    this.crossLots = const [],
  });

  /// The road-graph piece, and the arc along its road from its first control.
  final int piece;
  final double s;

  /// `joinDirsFor(road, right)`.
  final int dirs;

  /// The lot lies right of the road polyline (first to last) at [s].
  final bool right;

  /// `kJoin*` bits.
  final int flags;

  /// The largest kerb-cut half width legal here; 0 for a legacy slot.
  final double roomM;

  /// The kerb point, and the unit road normal into the lot.
  final double kerbE, kerbN, normE, normN;

  /// Graph lot indices of the auto lots the access corridor crosses,
  /// ascending.
  final List<int> crossLots;
}

/// Growable typed join columns, in `RoadGraph`'s layout (§2.2).
class JoinColumns {
  int count = 0;
  Int32List piece = Int32List(64);
  Float64List s = Float64List(64);
  Uint8List dirs = Uint8List(64);
  Uint8List right = Uint8List(64);
  Uint16List flags = Uint16List(64);
  Float32List roomM = Float32List(64);
  Float64List kerbE = Float64List(64), kerbN = Float64List(64);
  Float64List normE = Float64List(64), normN = Float64List(64);

  /// Slot k crosses `crossLot[crossStart[k] .. crossStart[k + 1] − 1]`.
  Int32List crossStart = Int32List(65);
  Int32List crossLot = Int32List(16);
  int crossCount = 0;

  void add(int piece, double s, int dirs, bool right, int flags, double room,
      double kerbE, double kerbN, double normE, double normN, List<int> cross) {
    final k = count;
    if (k == this.piece.length) _grow(k * 2);
    this.piece[k] = piece;
    this.s[k] = s;
    this.dirs[k] = dirs;
    this.right[k] = right ? 1 : 0;
    this.flags[k] = flags;
    roomM[k] = room;
    this.kerbE[k] = kerbE;
    this.kerbN[k] = kerbN;
    this.normE[k] = normE;
    this.normN[k] = normN;
    if (crossCount + cross.length > crossLot.length) {
      final bigger = Int32List(math.max(crossLot.length * 2,
          crossCount + cross.length));
      bigger.setRange(0, crossCount, crossLot);
      crossLot = bigger;
    }
    for (final l in cross) {
      crossLot[crossCount++] = l;
    }
    count = k + 1;
    crossStart[count] = crossCount;
  }

  void _grow(int n) {
    Int32List i32(Int32List a) => Int32List(n)..setRange(0, count, a);
    Float64List f64(Float64List a) => Float64List(n)..setRange(0, count, a);
    piece = i32(piece);
    s = f64(s);
    dirs = Uint8List(n)..setRange(0, count, dirs);
    right = Uint8List(n)..setRange(0, count, right);
    flags = Uint16List(n)..setRange(0, count, flags);
    roomM = Float32List(n)..setRange(0, count, roomM);
    kerbE = f64(kerbE);
    kerbN = f64(kerbN);
    normE = f64(normE);
    normN = f64(normN);
    crossStart = Int32List(n + 1)..setRange(0, count + 1, crossStart);
  }

  /// Slot [k] as an object.
  JoinSlot slotAt(int k) => JoinSlot(
        piece: piece[k],
        s: s[k],
        dirs: dirs[k],
        right: right[k] == 1,
        flags: flags[k],
        roomM: roomM[k],
        kerbE: kerbE[k],
        kerbN: kerbN[k],
        normE: normE[k],
        normN: normN[k],
        crossLots: List.unmodifiable(crossLot.sublist(crossStart[k],
            crossStart[k + 1])),
      );
}

/// Today's access point for a lot, the fallback a lot keeps when no cut fits
/// (§3.2 legacy slot): a graph road number, its arc, and the lot's side.
typedef LegacyAccess = ({int road, double s, bool right});

/// A corridor candidate's verdict: the auto lots it crosses, or a hard hit.
class _Corridor {
  const _Corridor(this.blocked, this.cross);
  final bool blocked;
  final List<int> cross;
}

/// Places a lot's join slots (§3.2) over one road graph.
///
/// Not re-entrant: it keeps its working state in fields between the steps of
/// one lot.
class SiteJoinPlacer {
  SiteJoinPlacer({
    required this.index,
    required this.slotToRoad,
    required this.roads,
    required this.recs,
    required this.roadFirstPiece,
    required this.pieceS0,
    required this.pieceS1,
    required this.pieceFrom,
    required this.pieceTo,
    required this.nodes,
    required this.windows,
    required this.parcels,
    required this.lotsNear,
    required this.roadNoOf,
    required this.sidewalkM,
    this.legacyOfLot,
  }) : _roadSlot = Int32List(roads.length)..fillRange(0, roads.length, -1) {
    for (var slot = 0; slot < slotToRoad.length; slot++) {
      final r = slotToRoad[slot];
      if (r >= 0) _roadSlot[r] = slot;
    }
  }

  final SegmentIndex index;
  final Int32List slotToRoad;
  final List<RoadSpline> roads;
  final List<IndexedRoad> recs;
  final Int32List roadFirstPiece;
  final Float64List pieceS0, pieceS1;
  final Int32List pieceFrom, pieceTo;
  final List<RoadNode> nodes;
  final KerbWindows windows;

  /// The graph's lots, by graph lot index, and the ones near a box (any
  /// order; the placer sorts what it keeps).
  final List<Parcel> parcels;
  final List<int> Function(Box2 box) lotsNear;

  final int? Function(String roadId) roadNoOf;
  final double sidewalkM;

  /// Today's access point of graph lot i (null: no road within reach), asked
  /// only when a lot needs it.
  final LegacyAccess? Function(int lot)? legacyOfLot;

  /// Graph road number -> index slot.
  final Int32List _roadSlot;

  static final double _maxEligibleHalfWidth = RoadClass.values
      .where(isEligibleJoinRoad)
      .fold(0.0, (m, c) => math.max(m, c.halfWidth));

  /// A road of at most this many samples (every straight street is two) is
  /// cheaper walked than looked up.
  static const int _scanSamples = 32;

  // ---- One placement's result and state (see [_place]). ----
  int _road = -1, _piece = -1, _flags = 0;
  double _s = 0;
  bool _right = false;
  List<int> _crossed = const [];
  bool _manual = false;
  double _spanLo = 0, _spanHi = 0;
  double _ax = 0, _ay = 0, _bx = 0, _by = 0, _vx = 0, _vy = 0;
  Float64List _cand = Float64List(48);
  int _candN = 0;

  /// The join slots of a lot with footprint [polygon], slot 0 first.
  List<JoinSlot> slotsFor(
    List<Vec2> polygon, {
    (Vec2, Vec2)? frontage,
    String? roadId,
    (Vec2, Vec2)? sideStreet,
    int ownLot = -1,
    LegacyAccess? legacy,
  }) {
    final out = JoinColumns();
    addSlots(out, polygon,
        frontage: frontage,
        roadId: roadId,
        sideStreet: sideStreet,
        ownLot: ownLot,
        legacy: legacy);
    return [for (var k = 0; k < out.count; k++) out.slotAt(k)];
  }

  /// Appends the join slots of a lot with footprint [polygon] to [out], slot
  /// 0 first, and returns how many.
  ///
  /// [frontage] is the stored frontage (null for frontage-less manual lots and
  /// grid cells), [roadId] and [sideStreet] an auto lot's, [ownLot] its graph
  /// lot index (−1 for a footprint that is not a lot). Today's access point is
  /// [legacy], or [legacyOfLot] of [ownLot]: when it is null there is no road
  /// within reach, and then no slot at all, so the lots without access are
  /// exactly today's. An auto lot whose road is in the graph always has one,
  /// and asks for it only when no cut fits.
  int addSlots(
    JoinColumns out,
    List<Vec2> polygon, {
    (Vec2, Vec2)? frontage,
    String? roadId,
    (Vec2, Vec2)? sideStreet,
    int ownLot = -1,
    LegacyAccess? legacy,
  }) {
    final own = roadId == null ? null : roadNoOf(roadId);
    var leg = legacy;
    if (own == null) {
      leg ??= ownLot >= 0 ? legacyOfLot?.call(ownLot) : null;
      if (leg == null) return 0;
    }

    // The frame's frontage. An auto lot's stored frontage, trusted, IS the
    // frame's (in some order, which the span does not read): taken without
    // building the frame, since every lot of a sprawl comes this way.
    double ax, ay, bx, by, width;
    Vec2? v;
    if (own != null && frontage != null && _trusted(polygon, frontage)) {
      ax = frontage.$1.e;
      ay = frontage.$1.n;
      bx = frontage.$2.e;
      by = frontage.$2.n;
      width = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
    } else {
      final frame = SiteFrame.of(polygon, frontage, index);
      if (frame == null) {
        _emitLegacy(out, leg ?? legacyOfLot!(ownLot)!);
        return 1;
      }
      ax = frame.origin.e;
      ay = frame.origin.n;
      bx = ax + frame.u.e * frame.widthM;
      by = ay + frame.u.n * frame.widthM;
      v = frame.v;
      width = frame.widthM;
    }
    final ip = _interior(polygon);

    var placed = false;
    int? sideRoad;
    if (own != null) {
      if (isEligibleJoinRoad(roads[own].roadClass)) {
        placed = _place(own, ax, ay, bx, by, v, ip, ownLot,
            manual: false, side: false);
      }
      if (sideStreet != null) {
        sideRoad = _sideStreetRoad(sideStreet, own, placed ? _piece : -1);
        if (!placed && sideRoad != null) {
          placed = _place(sideRoad, sideStreet.$1.e, sideStreet.$1.n,
              sideStreet.$2.e, sideStreet.$2.n, null, ip, ownLot,
              manual: false, side: true);
        }
      }
    } else if (roadId == null) {
      // Built above: a lot without a road of its own has no trusted shortcut.
      final inward = v!;
      final a = Vec2(ax, ay), b = Vec2(bx, by);
      for (final (r, ea, eb, facing) in _manualRoads(polygon, a, b, inward)) {
        placed = _place(r, ea.e, ea.n, eb.e, eb.n, facing ? inward : null, ip,
            ownLot,
            manual: true, side: false);
        if (placed) break;
      }
    }
    if (!placed) {
      _emitLegacy(out, leg ?? legacyOfLot!(ownLot)!);
      return 1;
    }

    final start = out.count;
    final slot0Flags = _flags;
    _emit(out);
    // Slot 1: a second slot on the same road at the far end of a wide span.
    if (slot0Flags & (kJoinSideStreet | kJoinOffFrontage) == 0 &&
        width >= kSecondSlotMinFrontageM) {
      _farSlot(out, ip, ownLot);
    }
    // Slot 2: a corner lot's side street, unless slot 0 already is.
    if (sideStreet != null &&
        sideRoad != null &&
        slot0Flags & kJoinSideStreet == 0 &&
        out.count - start < kMaxJoinSlots) {
      if (_place(sideRoad, sideStreet.$1.e, sideStreet.$1.n, sideStreet.$2.e,
          sideStreet.$2.n, null, ip, ownLot,
          manual: false, side: true)) {
        _emit(out);
      }
    }
    return out.count - start;
  }

  /// Whether [frontage] is one [SiteFrame.of] trusts on [polygon]: a finite
  /// polygon of three corners or more and at least 30 m², a frontage of some
  /// length whose midpoint lies within 1 m of the boundary. Then the frame
  /// fronts it exactly. Allocation-free.
  static bool _trusted(List<Vec2> polygon, (Vec2, Vec2) frontage) {
    final n = polygon.length;
    if (n < 3) return false;
    var twice = 0.0;
    for (var i = 0; i < n; i++) {
      final p = polygon[i], q = polygon[(i + 1) % n];
      if (!p.e.isFinite || !p.n.isFinite) return false;
      twice += p.e * q.n - p.n * q.e;
    }
    if (twice.abs() / 2 < kMinSiteAreaM2) return false;
    final fa = frontage.$1, fb = frontage.$2;
    final fe = fb.e - fa.e, fn = fb.n - fa.n;
    if (!(math.sqrt(fe * fe + fn * fn) >= kFrameDegenerateM)) return false;
    final me = (fa.e + fb.e) * 0.5, mn = (fa.n + fb.n) * 0.5;
    for (var i = 0; i < n; i++) {
      final p = polygon[i], q = polygon[(i + 1) % n];
      final ex = q.e - p.e, en = q.n - p.n;
      final len2 = ex * ex + en * en;
      final t = len2 <= 1e-12
          ? 0.0
          : (((me - p.e) * ex + (mn - p.n) * en) / len2).clamp(0.0, 1.0);
      final dx = me - (p.e + ex * t), dn = mn - (p.n + en * t);
      if (dx * dx + dn * dn <= kFrontageOffPolygonM * kFrontageOffPolygonM) {
        return true;
      }
    }
    return false;
  }

  /// [interiorPoint] of [polygon], without its allocations where the vertex
  /// average is inside (every convex lot): the same arithmetic, the same
  /// point.
  static Vec2 _interior(List<Vec2> polygon) {
    if (polygon.isEmpty) return interiorPoint(polygon);
    var se = 0.0, sn = 0.0;
    for (final p in polygon) {
      se += p.e;
      sn += p.n;
    }
    final ae = se / polygon.length, an = sn / polygon.length;
    return _containsXY(polygon, ae, an)
        ? Vec2(ae, an)
        : interiorPoint(polygon);
  }

  /// Today's point, kept as it was.
  void _emitLegacy(JoinColumns out, LegacyAccess legacy) {
    final r = legacy.road;
    _write(out, r, _pieceAt(r, legacy.s), legacy.s, legacy.right, kJoinLegacy,
        0, const []);
  }

  /// The placement last made by [_place].
  void _emit(JoinColumns out) => _write(out, _road, _piece, _s, _right, _flags,
      windows.roomAt(_piece, _s), _crossed);

  void _write(JoinColumns out, int r, int piece, double s, bool right,
      int flags, double room, List<int> cross) {
    final rec = recs[r];
    final i = _segmentAt(rec, s);
    var te = rec.e[i] - rec.e[i - 1], tn = rec.n[i] - rec.n[i - 1];
    final len = math.sqrt(te * te + tn * tn);
    if (len > 1e-12) {
      te /= len;
      tn /= len;
    }
    // The right normal of the tangent is (tn, −te); the left, its negation.
    final ne = right ? tn : -tn, nn = right ? -te : te;
    // The centreline point at s (the graph's own `_pointOn` arithmetic).
    final cum = rec.cum;
    final double ce, cn;
    if (s <= 0) {
      ce = rec.e[0];
      cn = rec.n[0];
    } else if (s >= cum[cum.length - 1]) {
      ce = rec.e[rec.sampleCount - 1];
      cn = rec.n[rec.sampleCount - 1];
    } else {
      final seg = cum[i] - cum[i - 1];
      final t = seg <= 1e-12 ? 0.0 : (s - cum[i - 1]) / seg;
      ce = rec.e[i - 1] + (rec.e[i] - rec.e[i - 1]) * t;
      cn = rec.n[i - 1] + (rec.n[i] - rec.n[i - 1]) * t;
    }
    final hw = roads[r].halfWidth;
    out.add(piece, s, joinDirsFor(roads[r], right), right, flags, room,
        ce + ne * hw, cn + nn * hw, ne, nn, cross);
  }

  int _pieceAt(int road, double s) {
    var lo = roadFirstPiece[road], hi = roadFirstPiece[road + 1] - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (pieceS0[mid] <= s) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  static Vec2 _pointOn(IndexedRoad rec, double s) {
    final cum = rec.cum;
    final n = cum.length;
    if (s <= 0) return rec.sampleAt(0);
    if (s >= cum[n - 1]) return rec.sampleAt(n - 1);
    final i = _segmentAt(rec, s);
    final seg = cum[i] - cum[i - 1];
    final t = seg <= 1e-12 ? 0.0 : (s - cum[i - 1]) / seg;
    return Vec2(rec.e[i - 1] + (rec.e[i] - rec.e[i - 1]) * t,
        rec.n[i - 1] + (rec.n[i] - rec.n[i - 1]) * t);
  }

  // Nearest segment found by [_project]'s walk: squared distance, segment,
  // parameter.
  double _pBest = 0, _pU = 0;
  int _pSeg = 1;

  /// Segment [seg] of [rec] against the best so far, for ([pe], [pn]):
  /// squared distances (the same order), and a segment whose bounding box
  /// already lies further than the best is not projected at all.
  void _consider(IndexedRoad rec, int seg, double pe, double pn) {
    final ae = rec.e[seg - 1], an = rec.n[seg - 1];
    final be = rec.e[seg], bn = rec.n[seg];
    final lx = pe < ae
        ? (pe < be ? (ae < be ? ae : be) - pe : 0.0)
        : (pe > be ? pe - (ae > be ? ae : be) : 0.0);
    final ly = pn < an
        ? (pn < bn ? (an < bn ? an : bn) - pn : 0.0)
        : (pn > bn ? pn - (an > bn ? an : bn) : 0.0);
    if (lx * lx + ly * ly > _pBest) return;
    final ex = be - ae, en = bn - an;
    final len2 = ex * ex + en * en;
    final u = len2 <= 1e-12
        ? 0.0
        : (((pe - ae) * ex + (pn - an) * en) / len2).clamp(0.0, 1.0);
    final dx = pe - (ae + ex * u), dn = pn - (an + en * u);
    final d = dx * dx + dn * dn;
    if (d < _pBest || (d == _pBest && seg < _pSeg)) {
      _pBest = d;
      _pSeg = seg;
      _pU = u;
    }
  }

  /// The arc of ([pe], [pn])'s nearest point on road [r], carried on along
  /// the end tangent past either end of the road (so a frontage running past
  /// a dead end projects to arcs beyond it).
  double _project(int r, double pe, double pn, double reachM) {
    final rec = recs[r];
    final slot = _roadSlot[r];
    _pBest = double.infinity;
    _pSeg = 1;
    _pU = 0;
    final nS = rec.sampleCount;
    if (nS <= _scanSamples) {
      for (var seg = 1; seg < nS; seg++) {
        _consider(rec, seg, pe, pn);
      }
    } else {
      if (slot >= 0) {
        index.visit(Box2(pe - reachM, pn - reachM, pe + reachM, pn + reachM),
            0, (s, other, seg) {
          if (s != slot || seg == 0 || !identical(other.e, rec.e)) return;
          _consider(rec, seg, pe, pn);
        });
      }
      if (_pBest.isInfinite) {
        for (var seg = 1; seg < nS; seg++) {
          _consider(rec, seg, pe, pn);
        }
      }
    }
    final bestSeg = _pSeg, bestU = _pU;
    var arc = rec.arcAt(bestSeg, bestU);
    final last = nS - 1;
    if (bestSeg == 1 && bestU <= 0) {
      final ex = rec.e[1] - rec.e[0], en = rec.n[1] - rec.n[0];
      final len = math.sqrt(ex * ex + en * en);
      if (len > 1e-12) {
        final along = ((pe - rec.e[0]) * ex + (pn - rec.n[0]) * en) / len;
        if (along < 0) arc = along;
      }
    }
    if (bestSeg == last && bestU >= 1) {
      final ex = rec.e[last] - rec.e[last - 1];
      final en = rec.n[last] - rec.n[last - 1];
      final len = math.sqrt(ex * ex + en * en);
      if (len > 1e-12) {
        final along =
            ((pe - rec.e[last]) * ex + (pn - rec.n[last]) * en) / len;
        if (along > 0) arc = rec.lengthM + along;
      }
    }
    return arc;
  }

  /// Adds the candidate interval [lo, hi] of [piece], narrowed to the 0.25 m
  /// quanta it holds; one holding none is no candidate (a slot is always on
  /// the quantum). A bound within [_quantumSlack] quanta of a quantum is
  /// that quantum: a lot corner projected onto its road lands a few
  /// nanometres either side of the metre it was cut at.
  void _pushCand(int piece, double lo, double hi) {
    lo = (lo / kJoinQuantumM - _quantumSlack).ceil() * kJoinQuantumM;
    hi = (hi / kJoinQuantumM + _quantumSlack).floor() * kJoinQuantumM;
    if (lo > hi) return;
    if (_candN + 3 > _cand.length) {
      _cand = Float64List(_cand.length * 2)..setRange(0, _candN, _cand);
    }
    _cand[_candN] = piece.toDouble();
    _cand[_candN + 1] = lo;
    _cand[_candN + 2] = hi;
    _candN += 3;
  }

  /// Places a slot on road [r] for the frontage ([ax], [ay])–([bx], [by])
  /// (inward normal [vIn], or the one facing [ip]) into the placement fields;
  /// false when no span fits even [kJoinMinRoomM].
  bool _place(int r, double ax, double ay, double bx, double by, Vec2? vIn,
      Vec2 ip, int ownLot,
      {required bool manual, required bool side}) {
    final w = math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
    if (!(w > 1e-6)) return false;
    final rec = recs[r];
    final road = roads[r];
    final len = rec.lengthM;
    final ue = (bx - ax) / w, un = (by - ay) / w;
    // u.perp, turned to face the lot unless the frame's normal is given.
    var ve = vIn?.e ?? -un, vn = vIn?.n ?? ue;
    if (vIn == null && (ip.e - ax) * ve + (ip.n - ay) * vn < 0) {
      ve = -ve;
      vn = -vn;
    }

    final reach = manual
        ? RoadGraph.manualReachM + road.halfWidth
        : road.halfWidth + sidewalkM + 8;
    final pa = _project(r, ax, ay, reach), pb = _project(r, bx, by, reach);
    final sLo = pa < pb ? pa : pb, sHi = pa < pb ? pb : pa;
    final narrow = w < kNarrowFrontageM;
    final cc = w >= kWideCornerFrontageM ? kWideCornerClearM : kCornerClearM;
    final pEnd = roadFirstPiece[r + 1];

    for (var attempt = 0; attempt < 2; attempt++) {
      final m = attempt == 1
          ? kJoinMinRoomM
          : (narrow ? kNarrowCutHalfM : kWideCutHalfM);
      final spanLo = sLo + m + cc, spanHi = sHi - m - cc;
      var flags = kJoinCut | (side ? kJoinSideStreet : 0);
      _candN = 0;
      for (var p = _pieceAt(r, spanLo); p < pEnd && pieceS0[p] <= spanHi; p++) {
        for (var k = windows.start[p]; k < windows.start[p + 1]; k++) {
          final lo = math.max(windows.lo[k] + m, spanLo);
          final hi = math.min(windows.hi[k] - m, spanHi);
          if (lo <= hi) _pushCand(p, lo, hi);
        }
      }
      double target;
      var other = double.nan;
      if (_candN == 0) {
        // A manual lot wholly past the road's end: the nearest window point,
        // bridged by a dogleg.
        if (!manual || !(spanHi < 0 || spanLo > len)) continue;
        for (var p = roadFirstPiece[r]; p < pEnd; p++) {
          for (var k = windows.start[p]; k < windows.start[p + 1]; k++) {
            final lo = windows.lo[k] + m, hi = windows.hi[k] - m;
            if (lo <= hi) _pushCand(p, lo, hi);
          }
        }
        if (_candN == 0) continue;
        target = spanHi < 0 ? 0.0 : len;
        flags |= kJoinOffFrontage;
      } else if (narrow) {
        final mid = ((sLo + sHi) / 2).clamp(0.0, len);
        final p = _pieceAt(r, mid);
        final d0 = mid - pieceS0[p], d1 = pieceS1[p] - mid;
        final hiT = sHi - kNarrowTargetInsetM, loT = sLo + kNarrowTargetInsetM;
        if ((d0 - d1).abs() <= kNarrowTieM || d0 < d1) {
          target = hiT;
          other = loT;
        } else {
          target = loT;
          other = hiT;
        }
      } else {
        target = _project(r, (ax + bx) * 0.5, (ay + by) * 0.5, reach);
      }

      var at = _nearestIn(target);
      if (narrow &&
          _intervalOf(target, _targetSlackM) < 0 &&
          _intervalOf(other, _targetSlackM) >= 0) {
        at = _nearestIn(other);
      }
      if ((at - target).abs() > kJoinClampedM) flags |= kJoinClamped;
      final k = _intervalOf(at);
      final s = _quantise(at, _cand[k + 1], _cand[k + 2]);

      _manual = manual;
      _spanLo = spanLo;
      _spanHi = spanHi;
      _ax = ax;
      _ay = ay;
      _bx = bx;
      _by = by;
      _vx = ve;
      _vy = vn;

      // Set back from the kerb, or bridged past a road end: the corridor
      // search picks the slot. Only a lot the plat did not cut can be: an
      // auto lot's frontage IS the pavement line (a curved street's chord
      // can read a little behind it, and must not send every lot on a bend
      // to the search).
      final dogleg = flags & kJoinOffFrontage != 0;
      var chosen = s;
      var cross = const <int>[];
      if (dogleg || (manual && _setBack(r, s, ip))) {
        final res = _corridorSearch(r, s, ip, w, dogleg, ownLot);
        if (res == null) {
          flags |= kJoinCorridorBlocked;
        } else {
          chosen = res.$1;
          cross = res.$2;
          if (cross.isNotEmpty) flags |= kJoinEasement;
          if ((chosen - target).abs() > kJoinClampedM) {
            flags |= kJoinClamped;
          } else {
            flags &= ~kJoinClamped;
          }
        }
      }
      _road = r;
      _s = chosen;
      _piece = _cand[_intervalOf(chosen)].toInt();
      _right = _rightAt(rec, chosen, ip.e, ip.n);
      _flags = flags;
      _crossed = cross;
      return true;
    }
    return false;
  }

  /// Slot 1: the far end of the last placement's span on its road, when it
  /// lies at least [kSecondSlotMinGapM] away and its corridor (if any) is
  /// clear. Reads the placement fields; writes nothing to them.
  void _farSlot(JoinColumns out, Vec2 ip, int ownLot) {
    final s0 = _s;
    final target = s0 - _spanLo > _spanHi - s0 ? _spanLo : _spanHi;
    final at = _nearestIn(target);
    final k = _intervalOf(at);
    final s = _quantise(at, _cand[k + 1], _cand[k + 2]);
    if ((s - s0).abs() < kSecondSlotMinGapM) return;
    var flags = kJoinCut;
    if ((s - target).abs() > kJoinClampedM) flags |= kJoinClamped;
    var cross = const <int>[];
    if (_manual && _setBack(_road, s, ip)) {
      final w = math.sqrt((_bx - _ax) * (_bx - _ax) + (_by - _ay) * (_by - _ay));
      final c = _evaluate(_road, s, ip, w, false, ownLot);
      if (c.blocked) return;
      cross = c.cross;
      if (cross.isNotEmpty) flags |= kJoinEasement;
    }
    final piece = _cand[k].toInt();
    _write(out, _road, piece, s, _rightAt(recs[_road], s, ip.e, ip.n), flags,
        windows.roomAt(piece, s), cross);
  }

  /// The point of the candidate intervals nearest [t]; ties to the smaller.
  double _nearestIn(double t) {
    var best = double.infinity;
    var at = t;
    for (var k = 0; k < _candN; k += 3) {
      final lo = _cand[k + 1], hi = _cand[k + 2];
      final x = t < lo ? lo : (t > hi ? hi : t);
      final d = (x - t).abs();
      if (d < best) {
        best = d;
        at = x;
      }
    }
    return at;
  }

  /// The offset (into the candidates) of the interval holding [s] (within
  /// [tol]), or −1.
  int _intervalOf(double s, [double tol = 0]) {
    for (var k = 0; k < _candN; k += 3) {
      if (s >= _cand[k + 1] - tol && s <= _cand[k + 2] + tol) return k;
    }
    return -1;
  }

  /// Quanta of slack in [_pushCand]'s bounds, and metres of slack in a
  /// target's membership: far above float noise, far below a quantum.
  static const double _quantumSlack = 1e-6;
  static const double _targetSlackM = 1e-6;

  /// [s] on the 0.25 m quantum, kept inside [lo, hi] (left as it is where the
  /// interval holds no quantum).
  static double _quantise(double s, double lo, double hi) {
    var q = (s / kJoinQuantumM).round() * kJoinQuantumM;
    if (q < lo) q += kJoinQuantumM;
    if (q > hi) q -= kJoinQuantumM;
    return q >= lo && q <= hi ? q : s;
  }

  /// Whether the frontage line lies more than `max(sidewalkM + 0.5, 3.0)`
  /// behind the kerb at [s] (§3.2 set-back lot).
  bool _setBack(int r, double s, Vec2 ip) =>
      _kerbToFrontage(r, s, ip) >
      math.max(sidewalkM + kSetBackSidewalkSlackM, kSetBackMinM);

  /// Metres from the kerb at [s] (on the lot's side) along the road normal to
  /// the placement's frontage line; 0 where the normal runs along it.
  double _kerbToFrontage(int r, double s, Vec2 ip) {
    final (k, nrm) = _kerb(r, s, ip);
    final denom = nrm.e * _vx + nrm.n * _vy;
    if (denom <= 1e-6) return 0;
    return ((_ax - k.e) * _vx + (_ay - k.n) * _vy) / denom;
  }

  /// The kerb point at [s] on [ip]'s side of road [r], and the unit normal
  /// into the lot.
  (Vec2, Vec2) _kerb(int r, double s, Vec2 ip) {
    final rec = recs[r];
    final right = _rightAt(rec, s, ip.e, ip.n);
    final i = _segmentAt(rec, s);
    var te = rec.e[i] - rec.e[i - 1], tn = rec.n[i] - rec.n[i - 1];
    final len = math.sqrt(te * te + tn * tn);
    if (len > 1e-12) {
      te /= len;
      tn /= len;
    }
    final nrm = right ? Vec2(tn, -te) : Vec2(-tn, te);
    return (_pointOn(rec, s) + nrm * roads[r].halfWidth, nrm);
  }

  /// The corridor polyline at [s] (§3.7a): kerb to frontage along the road
  /// normal, or the dogleg K → T → Q → F for a lot past a road end.
  List<Vec2> _corridorLine(int r, double s, Vec2 ip, double w, bool dogleg) {
    final (k, nrm) = _kerb(r, s, ip);
    final ea = Vec2(_ax, _ay);
    final inward = Vec2(_vx, _vy);
    if (!dogleg) {
      final denom = nrm.dot(inward);
      final gap = denom <= 1e-6 ? 0.0 : (ea - k).dot(inward) / denom;
      if (gap <= 1e-3) return [k];
      return [k, k + nrm * gap];
    }
    final u = Vec2(_bx - _ax, _by - _ay) * (1 / w);
    final t = k + nrm * kDoglegThroatM;
    final xj = (k - ea).dot(u);
    final xc = w >= 2 * kDoglegSideClearM
        ? (xj < kDoglegSideClearM
            ? kDoglegSideClearM
            : (xj > w - kDoglegSideClearM ? w - kDoglegSideClearM : xj))
        : w / 2;
    final ty = (t - ea).dot(inward);
    final q = ea + u * xc + inward * ty;
    final f = ea + u * xc;
    final pts = <Vec2>[k];
    for (final x in [t, q, f]) {
      if (x.distanceTo(pts.last) > 1e-6) pts.add(x);
    }
    return pts;
  }

  /// The §3.7a candidates for a set-back slot at [s0] over the placement's
  /// candidate intervals; the best one's arc and crossed lots, or null when
  /// every candidate hits a hard obstacle.
  (double, List<int>)? _corridorSearch(
      int r, double s0, Vec2 ip, double w, bool dogleg, int ownLot) {
    // (s, the lot a centred candidate is centred on, how many it must cross).
    final ss = <double>[];
    final centredOn = <int>[];
    final needs = <int>[];
    void add(double s, int lot, int need) {
      final q = (s / kJoinQuantumM).round() * kJoinQuantumM;
      if (_intervalOf(q) < 0) return;
      ss.add(q);
      centredOn.add(lot);
      needs.add(need);
    }

    add(s0, -1, -1);
    // Auto lots the corridor could cross anywhere along the candidates.
    var box = Box2.of(_corridorLine(r, _cand[1], ip, w, dogleg));
    for (var k = 0; k < _candN; k += 3) {
      for (final x in [_cand[k + 1], _cand[k + 2]]) {
        final b = Box2.of(_corridorLine(r, x, ip, w, dogleg));
        box = Box2(math.min(box.minE, b.minE), math.min(box.minN, b.minN),
            math.max(box.maxE, b.maxE), math.max(box.maxN, b.maxN));
      }
    }
    final near = lotsNear(box.grow(kAccessCorridorHalfM))..sort();
    final reach = roads[r].halfWidth + sidewalkM + 64;
    for (final l in near) {
      if (l == ownLot) continue;
      final lot = parcels[l];
      if (lot.manual) continue;
      final c = lot.centroid;
      add(_project(r, c.e, c.n, reach), l, 1);
      if (lot.frontageWidth < 2 * kAccessCorridorHalfM + 0.1) {
        final poly = lot.polygon;
        for (var i = 0; i < poly.length; i++) {
          final mid = (poly[i] + poly[(i + 1) % poly.length]) * 0.5;
          add(_project(r, mid.e, mid.n, reach), l, 2);
        }
      }
    }
    for (final d in kCorridorRetryM) {
      add(s0 - d, -1, -1);
      add(s0 + d, -1, -1);
    }

    // The choice is the least (crossed count, centred ? 0 : 1, |s − s0|, s).
    // Evaluated best-first, which picks exactly that without evaluating every
    // candidate: the uncentred ones (the target and its retries) first — one
    // crossing nothing is centred and beats all; then the lots' centres in
    // (|s − s0|, s) order — the first that crosses exactly its lot beats
    // every uncentred candidate crossing one lot or more; then an uncentred
    // one crossing a single lot; then the side lines, whose first valid one
    // crosses exactly two; else the best uncentred candidate.
    var bestS = 0.0;
    List<int>? bestCross;
    for (var i = 0; i < ss.length; i++) {
      if (centredOn[i] >= 0) continue;
      final s = ss[i];
      final c = _evaluate(r, s, ip, w, dogleg, ownLot);
      if (c.blocked) continue;
      final better = bestCross == null ||
          c.cross.length < bestCross.length ||
          (c.cross.length == bestCross.length &&
              ((s - s0).abs() < (bestS - s0).abs() ||
                  ((s - s0).abs() == (bestS - s0).abs() && s < bestS)));
      if (better) {
        bestS = s;
        bestCross = c.cross;
      }
      // The target itself (the first, |s − s0| = 0) crossing nothing is the
      // least key there is.
      if (i == 0 && s == s0 && c.cross.isEmpty) return (s, c.cross);
    }
    if (bestCross != null && bestCross.isEmpty) return (bestS, bestCross);
    for (final need in const [1, 2]) {
      if (need == 2 && bestCross != null && bestCross.length == 1) {
        return (bestS, bestCross);
      }
      final order = [
        for (var i = 0; i < ss.length; i++)
          if (centredOn[i] >= 0 && needs[i] == need) i
      ]..sort((x, y) {
          final dx = (ss[x] - s0).abs(), dy = (ss[y] - s0).abs();
          if (dx != dy) return dx.compareTo(dy);
          if (ss[x] != ss[y]) return ss[x].compareTo(ss[y]);
          return centredOn[x].compareTo(centredOn[y]);
        });
      for (final i in order) {
        final c = _evaluate(r, ss[i], ip, w, dogleg, ownLot);
        if (c.blocked || c.cross.length != need) continue;
        if (!c.cross.contains(centredOn[i])) continue;
        return (ss[i], c.cross);
      }
    }
    if (bestCross == null) return null;
    return (bestS, bestCross);
  }

  /// The corridor at [s]: blocked by a manual parcel or a road's carriageway
  /// and pavement, else the auto lots it crosses, ascending.
  _Corridor _evaluate(
      int r, double s, Vec2 ip, double w, bool dogleg, int ownLot) {
    final line = _corridorLine(r, s, ip, w, dogleg);
    final cross = <int>[];
    const h = kAccessCorridorHalfM;
    final joinSlot = _roadSlot[r];
    final joinRoad = roads[r];
    final joinPave = joinRoad.roadClass.hasPavement ? sidewalkM : 0.0;
    for (var i = 0; i + 1 < line.length; i++) {
      final p0 = line[i], p1 = line[i + 1];
      final box = Box2.of([p0, p1]).grow(h);
      var hit = false;
      index.visit(box, RoadGraph.maxHalfWidth + sidewalkM, (slot, rec, seg) {
        if (hit || seg == 0) return;
        final road = rec.road;
        if (road.roadClass.isElevated) return;
        final band =
            road.halfWidth + (road.roadClass.hasPavement ? sidewalkM : 0.0);
        final isJoin = slot == joinSlot && identical(rec.e, recs[r].e);
        final c0 = rec.cum[seg - 1], c1 = rec.cum[seg];
        // The join road near its own slot is where the corridor starts.
        final ranges = <(double, double)>[];
        if (isJoin) {
          final a = s - kCorridorJoinRoadSkipM, b = s + kCorridorJoinRoadSkipM;
          if (c0 < a) ranges.add((c0, math.min(c1, a)));
          if (c1 > b) ranges.add((math.max(c0, b), c1));
        } else {
          ranges.add((c0, c1));
        }
        // The first leg, against its own road, starts past its pavement.
        final legLen = p0.distanceTo(p1);
        final q0 = isJoin && i == 0
            ? p0 + (p1 - p0) * (math.min(joinPave, legLen) / math.max(1e-9, legLen))
            : p0;
        for (final (x0, x1) in ranges) {
          if (x1 - x0 <= 1e-9) continue;
          final deck = road.deck;
          final parts = deck == null ? 1 : math.max(1, ((x1 - x0) / 2).ceil());
          for (var k = 0; k < parts; k++) {
            final y0 = x0 + (x1 - x0) * k / parts;
            final y1 = x0 + (x1 - x0) * (k + 1) / parts;
            if (deck != null && deck.offGroundAt((y0 + y1) / 2, rec.lengthM)) {
              continue;
            }
            final a = _onSegment(rec, seg, y0), b = _onSegment(rec, seg, y1);
            if (_segmentToRect(a, b, q0, p1, h) < band) {
              hit = true;
              return;
            }
          }
        }
      });
      if (hit) return const _Corridor(true, []);
      for (final l in lotsNear(box)) {
        if (l == ownLot) continue;
        final lot = parcels[l];
        if (!_overlapsRect(lot.polygon, p0, p1, h, kCorridorOverlapM)) continue;
        if (lot.manual) return const _Corridor(true, []);
        if (!cross.contains(l)) cross.add(l);
      }
    }
    cross.sort();
    return _Corridor(false, cross);
  }

  static Vec2 _onSegment(IndexedRoad rec, int seg, double arc) {
    final c0 = rec.cum[seg - 1], c1 = rec.cum[seg];
    final t = c1 - c0 <= 1e-12 ? 0.0 : ((arc - c0) / (c1 - c0)).clamp(0.0, 1.0);
    return Vec2(rec.e[seg - 1] + (rec.e[seg] - rec.e[seg - 1]) * t,
        rec.n[seg - 1] + (rec.n[seg] - rec.n[seg - 1]) * t);
  }

  /// Distance from segment [a]–[b] to the rectangle of half width [h] along
  /// [p0]–[p1] (no end caps); 0 where they meet.
  static double _segmentToRect(Vec2 a, Vec2 b, Vec2 p0, Vec2 p1, double h) {
    final d = p1 - p0;
    final len = d.length;
    if (len <= 1e-9) return double.infinity;
    final t = d * (1 / len), nrm = t.perp;
    final ax = (a - p0).dot(t), ay = (a - p0).dot(nrm);
    final bx = (b - p0).dot(t), by = (b - p0).dot(nrm);
    // Liang-Barsky against [0, len] × [−h, h].
    var t0 = 0.0, t1 = 1.0;
    final dx = bx - ax, dy = by - ay;
    bool clip(double p, double q) {
      if (p == 0) return q >= 0;
      final r = q / p;
      if (p < 0) {
        if (r > t1) return false;
        if (r > t0) t0 = r;
      } else {
        if (r < t0) return false;
        if (r < t1) t1 = r;
      }
      return true;
    }

    if (clip(-dx, ax) &&
        clip(dx, len - ax) &&
        clip(-dy, ay + h) &&
        clip(dy, h - ay) &&
        t0 <= t1) {
      return 0;
    }
    double boxDist(double x, double y) {
      final cx = x < 0 ? -x : (x > len ? x - len : 0.0);
      final cy = y < -h ? -h - y : (y > h ? y - h : 0.0);
      return math.sqrt(cx * cx + cy * cy);
    }

    double segDist(double px, double py) {
      final l2 = dx * dx + dy * dy;
      final v = l2 <= 1e-18
          ? 0.0
          : (((px - ax) * dx + (py - ay) * dy) / l2).clamp(0.0, 1.0);
      final ex = px - (ax + dx * v), ey = py - (ay + dy * v);
      return math.sqrt(ex * ex + ey * ey);
    }

    var best = math.min(boxDist(ax, ay), boxDist(bx, by));
    for (final (x, y) in [(0.0, -h), (0.0, h), (len, -h), (len, h)]) {
      final dd = segDist(x, y);
      if (dd < best) best = dd;
    }
    return best;
  }

  /// Whether [polygon] overlaps the rectangle of half width [h] along
  /// [p0]–[p1] by more than [shrink]: the rectangle shrunk by it on every side
  /// meets the polygon's interior.
  static bool _overlapsRect(
      List<Vec2> polygon, Vec2 p0, Vec2 p1, double h, double shrink) {
    final d = p1 - p0;
    final len = d.length;
    if (len <= 2 * shrink || h <= shrink) return false;
    final t = d * (1 / len), nrm = t.perp;
    final x0 = shrink, x1 = len - shrink, hh = h - shrink;
    for (final v in polygon) {
      final x = (v - p0).dot(t), y = (v - p0).dot(nrm);
      if (x > x0 && x < x1 && y > -hh && y < hh) return true;
    }
    final corners = [
      p0 + t * x0 + nrm * -hh,
      p0 + t * x1 + nrm * -hh,
      p0 + t * x1 + nrm * hh,
      p0 + t * x0 + nrm * hh,
    ];
    for (final c in corners) {
      if (_containsXY(polygon, c.e, c.n)) return true;
    }
    for (var i = 0; i < polygon.length; i++) {
      final a = polygon[i], b = polygon[(i + 1) % polygon.length];
      for (var j = 0; j < 4; j++) {
        if (_cross(a, b, corners[j], corners[(j + 1) % 4])) return true;
      }
    }
    return false;
  }

  /// Even-odd containment, `site_frame.dart`'s arithmetic.
  static bool _containsXY(List<Vec2> poly, double pe, double pn) {
    var inside = false;
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final a = poly[i], b = poly[j];
      if ((a.n > pn) != (b.n > pn) &&
          pe < (b.e - a.e) * (pn - a.n) / (b.n - a.n) + a.e) {
        inside = !inside;
      }
    }
    return inside;
  }

  static bool _cross(Vec2 a, Vec2 b, Vec2 c, Vec2 d) {
    final ab = b - a, cd = d - c;
    final d1 = ab.cross(c - a), d2 = ab.cross(d - a);
    final d3 = cd.cross(a - c), d4 = cd.cross(b - c);
    return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) &&
        ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0));
  }

  /// A manual lot's candidate roads (§3.2): the eligible road its frontage
  /// [a]–[b] faces (the §3.1 score, nearest point outside the edge, the lot
  /// lying on [v]'s side), then every other eligible road within reach of an
  /// edge, nearest first, ties by road number. Each with the edge it is
  /// placed against, and whether that edge is the frontage.
  ///
  /// The facing road comes first and alone: the others are looked for only
  /// when no slot fits on it (the index walk over a whole installation's
  /// reach is the costly part of a manual lot).
  Iterable<(int, Vec2, Vec2, bool)> _manualRoads(
      List<Vec2> polygon, Vec2 a, Vec2 b, Vec2 v) sync* {
    final face = _facingRoad(a, b, v);
    if (face >= 0) yield (face, a, b, true);
    yield* _otherRoads(polygon, face);
  }

  /// Whether segment q0–q1's bounding box lies further than [limit] from the
  /// box [minE]..[maxN].
  static bool _boxFar(double minE, double minN, double maxE, double maxN,
      double q0e, double q0n, double q1e, double q1n, double limit) {
    final lo = q0e < q1e ? q0e : q1e, hi = q0e < q1e ? q1e : q0e;
    final lon = q0n < q1n ? q0n : q1n, hin = q0n < q1n ? q1n : q0n;
    final dx = lo > maxE ? lo - maxE : (minE > hi ? minE - hi : 0.0);
    final dy = lon > maxN ? lon - maxN : (minN > hin ? minN - hin : 0.0);
    return dx * dx + dy * dy > limit * limit;
  }

  /// The eligible graph road the frontage [a]–[b] faces (§3.1's score), or −1.
  int _facingRoad(Vec2 a, Vec2 b, Vec2 v) {
    final ab = b - a;
    final abLen = ab.length;
    final tEdge = abLen > 1e-9 ? ab * (1 / abLen) : const Vec2(1, 0);
    final lotSide = ab.cross(v) < 0 ? -1.0 : 1.0;
    final minE = math.min(a.e, b.e), maxE = math.max(a.e, b.e);
    final minN = math.min(a.n, b.n), maxN = math.max(a.n, b.n);
    var faceScore = double.infinity;
    var faceRoad = -1, faceSeg = -1;
    index.visit(Box2(minE, minN, maxE, maxN),
        RoadGraph.manualReachM + _maxEligibleHalfWidth, (slot, rec, seg) {
      if (seg == 0 || slot >= slotToRoad.length) return;
      final r = slotToRoad[slot];
      if (r < 0 || !identical(rec.e, recs[r].e)) return;
      final road = roads[r];
      if (!isEligibleJoinRoad(road.roadClass)) return;
      final limit = RoadGraph.manualReachM + road.halfWidth;
      if (_boxFar(minE, minN, maxE, maxN, rec.e[seg - 1], rec.n[seg - 1],
          rec.e[seg], rec.n[seg], limit)) {
        return;
      }
      final q0 = rec.sampleAt(seg - 1), q1 = rec.sampleAt(seg);
      final (dF, onRoad) = _segmentPair(a, b, q0, q1);
      if (dF <= limit && ab.cross(onRoad - a) * lotSide < 0) {
        final qd = q1 - q0;
        final ql = qd.length;
        if (ql > 1e-9) {
          final score = dF -
              kEffectiveFrontageTangentWeight * tEdge.dot(qd * (1 / ql)).abs();
          if (score < faceScore ||
              (score == faceScore &&
                  (r < faceRoad || (r == faceRoad && seg < faceSeg)))) {
            faceScore = score;
            faceRoad = r;
            faceSeg = seg;
          }
        }
      }
    });
    return faceRoad;
  }

  /// Every eligible graph road but [exclude] within reach of an edge of
  /// [polygon], nearest first, ties by road number, each with its nearest
  /// edge.
  List<(int, Vec2, Vec2, bool)> _otherRoads(List<Vec2> polygon, int exclude) {
    final box = Box2.of(polygon);
    final seen = <int, int>{};
    final order = <int>[];
    final dist = <double>[];
    final edgeOf = <int>[];
    index.visit(box, RoadGraph.manualReachM + _maxEligibleHalfWidth,
        (slot, rec, seg) {
      if (seg == 0 || slot >= slotToRoad.length) return;
      final r = slotToRoad[slot];
      if (r < 0 || r == exclude || !identical(rec.e, recs[r].e)) return;
      final road = roads[r];
      if (!isEligibleJoinRoad(road.roadClass)) return;
      final limit = RoadGraph.manualReachM + road.halfWidth;
      if (_boxFar(box.minE, box.minN, box.maxE, box.maxN, rec.e[seg - 1],
          rec.n[seg - 1], rec.e[seg], rec.n[seg], limit)) {
        return;
      }
      final q0 = rec.sampleAt(seg - 1), q1 = rec.sampleAt(seg);
      for (var k = 0; k < polygon.length; k++) {
        final (d, _) = _segmentPair(
            polygon[k], polygon[(k + 1) % polygon.length], q0, q1);
        if (d > limit) continue;
        final at = seen[r];
        if (at == null) {
          seen[r] = order.length;
          order.add(r);
          dist.add(d);
          edgeOf.add(k);
        } else if (d < dist[at] || (d == dist[at] && k < edgeOf[at])) {
          dist[at] = d;
          edgeOf[at] = k;
        }
      }
    });
    final idx = [for (var i = 0; i < order.length; i++) i]
      ..sort((x, y) {
        final c = dist[x].compareTo(dist[y]);
        return c != 0 ? c : order[x].compareTo(order[y]);
      });
    return [
      for (final i in idx)
        (
          order[i],
          polygon[edgeOf[i]],
          polygon[(edgeOf[i] + 1) % polygon.length],
          false,
        ),
    ];
  }

  /// The nearest distance between segments [a]–[b] and [q0]–[q1], and the
  /// point on the second where it is met (the first of the fixed candidates
  /// strictly nearest; the crossing point where they cross).
  static (double, Vec2) _segmentPair(Vec2 a, Vec2 b, Vec2 q0, Vec2 q1) {
    if (_cross(a, b, q0, q1)) {
      final ab = b - a, qd = q1 - q0;
      final denom = ab.cross(qd);
      final t = denom.abs() <= 1e-18 ? 0.0 : (a - q0).cross(ab) / -denom;
      return (0.0, q0 + qd * t);
    }
    var best = double.infinity;
    var at = q0;
    void consider(Vec2 onRoad, double d) {
      if (d < best) {
        best = d;
        at = onRoad;
      }
    }

    final ra = _nearestOn(a, q0, q1);
    consider(ra, a.distanceTo(ra));
    final rb = _nearestOn(b, q0, q1);
    consider(rb, b.distanceTo(rb));
    consider(q0, q0.distanceTo(_nearestOn(q0, a, b)));
    consider(q1, q1.distanceTo(_nearestOn(q1, a, b)));
    return (best, at);
  }

  static Vec2 _nearestOn(Vec2 p, Vec2 a, Vec2 b) {
    final d = b - a;
    final len2 = d.dot(d);
    if (len2 <= 1e-12) return a;
    final t = ((p - a).dot(d) / len2).clamp(0.0, 1.0);
    return a + d * t;
  }

  /// Distance from ([pe], [pn]) to road [r] over the at most [_scanSamples]
  /// segments at its end nearer [node] (its whole length when shorter).
  double _distanceNearEnd(int r, Vec2 node, double pe, double pn) {
    final rec = recs[r];
    final nS = rec.sampleCount;
    final last = nS - 1;
    final d0 = (rec.e[0] - node.e).abs() + (rec.n[0] - node.n).abs();
    final d1 = (rec.e[last] - node.e).abs() + (rec.n[last] - node.n).abs();
    final lo = d0 <= d1 ? 1 : math.max(1, nS - _scanSamples);
    final hi = d0 <= d1 ? math.min(last, _scanSamples) : last;
    _pBest = double.infinity;
    _pSeg = 1;
    _pU = 0;
    for (var seg = lo; seg <= hi; seg++) {
      _consider(rec, seg, pe, pn);
    }
    return math.sqrt(_pBest);
  }

  /// An auto lot's side street (§3.2 candidate 1): the eligible road other
  /// than [own] whose kerb line lies nearest the side edge [edge]'s midpoint
  /// (the plat's own corner test), ties by road number; null for none within
  /// 12 m of it. Asked first of the roads meeting the node at the nearer end
  /// of the lot's piece ([piece], or the piece the edge projects onto), which
  /// is where a corner lot's side street meets its own; the index answers
  /// only where none of those does.
  int? _sideStreetRoad((Vec2, Vec2) edge, int own, int piece) {
    final me = (edge.$1.e + edge.$2.e) * 0.5, mn = (edge.$1.n + edge.$2.n) * 0.5;
    const tol = 12.0;
    var best = double.infinity;
    var bestR = -1;
    if (own >= 0) {
      final p = piece >= 0
          ? piece
          : _pieceAt(own,
              _project(own, me, mn, roads[own].halfWidth + sidewalkM + 24));
      final nf = nodes[pieceFrom[p]], nt = nodes[pieceTo[p]];
      final df = (nf.at.e - me) * (nf.at.e - me) + (nf.at.n - mn) * (nf.at.n - mn);
      final dt = (nt.at.e - me) * (nt.at.e - me) + (nt.at.n - mn) * (nt.at.n - mn);
      final node = df <= dt ? nf : nt;
      for (final id in node.legRoadIds) {
        final r = roadNoOf(id);
        if (r == null || r == own) continue;
        if (!isEligibleJoinRoad(roads[r].roadClass)) continue;
        final gap = (_distanceNearEnd(r, node.at, me, mn) -
                roads[r].halfWidth -
                sidewalkM)
            .abs();
        if (gap < best || (gap == best && r < bestR)) {
          best = gap;
          bestR = r;
        }
      }
      if (bestR >= 0 && best <= tol) return bestR;
    }
    best = double.infinity;
    bestR = -1;
    final reach = RoadGraph.maxHalfWidth + sidewalkM + tol;
    index.visit(Box2(me - reach, mn - reach, me + reach, mn + reach), 0,
        (slot, rec, seg) {
      if (seg == 0 || slot >= slotToRoad.length) return;
      final r = slotToRoad[slot];
      if (r < 0 || r == own || !identical(rec.e, recs[r].e)) return;
      final road = roads[r];
      if (!isEligibleJoinRoad(road.roadClass)) return;
      final gap =
          (rec.distanceToSegment(Vec2(me, mn), seg) - road.halfWidth - sidewalkM)
              .abs();
      if (gap < best || (gap == best && r < bestR)) {
        best = gap;
        bestR = r;
      }
    });
    return bestR >= 0 && best <= tol ? bestR : null;
  }
}
