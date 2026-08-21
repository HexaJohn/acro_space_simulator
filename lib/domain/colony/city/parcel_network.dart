// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Connectivity over the road-spline network.
///
/// The cell grid answered "is this building road-served?" with a flood fill
/// over tiles. Parcels have no tiles, so the same question is answered on the
/// ROADS themselves: roads join where their carriageways touch, the network is
/// rooted at the colony's landing site, and a lot is served when the road it
/// fronts can trace back to that root.
///
/// Pure computation — takes a layout, returns sets. The aggregate caches one
/// of these per layout version, so the graph walk runs when a road is drawn,
/// not every tick.
library;

import 'city_layout.dart';
import 'parcel.dart';

class ParcelNetwork {
  ParcelNetwork._(this.rootedRoads, this.servedLots);

  /// Road ids whose component reaches the root.
  final Set<String> rootedRoads;

  /// Parcel ids that are served by a rooted road.
  final Set<String> servedLots;

  bool roadRooted(String id) => rootedRoads.contains(id);
  bool lotServed(String id) => servedLots.contains(id);

  /// Distance from [r] to the closest point of [p] — its boundary if the road
  /// is outside it, zero if the road runs through it.
  static double _reachToLot(RoadSpline r, Parcel p) {
    var best = r.distanceTo(p.centroid);
    for (final v in p.polygon) {
      final d = r.distanceTo(v);
      if (d < best) best = d;
    }
    // Edge midpoints too: a road can pass a long edge without coming near
    // either of its ends.
    for (var i = 0; i < p.polygon.length; i++) {
      final a = p.polygon[i], b = p.polygon[(i + 1) % p.polygon.length];
      final d = r.distanceTo(Vec2((a.e + b.e) / 2, (a.n + b.n) / 2));
      if (d < best) best = d;
    }
    return best;
  }

  factory ParcelNetwork.of(
    CityLayout layout, {
    Vec2 root = const Vec2(0, 0),
    double rootReachM = 60,
    double junctionSlackM = 4,
    double manualServeM = 90,
  }) {
    final roads = layout.roads.toList();
    if (roads.isEmpty) return ParcelNetwork._(const {}, const {});

    // Coarse samples per road. 12 m is well under any lot frontage, so a
    // junction cannot slip between two samples.
    final samples = <String, List<Vec2>>{
      for (final r in roads) r.id: r.sample(stepM: 12),
    };

    // Roads join where their carriageways touch: closest sample pair within
    // the two half-widths plus slack. Quadratic in roads and samples, but this
    // runs on layout CHANGES, not ticks, and a colony has tens of roads.
    bool touches(RoadSpline a, RoadSpline b) {
      final limit = a.halfWidth + b.halfWidth + junctionSlackM;
      final limit2 = limit * limit;
      for (final p in samples[a.id]!) {
        for (final q in samples[b.id]!) {
          final de = p.e - q.e, dn = p.n - q.n;
          if (de * de + dn * dn <= limit2) return true;
        }
      }
      return false;
    }

    // Root entries: roads passing the landing site. A colony whose first road
    // was drawn out in a field would otherwise never root ANYTHING, so if none
    // touches the site, the nearest road becomes the trunk — generous, and it
    // can never brick a colony.
    final entries = <String>{};
    for (final r in roads) {
      if (r.distanceTo(root) <= rootReachM + r.halfWidth) entries.add(r.id);
    }
    if (entries.isEmpty) {
      RoadSpline? nearest;
      var best = double.infinity;
      for (final r in roads) {
        final d = r.distanceTo(root);
        if (d < best) {
          best = d;
          nearest = r;
        }
      }
      if (nearest != null) entries.add(nearest.id);
    }

    // BFS the touch graph from the entries.
    final rooted = <String>{...entries};
    final queue = [...entries];
    while (queue.isNotEmpty) {
      final id = queue.removeLast();
      final a = roads.firstWhere((r) => r.id == id);
      for (final b in roads) {
        if (rooted.contains(b.id)) continue;
        if (touches(a, b)) {
          rooted.add(b.id);
          queue.add(b.id);
        }
      }
    }

    // Serving: an auto lot is served by its own frontage road. A manual lot
    // has no frontage road, so any rooted road passing near enough counts —
    // the megaproject's access track, effectively.
    final served = <String>{};
    for (final p in layout.parcels) {
      final rid = p.roadId;
      if (rid != null) {
        if (rooted.contains(rid)) served.add(p.id);
        continue;
      }
      for (final r in roads) {
        if (!rooted.contains(r.id)) continue;
        // Reach to the lot's NEAREST POINT, not its centre. A claimed site can
        // be enormous — a quarry is 3 km across — so a road running along its
        // edge is still 1.5 km from the centroid, and a centre-only test
        // reported every big installation as cut off however well connected it
        // was.
        if (_reachToLot(r, p) <= manualServeM + r.halfWidth) {
          served.add(p.id);
          break;
        }
      }
    }
    return ParcelNetwork._(rooted, served);
  }
}
