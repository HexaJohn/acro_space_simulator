// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/lot_features.dart';
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

  test('parking draws an apron, a driveway out, and fills by occupancy', () {
    ({int cars, int groundVerts}) park(double occupancy) {
      final ground = MeshBuilder();
      final cars = MeshBuilder();
      final glass = MeshBuilder();
      final n = LotFeatures.emitParking(ground, cars, glass, at, along, up, 10, 14,
          spaces: 12, occupancy: occupancy, airless: false);
      return (cars: n, groundVerts: ground.build().positions.length);
    }

    // The apron and the driveway are drawn whether or not anyone is parked —
    // an empty car park is still a car park.
    final empty = park(0.0);
    expect(empty.groundVerts, greaterThan(0));
    expect(empty.cars, 0);

    final half = park(0.5);
    final full = park(1.0);
    expect(half.cars, greaterThan(0));
    expect(full.cars, greaterThan(half.cars),
        reason: 'occupancy must show as more cars');
    expect(full.cars, lessThanOrEqualTo(12), reason: 'never more than bays');
  });

  test('an airless world parks rovers, not cars', () {
    final a = MeshBuilder(), b = MeshBuilder(), c = MeshBuilder();
    final n = LotFeatures.emitParking(a, b, c, at, along, up, 10, 14,
        spaces: 6, occupancy: 1.0, airless: true);
    expect(n, greaterThan(0));
    expect(b.build().positions, isNotEmpty);
  });
}
