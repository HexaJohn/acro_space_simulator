// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/elevated_structure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A straight 400 m line along +X on a Moon-sized body, anchored at its
  // first point so the points are anchor-relative like the traffic pass's.
  const r = 1.7374e6;
  final anchor = const Vector3(0, 0, r);
  final pts = [for (var i = 0; i <= 10; i++) Vector3(i * 40.0, 0, 0)];
  final length = ElevatedStructure.lengthOf(pts);

  test('the train has at most its car count, each car in an orthonormal frame',
      () {
    final poses = ElevatedStructure.trainCarPoses(
      pts: pts,
      anchorBF: anchor,
      lengthM: length,
      epochS: 123.0,
      seed: 7,
    );
    expect(poses, isNotEmpty);
    expect(poses.length, lessThanOrEqualTo(ElevatedStructure.trainCars));
    for (final car in poses) {
      expect(car.side.length, closeTo(1, 1e-9));
      expect(car.along.length, closeTo(1, 1e-9));
      expect(car.up.length, closeTo(1, 1e-9));
      expect(car.side.dot(car.along).abs(), lessThan(1e-9));
      expect(car.side.dot(car.up).abs(), lessThan(1e-9));
      // Along the line, standing on the deck above the anchor's radius.
      expect(car.along.x.abs(), closeTo(1, 1e-6));
      expect((car.centre + anchor).length, greaterThan(r));
    }
  });

  test('the baked train is the canonical car at every pose', () {
    final poses = ElevatedStructure.trainCarPoses(
      pts: pts,
      anchorBF: anchor,
      lengthM: length,
      epochS: 123.0,
      seed: 7,
    );
    final body = MeshBuilder();
    final glass = MeshBuilder();
    ElevatedStructure.emitTrain(body, glass,
        pts: pts, anchorBF: anchor, lengthM: length, epochS: 123.0, seed: 7);
    final carBody = MeshBuilder();
    final carGlass = MeshBuilder();
    ElevatedStructure.emitTrainCar(carBody, carGlass);
    expect(body.triangleCount, poses.length * carBody.triangleCount);
    expect(glass.triangleCount, poses.length * carGlass.triangleCount);
  });

  test('a line too short for the train carries none', () {
    final short = [const Vector3(0, 0, 0), const Vector3(30, 0, 0)];
    expect(
      ElevatedStructure.trainCarPoses(
        pts: short,
        anchorBF: anchor,
        lengthM: 30,
        epochS: 0,
        seed: 1,
      ),
      isEmpty,
    );
  });
}
