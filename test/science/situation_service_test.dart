import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/science/situation_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = SituationService();
  final body = SampleWorld.buildSystem().require(SampleWorld.kerbin);

  Vessel at(double altitude, {bool landed = false}) => Vessel(
        id: const VesselId('s'),
        name: 'S',
        ownerId: 'p',
        state: StateVector(
          position: Vector3(body.radius + altitude, 0, 0),
          velocity: Vector3.zero,
        ),
        dominantBody: SampleWorld.kerbin,
        stages: const [],
        landed: landed,
      );

  test('landed vessel reports a surface situation', () {
    expect(service.classify(at(0, landed: true), body), 'surface:kerbin');
  });

  test('inside the atmosphere reports a flying situation', () {
    // Kerbin atmosphere height is 70 km.
    expect(service.classify(at(30000), body), 'atmosphere:kerbin');
  });

  test('just above the atmosphere is a low orbit', () {
    expect(service.classify(at(100000), body), 'lowOrbit:kerbin');
  });

  test('far out is a high orbit', () {
    expect(service.classify(at(5000000), body), 'highOrbit:kerbin');
  });

  test('an airless body skips the atmosphere bucket', () {
    final mun = SampleWorld.buildSystem().require(SampleWorld.mun);
    final v = Vessel(
      id: const VesselId('m'),
      name: 'M',
      ownerId: 'p',
      state: StateVector(
        position: Vector3(mun.radius + 5000, 0, 0),
        velocity: Vector3.zero,
      ),
      dominantBody: SampleWorld.mun,
      stages: const [],
    );
    // 5 km over an airless moon -> low orbit, never "atmosphere".
    expect(service.classify(v, mun), 'lowOrbit:mun');
  });
}
