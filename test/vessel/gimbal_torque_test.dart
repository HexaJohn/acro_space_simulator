import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/part.dart';
import 'package:acro_space_simulator/domain/vessel/propulsion.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:acro_space_simulator/domain/vessel/stage.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Vessel withEngine({required double gimbalRange, Vector3? targetFacing}) {
    final tank = ResourceContainer(
        type: ResourceType.liquidFuel, capacity: 100, amount: 100, unitMass: 5);
    final engine = Part(
      id: const PartId('e'),
      name: 'e',
      dryMass: 1000,
      engine: Engine(
        name: 'vector',
        maxThrustVacuum: 100000,
        maxThrustSeaLevel: 90000,
        ispVacuum: 300,
        ispSeaLevel: 280,
        gimbalRange: gimbalRange,
      ),
      resources: [tank],
    );
    final v = Vessel(
      id: const VesselId('v'),
      name: 'v',
      ownerId: 'p',
      state: const StateVector(
        position: Vector3(700000, 0, 0),
        velocity: Vector3.zero,
        attitude: Quaternion.identity, // forward = +Z
      ),
      dominantBody: const BodyId('kerbin'),
      stages: [Stage(index: 0, parts: [engine])],
    );
    v.setThrottle(1.0);
    v.targetFacing = targetFacing;
    return v;
  }

  test('a gimballed engine steering off-axis produces a torque', () {
    final v = withEngine(gimbalRange: 0.1, targetFacing: Vector3.unitX);
    final contributor =
        v.thrustContributor(pressureFraction: 0, dt: 1.0)!;
    final gf = contributor.evaluate(v.state, v.massProperties);
    expect(gf.torque.length, greaterThan(0));
    // Thrust still mostly forward (+Z).
    expect(gf.force.z, greaterThan(0));
  });

  test('a fixed (non-gimballed) engine produces no torque', () {
    final v = withEngine(gimbalRange: 0, targetFacing: Vector3.unitX);
    final contributor =
        v.thrustContributor(pressureFraction: 0, dt: 1.0)!;
    final gf = contributor.evaluate(v.state, v.massProperties);
    expect(gf.torque.length, closeTo(0, 1e-9));
  });

  test('a gimballed engine with no target facing produces no torque', () {
    final v = withEngine(gimbalRange: 0.1, targetFacing: null);
    final contributor =
        v.thrustContributor(pressureFraction: 0, dt: 1.0)!;
    final gf = contributor.evaluate(v.state, v.massProperties);
    expect(gf.torque.length, closeTo(0, 1e-9));
  });
}
