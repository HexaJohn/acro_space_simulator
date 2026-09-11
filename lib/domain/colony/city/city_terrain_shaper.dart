// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

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
  /// stretch on piers or in a tunnel, which is shaped by NOT touching the
  /// ground: its key is added to [CitySim.shapedTerrain] here, with no
  /// brush to record, so it is settled once like every other segment.
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
    double groundUnder(Vec2 local) => groundRadiusAt(dirOf(local));

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
      return dir * groundRadiusAt(dir);
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
      // permanent edits to the ground.
      if (!road.graded) continue;
      final pts = road.sample(stepM: 24);
      if (pts.length < 2) continue;
      // Keyed by WIDTH as well as by place. The key is the record that a
      // corridor was cut, and an upgrade keeps a road's id: keyed by place
      // alone, a street widened to an avenue kept its street's corridor
      // for ever, the avenue's edges riding the unshaped hillside.
      final hw = road.halfWidth.toStringAsFixed(2);
      final deck = road.deck;
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

  /// How far past the deepest cut or tallest fill a deck corridor's bound
  /// reaches: the brush must be anchored within its bound of the real
  /// ground or it culls every sample (see `onGround` above).
  static const double deckCutMarginM = 10;

  /// The corridor of a raised or sunk road ([RoadSpline.deck]).
  ///
  /// Graded to the DECK, not to the ground: each 24 m segment is cut or
  /// filled to the deck's own straight grade line, so the road that looks
  /// level on its embankment is the road the ground was shaped to. Where
  /// the segment's midpoint stands on piers or runs in a tunnel nothing is
  /// emitted — a cut-and-fill is a radial prism, which under a bridge
  /// would raise an earth wall to the deck and over a tunnel would open a
  /// trench to the sky — but its key is recorded all the same, straight
  /// into [CitySim.shapedTerrain], so the stretch is never asked about
  /// again (the caller only records the keys it gets a brush for).
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
    // Arc along the 24 m samples, scaled to the road's own length — the
    // length its deck's ranges were measured on (the 2 m samples it was
    // cut from; a curve's 24 m chords run a little short of it).
    final cum = <double>[0];
    for (var i = 1; i < pts.length; i++) {
      cum.add(cum[i - 1] + pts[i].distanceTo(pts[i - 1]));
    }
    final lengthM = city.layout.roadIndex.byId(road.id)?.lengthM ?? cum.last;
    final scale = cum.last <= 1e-9 ? 1.0 : lengthM / cum.last;
    for (var i = 1; i < pts.length; i++) {
      final key = 'road:${road.id}:$hw:$i';
      if (city.shapedTerrain.contains(key)) continue;
      final sA = cum[i - 1] * scale, sB = cum[i] * scale;
      final sMid = (sA + sB) / 2;
      if (deck.onStructureAt(sMid) || deck.inTunnelAt(sMid)) {
        city.shapedTerrain.add(key);
        continue;
      }
      final a = pts[i - 1], b = pts[i];
      final datumA = bodyRadiusM + deck.heightAt(sA, lengthM);
      final datumB = bodyRadiusM + deck.heightAt(sB, lengthM);
      final fill = math.max(
          (datumA - groundUnder(a)).abs(), (datumB - groundUnder(b)).abs());
      out.add((
        key: key,
        brush: TerrainBrush.cutFill(
          // Anchored on the deck, which is within the bound of the ground
          // because the bound reaches past the fill.
          startBF: dirOf(a) * datumA,
          endBF: dirOf(b) * datumB,
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
