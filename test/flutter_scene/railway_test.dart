// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/rail_vehicles.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/railway.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const r = 1.7374e6;
  final anchor = const Vector3(0, 0, r);
  // A straight 3 km line along +X, anchor-relative, on a Moon-sized body.
  final line = [for (var i = 0; i <= 30; i++) Vector3(i * 100.0, 0, 0)];

  group('chains', () {
    test('segments split at crossings are joined back into one line', () {
      final a = [const Vector3(0, 0, 0), const Vector3(100, 0, 0)];
      // Reversed, and out of order.
      final b = [const Vector3(200, 0, 0), const Vector3(100, 0, 0)];
      final c = [const Vector3(200, 0, 0), const Vector3(300, 0, 0)];
      final chains = Railway.chains([c, a, b]);
      expect(chains, hasLength(1));
      final x = [for (final p in chains.single) p.x];
      expect(x, orderedEquals([300, 200, 100, 0]));
    });

    test('a siding that touches nothing stays its own line', () {
      final main = [const Vector3(0, 0, 0), const Vector3(500, 0, 0)];
      final siding = [const Vector3(100, 14, 0), const Vector3(400, 14, 0)];
      expect(Railway.chains([main, siding]), hasLength(2));
    });
  });

  group('timetable', () {
    const train = RailConsist.passenger;

    test('the head starts at the near end and moves forward', () {
      final h0 = train.headAt(lineM: 3000, stopsM: const [], epochS: 0);
      final h1 = train.headAt(lineM: 3000, stopsM: const [], epochS: 10);
      expect(h0.headM, 0);
      expect(h0.direction, 1);
      expect(h1.headM, closeTo(train.speedMs * 10, 1e-9));
    });

    test('it stands at a stop for the dwell, then goes on', () {
      final stop = 1500.0;
      final arrive = stop / train.speedMs;
      final during = train.headAt(
          lineM: 3000, stopsM: [stop], epochS: arrive + train.dwellS / 2);
      expect(during.headM, stop);
      final after = train.headAt(
          lineM: 3000, stopsM: [stop], epochS: arrive + train.dwellS + 10);
      expect(after.headM, closeTo(stop + train.speedMs * 10, 1e-6));
    });

    test('it comes back the way it went, never jumping', () {
      final oneWay = 3000 / train.speedMs;
      final out = train.headAt(lineM: 3000, stopsM: const [], epochS: oneWay - 1);
      final back = train.headAt(lineM: 3000, stopsM: const [], epochS: oneWay + 1);
      expect(out.direction, 1);
      expect(back.direction, -1);
      // Continuous through the turn-round.
      expect((out.headM - back.headM).abs(), lessThan(train.speedMs * 2 + 1));
      // And a whole cycle later it is back where it started.
      final again =
          train.headAt(lineM: 3000, stopsM: const [], epochS: oneWay * 2 + 5);
      expect(again.headM, closeTo(train.speedMs * 5, 1e-6));
    });
  });

  group('poses', () {
    test('cars trail the head at their own spacing, upright on the line', () {
      const train = RailConsist.freight;
      final poses = train.posesAt(
          pts: line, anchorBF: anchor, epochS: 400, stopsM: const []);
      // Fully on the line by now.
      expect(poses, hasLength(train.cars.length));
      for (var i = 1; i < poses.length; i++) {
        final gap = (poses[i].centre - poses[i - 1].centre).length;
        final expected = (poses[i].kind.lengthM + poses[i - 1].kind.lengthM) / 2 +
            RailConsist.couplingM;
        expect(gap, closeTo(expected, 0.05));
        // The head leads.
        expect(poses[i].centre.x, lessThan(poses[i - 1].centre.x));
      }
      for (final p in poses) {
        expect(p.up.length, closeTo(1, 1e-9));
        expect(p.side.dot(p.along).abs(), lessThan(1e-9));
        expect(p.along.x, closeTo(1, 1e-6));
      }
      expect(poses.first.kind, RailCarKind.loco);
    });

    test('a parked rake stands where it is put', () {
      const train = RailConsist.freight;
      final a = train.posesAt(
          pts: line, anchorBF: anchor, epochS: 0, moving: false, parkedAtM: 1000);
      final b = train.posesAt(
          pts: line, anchorBF: anchor, epochS: 999, moving: false, parkedAtM: 1000);
      expect(a.first.centre.x, closeTo(b.first.centre.x, 1e-9));
      // Within the lean of the rail-head lift along a curved body.
      expect(a.first.centre.x, closeTo(1000 - RailCarKind.loco.lengthM / 2, 1e-2));
    });

    test('a line shorter than the train carries none', () {
      final short = [const Vector3(0, 0, 0), const Vector3(60, 0, 0)];
      expect(
          RailConsist.passenger
              .posesAt(pts: short, anchorBF: anchor, epochS: 0),
          isEmpty);
    });
  });

  test('every car kind builds a body, and only the glazed ones a window band',
      () {
    for (final kind in RailCarKind.values) {
      final body = MeshBuilder();
      final glass = MeshBuilder();
      RailVehicleMeshes.emitModel(body, glass, kind);
      expect(body.triangleCount, greaterThan(0), reason: kind.name);
      expect(glass.triangleCount > 0, kind.glazed, reason: kind.name);
    }
  });

  test('the track lays ballast, sleepers and two rails along the line', () {
    final ballast = MeshBuilder();
    final concrete = MeshBuilder();
    final steel = MeshBuilder();
    Railway.emit(ballast, concrete, steel,
        pts: line.take(6).toList(), anchorBF: anchor, halfWidthM: 4);
    expect(ballast.triangleCount, greaterThan(0));
    expect(steel.triangleCount, greaterThan(0));
    // 500 m at a 2.4 m pitch: about two hundred sleepers, three quads each.
    expect(concrete.triangleCount ~/ 6, inInclusiveRange(200, 210));
  });
}
