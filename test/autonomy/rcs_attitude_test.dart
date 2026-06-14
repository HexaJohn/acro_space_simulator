import 'package:acro_space_simulator/domain/autonomy/attitude_controller.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/part.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:acro_space_simulator/domain/vessel/stage.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // RCS controller that consumes monopropellant to slew.
  const rcs = AttitudeController(useRcs: true, monopropPerRadian: 1.0);

  Vessel vessel({required double monoprop}) {
    final tank = ResourceContainer(
      type: ResourceType.monopropellant,
      capacity: 100,
      amount: monoprop,
      unitMass: 4,
    );
    final v = Vessel(
      id: const VesselId('r'),
      name: 'R',
      ownerId: 'p',
      state: const StateVector(
        position: Vector3(700000, 0, 0),
        velocity: Vector3.zero,
        attitude: Quaternion.identity, // forward = +Z
      ),
      dominantBody: const BodyId('kerbin'),
      stages: [
        Stage(index: 0, parts: [
          Part(id: const PartId('rcs'), name: 'rcs', dryMass: 500, resources: [tank]),
        ]),
      ],
    );
    v.targetFacing = Vector3.unitX;
    return v;
  }

  test('RCS slewing consumes monopropellant', () {
    final v = vessel(monoprop: 100);
    rcs.update(v, dt: 0.5);
    final mono = v.allParts.expand((p) => p.resources).first;
    expect(mono.amount, lessThan(100)); // burned some monoprop
  });

  test('with no monopropellant an RCS vessel cannot slew', () {
    final v = vessel(monoprop: 0);
    final q0 = v.state.attitude;
    rcs.update(v, dt: 0.5);
    // Attitude unchanged — no propellant, no torque.
    expect(v.state.attitude.w, q0.w);
    expect(v.state.attitude.x, q0.x);
  });

  test('reaction-wheel controller slews without any propellant', () {
    const wheels = AttitudeController(); // default: no RCS
    final v = vessel(monoprop: 0);
    final before = v.state.attitude.rotate(Vector3.unitZ).dot(Vector3.unitX);
    for (var i = 0; i < 100; i++) {
      wheels.update(v, dt: 0.1);
    }
    final after = v.state.attitude.rotate(Vector3.unitZ).dot(Vector3.unitX);
    expect(after, greaterThan(before)); // turned despite zero monoprop
  });
}
