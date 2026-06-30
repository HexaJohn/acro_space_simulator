import 'package:acro_space_simulator/domain/comms/relay_network.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const network = RelayNetwork();

  // Earth at origin, radius ~6371 km; ground station on +X surface.
  final body = CelestialBody(
    id: const BodyId('earth'),
    name: 'Earth',
    mu: 3.986004418e14,
    radius: 6.371e6,
    soiRadius: 9.24e8,
    siderealRotationPeriod: 21549,
    parent: null,
  );

  Vessel at(String id, Vector3 pos) => Vessel(
        id: VesselId(id),
        name: id,
        ownerId: 'p',
        state: StateVector(position: pos, velocity: Vector3.zero),
        dominantBody: const BodyId('earth'),
        stages: const [],
      );

  test('a vessel with direct line of sight to the station has a link', () {
    final v = at('a', const Vector3(10000000, 0, 0)); // out along +X, sees +X station
    final links = network.computeLinks([v], body);
    expect(links['a'], isTrue);
  });

  test('a vessel behind the planet has no DIRECT link', () {
    final v = at('a', const Vector3(-10000000, 0, 0)); // far side
    final links = network.computeLinks([v], body);
    expect(links['a'], isFalse);
  });

  test('a relay restores the link for a vessel behind the planet', () {
    // Relay high on the +X/+Z side sees the +X station; the far-side ship sees
    // the relay (clear line over the top) and routes through it.
    final relay = at('relay', const Vector3(20000000, 0, 20000000));
    final blocked = at('ship', const Vector3(-20000000, 0, 20000000));

    final links = network.computeLinks([relay, blocked], body);
    expect(links['relay'], isTrue); // relay sees the station
    expect(links['ship'], isTrue); // ship routes through the relay
  });

  test('two isolated far-side ships with no relay both stay dark', () {
    final a = at('a', const Vector3(-10000000, 1000000, 0));
    final b = at('b', const Vector3(-10000000, -1000000, 0));
    final links = network.computeLinks([a, b], body);
    expect(links['a'], isFalse);
    expect(links['b'], isFalse);
  });
}
