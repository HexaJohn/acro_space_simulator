// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import '../../shared/vector3.dart';
import '../../terrain/terrain_brush.dart';
import '../surface_placement.dart';
import 'city_building_spec.dart';
import 'city_sim.dart';
import 'parcel.dart';

/// Turns a colony's layout into terrain deformation.
///
/// A city does not sit on the landscape, it re-cuts it: building sites are
/// levelled, roads are graded through rises and over dips, and a quarry eats a
/// stepped hole out of the ground. All of that is expressed as [TerrainBrush]
/// edits, so it composes with the existing crater/excavation machinery,
/// survives LOD (the brushes are analytic, evaluated at any sample rate), and
/// is authoritative — the deformed surface is what a lander touches down on.
///
/// Emission is INCREMENTAL and keyed: each parcel, road and pit contributes one
/// brush, recorded once. Re-emitting every tick would grow the edit list without
/// bound and, because brushes compose by ordered `min`/`max`, would also make
/// the composed field depend on how long the game had been running.
class CityTerrainShaper {
  const CityTerrainShaper({
    this.padMarginM = 6,
    this.padFalloffM = 14,
    this.roadFalloffM = 6,
    this.padEdgeM = 0.6,
    this.voxelM = 15,
  });

  /// How far a levelled pad extends beyond the building footprint.
  final double padMarginM;

  /// Width of the ring easing a pad back into natural ground. This is the
  /// "softly" in soft levelling — a colony should look bulldozed, not stamped.
  final double padFalloffM;

  final double roadFalloffM;

  /// How far a LOT pad eases off past its own boundary. Deliberately tiny: see
  /// the call site — anything wide re-levels the neighbour.
  final double padEdgeM;

  /// Voxel size (m) the city's brushes are content to be meshed at — see
  /// [TerrainBrush.minVoxelM]. Derived from their radii, a lot pad asks for
  /// ~5 m and a road corridor for 1 m, which forces the quadtree to level
  /// 15-17 under every street: a six-block colony measured 1,133 resident
  /// chunks against ~590 for the same ground unbuilt. At 15 m the whole
  /// colony sits at level 13 (boosted). The trade is edge sharpness: pad
  /// rims and road shoulders are smoothed at this scale, which the ground
  /// patches cover inside the colony. First-test value; tune from the studio.
  final double voxelM;

  /// Brushes for everything in [city] that is not yet shaped.
  ///
  /// [groundRadiusAt] returns the natural ground radius (m from the body
  /// centre) along a body-fixed direction — normally the terrain field's own
  /// query, so a pad levels to the real ground rather than to the datum sphere.
  ///
  /// The caller records each returned brush and adds its key to
  /// [CitySim.shapedTerrain]. The one exception is a raised or sunk road's
  /// segment that is not simply one graded piece: on piers or in a tunnel
  /// it is shaped by NOT touching the ground, and where it runs onto a
  /// bridge or into a portal it is cut or filled piece by piece. Its own
  /// key is added to [CitySim.shapedTerrain] here, with no brush to record
  /// under it, so it is settled once like every other segment.
  List<({String key, TerrainBrush brush})> pending(
    CitySim city, {
    required double bodyRadiusM,
    required double Function(Vector3 dirBF) groundRadiusAt,
    int tick = 0,
    SurfacePlacement placement = const SurfacePlacement(),
  }) {
    final out = <({String key, TerrainBrush brush})>[];
    final latRad = city.cityLat * math.pi / 180.0;
    final lonRad = city.cityLon * math.pi / 180.0;

    // Every direction asked of the ground in this call, answered once. A
    // pad asks its centre twice (datum, anchor) and each corner twice
    // (relief, outline), a corridor asks each sample as the end of one
    // segment and the start of the next, anchor and datum both, and a
    // lot's corners are its neighbours' corners: a road edit's re-plat
    // asked 52 samples for 14 places. Each is a march of the composed
    // field through every brush the town has laid there — milliseconds on
    // real ground — and the whole batch runs inside one tick, so the
    // repeats were a frozen frame. Exact: the ground does not change
    // during a call (its brushes are recorded after it returns), so an
    // answer is the answer. A direction with a zero component, whose sign
    // a relief sampler may read and whose key cannot tell it, is asked.
    final asked = <Vector3, double>{};
    double ground(Vector3 dir) {
      if (dir.x == 0 || dir.y == 0 || dir.z == 0) return groundRadiusAt(dir);
      return asked[dir] ??= groundRadiusAt(dir);
    }

    /// Direction from the body centre to a local point. Only the DIRECTION is
    /// taken from this, so the datum radius it is built at does not matter.
    Vector3 dirOf(Vec2 local) => placement
        .place(
          radius: bodyRadiusM,
          lat: latRad,
          lon: lonRad,
          east: local.e,
          north: local.n,
        )
        .position
        .normalized;

    /// Ground radius under a local point.
    double groundUnder(Vec2 local) => ground(dirOf(local));

    /// The point on the REAL GROUND under a local point.
    ///
    /// Brushes must be anchored HERE, not on the datum sphere. Every brush
    /// culls samples outside its own bounding radius — tens of metres for a
    /// building pad — and a body's ground sits hundreds of metres off its
    /// datum (885 m below it at a typical lunar site). Anchored on the datum,
    /// every ground sample fell outside the bound, so `apply` returned the
    /// density untouched and the brush did NOTHING: pads never levelled their
    /// lots and road corridors were never graded, which is exactly how it
    /// looked — buildings sitting on raw relief and roads clipping through it.
    Vector3 onGround(Vec2 local) {
      final dir = dirOf(local);
      return dir * ground(dir);
    }

    // ---- Building pads -------------------------------------------------
    for (final (parcel, spec) in city.buildingParcels()) {
      // A lot that follows the land is draped, not levelled.
      if (!parcel.graded) continue;
      final key = 'pad:${parcel.id}';
      if (city.shapedTerrain.contains(key)) continue;

      final centre = parcel.centroid;
      final extent = parcel.buildableExtent;
      // A pit still circumscribes: a quarry is round, and nothing tiles
      // against it.
      final radius =
          math.sqrt(extent.width * extent.width + extent.depth * extent.depth) /
                  2 +
              padMarginM;

      // Level to the ground under the CENTRE of the lot, so the cut and the
      // fill roughly balance instead of the whole site being raised to its
      // highest corner.
      final datum = groundUnder(centre);
      final relief = _reliefAcross(parcel, groundUnder);

      out.add((
        key: key,
        brush: _isPit(spec)
            ? TerrainBrush.steppedPit(
                centreBF: onGround(centre),
                radiusM: radius,
                datumRadiusM: datum,
                depthM: pitDepthFor(radius),
                benches: benchesFor(radius),
                falloffM: padFalloffM * 3,
                tick: tick,
                minVoxelM: voxelM,
              )
            : TerrainBrush.padPoly(
                centreBF: onGround(centre),
                // The lot's own outline, on the ground. Every parcel is a
                // polygon — lots taper wherever a road bends — so a rectangle
                // either overhangs the neighbour or misses its own corners.
                polygonBF: [for (final v in parcel.polygon) onGround(v)],
                datumRadiusM: datum,
                falloffM: padEdgeM,
                // The bound must clear the relief actually being moved.
                maxCutM: math.max(20, relief * 1.5),
                tick: tick,
                minVoxelM: voxelM,
              ),
      ));
    }

    // ---- Road corridors ------------------------------------------------
    for (final road in city.layout.roads) {
      // A road that follows the land is draped, not graded — see
      // [RoadSpline.graded]; a sprawl of them would be a hundred thousand
      // permanent edits to the ground. A raised or sunk road does NOT
      // follow the land, whatever it was first laid as: a suburb's street
      // dragged up onto a deck (Adjust Roads keeps `graded`) is shaped to
      // its deck like any other, or its first stretch would be a slab
      // floating over the hillside, too low for piers and never filled.
      final deck = road.deck;
      if (!road.graded && deck == null) continue;
      final pts = road.sample(stepM: corridorStepM);
      if (pts.length < 2) continue;
      // Keyed by WIDTH as well as by place. The key is the record that a
      // corridor was cut, and an upgrade keeps a road's id: keyed by place
      // alone, a street widened to an avenue kept its street's corridor
      // for ever, the avenue's edges riding the unshaped hillside.
      final hw = road.halfWidth.toStringAsFixed(2);
      if (deck != null) {
        _deckCorridor(city, road, deck, pts, hw, out,
            bodyRadiusM: bodyRadiusM,
            dirOf: dirOf,
            groundUnder: groundUnder,
            tick: tick);
        continue;
      }
      for (var i = 1; i < pts.length; i++) {
        final key = 'road:${road.id}:$hw:$i';
        if (city.shapedTerrain.contains(key)) continue;
        final a = pts[i - 1], b = pts[i];
        out.add((
          key: key,
          brush: TerrainBrush.cutFill(
            startBF: onGround(a),
            endBF: onGround(b),
            radiusM: road.halfWidth,
            datumRadiusM: groundUnder(a),
            datumRadiusEndM: groundUnder(b),
            falloffM: roadFalloffM,
            tick: tick,
            minVoxelM: voxelM,
          ),
        ));
      }
    }
    return out;
  }

  /// Spacing (m) of a road corridor's knots: a road is graded as straight
  /// segments between its `sample(stepM: corridorStepM)` points, one brush
  /// each ([pending]). Not the road's own spacing: `sample` rounds each
  /// span UP to whole steps, so a 64.5 m road has knots every 21.5 m and a
  /// 48.00000000000001 m one every 16 m — see [corridorGround].
  static const double corridorStepM = 24;

  /// Record that [brush], returned by [pending] under [key], has been laid
  /// on [city]'s ground — what every caller of [pending] does with each
  /// brush it records.
  ///
  /// A road corridor's segment also keeps the datum radii it was cut to
  /// ([CitySim.corridorDatums]): the road is drawn on them
  /// ([corridorGround]), not on the ground read back at its knots.
  static void markShaped(CitySim city, String key, TerrainBrush brush) {
    city.shapedTerrain.add(key);
    if (brush.kind == TerrainBrushKind.cutFill) {
      city.corridorDatums[key] = (brush.datumRadiusM, brush.datumRadiusEndM);
    }
  }

  /// The ground a plain corridor — a graded road with no deck, as [pending]
  /// cuts it — leaves under [pts], the road's own points in order, as radii
  /// from the body centre written into [out].
  ///
  /// [knots] are the corridor's knots (`road.sample(stepM: corridorStepM)`),
  /// segment j running from knot j to knot j + 1; [datumStart] and
  /// [datumEnd] are the radii segment j is cut to at its two knots, and
  /// [halfWidthM] is the road's half width. Read back from the brushes' own
  /// rules rather than asked of the field at every point, which in a built
  /// colony is a march through every brush there: segment j is cut or
  /// filled to the straight line between its datums, at full weight within
  /// [halfWidthM] of its chord; each segment after it, recorded after it,
  /// holds the last metres before its own first knot at that knot's datum
  /// and eases out over [roadFalloffM] ([TerrainBrush.falloffWeight]).
  ///
  /// The datums are the ones the shaper CUT to ([CitySim.corridorDatums]),
  /// not the ground read back at the knots once it has. A knot's ground is
  /// not its segment's datum wherever the next segment's easing reaches
  /// back over it — and on a curve it always does, its knots metres apart:
  /// taken for a datum, that pulled-down ground drew a whole segment on the
  /// wrong line, a curved street buried 9.6 m where it crossed a levelled
  /// lot's edge. Before a segment is cut its datums are the ground at its
  /// knots, which is exactly what [pending] will measure: the road is drawn
  /// on the ground it is about to be graded to.
  ///
  /// Only this corridor's own brushes: whatever was laid over it since — a
  /// crossing road's corridor recorded after it, reaching over its end, or
  /// a crater — is not modelled. The frame asks the ground itself at the
  /// points such a brush can reach (`_drapeRoad` in the world snapshot).
  ///
  /// Measured in the colony's plane (metres east and north) plus the rise
  /// between knots: over a corridor segment the body's curve is
  /// millimetres. A brush reads a point's place along its chord in three
  /// dimensions — the chord rising from one datum to the next — so a
  /// point the next segment's cap pulls below a steep chord reads a little
  /// further along it, and the ground is the height that agrees with
  /// itself: found by iterating, a few passes, as the rise over a segment
  /// is small against its length.
  ///
  /// Each segment's chord is worked out once, not per point and pass, and
  /// nothing is allocated per point: this ran every frame for every graded
  /// road until the snapshot cached its result.
  void corridorGround(
    List<Vec2> pts,
    List<Vec2> knots,
    List<double> datumStart,
    List<double> datumEnd,
    double halfWidthM,
    List<double> out,
  ) {
    final m = knots.length - 1;
    assert(m >= 1, 'a corridor has at least one segment');
    assert(datumStart.length >= m && datumEnd.length >= m);
    assert(out.length >= pts.length);
    if (m < 1) return;
    // Each segment's chord: its first knot, its run in plan, its rise.
    final ke = Float64List(m + 1), kn = Float64List(m + 1);
    for (var k = 0; k <= m; k++) {
      ke[k] = knots[k].e;
      kn[k] = knots[k].n;
    }
    final de = Float64List(m), dn = Float64List(m);
    final plan2 = Float64List(m), rise = Float64List(m), len3 = Float64List(m);
    for (var j = 0; j < m; j++) {
      de[j] = ke[j + 1] - ke[j];
      dn[j] = kn[j + 1] - kn[j];
      plan2[j] = de[j] * de[j] + dn[j] * dn[j];
      rise[j] = datumEnd[j] - datumStart[j];
      len3[j] = plan2[j] + rise[j] * rise[j];
    }
    // Where (pe, pn) lies along segment [j] in plan, 0 at its first knot
    // and 1 at its last: which segment a point runs along. A segment of no
    // length is always passed (its brush levels nothing — `cutFill`).
    double plan(double pe, double pn, int j) => plan2[j] <= 1e-9
        ? 1
        : ((pe - ke[j]) * de[j] + (pn - kn[j]) * dn[j]) / plan2[j];
    // How far (squared, in plan) (pe, pn) lies from segment [j]'s chord.
    double near2(double pe, double pn, int j) {
      var t = plan2[j] <= 1e-9 ? 0.0 : plan(pe, pn, j);
      t = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
      final ce = ke[j] + de[j] * t - pe, cn = kn[j] + dn[j] * t - pn;
      return ce * ce + cn * cn;
    }

    final reach = halfWidthM + roadFalloffM;
    final reach2 = reach * reach;
    var own = 0;
    for (var i = 0; i < pts.length; i++) {
      final pe = pts[i].e, pn = pts[i].n;
      // The segment the point runs along: the nearest to it, searched on
      // from the last point's — the points are in order, so it only moves
      // on. Not the first whose far knot the point has not passed: a road
      // whose first metre doubles back (a generated street's hook off the
      // node it leaves) has a first segment every later point lies BEHIND,
      // and a whole street was drawn at its first datum, 0.6 m in the
      // ground 100 m on.
      while (own < m - 1 && near2(pe, pn, own + 1) <= near2(pe, pn, own)) {
        own++;
      }
      var t0 = plan(pe, pn, own);
      t0 = t0 < 0 ? 0.0 : (t0 > 1 ? 1.0 : t0);
      // The ground before this corridor, as far as it matters: wherever
      // the point's own segment levels it outright, not at all.
      final before = datumStart[own] + rise[own] * t0;
      final first = own > 0 ? own - 1 : 0;
      var r = before;
      for (var pass = 0; pass < 8; pass++) {
        var v = before;
        // The segments in the order they were recorded: the one before (its
        // end cap, overruled by the point's own segment), its own, and
        // those after it whose first knot's cap reaches back to the point.
        for (var j = first; j < m; j++) {
          if (j > own + 1) {
            final ex = pe - ke[j], en = pn - kn[j];
            if (ex * ex + en * en > reach2) break;
          }
          if (plan2[j] <= 1e-9) continue;
          // Where the point, at radius r, projects along the segment's
          // chord as its brush projects it: in three dimensions.
          var t = ((pe - ke[j]) * de[j] +
                  (pn - kn[j]) * dn[j] +
                  (r - datumStart[j]) * rise[j]) /
              len3[j];
          t = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
          final ce = ke[j] + de[j] * t - pe, cn = kn[j] + dn[j] * t - pn;
          final w = TerrainBrush.falloffWeight(
              math.sqrt(ce * ce + cn * cn), halfWidthM, roadFalloffM);
          if (w <= 0) continue;
          v = v * (1 - w) + (datumStart[j] + rise[j] * t) * w;
        }
        final moved = (v - r).abs();
        r = v;
        if (moved < 1e-5) break;
      }
      out[i] = r;
    }
  }

  /// How far past the deepest cut or tallest fill a deck corridor's bound
  /// reaches: the brush must be anchored within its bound of the real
  /// ground or it culls every sample (see `onGround` above).
  static const double deckCutMarginM = 10;

  /// The corridor of a raised or sunk road ([RoadSpline.deck]).
  ///
  /// Graded to the DECK, not to the ground: each 24 m segment is cut or
  /// filled to the deck's own straight grade line, so the road that looks
  /// level on its embankment is the road the ground was shaped to. Where
  /// it stands on piers or runs in a tunnel nothing is emitted — a
  /// cut-and-fill is a radial prism, which under a bridge would raise an
  /// earth wall to the deck and over a tunnel would open a trench to the
  /// sky.
  ///
  /// Clipped, not classified: the survey cuts its structure and tunnel
  /// ranges every 8 m, anywhere along a segment, and judged by its midpoint
  /// a segment straddling a bridge's end either left up to 12 m of graded
  /// deck unfilled (a slab floating over the hillside, too low for piers)
  /// or ran its prism 12 m under the bridge. So only a segment's GRADED
  /// pieces ([gradedPieces]) are cut or filled, each to the deck between
  /// its own ends. A segment that is one piece keeps its key; one that
  /// splits keys its pieces `'<key>:<j>'` for the caller to record. Either
  /// way nothing is asked about again: a segment with no piece, or several,
  /// has its own key recorded here, straight into [CitySim.shapedTerrain]
  /// (the caller only records the keys it gets a brush for).
  void _deckCorridor(
    CitySim city,
    RoadSpline road,
    RoadDeck deck,
    List<Vec2> pts,
    String hw,
    List<({String key, TerrainBrush brush})> out, {
    required double bodyRadiusM,
    required Vector3 Function(Vec2) dirOf,
    required double Function(Vec2) groundUnder,
    required int tick,
  }) {
    // Arc along the 24 m samples, scaled to the length its deck's ranges
    // were measured on ([RoadDeck.rangeLengthM]; a curve's 24 m chords run
    // a little short of it) — or, for a deck saved before it knew that, to
    // the road's own length as indexed (the 2 m samples it was cut from).
    final cum = <double>[0];
    for (var i = 1; i < pts.length; i++) {
      cum.add(cum[i - 1] + pts[i].distanceTo(pts[i - 1]));
    }
    final lengthM = deck.rangeLengthM ??
        city.layout.roadIndex.byId(road.id)?.lengthM ??
        cum.last;
    final scale = cum.last <= 1e-9 ? 1.0 : lengthM / cum.last;
    for (var i = 1; i < pts.length; i++) {
      final key = 'road:${road.id}:$hw:$i';
      if (city.shapedTerrain.contains(key)) continue;
      final sA = cum[i - 1] * scale, sB = cum[i] * scale;
      final pieces = gradedPieces(deck, sA, sB);
      // Settled here unless it is one piece, whose brush the caller
      // records under this same key.
      if (pieces.length != 1) city.shapedTerrain.add(key);
      final a = pts[i - 1], b = pts[i];
      // A cut at a range's end lands on the chord between the samples, at
      // its share of the segment's arc. The segment's own ends are the
      // samples themselves, so an unclipped segment is the brush it was.
      Vec2 at(double s) => s <= sA
          ? a
          : s >= sB
              ? b
              : a + (b - a) * ((s - sA) / (sB - sA));
      for (var j = 0; j < pieces.length; j++) {
        final (g0, g1) = pieces[j];
        final pa = at(g0), pb = at(g1);
        final datumA = bodyRadiusM + deck.heightAt(g0, lengthM);
        final datumB = bodyRadiusM + deck.heightAt(g1, lengthM);
        final fill = math.max((datumA - groundUnder(pa)).abs(),
            (datumB - groundUnder(pb)).abs());
        out.add((
          key: pieces.length == 1 ? key : '$key:$j',
          brush: TerrainBrush.cutFill(
            // Anchored on the deck, which is within the bound of the ground
            // because the bound reaches past the fill.
            startBF: dirOf(pa) * datumA,
            endBF: dirOf(pb) * datumB,
            radiusM: road.halfWidth,
            datumRadiusM: datumA,
            datumRadiusEndM: datumB,
            // An embankment's side eases out over half again its height: a
            // six-metre falloff under a twelve-metre fill is a cliff.
            falloffM: math.max(roadFalloffM, fill * 1.5),
            maxCutM: math.max(40.0, fill + deckCutMarginM),
            tick: tick,
            minVoxelM: voxelM,
          ),
        ));
      }
    }
  }

  /// A graded piece shorter than this is left to its neighbours' falloff:
  /// a brush a metre long is an edit to the ground that shapes nothing.
  static const double minPieceM = 1;

  /// What is left of the arc range [sA]..[sB] of [deck]'s road once its
  /// stretches on piers and underground are cut out: the pieces that run
  /// near enough the ground to be cut or filled to it, in order, each
  /// longer than [minPieceM].
  static List<(double, double)> gradedPieces(
      RoadDeck deck, double sA, double sB) {
    final off = [
      for (final r in [...deck.structures, ...deck.tunnels])
        if (r.$2 > sA && r.$1 < sB) r,
    ]..sort((x, y) => x.$1.compareTo(y.$1));
    final out = <(double, double)>[];
    var from = sA;
    for (final (a, b) in off) {
      if (a - from > minPieceM) out.add((from, a));
      if (b > from) from = b;
    }
    if (sB - from > minPieceM) out.add((from, sB));
    return out;
  }

  /// Peak-to-trough ground relief across a parcel, sampled at its corners and
  /// centre — enough to size the cut without a full raster of the lot.
  double _reliefAcross(Parcel parcel, double Function(Vec2) groundUnder) {
    var lo = double.infinity, hi = -double.infinity;
    for (final v in [...parcel.polygon, parcel.centroid]) {
      final r = groundUnder(v);
      lo = math.min(lo, r);
      hi = math.max(hi, r);
    }
    return hi - lo;
  }

  /// Which buildings dig instead of levelling.
  bool _isPit(CityBuildingSpec spec) => spec.siteKind == SiteKind.pit;

  /// Pit depth from its radius. Real open-pit mines run roughly 1:4 depth to
  /// width at a stable bench angle, and holding to that is what makes a big
  /// quarry read as genuinely huge rather than as a wide scrape.
  double pitDepthFor(double radiusM) => (radiusM * 0.5).clamp(12.0, 900.0);

  /// One bench per ~25 m of depth, which is the working height of real
  /// haul-truck terraces.
  int benchesFor(double radiusM) =>
      (pitDepthFor(radiusM) / 25).round().clamp(3, 24);
}
