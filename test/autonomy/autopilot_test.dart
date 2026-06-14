import 'dart:math' as math;

import 'package:acro_space_simulator/domain/autonomy/autopilot_updater.dart';
import 'package:acro_space_simulator/domain/autonomy/flight_plan.dart';
import 'package:acro_space_simulator/domain/autonomy/plan_validator.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Bare test vessels carry no engine; bypass the fuel gate to exercise the
  // pure burn/PNR math.
  const updater = AutopilotUpdater(validator: AlwaysAffordablePlanValidator());

  Vessel orbiter({required Vector3 dv, required Epoch executeAt}) {
    final v = Vessel(
      id: const VesselId('ap'),
      name: 'Autopilot Test',
      ownerId: 'ai',
      // Circular-ish: pos +X, vel +Y.
      state: const StateVector(
        position: Vector3(700000, 0, 0),
        velocity: Vector3(0, 2000, 0),
      ),
      dominantBody: const BodyId('kerbin'),
      stages: const [],
    );
    v.flightPlan = FlightPlan(
      vessel: v.id,
      legs: [
        FlightLeg(
          targetBody: const BodyId('kerbin'),
          targetAltitude: 100000,
          nodes: [ManeuverNode(executeAt: executeAt, deltaV: dv)],
        ),
      ],
    );
    return v;
  }

  test('prograde node adds speed along the velocity vector', () {
    // 100 m/s prograde.
    final v = orbiter(dv: const Vector3(100, 0, 0), executeAt: Epoch.zero);
    final before = v.state.velocity.length;
    updater.update(v, now: Epoch.zero);
    final after = v.state.velocity.length;
    expect(after - before, closeTo(100, 1e-6));
    // Direction unchanged (pure prograde).
    expect(v.state.velocity.normalized.y, closeTo(1.0, 1e-6));
  });

  test('node only fires once its execute epoch has passed', () {
    final v = orbiter(dv: const Vector3(100, 0, 0), executeAt: const Epoch(50));
    updater.update(v, now: Epoch.zero); // too early
    expect(v.state.velocity.length, closeTo(2000, 1e-6));
    updater.update(v, now: const Epoch(60)); // now due
    expect(v.state.velocity.length, closeTo(2100, 1e-6));
  });

  test('executed node is consumed and the leg advances when empty', () {
    final v = orbiter(dv: const Vector3(50, 0, 0), executeAt: Epoch.zero);
    updater.update(v, now: Epoch.zero);
    expect(v.flightPlan!.isComplete, isTrue);
  });

  test('radial node rotates the velocity without (much) speed change for small dv',
      () {
    // Radial points along +X here (r direction). A radial burn adds a sideways
    // component.
    final v = orbiter(dv: const Vector3(0, 0, 100), executeAt: Epoch.zero);
    updater.update(v, now: Epoch.zero);
    // Velocity gained an X (radial) component.
    expect(v.state.velocity.x.abs(), greaterThan(1));
    // Speed grew only modestly (quadrature add): sqrt(2000^2+100^2) ~ 2002.5.
    expect(v.state.velocity.length, closeTo(math.sqrt(2000 * 2000 + 100 * 100), 1));
  });
}
