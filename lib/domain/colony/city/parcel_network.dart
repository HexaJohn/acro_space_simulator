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
/// not every tick. Every touch test goes through the layout's road index:
/// a road probes the segments within reach of its own samples, so the walk
/// costs the length of the network, not the square of its road count.
library;

import 'dart:math' as math;

import 'city_layout.dart';
import 'parcel.dart';
import 'spatial_index.dart';

class ParcelNetwork {
  ParcelNetwork._(this.rootedRoads, this.servedLots);

  /// Road ids whose component reaches the root.
  final Set<String> rootedRoads;

  /// Parcel ids that are served by a rooted road.
  final Set<String> servedLots;

  bool roadRooted(String id) => rootedRoads.contains(id);
  bool lotServed(String id) => servedLots.contains(id);

  static final double _maxHalfWidth =
      RoadClass.values.fold(0.0, (m, c) => math.max(m, c.halfWidth));

  /// Distance from [p] to the nearest of [segs] on [rec].
  static double _nearestOf(IndexedRoad rec, List<int> segs, Vec2 p) {
    var best = double.infinity;
    for (final s in segs) {
      final d = s == 0
          ? p.distanceTo(rec.sampleAt(0))
          : rec.distanceToSegment(p, s);
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
    final idx = layout.roadIndex;
    if (idx.roadCount == 0) return ParcelNetwork._(const {}, const {});

    // Roads join where their carriageways touch: a sample of one within the
    // two half-widths plus slack of a segment of the other. Probed every
    // 12 m along each road, which is well under any lot frontage, so a
    // junction cannot slip between two probes.
    final touching = <int, Set<int>>{};
    final stride = math.max(1, (12 / idx.sampleM).round());
    for (final (slotA, a) in idx.indexed) {
      final mine = touching[slotA] ??= {};
      final reach = a.road.halfWidth + _maxHalfWidth + junctionSlackM;
      for (var i = 0; i < a.sampleCount; i += stride) {
        final p = a.sampleAt(i);
        idx.visit(Box2.around(p, reach), 0, (slotB, b, seg) {
          if (slotB == slotA || mine.contains(slotB)) return;
          final limit = a.road.halfWidth + b.road.halfWidth + junctionSlackM;
          final d = seg == 0
              ? p.distanceTo(b.sampleAt(0))
              : b.distanceToSegment(p, seg);
          if (d <= limit) {
            mine.add(slotB);
            (touching[slotB] ??= {}).add(slotA);
          }
        });
      }
      // The last sample too: a short stub's end is where it meets a road.
      if (a.sampleCount > 1 && (a.sampleCount - 1) % stride != 0) {
        final p = a.sampleAt(a.sampleCount - 1);
        idx.visit(Box2.around(p, reach), 0, (slotB, b, seg) {
          if (slotB == slotA || mine.contains(slotB)) return;
          final limit = a.road.halfWidth + b.road.halfWidth + junctionSlackM;
          final d = seg == 0
              ? p.distanceTo(b.sampleAt(0))
              : b.distanceToSegment(p, seg);
          if (d <= limit) {
            mine.add(slotB);
            (touching[slotB] ??= {}).add(slotA);
          }
        });
      }
    }

    // Root entries: roads passing the landing site. A colony whose first road
    // was drawn out in a field would otherwise never root ANYTHING, so if none
    // touches the site, the nearest road becomes the trunk — generous, and it
    // can never brick a colony.
    final entries = <int>{};
    final nearRoot = <int, double>{};
    idx.visit(Box2.around(root, rootReachM + _maxHalfWidth), 0,
        (slot, rec, seg) {
      final d = seg == 0
          ? root.distanceTo(rec.sampleAt(0))
          : rec.distanceToSegment(root, seg);
      final prev = nearRoot[slot];
      if (prev == null || d < prev) nearRoot[slot] = d;
    });
    nearRoot.forEach((slot, d) {
      if (d <= rootReachM + idx.bySlot(slot)!.road.halfWidth) entries.add(slot);
    });
    if (entries.isEmpty) {
      final nearest = idx.nearest(root);
      if (nearest != null) entries.add(nearest.slot);
    }

    // BFS the touch graph from the entries.
    final rooted = <int>{...entries};
    final queue = [...entries];
    while (queue.isNotEmpty) {
      final slot = queue.removeLast();
      for (final other in touching[slot] ?? const <int>{}) {
        if (rooted.add(other)) queue.add(other);
      }
    }
    final rootedIds = {for (final s in rooted) idx.bySlot(s)!.road.id};

    // Serving: an auto lot is served by its own frontage road. A manual lot
    // has no frontage road, so any rooted road passing near enough counts —
    // the megaproject's access track, effectively.
    final served = <String>{};
    for (final p in layout.parcels) {
      final rid = p.roadId;
      if (rid != null) {
        if (rootedIds.contains(rid)) served.add(p.id);
        continue;
      }
      // Reach to the lot's NEAREST POINT, not its centre. A claimed site can
      // be enormous — a quarry is 3 km across — so a road running along its
      // edge is still 1.5 km from the centroid, and a centre-only test
      // reported every big installation as cut off however well connected it
      // was. Edge midpoints too: a road can pass a long edge without coming
      // near either of its ends.
      final probes = <Vec2>[p.centroid, ...p.polygon];
      for (var i = 0; i < p.polygon.length; i++) {
        final a = p.polygon[i], b = p.polygon[(i + 1) % p.polygon.length];
        probes.add(Vec2((a.e + b.e) / 2, (a.n + b.n) / 2));
      }
      final near =
          idx.segmentsNear(Box2.of(p.polygon), manualServeM + _maxHalfWidth);
      for (final entry in near.entries) {
        if (!rooted.contains(entry.key)) continue;
        final rec = idx.bySlot(entry.key)!;
        var reach = double.infinity;
        for (final v in probes) {
          reach = math.min(reach, _nearestOf(rec, entry.value, v));
        }
        if (reach <= manualServeM + rec.road.halfWidth) {
          served.add(p.id);
          break;
        }
      }
    }
    return ParcelNetwork._(rootedIds, served);
  }
}
