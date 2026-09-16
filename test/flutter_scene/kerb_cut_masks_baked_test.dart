// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A12, the ROAD half (docs/plans/site-access.md §5.5, §8.3 R4): the baked
/// kerb cars `CityTileMesher.curbParkingFor` stands down agree with
/// `KerbCuts.parkingBlocked` on the drawn arc, within half a metre per cut —
/// the same asymmetric form the agents' kerb slots ask, so the picture and
/// the simulation mask the same kerb.
library;

import 'dart:typed_data';

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/kerb_cuts.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/domain/scatter/prop_mesh.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_mesher.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/vehicle_meshes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const r = 1.7374e6;
  const anchor = Vector3(0, 0, r);
  const lengthM = 400.0;
  const spacingM = 7.4; // the bay pitch `curbParkingFor` walks
  final halfWidth = RoadClass.street.width / 2;

  /// A straight street through the anchor, a station every two metres.
  final pts = <Vector3>[
    for (var i = 0; i <= lengthM ~/ 2; i++) Vector3(i * 2.0, 0, 0),
  ];

  final road = RoadSnapshot(
    colonyId: 'c',
    body: 'moon',
    points: [for (final p in pts) ...[p.x, p.y, p.z + r]],
    halfWidthM: halfWidth,
    roadClassIndex: RoadClass.street.index,
    sealed: false,
  );

  /// Drawn entries: a two-way road drives on the right, so σ is +1 on
  /// side 1 (the kerb at −y here) and −1 on side 0.
  Float64List cuts(List<(int side, double c, double h, int kind)> of) {
    final out = Float64List(of.length * KerbCuts.stride);
    for (var i = 0; i < of.length; i++) {
      final (side, c, h, kind) = of[i];
      out[i * 5] = side.toDouble();
      out[i * 5 + 1] = c;
      out[i * 5 + 2] = h;
      out[i * 5 + 3] = side == 1 ? 1 : -1;
      out[i * 5 + 4] = kind.toDouble();
    }
    return out;
  }

  /// The bays `curbParkingFor` walks, in its own order: the arc it stands a
  /// car at and the kerb it stands on (1 right of travel).
  List<(double, int)> bays({required int budget}) {
    final out = <(double, int)>[];
    var travelled = 0.0, next = spacingM;
    var placed = 0;
    for (var i = 1; i < pts.length && placed < budget; i++) {
      travelled += (pts[i] - pts[i - 1]).length;
      if (travelled < next) continue;
      next += spacingM;
      final h = (i * 2654435761) & 0x7FFFFFFF;
      final kind = VehicleKind.road[h % VehicleKind.road.length];
      if (kind.lengthM > spacingM * 0.85) continue;
      out.add((travelled, placed.isEven ? 1 : 0));
      placed++;
    }
    return out;
  }

  PropMesh baked({Float64List? with_, int budget = 1000}) {
    final body = MeshBuilder(), glass = MeshBuilder();
    CityTileMesher.curbParkingFor(body, glass, pts, road, anchor,
        budget: budget, cuts: with_);
    return body.build();
  }

  double arcOf(PropMesh m, int i) => m.positions[i * 3] * 1000.0;

  /// Which kerb a vertex stands on: side 1 is at −y.
  int sideOf(PropMesh m, int i) => m.positions[i * 3 + 1] < 0 ? 1 : 0;

  group('the baked cars and the mask agree', () {
    test('a car stands exactly where parkingBlocked does not', () {
      final table = cuts([
        (1, 80.0, 4.0, KerbCuts.kindHomeLot),
        (0, 80.0, 4.0, KerbCuts.kindHomeFarSwing),
        (1, 200.0, 3.5, KerbCuts.kindDropped),
        (0, 310.0, 5.0, KerbCuts.kindDropped),
      ]);
      // What the mask says of each bay, computed straight from the
      // canonical function.
      final want = [
        for (final (s, side) in bays(budget: 1000))
          if (!KerbCuts.parkingBlocked(table, side, s)) (s, side),
      ];
      final all = bays(budget: 1000);
      expect(want.length, lessThan(all.length), reason: 'some bay is masked');
      // And what the tiles bake. Every vertex of every car belongs to one
      // of the unmasked bays: within half a metre of its centre along the
      // road, plus the car's own half length.
      final m = baked(with_: table);
      expect(m.vertexCount, greaterThan(0));
      for (var i = 0; i < m.vertexCount; i++) {
        final arc = arcOf(m, i), side = sideOf(m, i);
        final near = want.any((b) =>
            b.$2 == side && (b.$1 - arc).abs() <= 3.7 + 0.5);
        expect(near, isTrue,
            reason: 'a car vertex at $arc on kerb $side stands in no '
                'unmasked bay');
      }
      // Nothing was quietly dropped either: every unmasked bay carries a
      // car (its body reaches within half its length of its centre).
      for (final (s, side) in want) {
        var found = false;
        for (var i = 0; i < m.vertexCount && !found; i++) {
          found = sideOf(m, i) == side && (arcOf(m, i) - s).abs() < 2.5;
        }
        expect(found, isTrue, reason: 'no car near $s on kerb $side');
      }
    });

    test('no car body reaches a home back-out\'s swing path', () {
      // The home join at 80 m, served both ways on a two-way street: its
      // own kerb takes the dropped kerb, the far kerb the swing mask.
      final table = cuts([
        (1, 80.0, kHomeCutHalfM, KerbCuts.kindHomeLot),
        (0, 80.0, kHomeCutHalfM, KerbCuts.kindHomeFarSwing),
      ]);
      final m = baked(with_: table);
      for (var i = 0; i < m.vertexCount; i++) {
        final side = sideOf(m, i);
        final sigma = side == 1 ? 1.0 : -1.0;
        final x = sigma * (arcOf(m, i) - 80.0);
        // `[T − 12, T + 3]` in travel terms, on BOTH served kerbs.
        expect(x > -kHomeSwingUpM && x < kHomeSwingDownM, isFalse,
            reason: 'a car body at $x of the swing on kerb $side');
      }
    });

    test('an ordinary cut masks its own kerb only, 3.25 m each way', () {
      final table = cuts([(1, 200.0, 3.5, KerbCuts.kindDropped)]);
      final m = baked(with_: table);
      for (var i = 0; i < m.vertexCount; i++) {
        if (sideOf(m, i) != 1) continue;
        // A centre inside (200 ± (3.5 + 3.25)) is masked, so no vertex is
        // nearer than that less the car's half length.
        expect((arcOf(m, i) - 200).abs(),
            greaterThan(3.5 + kKerbMaskM - 3.7 - 1e-6));
      }
      // The far kerb keeps every car it had.
      var far = 0, farPlain = 0;
      for (var i = 0; i < m.vertexCount; i++) {
        if (sideOf(m, i) == 0) far++;
      }
      final plain = baked();
      for (var i = 0; i < plain.vertexCount; i++) {
        if (sideOf(plain, i) == 0) farPlain++;
      }
      expect(far, farPlain);
    });

    test('no cuts, and a table of none, are the kerb as it was, to the byte',
        () {
      final plain = baked().positions.toList();
      expect(baked(with_: Float64List(0)).positions.toList(), plain);
      expect(baked(with_: cuts([(1, 900.0, 4.0, 0)])).positions.toList(),
          plain);
    });

    test('a masked bay keeps the kerb alternation, and costs its budget', () {
      // The alternation is what fills both sides of a street: a bay that
      // stands empty must not hand its kerb to the next car.
      final table = cuts([(1, 80.0, 4.0, KerbCuts.kindDropped)]);
      final m = baked(with_: table);
      final want = [
        for (final (s, side) in bays(budget: 1000))
          if (!KerbCuts.parkingBlocked(table, side, s)) (s, side),
      ];
      for (final (s, side) in want) {
        var seen = false;
        for (var i = 0; i < m.vertexCount && !seen; i++) {
          seen = (arcOf(m, i) - s).abs() < 2.5 && sideOf(m, i) == side;
        }
        expect(seen, isTrue, reason: 'bay $s stayed on kerb $side');
      }
    });
  });
}
