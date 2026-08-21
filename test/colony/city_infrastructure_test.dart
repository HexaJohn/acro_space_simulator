// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/elevated_structure.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/street_furniture.dart';
import 'package:flutter_test/flutter_test.dart';

/// The geometry that is not a building: viaducts, the L, and everything
/// standing on a pavement.
void main() {
  // A straight alignment 300 m long, a kilometre out from a body centre so the
  // radial "up" is a real direction rather than a degenerate one.
  final anchorBF = Vector3(6.371e6, 0, 0);
  final pts = [
    for (var i = 0; i <= 12; i++) Vector3(0, -150.0 + i * 25, 0),
  ];

  /// Fraction of triangles wound AGAINST their own declared normal. Every mesh
  /// in this renderer opposes; the value is compared between meshes rather
  /// than asserted absolutely, because the convention is the engine's and not
  /// something this test should be re-deciding.
  double opposing(dynamic mesh) {
    final p = mesh.positions as List<double>;
    final n = mesh.normals as List<double>;
    final idx = mesh.indices as List<int>;
    var against = 0, total = 0;
    for (var t = 0; t + 2 < idx.length; t += 3) {
      final a = idx[t] * 3, b = idx[t + 1] * 3, c = idx[t + 2] * 3;
      final e1 = [p[b] - p[a], p[b + 1] - p[a + 1], p[b + 2] - p[a + 2]];
      final e2 = [p[c] - p[a], p[c + 1] - p[a + 1], p[c + 2] - p[a + 2]];
      final wx = e1[1] * e2[2] - e1[2] * e2[1];
      final wy = e1[2] * e2[0] - e1[0] * e2[2];
      final wz = e1[0] * e2[1] - e1[1] * e2[0];
      final d = wx * n[a] + wy * n[a + 1] + wz * n[a + 2];
      if (d.abs() < 1e-18) continue;
      total++;
      if (d < 0) against++;
    }
    return total == 0 ? -1 : against / total;
  }

  ({MeshBuilder solid, MeshBuilder deck, MeshBuilder glow}) build(
      RoadClass cls) {
    final solid = MeshBuilder(), deck = MeshBuilder(), glow = MeshBuilder();
    ElevatedStructure.emit(solid, deck, glow,
        pts: pts,
        anchorBF: anchorBF,
        cls: cls,
        halfWidthM: cls.halfWidth);
    return (solid: solid, deck: deck, glow: glow);
  }

  group('elevated structures', () {
    test('an at-grade road builds no structure at all', () {
      final b = build(RoadClass.street);
      expect(b.solid.build().isEmpty, isTrue);
      expect(b.deck.build().isEmpty, isTrue);
    });

    test('the rail trestle and the viaduct are DIFFERENT structures', () {
      final rail = build(RoadClass.transit).solid.build();
      final road = build(RoadClass.elevated).solid.build();
      expect(rail.isEmpty, isFalse);
      expect(road.isEmpty, isFalse);
      // Short spans and many light members vs long spans and heavy ones. If
      // these converge, one has quietly started drawing the other.
      expect(ElevatedStructure.spacingFor(RoadClass.transit),
          lessThan(ElevatedStructure.spacingFor(RoadClass.elevated)));
      expect(rail.triangleCount, greaterThan(road.triangleCount),
          reason: 'a trestle is many small members; a viaduct is few big ones');
    });

    test('the deck is up in the air and the columns reach the ground', () {
      final b = build(RoadClass.transit);
      final solid = b.solid.build();
      const scale = 1e-3;
      var lo = double.infinity, hi = -double.infinity;
      for (var i = 0; i + 2 < solid.positions.length; i += 3) {
        // Up is +X here: the anchor puts the radial along it.
        final z = solid.positions[i] / scale;
        if (z < lo) lo = z;
        if (z > hi) hi = z;
      }
      expect(lo, lessThan(0.5), reason: 'nothing reaches the ground');
      expect(hi, greaterThan(RoadClass.transit.deckHeightM - 0.5),
          reason: 'the deck is not at deck height');
    });

    test('a train runs, and only along enough track to hold one', () {
      final body = MeshBuilder(), glass = MeshBuilder();
      ElevatedStructure.emitTrain(body, glass,
          pts: pts,
          anchorBF: anchorBF,
          lengthM: ElevatedStructure.lengthOf(pts),
          epochS: 12,
          seed: 1);
      expect(body.build().isEmpty, isFalse);

      // A stub of track shorter than the train gets none.
      final short = MeshBuilder();
      ElevatedStructure.emitTrain(short, MeshBuilder(),
          pts: [pts.first, pts[1]],
          anchorBF: anchorBF,
          lengthM: 25,
          epochS: 12,
          seed: 1);
      expect(short.build().isEmpty, isTrue);
    });

    test('it moves with the clock, and repeats for the same clock', () {
      List<double> at(double t) {
        final m = MeshBuilder();
        ElevatedStructure.emitTrain(m, MeshBuilder(),
            pts: pts,
            anchorBF: anchorBF,
            lengthM: ElevatedStructure.lengthOf(pts),
            epochS: t,
            seed: 1);
        return m.build().positions.toList();
      }

      expect(at(4.0), equals(at(4.0)),
          reason: 'derived from the tick: two clients must agree');
      expect(at(4.0), isNot(equals(at(9.0))), reason: 'the train never moved');
    });
  });

  group('street furniture', () {
    int furnish(RoadClass cls, {int budget = 1 << 30}) {
      final solid = MeshBuilder(), glow = MeshBuilder();
      return StreetFurniture.emit(solid, glow,
          pts: pts,
          anchorBF: anchorBF,
          cls: cls,
          halfWidthM: cls.halfWidth,
          pavementM: 3,
          seed: 5,
          budget: budget);
    }

    test('pavements get furniture; alleys and viaducts do not', () {
      expect(furnish(RoadClass.street), greaterThan(0));
      expect(furnish(RoadClass.alley), 0);
      expect(furnish(RoadClass.elevated), 0);
      expect(furnish(RoadClass.transit), 0);
    });

    test('the budget is respected, because a colony has to share one', () {
      expect(furnish(RoadClass.street, budget: 3), lessThanOrEqualTo(3));
    });

    test('the same street furnishes the same way twice', () {
      List<double> once() {
        final m = MeshBuilder();
        StreetFurniture.emit(m, MeshBuilder(),
            pts: pts,
            anchorBF: anchorBF,
            cls: RoadClass.street,
            halfWidthM: 4,
            pavementM: 3,
            seed: 9);
        return m.build().positions.toList();
      }

      expect(once(), equals(once()),
          reason: 'furniture that jitters between frames is furniture that '
              'crawls about the pavement');
    });

    test('nothing stands in the carriageway, or off the far side of the path',
        () {
      final m = MeshBuilder();
      StreetFurniture.emit(m, MeshBuilder(),
          pts: pts,
          anchorBF: anchorBF,
          cls: RoadClass.street,
          halfWidthM: 4,
          pavementM: 3,
          seed: 2);
      final mesh = m.build();
      const scale = 1e-3;
      // The alignment runs along +Y and up is +X, so lateral offset is Z.
      for (var i = 0; i + 2 < mesh.positions.length; i += 3) {
        final across = (mesh.positions[i + 2] / scale).abs();
        expect(across, greaterThan(3.0),
            reason: 'a bin is standing in the road');
        expect(across, lessThan(9.0),
            reason: 'furniture is off the back of the pavement');
      }
    });

    test('the toggle actually stops it', () {
      addTearDown(() => StreetFurniture.enabled = true);
      StreetFurniture.enabled = false;
      expect(furnish(RoadClass.street), 0);
    });
  });

  test('everything winds the way the rest of the city does', () {
    // Measured against the viaduct DECK, which is emitted by the same ribbon
    // code the ground roads use and is therefore known to render face up.
    final v = build(RoadClass.elevated);
    final want = opposing(v.deck.build());
    expect(want, isNot(-1));

    final furniture = MeshBuilder();
    StreetFurniture.emit(furniture, MeshBuilder(),
        pts: pts,
        anchorBF: anchorBF,
        cls: RoadClass.street,
        halfWidthM: 4,
        pavementM: 3,
        seed: 3);

    for (final (label, mesh) in [
      ('viaduct', v.solid.build()),
      ('trestle', build(RoadClass.transit).solid.build()),
      ('furniture', furniture.build()),
    ]) {
      expect(opposing(mesh), closeTo(want, 0.06), reason: '$label is inside out');
    }
  });
}
