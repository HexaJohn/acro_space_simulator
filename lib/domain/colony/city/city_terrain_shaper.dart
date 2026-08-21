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

  /// Brushes for everything in [city] that is not yet shaped.
  ///
  /// [groundRadiusAt] returns the natural ground radius (m from the body
  /// centre) along a body-fixed direction — normally the terrain field's own
  /// query, so a pad levels to the real ground rather than to the datum sphere.
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
              ),
      ));
    }

    // ---- Road corridors ------------------------------------------------
    for (final road in city.layout.roads) {
      final pts = road.sample(stepM: 24);
      if (pts.length < 2) continue;
      for (var i = 1; i < pts.length; i++) {
        final key = 'road:${road.id}:$i';
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
          ),
        ));
      }
    }
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
