import 'dart:convert';

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/adapters/repositories/in_memory_repositories.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WorldSnapshot render frame', () {
    // A vessel with a non-identity attitude + spin so we can prove they survive.
    final attitude = Quaternion.axisAngle(Vector3.unitZ, 0.5);
    final spin = Vector3(0.1, 0.2, 0.3);
    final vessel = SampleWorld.buildVessel()
      ..state = SampleWorld.buildVessel().state.copyWith(
            attitude: attitude,
            angularVelocity: spin,
          );
    final vessels = InMemoryVesselRepository([vessel]);
    final system = SampleWorld.realSystem();

    test('VesselSnapshot carries attitude, angular velocity, and landed', () {
      final snap = WorldSnapshot.capture(0, vessels);
      final v = snap.vessels['demo-1']!;
      expect(v.qw, closeTo(attitude.w, 1e-12));
      expect(v.qx, closeTo(attitude.x, 1e-12));
      expect(v.qy, closeTo(attitude.y, 1e-12));
      expect(v.qz, closeTo(attitude.z, 1e-12));
      expect(v.wx, closeTo(0.1, 1e-12));
      expect(v.wy, closeTo(0.2, 1e-12));
      expect(v.wz, closeTo(0.3, 1e-12));
      expect(v.landed, isFalse);
    });

    test('capture with a StarSystem includes body transforms', () {
      final snap =
          WorldSnapshot.capture(7, vessels, system: system, epoch: const Epoch(100));
      expect(snap.epoch, 100);
      // The real system carries many bodies; assert the ones we care about are
      // present rather than an exact set.
      expect(snap.bodies.keys, contains('earth'));
      expect(snap.bodies.keys, contains('moon'));

      // Root star (the Sun) sits at the origin.
      final sun = snap.bodies['sun']!;
      expect(Vector3(sun.px, sun.py, sun.pz).length, closeTo(0, 1e-6));

      // Earth carries its real equatorial radius.
      final earth = snap.bodies['earth']!;
      expect(earth.radius, 6.371e6);

      // The Moon is offset from the root (chains Moon -> Earth -> Sun) and its
      // quaternion is unit-length.
      final moon = snap.bodies['moon']!;
      expect(Vector3(moon.px, moon.py, moon.pz).length, greaterThan(1e6));
      final qLen = moon.qw * moon.qw +
          moon.qx * moon.qx +
          moon.qy * moon.qy +
          moon.qz * moon.qz;
      expect(qLen, closeTo(1.0, 1e-9));
    });

    test('JSON round-trips vessels + bodies + epoch losslessly', () {
      final snap =
          WorldSnapshot.capture(42, vessels, system: system, epoch: const Epoch(250));
      final back = WorldSnapshot.fromJson(
        jsonDecode(jsonEncode(snap.toJson())) as Map<String, dynamic>,
      );

      expect(back.tick, 42);
      expect(back.epoch, 250);

      final a = snap.vessels['demo-1']!;
      final b = back.vessels['demo-1']!;
      expect(b.qw, closeTo(a.qw, 1e-12));
      expect(b.qz, closeTo(a.qz, 1e-12));
      expect(b.wx, closeTo(a.wx, 1e-12));
      expect(b.px, closeTo(a.px, 1e-9));
      expect(b.landed, a.landed);

      expect(back.bodies.keys.toSet(), snap.bodies.keys.toSet());
      final am = snap.bodies['moon']!;
      final bm = back.bodies['moon']!;
      expect(bm.px, closeTo(am.px, 1e-6));
      expect(bm.qw, closeTo(am.qw, 1e-12));
      expect(bm.radius, am.radius);
    });

    test('fromJson tolerates legacy payloads without attitude/landed', () {
      final v = VesselSnapshot.fromJson({
        'id': 'x',
        'ownerId': 'o',
        'body': 'earth',
        'p': [1, 2, 3],
        'v': [4, 5, 6],
        'throttle': 0.5,
        'onRails': true,
      });
      expect(v.qw, 1);
      expect(v.qx, 0);
      expect(v.wx, 0);
      expect(v.landed, isFalse);
    });
  });
}
