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
  });

  /// How far a levelled pad extends beyond the building footprint.
  final double padMarginM;

  /// Width of the ring easing a pad back into natural ground. This is the
  /// "softly" in soft levelling — a colony should look bulldozed, not stamped.
  final double padFalloffM;

  final double roadFalloffM;

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

    Vector3 toBodyFixed(Vec2 local) => placement
        .place(
          radius: bodyRadiusM,
          lat: latRad,
          lon: lonRad,
          east: local.e,
          north: local.n,
        )
        .position;

    /// Ground radius under a local point.
    double groundUnder(Vec2 local) =>
        groundRadiusAt(toBodyFixed(local).normalized);

    // ---- Building pads -------------------------------------------------
    for (final (parcel, spec) in city.buildingParcels()) {
      final key = 'pad:${parcel.id}';
      if (city.shapedTerrain.contains(key)) continue;

      final centre = parcel.centroid;
      final extent = parcel.buildableExtent;
      // Circumscribe the lot: a pad has to cover the corners of the footprint,
      // not just its inscribed circle, or the building sits on a plinth.
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
                centreBF: toBodyFixed(centre),
                radiusM: radius,
                datumRadiusM: datum,
                depthM: _pitDepthFor(radius),
                benches: _benchesFor(radius),
                falloffM: padFalloffM * 3,
                tick: tick,
              )
            : TerrainBrush.pad(
                centreBF: toBodyFixed(centre),
                radiusM: radius,
                datumRadiusM: datum,
                falloffM: padFalloffM,
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
            startBF: toBodyFixed(a),
            endBF: toBodyFixed(b),
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
  bool _isPit(CityBuildingSpec spec) =>
      spec.type == 'mine' || spec.type == 'quarry';

  /// Pit depth from its radius. Real open-pit mines run roughly 1:4 depth to
  /// width at a stable bench angle, and holding to that is what makes a big
  /// quarry read as genuinely huge rather than as a wide scrape.
  double _pitDepthFor(double radiusM) => (radiusM * 0.5).clamp(12.0, 900.0);

  /// One bench per ~25 m of depth, which is the working height of real
  /// haul-truck terraces.
  int _benchesFor(double radiusM) =>
      (_pitDepthFor(radiusM) / 25).round().clamp(3, 24);
}
