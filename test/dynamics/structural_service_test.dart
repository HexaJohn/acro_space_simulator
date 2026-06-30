import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/dynamics/structural_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/domain_event.dart';
import 'package:acro_space_simulator/domain/universe/atmosphere_model.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = StructuralService();

  Vessel ship(Vector3 velocity) => Vessel(
        id: const VesselId('s'),
        name: 'S',
        ownerId: 'p',
        state: StateVector(position: const Vector3(700000, 0, 0), velocity: velocity),
        dominantBody: const BodyId('earth'),
        stages: const [],
      );

  // Dynamic pressure q = 0.5 * rho * v^2.
  const denseAir = AtmosphereSample(
    pressure: 101325,
    density: 1.225,
    temperature: 288,
    speedOfSound: 340,
  );

  test('below the dynamic-pressure limit the vessel survives', () {
    final v = ship(const Vector3(0, 100, 0)); // q = 0.5*1.225*100^2 = 6125 Pa
    final failed = service.check(v, ambient: denseAir, maxDynamicPressure: 80000);
    expect(failed, isFalse);
    expect(v.drainEvents().whereType<StructuralFailure>(), isEmpty);
  });

  test('exceeding the dynamic-pressure limit causes structural failure', () {
    final v = ship(const Vector3(0, 400, 0)); // q = 0.5*1.225*400^2 = 98000 Pa
    final failed = service.check(v, ambient: denseAir, maxDynamicPressure: 80000);
    expect(failed, isTrue);
    expect(v.drainEvents().whereType<StructuralFailure>().isNotEmpty, isTrue);
  });

  test('in vacuum there is no dynamic pressure, so no failure', () {
    final v = ship(const Vector3(0, 5000, 0)); // fast but no air
    final failed = service.check(
      v,
      ambient: AtmosphereSample.vacuum,
      maxDynamicPressure: 80000,
    );
    expect(failed, isFalse);
  });
}
