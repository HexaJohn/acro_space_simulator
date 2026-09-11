// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The roads' share of the scatter mask: which stretches of a road clear the
/// props, and what about a road makes the mask rebuild. Pure — the node
/// itself needs a GPU, its road arithmetic does not.
library;

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/surface_placement.dart';
import 'package:acro_space_simulator/domain/scatter/scatter_mask.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/scatter/scatter_nodes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const groundR = 6371000.0;

  /// A body-fixed direction [east]/[north] metres from the site at (0,0).
  Vector3 dirAt(double east, double north) =>
      Vector3(groundR, east, north).normalized;

  /// A road sampled every 6 m, as the snapshot samples one, from
  /// ([eastStart], -300) to ([eastEnd], 300) on the ground, with a deck
  /// [liftAt] each sample's north when given.
  RoadSnapshot road({
    String id = 'r0',
    String body = 'earth',
    double halfWidthM = 4,
    double eastStart = 0,
    double eastEnd = 0,
    double Function(double north)? liftAt,
  }) {
    const n = 101;
    final pts = <double>[];
    final lifts = <double>[];
    for (var k = 0; k < n; k++) {
      final t = k / (n - 1);
      final north = -300 + 600 * t;
      final p =
          dirAt(eastStart + (eastEnd - eastStart) * t, north) * groundR;
      pts.addAll([p.x, p.y, p.z]);
      if (liftAt != null) lifts.add(liftAt(north));
    }
    return RoadSnapshot(
      colonyId: 'c',
      body: body,
      points: pts,
      halfWidthM: halfWidthM,
      roadClassIndex: 0,
      id: id,
      lifts: lifts,
    );
  }

  ScatterMaskBuilder builder() => ScatterMaskBuilder(
        originBF: Vector3(groundR, 0, 0),
        groundRadiusM: groundR,
      );

  ScatterMask maskOf(RoadSnapshot r) {
    final b = builder();
    ScatterNodes.addRoadCorridor(b, r);
    return b.build(1);
  }

  group('corridor', () {
    test('a tunnel leaves the trees standing on the hill above it', () {
      final mask =
          maskOf(road(liftAt: (north) => north.abs() < 100 ? -20 : 0));
      for (final north in [-60.0, 0.0, 60.0]) {
        expect(mask.blocks(dirAt(0, north)), isFalse,
            reason: 'over the tunnel at $north m');
      }
      for (final north in [-250.0, -150.0, 150.0, 250.0]) {
        expect(mask.blocks(dirAt(0, north)), isTrue,
            reason: 'the road on the surface at $north m');
        expect(mask.blocks(dirAt(6, north)), isTrue, reason: 'and its verge');
      }
    });

    test('a cutting, a bridge and a viaduct are still in the road', () {
      for (final lift in [-3.0, 12.0, 40.0]) {
        expect(maskOf(road(liftAt: (_) => lift)).blocks(dirAt(0, 0)), isTrue,
            reason: 'deck $lift m');
      }
    });

    test('a road wholly underground masks nothing', () {
      final b = builder();
      expect(ScatterNodes.addRoadCorridor(b, road(liftAt: (_) => -20)), 0);
      expect(b.isEmpty, isTrue);
    });

    test('a road that surfaces for one sample between tunnels masks it', () {
      final mask =
          maskOf(road(liftAt: (north) => north.abs() < 3 ? 0 : -20));
      expect(mask.blocks(dirAt(0, 0)), isTrue);
      expect(mask.blocks(dirAt(0, 30)), isFalse);
    });

    test('a road with no deck masks exactly as one on the ground', () {
      expect(maskOf(road()).features, maskOf(road(liftAt: (_) => 0)).features);
    });
  });

  group('signature', () {
    int sig(List<RoadSnapshot> roads) =>
        ScatterNodes.roadMaskSignature(roads, 'earth').hash;
    final base = sig([road()]);

    test('an Upgrade in place, same id and samples, rebuilds the mask', () {
      final wider = road(halfWidthM: 11.5);
      expect(wider.points.length, road().points.length);
      expect(sig([wider]), isNot(base));
    });

    test('an Adjust drag a few metres sideways rebuilds the mask', () {
      final dragged = road(id: 'r0x0', eastEnd: 4);
      expect(dragged.points.length, road().points.length,
          reason: 'too small a move to change the sample count');
      expect(sig([dragged]), isNot(base));
    });

    test('ground re-graded under a road is not a road that moved', () {
      // Placed as the snapshot places a road (city.localToBodyFixed): the
      // tangent offset is in metres, so the ground's radius leaks into a
      // point's DIRECTION. Two kilometres out on the Moon, five metres of
      // fill turns the road's ends by a few parts in a billion.
      const moonR = 1737400.0, ground = 120.0;
      RoadSnapshot moonRoad(double groundM) {
        final pts = <double>[];
        for (var k = 0; k <= 10; k++) {
          final p = const SurfacePlacement()
              .place(
                radius: moonR + groundM,
                lat: 0.3,
                lon: 0.5,
                east: 2000,
                north: -30 + 6.0 * k,
              )
              .position;
          pts.addAll([p.x, p.y, p.z]);
        }
        return RoadSnapshot(
          colonyId: 'c',
          body: 'moon',
          points: pts,
          halfWidthM: 4,
          roadClassIndex: 0,
          id: 'r0',
        );
      }

      Vector3 start(RoadSnapshot r) =>
          Vector3(r.points[0], r.points[1], r.points[2]).normalized;
      final before = moonRoad(ground), after = moonRoad(ground + 5);
      expect((start(after) - start(before)).length, greaterThan(1e-9),
          reason: 'the regrade does turn the end');
      expect(ScatterNodes.roadMaskSignature([after], 'moon').hash,
          ScatterNodes.roadMaskSignature([before], 'moon').hash);
    });

    test('only the body being drawn counts', () {
      final both = ScatterNodes.roadMaskSignature(
          [road(), road(id: 'r9', body: 'moon')], 'earth');
      expect(both.roads, 1);
      expect(both.hash, base);
    });
  });
}
