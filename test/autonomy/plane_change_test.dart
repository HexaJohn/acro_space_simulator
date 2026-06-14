import 'dart:math' as math;

import 'package:acro_space_simulator/domain/autonomy/maneuver_planner.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const planner = ManeuverPlanner();
  const mu = 3.5316e12;

  test('plane-change delta-v matches 2 v sin(di/2), in the normal axis', () {
    final r = 700000.0;
    final v = math.sqrt(mu / r);
    final di = 0.3; // rad
    final node = planner.planeChange(
      orbitalSpeed: v,
      inclinationChange: di,
      atEpoch: const Epoch(5),
    );
    final expected = 2 * v * math.sin(di / 2);
    // Burn is purely normal (y component); no prograde/radial.
    expect(node.deltaV.y, closeTo(expected, 1e-6));
    expect(node.deltaV.x, 0);
    expect(node.deltaV.z, 0);
    expect(node.executeAt.seconds, 5);
  });

  test('zero inclination change costs zero delta-v', () {
    final node = planner.planeChange(
      orbitalSpeed: 2000,
      inclinationChange: 0,
      atEpoch: Epoch.zero,
    );
    expect(node.magnitude, closeTo(0, 1e-9));
  });

  test('a combined Hohmann + plane change returns three nodes', () {
    final nodes = planner.hohmannWithPlaneChange(
      mu: mu,
      fromRadius: 700000,
      toRadius: 900000,
      inclinationChange: 0.2,
      startEpoch: Epoch.zero,
    );
    expect(nodes.length, 3);
    // The plane change is the last burn (at the destination), purely normal.
    expect(nodes.last.deltaV.y.abs(), greaterThan(0));
    expect(nodes.last.deltaV.x, 0);
  });
}
