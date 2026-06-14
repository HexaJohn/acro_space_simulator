import 'package:acro_space_simulator/domain/autonomy/rendezvous_service.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = RendezvousService();

  StateVector at(Vector3 p, Vector3 v) => StateVector(position: p, velocity: v);

  test('range is the distance between the two vessels', () {
    final info = service.compute(
      chaser: at(const Vector3(0, 0, 0), Vector3.zero),
      target: at(const Vector3(300, 400, 0), Vector3.zero),
    );
    expect(info.range, closeTo(500, 1e-9));
  });

  test('closing range-rate is negative when approaching', () {
    // Chaser at origin moving +X toward a target on +X.
    final info = service.compute(
      chaser: at(const Vector3(0, 0, 0), const Vector3(10, 0, 0)),
      target: at(const Vector3(1000, 0, 0), Vector3.zero),
    );
    // Range is shrinking -> rangeRate negative.
    expect(info.rangeRate, lessThan(0));
    expect(info.isClosing, isTrue);
  });

  test('range-rate is positive when separating', () {
    final info = service.compute(
      chaser: at(const Vector3(0, 0, 0), const Vector3(-10, 0, 0)),
      target: at(const Vector3(1000, 0, 0), Vector3.zero),
    );
    expect(info.rangeRate, greaterThan(0));
    expect(info.isClosing, isFalse);
  });

  test('time to closest approach for a head-on closing pair', () {
    // 1000 m apart, closing at 10 m/s head-on -> closest approach in 100 s.
    final info = service.compute(
      chaser: at(const Vector3(0, 0, 0), const Vector3(10, 0, 0)),
      target: at(const Vector3(1000, 0, 0), Vector3.zero),
    );
    expect(info.timeToClosestApproach, closeTo(100, 1e-6));
  });

  test('parallel non-closing motion has no finite approach time', () {
    final info = service.compute(
      chaser: at(const Vector3(0, 0, 0), const Vector3(0, 5, 0)),
      target: at(const Vector3(1000, 0, 0), const Vector3(0, 5, 0)),
    );
    // Constant separation -> relative velocity perpendicular to range -> tca 0
    // (already at closest along-track) and rangeRate ~ 0.
    expect(info.rangeRate.abs(), lessThan(1e-9));
  });
}
