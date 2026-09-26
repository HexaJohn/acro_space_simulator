// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A sealed pedestrian tube running along the verge.
///
/// On an airless world people cannot use a pavement, and the colony already
/// says so for its grid roads — `roadSealed` renders those as pressurised
/// tubes. The spline roads the in-world editor builds never carried the flag,
/// so a lunar street was drawn as open asphalt with a curb nobody could stand
/// on. This is the same idea, cut as real geometry: a hexagonal glass barrel
/// on a low curb, offset clear of the carriageway.
///
/// It lives out here, next to the viaduct and the street furniture, because a
/// barrel is the one piece of city geometry whose winding cannot be checked by
/// looking at it: an inside-out tube still reads as a tube until you notice
/// you are seeing its far wall through its near one. Out of the renderer it is
/// a pure function of a polyline, and a test can measure the winding.
///
/// ## Crossing a drive (docs/plans/site-access.md §3.8, §10.2 Q8 option (a))
///
/// A sealed road has no pavement (`city_tile_mesher.dart`, `walked`), so the
/// tube is the ONLY thing a kerb cut can break there — and a barrel is not a
/// kerb: a drive that ran into the side of it would run into a wall. Where a
/// drawn cut falls on the tube's own kerb the tube RISES OVER the drive on
/// legs, and the drive passes underneath.
///
/// The rise is not negotiable and the grade is not either, so the SHAPE is a
/// consequence rather than a choice. A rover is 1.95 m tall, so the soffit
/// must stand [crossClearM] over the drive; with the deck's own depth that is
/// [crossLiftM] of rise, and at [rampGrade] — one in twelve, the accessible
/// maximum, the steepest thing that is still a ramp and not a stair — each
/// approach is [rampM] long. Nothing here knows what body it is on, so the
/// grade is the Earth standard applied unchanged; a sixth of a gravity would
/// carry a steeper one, but this seam is handed a polyline and nothing else.
///
/// Two crossings closer together than two ramps cannot get down and back up
/// between them, so their holds MERGE and the tube simply stays up. A house
/// lot is 17–24 m of frontage (§3 C-1; `ParcelSettings.frontageM` is 24 m and
/// `CitySpec.frontageM` 30 m), and a cut's spacing IS its lot's frontage, so
/// on a terrace the clear gap between two holds is 7–14 m against 58.8 m of
/// two ramps: every crossing on the street merges, and the result is one
/// continuous raised walkway on legs down the whole block, with isolated
/// bridges only where the cuts are sparse. That is a consequence of the rise
/// and the grade rather than an accident of the rule: a profile that tried to
/// touch down between two near cuts would sag a few centimetres over a few
/// metres, which reads as a fault in the structure rather than a ramp.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../../domain/colony/city/site_access/kerb_cuts.dart';
import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/shared/vector3.dart';
import '../coord_convert.dart';
import 'road_mesher.dart';

class PedestrianTube {
  const PedestrianTube._();

  /// Half the span of the barrel, and the height of the walkway inside it.
  static const double radiusM = 1.7;

  /// A hexagon: enough to read as round at street scale, and six quads a ring
  /// is what keeps a whole sealed colony's worth of tube affordable.
  static const int sides = 6;

  /// How far the barrel's near face stands off the carriageway edge, and how
  /// high its curb rides over the drape.
  static const double clearOfLaneM = 1.0;
  static const double curbLiftM = 0.2;

  // ---- Crossing a drive ------------------------------------------------------------

  /// Headroom under the soffit where the tube passes over a drive: a rover is
  /// 1.95 m tall (`VehicleKind.rover`), so this is a garage door's worth.
  static const double crossClearM = 2.3;

  /// The depth of the deck the barrel rides on. At grade it is the curb face
  /// (buried but for its top 20 cm); in the air it is the structure.
  static const double deckThickM = 0.35;

  /// What the curb line rises by over a crossing: soffit plus deck, less the
  /// 20 cm the curb already stands.
  static const double crossLiftM = crossClearM + deckThickM - curbLiftM;

  /// One in twelve: the accessible-ramp maximum.
  static const double rampGrade = 1 / 12;

  /// The run of one approach, from the touchdown to the level deck.
  static const double rampM = crossLiftM / rampGrade;

  /// How far past a cut's own half width the deck stays level, so the soffit
  /// clears the drive's edges rather than ending on them.
  static const double crossMarginM = 1.0;

  /// Legs, each [legHalfM] half-thick, standing in pairs [legOffsetM] either
  /// side of the barrel's axis and [legFootM] into the ground, wherever the
  /// deck stands at least [legMinLiftM] over the CURB LINE — a deck top
  /// `curbLiftM + legMinLiftM` (1.0 m) over the drape, and a soffit 0.65 m
  /// over it. [legSpacingM] is the step WITHIN a clear run and not the whole
  /// rule: no post may stand within [legClearM] of a drive, so the longest
  /// unheld stretch is a drive's opening plus that clearance. [legArcsOf]
  /// places them.
  static const double legSpacingM = 7.5;
  static const double legHalfM = 0.16;
  static const double legOffsetM = 1.15;
  static const double legFootM = 0.15;
  static const double legClearM = 2.0;
  static const double legMinLiftM = 0.8;

  /// How far into an approach the deck still stands [legMinLiftM] over the
  /// curb line, and so still wants holding up: 19.8 m of the 29.4 m ramp.
  static const double legRunM = (crossLiftM - legMinLiftM) / rampGrade;

  /// The stretches of [cuts] the tube is held up over, in the road's own
  /// drawn arc, ascending and disjoint.
  ///
  /// Only the tube's OWN kerb counts: the barrel runs down one verge (side 1,
  /// right of the first → last polyline), so a drive that breaks the far kerb
  /// crosses nothing. Far-swing masks ([KerbCuts.kindHomeFarSwing]) break no
  /// kerb at all. Each drawn cut holds `[c − h − margin, c + h + margin]`, and
  /// two holds less than two ramps apart are merged into one: the tube cannot
  /// come down and go back up in that distance, so it stays up.
  static List<(double, double)> crossingsOf(Float64List? cuts) {
    if (cuts == null || cuts.isEmpty) return const [];
    // Read through a local the promotion cannot be lost on: this SDK's AOT
    // build can read a nullable through a promotion inside a loop (see
    // road_mesher.dart's `verges`, and terrain_nodes.dart:993).
    final table = cuts;
    final holds = <(double, double)>[];
    for (var i = 0; i + KerbCuts.stride <= table.length; i += KerbCuts.stride) {
      if (table[i] != 1) continue;
      if (table[i + 4] == KerbCuts.kindHomeFarSwing) continue;
      final c = table[i + 1], h = table[i + 2];
      holds.add((c - h - crossMarginM, c + h + crossMarginM));
    }
    if (holds.isEmpty) return const [];
    holds.sort((a, b) => a.$1.compareTo(b.$1));
    final out = <(double, double)>[];
    var from = holds.first.$1, to = holds.first.$2;
    for (var i = 1; i < holds.length; i++) {
      final (a, b) = holds[i];
      if (a - to < 2 * rampM) {
        if (b > to) to = b;
      } else {
        out.add((from, to));
        from = a;
        to = b;
      }
    }
    out.add((from, to));
    return out;
  }

  /// The tube's lift over its curb line at arc [s], given [over] from
  /// [crossingsOf]: [crossLiftM] across a hold, easing to zero over [rampM]
  /// either side of it, and zero everywhere else. The holds are at least two
  /// ramps apart, so at most one of them reaches any arc.
  static double liftAt(List<(double, double)> over, double s) {
    for (final (a, b) in over) {
      if (s <= a - rampM || s >= b + rampM) continue;
      if (s >= a && s <= b) return crossLiftM;
      final d = s < a ? a - s : s - b;
      return crossLiftM * (1 - d / rampM);
    }
    return 0;
  }

  /// The arcs a PAIR of legs stands at, in the road's own drawn arc,
  /// ascending, over the crossings [over] and the drives [cuts] draws.
  ///
  /// The deck wants holding wherever it stands at least [legMinLiftM] over
  /// the curb line, which is the hold plus [legRunM] into each approach. A
  /// post may not stand in a drive, so [legClearM] either side of every drawn
  /// cut on this kerb is kept clear — with equal extents the mask is
  /// symmetric, so the lane's travel sign cancels and this is exactly the
  /// stretch `KerbCuts.blocked` reports. A pair stands at each EDGE of every
  /// such stretch, so the deck spans a drive's opening and nothing more, and
  /// each clear run between them is divided evenly into steps of at most
  /// [legSpacingM].
  ///
  /// These arcs are the structure's, not the polyline's: [emit] inserts them
  /// as stations of their own, so a coarsely drawn street carries the same
  /// legs a finely drawn one does. Placing posts only where the road happened
  /// to have a vertex left a fused terrace standing on nothing at all.
  static List<double> legArcsOf(
      List<(double, double)> over, Float64List? cuts) {
    final out = <double>[];
    for (final (holdA, holdB) in over) {
      final from = holdA - legRunM, to = holdB + legRunM;
      // The drives inside this crossing, as the stretches no post may stand
      // in, ascending by their near edge.
      final shut = <(double, double)>[];
      if (cuts != null) {
        // Through a local, as `crossingsOf` reads it (the AOT promotion trap).
        final table = cuts;
        for (var i = 0;
            i + KerbCuts.stride <= table.length;
            i += KerbCuts.stride) {
          if (table[i] != 1) continue;
          if (table[i + 4] == KerbCuts.kindHomeFarSwing) continue;
          final c = table[i + 1], w = table[i + 2] + legClearM;
          if (c + w <= from || c - w >= to) continue;
          shut.add((c - w, c + w));
        }
        shut.sort((x, y) => x.$1.compareTo(y.$1));
      }
      var at = from;
      for (final (lo, hi) in shut) {
        if (lo > at) _fill(out, at, lo);
        if (hi > at) at = hi; // overlapping drives merge into one gap
      }
      if (to > at) _fill(out, at, to);
    }
    return out;
  }

  /// Posts at both ends of the clear run [u]–[v] and evenly between it, in
  /// steps of at most [legSpacingM]. A run narrower than a post is thick
  /// takes one post in the middle of it rather than two in the same place.
  static void _fill(List<double> out, double u, double v) {
    if (v - u < 2 * legHalfM) {
      out.add((u + v) / 2);
      return;
    }
    final n = ((v - u) / legSpacingM).ceil();
    for (var k = 0; k <= n; k++) {
      out.add(u + (v - u) * k / n);
    }
  }

  /// Build the tube carrying [pts] (anchor-relative metres) into [solid] (the
  /// curb) and [glass] (the barrel).
  ///
  /// With [cuts] — the road's drawn kerb cuts, measured from the arc
  /// [arcOffset] of [pts]'s first point along the whole road, the same frame
  /// `RoadMesher.sidewalks` reads — the tube rises over every drive that
  /// breaks its own kerb, on a deck carried by legs. With no cut that reaches
  /// this span the output is byte-identical to what it always was.
  static void emit(
    MeshBuilder solid,
    MeshBuilder glass, {
    required List<Vector3> pts,
    required double halfWidthM,
    required Vector3 anchorBF,
    Float64List? cuts,
    double arcOffset = 0,
  }) {
    var total = 0.0;
    for (var i = 1; i < pts.length; i++) {
      total += (pts[i] - pts[i - 1]).length;
    }
    // The crossings this span actually carries, approaches included.
    final over = <(double, double)>[
      for (final hold in crossingsOf(cuts))
        if (hold.$1 - rampM < arcOffset + total &&
            hold.$2 + rampM > arcOffset)
          hold,
    ];
    final raised = over.isNotEmpty;
    var line = pts;
    var legs = const <double>[];
    if (raised) {
      // The ramp's own corners, so the lift is piecewise linear in arc and
      // the barrel bends where the ramp bends and nowhere else.
      final want = <double>[];
      for (final (a, b) in over) {
        for (final s in [a - rampM, a, b, b + rampM]) {
          final t = s - arcOffset;
          if (t > 0 && t < total) want.add(t);
        }
      }
      // And the posts' own arcs, so the structure decides where it is held up
      // rather than the density the road happens to be drawn at.
      legs = [
        for (final s in legArcsOf(over, cuts))
          if (s >= arcOffset - 1e-6 && s <= arcOffset + total + 1e-6) s,
      ];
      for (final s in legs) {
        final t = s - arcOffset;
        if (t > 1e-6 && t < total - 1e-6) want.add(t);
      }
      line = RoadMesher.withStations(line, want);
    }
    final across = halfWidthM + radiusM + clearOfLaneM;

    List<int>? prev;
    List<int>? prevCurb;
    List<int>? prevBeam;
    var arc = arcOffset;
    var nextLeg = 0;
    for (var i = 0; i < line.length; i++) {
      final p = line[i];
      if (i > 0) arc += (p - line[i - 1]).length;
      final up = (p + anchorBF).normalized;
      final ahead = i + 1 < line.length ? line[i + 1] - p : p - line[i - 1];
      if (ahead.length < 1e-6) continue;
      final along = ahead.normalized;
      final side = along.cross(up).normalized;
      final lift = raised ? liftAt(over, arc) : 0.0;
      // Outside the curb, clear of the traffic lane — and up over the drive
      // where one crosses.
      final axis = p + side * across + up * (curbLiftM + lift);

      final ring = <int>[];
      for (var k = 0; k < sides; k++) {
        final a = 2 * math.pi * k / sides + math.pi / sides;
        final n = side * math.cos(a) + up * math.sin(a);
        ring.add(glass.vertex(
            (axis + n * radiusM + up * radiusM) * kRenderScale,
            n,
            k / sides,
            0.5));
      }
      // A curb strip under it, so the barrel does not float on the ground.
      List<int>? curb, beam;
      if (raised) {
        // Carrying a drive, the strip is a beam with a soffit and two faces:
        // in the air it is what the legs hold up, and at the touchdown it is
        // the curb it always was with its underside in the ground, so the two
        // meet in one surface instead of a step.
        final top = axis, bot = axis - up * deckThickM;
        final l = side * -radiusM, rt = side * radiusM;
        beam = [
          solid.vertex((top + l) * kRenderScale, up, 0, 0.5),
          solid.vertex((top + rt) * kRenderScale, up, 1, 0.5),
          solid.vertex((bot + rt) * kRenderScale, up * -1, 0, 0.5),
          solid.vertex((bot + l) * kRenderScale, up * -1, 1, 0.5),
          solid.vertex((top + rt) * kRenderScale, side, 0.5, 0),
          solid.vertex((bot + rt) * kRenderScale, side, 0.5, 1),
          solid.vertex((bot + l) * kRenderScale, side * -1, 0.5, 1),
          solid.vertex((top + l) * kRenderScale, side * -1, 0.5, 0),
        ];
      } else {
        curb = [
          solid.vertex((axis - side * radiusM) * kRenderScale, up, 0, 0.5),
          solid.vertex((axis + side * radiusM) * kRenderScale, up, 1, 0.5),
        ];
      }
      if (prev != null) {
        for (var k = 0; k < sides; k++) {
          final n = (k + 1) % sides;
          // Ring angle runs from `side` towards `up`, which turns about
          // -`along` — the opposite hand to the direction of travel. So the
          // quad has to run BACKWARDS along the tube (this ring, then the one
          // behind it) for its right-hand normal to come out radially outward,
          // which is the order MeshBuilder.quad wants. Sweeping forwards, the
          // obvious way, wound every barrel in the colony inside out.
          glass.quad(ring[k], ring[n], prev[n], prev[k]);
        }
        if (prevCurb != null && curb != null) {
          solid.quad(prevCurb[0], prevCurb[1], curb[1], curb[0]);
        }
        if (prevBeam != null && beam != null) {
          // Each face is a pair (a, b) with `(b − a) × along` its own normal,
          // so every one of the four winds the way the flat curb strip does.
          for (var f = 0; f < 4; f++) {
            solid.quad(prevBeam[f * 2], prevBeam[f * 2 + 1], beam[f * 2 + 1],
                beam[f * 2]);
          }
        }
      }
      // Every post this station carries: its arc was inserted as a station
      // above, so the first station at or past it IS it.
      var post = false;
      while (nextLeg < legs.length && legs[nextLeg] <= arc + 1e-6) {
        nextLeg++;
        post = true;
      }
      if (post) {
        // The ground under the axis, not under the centreline: the leg stands
        // where the deck is, which is what keeps it out of the carriageway.
        final foot = p + side * across;
        for (final o in const [-1.0, 1.0]) {
          _leg(solid, foot + side * (legOffsetM * o), along, side, up,
              curbLiftM + lift - deckThickM);
        }
      }
      prev = ring;
      prevCurb = curb;
      prevBeam = beam;
    }
  }

  /// One leg of the raised walkway: a square post from [legFootM] under
  /// [foot] up to [heightM] over it, where the soffit is.
  static void _leg(MeshBuilder m, Vector3 foot, Vector3 along, Vector3 side,
      Vector3 up, double heightM) {
    final base = foot - up * legFootM;
    final rise = up * (heightM + legFootM);
    final c = [
      base - side * legHalfM - along * legHalfM,
      base + side * legHalfM - along * legHalfM,
      base + side * legHalfM + along * legHalfM,
      base - side * legHalfM + along * legHalfM,
    ];
    final n = [along * -1, side, along, side * -1];
    for (var f = 0; f < 4; f++) {
      final a = c[f], b = c[(f + 1) % 4];
      final i0 = m.vertex(a * kRenderScale, n[f], 0.5, 0);
      final i1 = m.vertex(b * kRenderScale, n[f], 0.5, 0);
      final i2 = m.vertex((b + rise) * kRenderScale, n[f], 0.5, 1);
      final i3 = m.vertex((a + rise) * kRenderScale, n[f], 0.5, 1);
      m.quad(i0, i1, i2, i3);
    }
  }
}
