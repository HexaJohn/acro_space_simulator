import 'dart:math' as math;

import 'package:acro_space_simulator/domain/autonomy/flight_plan.dart';
import 'package:acro_space_simulator/domain/autonomy/plan_validator.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/shared/units.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/part.dart';
import 'package:acro_space_simulator/domain/vessel/propulsion.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:acro_space_simulator/domain/vessel/stage.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

Vessel rocket({required double fuelUnits, required double fuelUnitMass}) {
  final tank = ResourceContainer(
    type: ResourceType.liquidFuel,
    capacity: fuelUnits,
    amount: fuelUnits,
    unitMass: fuelUnitMass,
  );
  final engine = Part(
    id: const PartId('e'),
    name: 'engine',
    dryMass: 1000,
    engine: const Engine(
      name: 'eng',
      maxThrustVacuum: 200000,
      maxThrustSeaLevel: 180000,
      ispVacuum: 300,
      ispSeaLevel: 280,
    ),
    resources: [tank],
  );
  return Vessel(
    id: const VesselId('r'),
    name: 'R',
    ownerId: 'ai',
    state: const StateVector(position: Vector3(700000, 0, 0), velocity: Vector3.zero),
    dominantBody: const BodyId('earth'),
    stages: [Stage(index: 0, parts: [engine])],
  );
}

void main() {
  const validator = PlanValidator();

  test('deltaV capacity matches the Tsiolkovsky rocket equation', () {
    final v = rocket(fuelUnits: 100, fuelUnitMass: 5); // 500 kg propellant
    final dryMass = 1000.0; // engine dry mass, tank dry mass folded in is 0 here
    final m0 = dryMass + 500;
    final mf = dryMass;
    final expected = 300 * standardGravity * math.log(m0 / mf);
    expect(v.deltaVCapacity(), closeTo(expected, 1e-3));
  });

  test('a plan within the dv budget is accepted', () {
    final v = rocket(fuelUnits: 400, fuelUnitMass: 5); // lots of fuel
    final plan = FlightPlan(
      vessel: v.id,
      legs: [
        FlightLeg(
          targetBody: const BodyId('earth'),
          targetAltitude: 200000,
          nodes: [
            ManeuverNode(executeAt: Epoch.zero, deltaV: const Vector3(100, 0, 0)),
            ManeuverNode(executeAt: const Epoch(100), deltaV: const Vector3(80, 0, 0)),
          ],
        ),
      ],
    );
    expect(validator.canAfford(v, plan), isTrue);
  });

  test('a plan exceeding the dv budget is rejected', () {
    final v = rocket(fuelUnits: 10, fuelUnitMass: 5); // tiny fuel
    final plan = FlightPlan(
      vessel: v.id,
      legs: [
        FlightLeg(
          targetBody: const BodyId('earth'),
          targetAltitude: 200000,
          nodes: [
            ManeuverNode(executeAt: Epoch.zero, deltaV: const Vector3(5000, 0, 0)),
          ],
        ),
      ],
    );
    expect(validator.canAfford(v, plan), isFalse);
  });
}
