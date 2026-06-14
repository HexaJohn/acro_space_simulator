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
  // Bypass the fuel gate; we only test comms gating here.
  const updater = AutopilotUpdater(validator: AlwaysAffordablePlanValidator());

  Vessel withDueBurn({required bool commLink}) {
    final v = Vessel(
      id: const VesselId('c'),
      name: 'C',
      ownerId: 'ai',
      state: const StateVector(
        position: Vector3(700000, 0, 0),
        velocity: Vector3(0, 2000, 0),
      ),
      dominantBody: const BodyId('kerbin'),
      stages: const [],
    );
    v.hasCommLink = commLink;
    v.flightPlan = FlightPlan(
      vessel: v.id,
      legs: [
        FlightLeg(
          targetBody: const BodyId('kerbin'),
          targetAltitude: 200000,
          nodes: [ManeuverNode(executeAt: Epoch.zero, deltaV: const Vector3(100, 0, 0))],
        ),
      ],
    );
    return v;
  }

  test('autopilot executes the due burn when a comm link is present', () {
    final v = withDueBurn(commLink: true);
    final before = v.state.velocity.length;
    updater.update(v, now: Epoch.zero);
    expect(v.state.velocity.length - before, closeTo(100, 1e-6));
  });

  test('autopilot holds the burn during a comms blackout', () {
    final v = withDueBurn(commLink: false);
    final before = v.state.velocity.length;
    updater.update(v, now: Epoch.zero);
    // No burn applied; node still pending.
    expect(v.state.velocity.length, closeTo(before, 1e-9));
    expect(v.flightPlan!.currentLeg!.nodes.length, 1);
  });

  test('the burn fires once the link is restored', () {
    final v = withDueBurn(commLink: false);
    updater.update(v, now: Epoch.zero); // blacked out -> held
    v.hasCommLink = true;
    updater.update(v, now: Epoch.zero); // link back -> fires
    expect(v.flightPlan!.isComplete, isTrue);
  });
}
