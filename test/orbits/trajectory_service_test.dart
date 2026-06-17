import 'dart:math' as math;

import 'package:acro_space_simulator/domain/orbits/trajectory_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = TrajectoryService();

  test('predicted path of a circular orbit stays near constant radius', () {
    final body = SampleWorld.buildSystem().require(SampleWorld.kerbin);
    final r = body.radius + 100000;
    final v = math.sqrt(body.mu / r);

    final points = service.predictPath(
      position: Vector3(r, 0, 0),
      velocity: Vector3(0, v, 0),
      body: body,
      epoch: Epoch.zero,
      samples: 32,
    );

    expect(points.length, 33); // samples + 1: the loop closes back to the start
    for (final p in points) {
      expect(p.length, closeTo(r, r * 1e-2));
    }
    // The closing point coincides with the first (continuous, passes the craft).
    expect((points.last - points.first).length, lessThan(r * 1e-3));
  });

  test('path samples span roughly one full orbit (covers all quadrants)', () {
    final body = SampleWorld.buildSystem().require(SampleWorld.kerbin);
    final r = body.radius + 100000;
    final v = math.sqrt(body.mu / r);

    final points = service.predictPath(
      position: Vector3(r, 0, 0),
      velocity: Vector3(0, v, 0),
      body: body,
      epoch: Epoch.zero,
      samples: 64,
    );

    final hasPlusX = points.any((p) => p.x > r * 0.5);
    final hasMinusX = points.any((p) => p.x < -r * 0.5);
    final hasPlusY = points.any((p) => p.y > r * 0.5);
    final hasMinusY = points.any((p) => p.y < -r * 0.5);
    expect(hasPlusX && hasMinusX && hasPlusY && hasMinusY, isTrue);
  });

  test('an open (hyperbolic-ish) fast trajectory still returns finite points', () {
    final body = SampleWorld.buildSystem().require(SampleWorld.kerbin);
    final r = body.radius + 100000;
    final vEsc = math.sqrt(2 * body.mu / r);

    final points = service.predictPath(
      position: Vector3(r, 0, 0),
      velocity: Vector3(0, vEsc * 1.2, 0), // escape
      body: body,
      epoch: Epoch.zero,
      samples: 16,
    );
    expect(points.length, greaterThan(0));
    for (final p in points) {
      expect(p.x.isFinite && p.y.isFinite && p.z.isFinite, isTrue);
    }
  });
}
