// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The two R2 plan checks the frozen R2a validator (V1–V13) leaves open
/// (docs/plans/site-access.md §2.4 as built, §3.7a): every pave ring lies
/// inside the site's parcel ∪ the access corridors of its cut joins, and
/// every corridor keeps its clearance.
///
/// The corridor of a cut join is §3.7a's polyline from the join's kerb point:
/// along the slot's road normal to the frontage line, or R1's dogleg
/// `K → T → Q → F` for a `kJoinOffFrontage` slot; `kAccessCorridorHalfM`
/// either side, no end caps. As built, its last leg runs on past the frontage
/// line until its whole width is inside the lot (`h·|d·u|/(d·v)` further), so a
/// drive leaving a skewed kerb is inside the corridor or the parcel at every
/// point ("restricted to the stretch outside the lot's own polygon"). Past the
/// frontage line (frame `y > 0`) every leg, the run-on included, is clipped to
/// the lot's side lines (`0 ≤ x ≤ W`): pave past a side line near the
/// frontage corner is still reported.
///
/// Paving: each ring is sampled (its vertices, its edges every 0.25 m, its
/// inside on a 1 m grid); a sample inside the parcel polygon or a corridor leg
/// (within 5 cm) passes. The first failing sample of a ring is reported.
///
/// Clearance: a used slot is not `kJoinCorridorBlocked`; none of its crossed
/// lots is BUILT; and, for a set-back corridor (longer than the 3.5 m §3.2
/// set-back threshold) or a dogleg — the corridors R1 searched — no other
/// at-grade road's carriageway and pavement (nor the join road's beyond 12 m
/// of arc from the join) comes within it, by R1's distance test (elevated
/// roads and off-ground deck stretches skipped). A kerb crossing inside its
/// own road's pavement strip is the plat's, not a corridor's (a sprawl lot
/// beside another street's dead end meets that street's pavement there).
/// As built: other MANUAL parcels are not re-tested here —
/// `RoadGraph` exposes no lot polygons — so that clearance stays R1's
/// placement guarantee (`kJoinCorridorBlocked`) and the book's placement
/// refusal (§3.7a rule 5).
///
/// Pure: reads the context's graph, parcel and slots and the plan's rows;
/// never the ground; no platform hash, draw, clock, map iteration or
/// trigonometry (§3.9). A test-time and sync-time check: it allocates.
library;

import 'dart:math' as math;

import '../parcel.dart';
import '../road_graph.dart';
import '../spatial_index.dart';
import 'site_access_constants.dart';
import 'site_access_plan.dart';
import 'site_frame.dart';
import 'site_join.dart';
import 'site_plan_generator.dart';

/// A sample within this of the parcel or a corridor passes.
const double _kTolM = 0.05;

/// Edge and interior sample pitches.
const double _kEdgeStepM = 0.25;
const double _kInsideStepM = 1.0;

/// The pavement width of a road with one, for the clearance test: the
/// layout's default `sidewalkM` (`RoadGraph` keeps its own private). Not in
/// `site_access_constants.dart`; reported to core.
const double _kPavementM = 3.0;

/// One straight corridor leg, world metres.
class _Leg {
  _Leg(this.a, this.b, {this.sides})
      : len = a.distanceTo(b),
        t = (b - a).normalized;
  final Vec2 a, b;
  final double len;
  final Vec2 t;

  /// The site frame the corridor is clipped by: past the frontage line
  /// (`y > 0`) a sample counts only between the lot's side lines `x = 0` and
  /// `x = W` (the corridor is the stretch outside the lot; pave past a side
  /// line near the frontage corner is in a neighbour, not the corridor).
  final SiteFrame? sides;

  bool contains(Vec2 p) {
    final d = p - a;
    final along = d.dot(t);
    final lat = d.dot(t.perp).abs();
    if (along < -_kTolM ||
        along > len + _kTolM ||
        lat > kAccessCorridorHalfM + _kTolM) {
      return false;
    }
    final f = sides;
    if (f == null) return true;
    final l = f.toLocal(p);
    if (l.n <= _kTolM) return true;
    return l.e >= -_kTolM && l.e <= f.widthM + _kTolM;
  }
}

/// Every paving and corridor-clearance breach of [plan], generated for [ctx],
/// one line each (`'<check> [<siteId>]: <detail>'`); empty when it has none.
List<String> sitePavingViolations(SiteContext ctx, SiteAccessPlan plan) {
  if (!plan.hasNetwork) return const [];
  final out = <String>[];
  final id = plan.siteId;
  final frame = ctx.frame;
  if (frame == null) {
    if (plan.paveCount > 0) out.add('paving [$id]: paves on a site with no frame');
    return out;
  }
  final legs = <_Leg>[];
  for (var j = 0; j < plan.joinCount; j++) {
    if (!plan.joinIsCut(j)) continue;
    final slot = _slotOf(ctx, plan, j);
    if (slot == null) {
      out.add('corridor [$id]: cut join $j matches no slot of the site');
      continue;
    }
    final line = corridorLineOf(frame, slot);
    final own = <_Leg>[
      for (var i = 0; i + 1 < line.length; i++) _Leg(line[i], line[i + 1]),
    ];
    // The last leg runs on until its whole width is past the frontage line.
    // A kerb on (or behind) the frontage line has no leg of its own; it
    // gets that extension alone, from the kerb along the slot normal, so a
    // skewed lot's kerb corners are covered as a set-back lot's are.
    if (line.length == 1) {
      final nrm = Vec2(slot.normE, slot.normN);
      final dv = nrm.dot(frame.v);
      final ext = dv > 1e-6
          ? kAccessCorridorHalfM * nrm.dot(frame.u).abs() / dv
          : 0.0;
      if (ext > 1e-6) {
        legs.add(_Leg(line[0], line[0] + nrm * ext, sides: frame));
      }
    } else {
      final last = own.last;
      final dv = last.t.dot(frame.v);
      final ext = dv > 1e-6
          ? kAccessCorridorHalfM * last.t.dot(frame.u).abs() / dv
          : 0.0;
      for (final l in own) {
        legs.add(_Leg(l.a, l.b, sides: frame));
      }
      if (ext > 1e-6) {
        legs.add(_Leg(last.b, last.b + last.t * ext, sides: frame));
      }
    }
    _clearance(ctx, slot, j, own, out, id);
  }

  final poly = ctx.parcel.polygon;
  for (var q = 0; q < plan.paveCount; q++) {
    final a = plan.paveStart(q), b = plan.paveStart(q + 1);
    final ring = [
      for (var i = a; i < b; i++)
        Vec2(plan.ptE(plan.pavePt(i)), plan.ptN(plan.pavePt(i))),
    ];
    final bad = _firstOutside(ring, poly, legs);
    if (bad != null) {
      out.add('paving [$id]: pave $q point (${bad.e.toStringAsFixed(2)}, '
          '${bad.n.toStringAsFixed(2)}) lies outside the parcel and every '
          'access corridor');
    }
  }
  return out;
}

/// The §3.7a corridor polyline of [slot] in [frame] (world metres): the kerb
/// point, then the frontage crossing along the slot normal — or R1's dogleg
/// `K → T → Q → F` for a `kJoinOffFrontage` slot. A single point when the
/// kerb already lies on or behind the frontage line.
List<Vec2> corridorLineOf(SiteFrame frame, JoinSlot slot) {
  final k = Vec2(slot.kerbE, slot.kerbN);
  final nrm = Vec2(slot.normE, slot.normN);
  final kl = frame.toLocal(k);
  final u = frame.u, v = frame.v;
  if (slot.flags & kJoinOffFrontage == 0) {
    final denom = nrm.dot(v);
    final gap = denom <= 1e-6 ? 0.0 : -kl.n / denom;
    if (gap <= 1e-3) return [k];
    return [k, k + nrm * gap];
  }
  final w = frame.widthM;
  final t = k + nrm * kDoglegThroatM;
  final xj = kl.e;
  final xc = w >= 2 * kDoglegSideClearM
      ? (xj < kDoglegSideClearM
          ? kDoglegSideClearM
          : (xj > w - kDoglegSideClearM ? w - kDoglegSideClearM : xj))
      : w / 2;
  final ty = frame.toLocal(t).n;
  final q = frame.origin + u * xc + v * ty;
  final f = frame.origin + u * xc;
  final pts = <Vec2>[k];
  for (final x in [t, q, f]) {
    if (x.distanceTo(pts.last) > 1e-6) pts.add(x);
  }
  return pts;
}

/// The slot plan join [j] uses: packed slot 0 or 1, or the side-street or
/// rear-alley slot; null when the context has none matching the join's piece
/// and arc.
JoinSlot? _slotOf(SiteContext ctx, SiteAccessPlan plan, int j) {
  final k = plan.joinSlot(j);
  JoinSlot? s;
  if (k == kJoinSlotSideStreet) {
    s = ctx.sideStreetSlot;
  } else if (k == kJoinSlotAlley) {
    s = ctx.alleySlot;
  } else if (k >= 0 && k < ctx.slotCount) {
    s = ctx.slot(k);
  }
  if (s == null || s.piece != plan.joinPiece(j) || s.s != plan.joinRoadS(j)) {
    return null;
  }
  return s;
}

/// The first sample of convex ring [ring] outside [poly] and every leg.
Vec2? _firstOutside(List<Vec2> ring, List<Vec2> poly, List<_Leg> legs) {
  bool ok(Vec2 p) {
    if (_inPolygon(poly, p)) return true;
    for (final l in legs) {
      if (l.contains(p)) return true;
    }
    return false;
  }

  final n = ring.length;
  if (n == 0) return null;
  for (var i = 0; i < n; i++) {
    final a = ring[i], b = ring[(i + 1) % n];
    final len = a.distanceTo(b);
    final steps = math.max(1, (len / _kEdgeStepM).ceil());
    for (var s = 0; s < steps; s++) {
      final p = a + (b - a) * (s / steps);
      if (!ok(p)) return p;
    }
  }
  final box = Box2.of(ring);
  for (var y = box.minN + _kInsideStepM / 2; y < box.maxN; y += _kInsideStepM) {
    for (var x = box.minE + _kInsideStepM / 2;
        x < box.maxE;
        x += _kInsideStepM) {
      final p = Vec2(x, y);
      if (!_inConvex(ring, p)) continue;
      if (!ok(p)) return p;
    }
  }
  return null;
}

/// Whether [p] lies in the counter-clockwise convex [ring].
bool _inConvex(List<Vec2> ring, Vec2 p) {
  for (var i = 0; i < ring.length; i++) {
    final a = ring[i], b = ring[(i + 1) % ring.length];
    if ((b - a).cross(p - a) < 0) return false;
  }
  return true;
}

/// Whether [p] lies in [poly] (either winding), or within [_kTolM] of its
/// boundary.
bool _inPolygon(List<Vec2> poly, Vec2 p) {
  var inside = false;
  final m = poly.length;
  for (var i = 0, j = m - 1; i < m; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a.n > p.n) != (b.n > p.n) &&
        p.e < (b.e - a.e) * (p.n - a.n) / (b.n - a.n) + a.e) {
      inside = !inside;
    }
  }
  if (inside) return true;
  for (var i = 0; i < m; i++) {
    if (_pointToSegment(p, poly[i], poly[(i + 1) % m]) <= _kTolM) return true;
  }
  return false;
}

double _pointToSegment(Vec2 p, Vec2 a, Vec2 b) {
  final d = b - a;
  final len2 = d.dot(d);
  if (len2 <= 1e-18) return p.distanceTo(a);
  final t = ((p - a).dot(d) / len2).clamp(0.0, 1.0);
  return p.distanceTo(a + d * t);
}

/// §3.7a's clearance of join [j]'s corridor [legs] on [slot].
void _clearance(SiteContext ctx, JoinSlot slot, int j, List<_Leg> legs,
    List<String> out, String id) {
  if (slot.flags & kJoinCorridorBlocked != 0) {
    out.add('corridor clearance [$id]: join $j uses a blocked corridor');
  }
  final g = ctx.graph;
  for (final lot in slot.crossLots) {
    if (ctx.lotBuilt(lot)) {
      out.add('corridor clearance [$id]: join $j crosses the built lot '
          '${g.lotIds[lot]}');
    }
  }
  if (legs.isEmpty) return;
  // Only a set-back corridor (§3.2: the frontage more than 3.5 m behind the
  // kerb) or a dogleg is §3.7a's to keep clear, as only those were searched
  // (R1). A kerb crossing no longer than that lies in its own road's
  // pavement strip, which the plat laid; a plat lot beside another street's
  // end is the layout's, not a corridor breach.
  var length = 0.0;
  for (final l in legs) {
    length += l.len;
  }
  if (slot.flags & kJoinOffFrontage == 0 &&
      length <= _kPavementM + kSetBackSidewalkSlackM + kGenEpsM) {
    return;
  }
  final joinRoad = ctx.roadOf(slot);
  final joinPave = joinRoad.roadClass.hasPavement ? _kPavementM : 0.0;
  const h = kAccessCorridorHalfM;
  for (var i = 0; i < legs.length; i++) {
    final leg = legs[i];
    final box = Box2.of([leg.a, leg.b]).grow(h);
    String? hit;
    g.index.visit(box, RoadGraph.maxHalfWidth + _kPavementM, (slotNo, rec, seg) {
      if (hit != null || seg == 0) return;
      final road = rec.road;
      if (road.roadClass.isElevated) return;
      final band =
          road.halfWidth + (road.roadClass.hasPavement ? _kPavementM : 0.0);
      final isJoin = road.id == joinRoad.id;
      final c0 = rec.cum[seg - 1], c1 = rec.cum[seg];
      final ranges = <(double, double)>[];
      if (isJoin) {
        final lo = slot.s - kCorridorJoinRoadSkipM;
        final hi = slot.s + kCorridorJoinRoadSkipM;
        if (c0 < lo) ranges.add((c0, math.min(c1, lo)));
        if (c1 > hi) ranges.add((math.max(c0, hi), c1));
      } else {
        ranges.add((c0, c1));
      }
      // The first leg, against its own road, starts past its pavement.
      final a0 = isJoin && i == 0
          ? leg.a + leg.t * math.min(joinPave, leg.len)
          : leg.a;
      for (final (x0, x1) in ranges) {
        if (x1 - x0 <= 1e-9) continue;
        final deck = road.deck;
        final parts = deck == null ? 1 : math.max(1, ((x1 - x0) / 2).ceil());
        for (var p = 0; p < parts; p++) {
          final y0 = x0 + (x1 - x0) * p / parts;
          final y1 = x0 + (x1 - x0) * (p + 1) / parts;
          if (deck != null && deck.offGroundAt((y0 + y1) / 2, rec.lengthM)) {
            continue;
          }
          final s0 = _onSegment(rec, seg, y0), s1 = _onSegment(rec, seg, y1);
          if (_segmentToRect(s0, s1, a0, leg.b, h) < band) {
            hit = road.id;
            return;
          }
        }
      }
    });
    if (hit != null) {
      out.add('corridor clearance [$id]: join $j corridor leg $i comes within '
          'the carriageway or pavement of road $hit');
    }
  }
}

Vec2 _onSegment(IndexedRoad rec, int seg, double arc) {
  final c0 = rec.cum[seg - 1], c1 = rec.cum[seg];
  final t = c1 - c0 <= 1e-12 ? 0.0 : ((arc - c0) / (c1 - c0)).clamp(0.0, 1.0);
  return Vec2(rec.e[seg - 1] + (rec.e[seg] - rec.e[seg - 1]) * t,
      rec.n[seg - 1] + (rec.n[seg] - rec.n[seg - 1]) * t);
}

/// Distance from segment [a]–[b] to the rectangle of half width [h] along
/// [p0]–[p1] (no end caps); 0 where they meet; infinite for an empty leg.
double _segmentToRect(Vec2 a, Vec2 b, Vec2 p0, Vec2 p1, double h) {
  final d = p1 - p0;
  final len = d.length;
  if (len <= 1e-9) return double.infinity;
  final t = d * (1 / len), nrm = t.perp;
  Vec2 local(Vec2 x) => Vec2((x - p0).dot(t), (x - p0).dot(nrm));
  final la = local(a), lb = local(b);
  // Liang-Barsky against [0, len] × [−h, h].
  var t0 = 0.0, t1 = 1.0;
  final dx = lb.e - la.e, dy = lb.n - la.n;
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

  if (clip(-dx, la.e) &&
      clip(dx, len - la.e) &&
      clip(-dy, la.n + h) &&
      clip(dy, h - la.n) &&
      t0 <= t1) {
    return 0;
  }
  double boxDist(Vec2 x) {
    final cx = x.e < 0 ? -x.e : (x.e > len ? x.e - len : 0.0);
    final cy = x.n < -h ? -h - x.n : (x.n > h ? x.n - h : 0.0);
    return math.sqrt(cx * cx + cy * cy);
  }

  var best = math.min(boxDist(la), boxDist(lb));
  for (final c in [Vec2(0, -h), Vec2(len, -h), Vec2(len, h), Vec2(0, h)]) {
    best = math.min(best, _pointToSegment(c, la, lb));
  }
  return best;
}
