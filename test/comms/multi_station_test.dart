import 'package:acro_space_simulator/domain/comms/relay_network.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const network = RelayNetwork();
  final body = CelestialBody(
    id: const BodyId('kerbin'),
    name: 'Kerbin',
    mu: 3.5316e12,
    radius: 600000,
    soiRadius: 84159286,
    siderealRotationPeriod: 21549,
    parent: null,
  );

  Vessel at(String id, Vector3 pos) => Vessel(
        id: VesselId(id),
        name: id,
        ownerId: 'p',
        state: StateVector(position: pos, velocity: Vector3.zero),
        dominantBody: const BodyId('kerbin'),
        stages: const [],
      );

  test('a vessel over the -X hemisphere links via a second -X ground station', () {
    final v = at('a', const Vector3(-1000000, 0, 0)); // far side from +X station
    // With only the default +X station -> dark.
    expect(network.computeLinks([v], body)['a'], isFalse);
    // Add a station on -X -> the vessel sees it -> linked.
    final stations = [
      const Vector3(600000, 0, 0), // +X
      const Vector3(-600000, 0, 0), // -X
    ];
    expect(
      network.computeLinks([v], body, stations: stations)['a'],
      isTrue,
    );
  });

  test('an empty station list leaves everyone dark (no ground contact)', () {
    final v = at('a', const Vector3(1000000, 0, 0));
    expect(
      network.computeLinks([v], body, stations: const [])['a'],
      isFalse,
    );
  });
}
