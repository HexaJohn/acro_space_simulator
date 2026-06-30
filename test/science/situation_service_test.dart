import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/science/situation_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = SituationService();
  final body = SampleWorld.realSystem().require(SampleWorld.earth);

  Vessel at(double altitude, {bool landed = false}) => Vessel(
        id: const VesselId('s'),
        name: 'S',
        ownerId: 'p',
        state: StateVector(
          position: Vector3(body.radius + altitude, 0, 0),
          velocity: Vector3.zero,
        ),
        dominantBody: SampleWorld.earth,
        stages: const [],
        landed: landed,
      );

  test('landed vessel reports a surface situation', () {
    expect(service.classify(at(0, landed: true), body), 'surface:earth');
  });

  test('inside the atmosphere reports a flying situation', () {
    // Earth atmosphere height is 140 km.
    expect(service.classify(at(30000), body), 'atmosphere:earth');
  });

  test('just above the atmosphere is a low orbit', () {
    // 200 km clears Earth's 140 km atmosphere but is below the 250 km
    // high-orbit cutoff.
    expect(service.classify(at(200000), body), 'lowOrbit:earth');
  });

  test('far out is a high orbit', () {
    expect(service.classify(at(5000000), body), 'highOrbit:earth');
  });

  test('an airless body skips the atmosphere bucket', () {
    final moon = SampleWorld.realSystem().require(SampleWorld.moon);
    final v = Vessel(
      id: const VesselId('m'),
      name: 'M',
      ownerId: 'p',
      state: StateVector(
        position: Vector3(moon.radius + 5000, 0, 0),
        velocity: Vector3.zero,
      ),
      dominantBody: SampleWorld.moon,
      stages: const [],
    );
    // 5 km over an airless moon -> low orbit, never "atmosphere".
    expect(service.classify(v, moon), 'lowOrbit:moon');
  });
}
