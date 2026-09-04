// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/architecture/building_massing.dart';
import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/lot_features.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_mesher.dart';
import 'package:flutter_test/flutter_test.dart';

/// What stands on a lot besides its building.
///
/// The zone type already encodes both kind AND density (`r-low`, `i-high`),
/// which is why none of this needs anything new on the wire.
void main() {
  final up = Vector3(1, 0, 0);
  final along = Vector3(0, 1, 0);
  final at = up * 1000.0;

  test('edging follows kind AND density', () {
    // Houses have a garden to enclose; a tower meets the pavement.
    expect(LotFeatures.edgingFor('r-low'), LotEdging.picket);
    expect(LotFeatures.edgingFor('r-med'), LotEdging.picket);
    expect(LotFeatures.edgingFor('r-high'), LotEdging.none);
    // A works worth fencing is a works with something in the yard.
    expect(LotFeatures.edgingFor('i-med'), LotEdging.chainLink);
    expect(LotFeatures.edgingFor('i-high'), LotEdging.chainLink);
    expect(LotFeatures.edgingFor('i-low'), LotEdging.none);
    // Shops are signed, not fenced.
    expect(LotFeatures.edgingFor('c-med'), LotEdging.none);
  });

  test('every commercial density carries a sign', () {
    for (final t in ['c-low', 'c-med', 'c-high']) {
      expect(LotFeatures.signFor(t), isTrue, reason: t);
    }
    for (final t in ['r-low', 'r-high', 'i-med']) {
      expect(LotFeatures.signFor(t), isFalse, reason: t);
    }
  });

  test('a fence builds geometry, and leaves the street edge open', () {
    for (final kind in [LotEdging.picket, LotEdging.chainLink]) {
      final m = MeshBuilder();
      LotFeatures.emitFence(m, kind, at, along, up, 10, 14);
      final mesh = m.build();
      expect(mesh.positions.length, greaterThan(60), reason: '$kind is empty');

      // Nothing may cross the FRONT of the lot: a fully enclosed plot has no
      // way in and reads as a compound.
      var minAlong = double.infinity;
      for (var i = 0; i + 2 < mesh.positions.length; i += 3) {
        final y = mesh.positions[i + 1] / 0.001;
        if (y < minAlong) minAlong = y;
      }
      expect(minAlong, greaterThan(-14.5), reason: '$kind fenced its frontage');
    }
    // None means none.
    final none = MeshBuilder();
    LotFeatures.emitFence(none, LotEdging.none, at, along, up, 10, 14);
    expect(none.build().positions, isEmpty);
  });

  test('a picket stands lower than chain link', () {
    double height(LotEdging kind) {
      final m = MeshBuilder();
      LotFeatures.emitFence(m, kind, at, along, up, 10, 14);
      final p = m.build().positions;
      var hi = -double.infinity;
      for (var i = 0; i + 2 < p.length; i += 3) {
        final h = p[i] / 0.001 - 1000.0;
        if (h > hi) hi = h;
      }
      return hi;
    }
    expect(height(LotEdging.picket), lessThan(height(LotEdging.chainLink)));
    expect(height(LotEdging.picket), closeTo(1.05, 0.2));
  });

  test('the sign has a dark board and a lit face', () {
    final solid = MeshBuilder();
    final glow = MeshBuilder();
    LotFeatures.emitSign(solid, glow, at, along, up, 10, 14, 1.0);
    expect(solid.build().positions, isNotEmpty, reason: 'post + board');
    expect(glow.build().positions, isNotEmpty, reason: 'the lit face');
  });

  test('a lot fills by occupancy, and an airless world parks rovers', () {
    const lot = ParkingLot(x: 0, y: -19, width: 28, depth: 20, spaces: 12);
    int park(double occupancy, {bool airless = false}) =>
        LotFeatures.emitLot(MeshBuilder(), MeshBuilder(), MeshBuilder(),
            Vector3.zero, Vector3(0, 1, 0), Vector3(0, 0, 1), up, lot, (0, -8),
            frontLineY: -30,
            rearLineY: 30,
            behind: false,
            rearDoorY: 12,
            occupancy: occupancy,
            airless: airless);
    expect(park(0.0), 0);
    final half = park(0.5);
    final full = park(1.0);
    expect(half, greaterThan(0));
    expect(full, greaterThan(half), reason: 'occupancy must show as more cars');
    expect(full, lessThanOrEqualTo(12), reason: 'never more than bays');
    final rovers = MeshBuilder();
    final n = LotFeatures.emitLot(MeshBuilder(), rovers, MeshBuilder(),
        Vector3.zero, Vector3(0, 1, 0), Vector3(0, 0, 1), up, lot, (0, -8),
        frontLineY: -30,
        rearLineY: 30,
        behind: false,
        rearDoorY: 12,
        occupancy: 1.0,
        airless: true);
    expect(n, greaterThan(0));
    expect(rovers.build().positions, isNotEmpty);
  });

  group('the car park the massing placed', () {
    // The building's plan frame at the origin, up +X, street along +Y, into
    // the lot along +Z: so a vertex's y is its x-across and z its y-along.
    final side = Vector3(0, 1, 0);
    final into = Vector3(0, 0, 1);
    ({double minX, double maxX, double minY, double maxY}) bounds(
        MeshBuilder m) {
      final mesh = m.build();
      var minX = double.infinity, maxX = -double.infinity;
      var minY = double.infinity, maxY = -double.infinity;
      for (var v = 0; v < mesh.vertexCount; v++) {
        final x = mesh.positions[v * 3 + 1] / 0.001;
        final y = mesh.positions[v * 3 + 2] / 0.001;
        minX = math.min(minX, x);
        maxX = math.max(maxX, x);
        minY = math.min(minY, y);
        maxY = math.max(maxY, y);
      }
      return (minX: minX, maxX: maxX, minY: minY, maxY: maxY);
    }

    test('a front lot: driveway to the curb across the sidewalk, footpath '
        'from the door to the lot line, bays inside the lot', () {
      // A 30 m wide parcel, 60 m deep: lot line at y = -30, a 20 m lot
      // just inside it, the building behind with its door at y = -8.
      const lot = ParkingLot(x: 0, y: -19, width: 28, depth: 20, spaces: 20);
      final paving = MeshBuilder(), cars = MeshBuilder(), glass = MeshBuilder();
      final placed = LotFeatures.emitLot(
          paving, cars, glass, Vector3.zero, side, into, up, lot, (0, -8),
          frontLineY: -30,
          rearLineY: 30,
          behind: false,
          rearDoorY: 12,
          occupancy: 0.5,
          airless: false,
          sidewalkM: 3);
      final b = bounds(paving);
      // The driveway reaches the curb, three metres past the lot line...
      expect(b.minY, lessThan(-30 - 3 + 0.5));
      // ...and nothing goes further than the curb or wider than the lot.
      expect(b.minY, greaterThan(-30 - 3 - 1));
      expect(b.minX, greaterThan(-28 / 2 - 1));
      expect(b.maxX, lessThan(28 / 2 + 1));
      // The path goes all the way to the door.
      expect(b.maxY, greaterThanOrEqualTo(-8));
      // Half the twenty bays, at most, hold a car; none when empty.
      expect(placed, inInclusiveRange(1, 10));
      expect(cars.build().triangleCount, greaterThan(0));
      final empty = MeshBuilder();
      expect(
          LotFeatures.emitLot(empty, MeshBuilder(), MeshBuilder(), Vector3.zero,
              side, into, up, lot, (0, -8),
              frontLineY: -30,
              rearLineY: 30,
              behind: false,
              rearDoorY: 12,
              occupancy: 0,
              airless: false),
          0);
      // Without detail there are no bay lines, so far fewer triangles.
      final coarse = MeshBuilder();
      LotFeatures.emitLot(coarse, MeshBuilder(), MeshBuilder(), Vector3.zero,
          side, into, up, lot, (0, -8),
          frontLineY: -30,
          rearLineY: 30,
          behind: false,
          rearDoorY: 12,
          occupancy: 0.5,
          airless: false,
          detailed: false);
      expect(coarse.build().triangleCount, lessThan(paving.build().triangleCount));
    });

    test('a rear lot: driveway out into the alley, footpath to the back door,'
        ' and no driveway across the front', () {
      const lot = ParkingLot(x: 0, y: 20, width: 28, depth: 16, spaces: 16);
      final paving = MeshBuilder();
      LotFeatures.emitLot(paving, MeshBuilder(), MeshBuilder(), Vector3.zero,
          side, into, up, lot, (0, -30),
          frontLineY: -30,
          rearLineY: 30,
          behind: true,
          rearDoorY: 9,
          occupancy: 0.5,
          airless: false);
      final b = bounds(paving);
      // Into the alley past the rear line.
      expect(b.maxY, greaterThan(30));
      expect(b.maxY, lessThan(32));
      // The path reaches the back wall; nothing reaches the street — the
      // door is ON the lot line, a street wall.
      expect(b.minY, lessThanOrEqualTo(9));
      expect(b.minY, greaterThan(0));
    });

    test('paint rides the lot slab, not the ground', () {
      const lot = ParkingLot(x: 0, y: -19, width: 28, depth: 20, spaces: 20);
      final paving = MeshBuilder();
      LotFeatures.emitLot(paving, MeshBuilder(), MeshBuilder(), Vector3.zero,
          side, into, up, lot, (0, -8),
          frontLineY: -30,
          rearLineY: 30,
          behind: false,
          rearDoorY: 12,
          occupancy: 0,
          airless: false);
      final mesh = paving.build();
      var minUp = double.infinity;
      for (var v = 0; v < mesh.vertexCount; v++) {
        minUp = math.min(minUp, mesh.positions[v * 3] / 0.001);
      }
      expect(minUp, greaterThan(0.08), reason: 'over the 8 cm slab');
      expect(RoadMesher.paintLiftM, lessThan(0.1));
    });
  });
}
