// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/autonomy/autopilot_updater.dart';
import 'package:acro_space_simulator/domain/autonomy/flight_plan.dart';
import 'package:acro_space_simulator/domain/orbits/pnr_basis.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

/// Burning while falling straight down.
///
/// On a radial trajectory the prograde vector is parallel to gravity, so the
/// orbit normal `r x v` is mathematically zero and numerically pure rounding
/// error — around 1e-6 at planetary scale. The old guard tested it against an
/// ABSOLUTE 1e-9, which sits BELOW that error, so it never fired: `normal` came
/// out as a normalised rounding error and `radial` followed it. Any node with a
/// normal or radial component then burned in an arbitrary direction, and the
/// craft left along a trajectory unrelated to the one that was planned.
void main() {
  final earth = SampleWorld.realSystem().require(SampleWorld.earth);

  /// A radial state that is NOT axis-aligned — which every real one is. Exactly
  /// on an axis the cross product cancels to a clean zero and hides the bug.
  ({Vector3 r, Vector3 v}) radialState({double speed = 1200}) {
    final d = Vector3(0.53, -0.41, 0.74).normalized;
    return (r: d * (earth.radius + 300000), v: d * -speed);
  }

  test('the basis is orthonormal even when the normal is undefined', () {
    final s = radialState();
    final b = pnrBasis(s.r, s.v);
    for (final u in [b.prograde, b.normal, b.radial]) {
      expect(u.length, closeTo(1.0, 1e-12), reason: 'unit');
    }
    expect(b.prograde.dot(b.normal).abs(), lessThan(1e-12));
    expect(b.prograde.dot(b.radial).abs(), lessThan(1e-12));
    expect(b.normal.dot(b.radial).abs(), lessThan(1e-12));
  });

  test('the basis does not swing on a numerical nudge', () {
    final s = radialState();
    final a = pnrBasis(s.r, s.v);
    // One part in 1e10 of velocity: physically the same trajectory.
    final b = pnrBasis(s.r, s.v * 1.0000000001);
    expect((b.normal - a.normal).length, lessThan(1e-9),
        reason: 'the normal must not depend on rounding error');
    expect((b.radial - a.radial).length, lessThan(1e-9));
  });

  test('a real orbit still uses its true orbit normal', () {
    // Circular: r perpendicular to v, so the normal is well defined and must be
    // the actual angular momentum direction, not the fallback.
    final r = Vector3(earth.radius + 400000, 0, 0);
    final v = Vector3(0, 7670, 0);
    final b = pnrBasis(r, v);
    expect((b.normal - Vector3(0, 0, 1)).length, lessThan(1e-9));
  });

  test('a radial burn on a radial trajectory goes where it was aimed', () {
    final s = radialState();
    final basis = pnrBasis(s.r, s.v);
    final vessel = SampleWorld.buildSurfaceCraft(earth, id: 'burner')
      ..landed = false
      ..updateState(StateVector(position: s.r, velocity: s.v));
    // 100 m/s of pure RADIAL delta-v — the component that used to fire into an
    // arbitrary direction.
    vessel.flightPlan = FlightPlan(vessel: vessel.id, legs: [
      FlightLeg(
        targetBody: earth.id,
        targetAltitude: 400000,
        nodes: [
          const ManeuverNode(
              executeAt: Epoch(0), deltaV: Vector3(0, 0, 100)),
        ],
      ),
    ]);
    const AutopilotUpdater().update(vessel, now: const Epoch(0));

    final dv = vessel.state.velocity - s.v;
    expect(dv.length, closeTo(100, 1e-6));
    // It went along the basis's radial axis, and that axis is perpendicular to
    // the fall line rather than pointing somewhere arbitrary.
    expect((dv.normalized - basis.radial).length, lessThan(1e-9));
    expect(dv.dot(s.v.normalized).abs(), lessThan(1e-6),
        reason: 'a radial burn adds nothing along prograde');
  });

  test('a prograde burn while falling straight down stays prograde', () {
    final s = radialState();
    final vessel = SampleWorld.buildSurfaceCraft(earth, id: 'burner2')
      ..landed = false
      ..updateState(StateVector(position: s.r, velocity: s.v));
    vessel.flightPlan = FlightPlan(vessel: vessel.id, legs: [
      FlightLeg(
        targetBody: earth.id,
        targetAltitude: 400000,
        nodes: [
          const ManeuverNode(
              executeAt: Epoch(0), deltaV: Vector3(50, 0, 0)),
        ],
      ),
    ]);
    const AutopilotUpdater().update(vessel, now: const Epoch(0));

    final dv = vessel.state.velocity - s.v;
    // Straight down the fall line: no sideways component at all.
    expect((dv.normalized - s.v.normalized).length, lessThan(1e-9));
  });
}
