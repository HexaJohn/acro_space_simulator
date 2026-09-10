// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Why the city-builder mode's Earth default sits where it does.
//
// The site was chosen off the baked DEM, not off a map, against two competing
// requirements: the town's own ground has to be flat enough to lay a plat on,
// and the ground around it has to RISE, or the colony has nothing to be
// measured against. The survey prints the whole candidate table (run it with
// `-r expanded` to read it); the assertions pin the one that shipped, so a
// re-bake of the DEM that moves the coastline or the heights fails here rather
// than silently founding the mode's opening view on a mudflat.

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/baked_terrain_data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('survey candidate sites', () async {
    await loadBakedTerrainData();
    final earth = RealSolarSystem.build().require(const BodyId('earth'));
    final field = earth.terrainFieldWith(null);
    expect(field, isNotNull, reason: 'no Earth DEM registered');

    double elevAt(double latDeg, double lonDeg) {
      final lat = latDeg * math.pi / 180, lon = lonDeg * math.pi / 180;
      final x = math.cos(lat) * math.cos(lon);
      final y = math.cos(lat) * math.sin(lon);
      final z = math.sin(lat);
      return field!.groundRadiusAt(x, y, z) - earth.radius;
    }

    // Metres per degree, near enough for a local sample ring.
    const mPerDegLat = 111320.0;

    final sites = <String, (double, double)>{
      'Swiss Alps (Interlaken)': (46.7, 7.9),
      'Bavarian Alps': (47.6, 11.3),
      'NZ Southern Alps': (-44.0, 170.3),
      'Cascades (WA)': (47.4, -121.5),
      'Smokies (TN)': (35.6, -83.4),
      'Andes (Bariloche)': (-41.1, -71.3),
      'Rockies Front Range': (39.6, -105.4),
      'Himalaya (Pokhara)': (28.2, 83.9),
      'Japan (Nagano)': (36.2, 138.0),
      'Norway (Sognefjord)': (61.2, 7.1),
      'Patagonia (El Chalten)': (-49.3, -72.9),
      'Scotland (Glencoe)': (56.7, -5.1),
      'Lauterbrunnen valley': (46.59, 7.91),
      'Zermatt valley': (46.02, 7.75),
      'Chamonix valley': (45.92, 6.87),
      'Yosemite valley': (37.74, -119.60),
      'Geirangerfjord': (62.10, 7.21),
      'Milford Sound': (-44.67, 167.93),
      'Queenstown (Wakatipu)': (-45.03, 168.66),
      'Banff valley': (51.18, -115.57),
      'Innsbruck (Inn valley)': (47.26, 11.39),
      'Interlaken flats': (46.69, 7.86),
      'CURRENT default (AZ)': (35.0, -110.0),
    };

    // The shipped default: Queenstown basin, Southern Alps.
    const defaultLat = -45.03, defaultLon = 168.66;
    final siteElev = elevAt(defaultLat, defaultLon);
    expect(siteElev, greaterThan(50),
        reason: 'the default site must be dry land, not sea floor');

    double ringMax(double km) {
      var hi = -1e9;
      for (var i = 0; i < 32; i++) {
        final th = i / 32 * 2 * math.pi;
        final dLat = km * 1000 * math.cos(th) / mPerDegLat;
        final dLon = km *
            1000 *
            math.sin(th) /
            (mPerDegLat * math.cos(defaultLat * math.pi / 180));
        hi = math.max(hi, elevAt(defaultLat + dLat, defaultLon + dLon));
      }
      return hi;
    }

    // Flat enough to build on: the starter kit spans about 2 km.
    var coreLo = siteElev, coreHi = siteElev;
    for (var i = 0; i < 16; i++) {
      final th = i / 16 * 2 * math.pi;
      final dLat = 1000 * math.cos(th) / mPerDegLat;
      final dLon = 1000 *
          math.sin(th) /
          (mPerDegLat * math.cos(defaultLat * math.pi / 180));
      final v = elevAt(defaultLat + dLat, defaultLon + dLon);
      coreLo = math.min(coreLo, v);
      coreHi = math.max(coreHi, v);
    }
    expect(coreHi - coreLo, lessThan(150),
        reason: 'the town core must be layable, not a hillside');

    // And rising CLOSE, which is the half that actually renders: peaks 25 km
    // out flatten into the far field at every playable camera height.
    expect(ringMax(4) - siteElev, greaterThan(200),
        reason: 'nothing near enough to give the colony a sense of scale');
    expect(ringMax(8) - siteElev, greaterThan(400));

    for (final e in sites.entries) {
      final (lat, lon) = e.value;
      final here = elevAt(lat, lon);
      // Relief per RING, because distance decides whether it is rendered at
      // all: the near bands carry the DEM, the far field smooths out.
      final rings = <double, (double, double)>{};
      for (final kmR in [2.0, 4.0, 8.0, 16.0]) {
        var lo = here, hi = here;
        for (var i = 0; i < 32; i++) {
          final th = i / 32 * 2 * math.pi;
          final dLat = kmR * 1000 * math.cos(th) / mPerDegLat;
          final dLon = kmR *
              1000 *
              math.sin(th) /
              (mPerDegLat * math.cos(lat * math.pi / 180));
          final v = elevAt(lat + dLat, lon + dLon);
          lo = math.min(lo, v);
          hi = math.max(hi, v);
        }
        rings[kmR] = (lo, hi);
      }
      // Local flatness of the 2 km the town itself sits on.
      var flatLo = here, flatHi = here;
      for (var i = 0; i < 8; i++) {
        final th = i / 8 * 2 * math.pi;
        final dLat = 1000 * math.cos(th) / mPerDegLat;
        final dLon =
            1000 * math.sin(th) / (mPerDegLat * math.cos(lat * math.pi / 180));
        final v = elevAt(lat + dLat, lon + dLon);
        flatLo = math.min(flatLo, v);
        flatHi = math.max(flatHi, v);
      }
      final ringTxt = rings.entries
          .map((r) =>
              '${r.key.toStringAsFixed(0)}km +${(r.value.$2 - here).toStringAsFixed(0).padLeft(4)}'
              '/${(r.value.$1 - here).toStringAsFixed(0).padLeft(5)}')
          .join('  ');
      // ignore: avoid_print
      print('${e.key.padRight(24)} site ${here.toStringAsFixed(0).padLeft(5)}m'
          '  flat±1km ${(flatHi - flatLo).toStringAsFixed(0).padLeft(4)}m  '
          '$ringTxt');
    }
  });
}
