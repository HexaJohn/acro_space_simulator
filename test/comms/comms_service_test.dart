import 'package:acro_space_simulator/domain/comms/comms_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const comms = CommsService();

  test('one-way signal delay is distance / c', () {
    final a = Vector3.zero;
    final b = const Vector3(299792458.0, 0, 0); // 1 light-second away
    expect(comms.signalDelaySeconds(a, b), closeTo(1.0, 1e-9));
    // Round-trip is double.
    expect(comms.roundTripDelaySeconds(a, b), closeTo(2.0, 1e-9));
  });

  test('clear line of sight when no body blocks the path', () {
    final a = const Vector3(1000000, 0, 0);
    final b = const Vector3(-1000000, 0, 0);
    // Occluder small and off to the side.
    final blocked = comms.isOccluded(
      a,
      b,
      occluderCentre: const Vector3(0, 5000000, 0),
      occluderRadius: 600000,
    );
    expect(blocked, isFalse);
  });

  test('line of sight blocked when a body sits between the endpoints', () {
    final a = const Vector3(2000000, 0, 0);
    final b = const Vector3(-2000000, 0, 0);
    // Big body centred on the origin, directly between a and b.
    final blocked = comms.isOccluded(
      a,
      b,
      occluderCentre: Vector3.zero,
      occluderRadius: 600000,
    );
    expect(blocked, isTrue);
  });

  test('a body behind one endpoint does not block (segment is clamped)', () {
    final a = const Vector3(1000000, 0, 0);
    final b = const Vector3(2000000, 0, 0);
    // Body is at the far -X side, behind a; the segment never reaches it.
    final blocked = comms.isOccluded(
      a,
      b,
      occluderCentre: const Vector3(-5000000, 0, 0),
      occluderRadius: 600000,
    );
    expect(blocked, isFalse);
  });

  test('signal strength falls off with distance (inverse square)', () {
    final near = comms.signalStrength(distance: 1000, transmitPower: 100);
    final far = comms.signalStrength(distance: 2000, transmitPower: 100);
    // Doubling distance quarters the strength.
    expect(far, closeTo(near / 4, near * 1e-6));
  });
}
