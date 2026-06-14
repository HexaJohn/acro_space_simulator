import 'dart:math' as math;

import 'package:acro_space_simulator/domain/autonomy/maneuver_planner.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const planner = ManeuverPlanner();
  const mu = 3.5316e12; // Kerbin

  test('Hohmann from 100km to 200km gives two positive prograde burns', () {
    final r1 = 600000 + 100000.0;
    final r2 = 600000 + 200000.0;
    final plan = planner.hohmann(
      mu: mu,
      fromRadius: r1,
      toRadius: r2,
      startEpoch: Epoch.zero,
    );

    expect(plan.length, 2);
    // Raising orbit: first burn prograde (+), arrival burn prograde (+).
    expect(plan[0].deltaV.x, greaterThan(0));
    expect(plan[1].deltaV.x, greaterThan(0));

    // Second node executes half a transfer period after the first.
    final at = (r1 + r2) / 2;
    final tHalf = math.pi * math.sqrt(at * at * at / mu);
    expect(plan[1].executeAt.seconds - plan[0].executeAt.seconds,
        closeTo(tHalf, 1));
  });

  test('Hohmann delta-v magnitudes match the closed-form values', () {
    final r1 = 700000.0;
    final r2 = 900000.0;
    final at = (r1 + r2) / 2;
    final dv1 = math.sqrt(mu / r1) * (math.sqrt(2 * r2 / (r1 + r2)) - 1);
    final dv2 = math.sqrt(mu / r2) * (1 - math.sqrt(2 * r1 / (r1 + r2)));

    final plan = planner.hohmann(
      mu: mu,
      fromRadius: r1,
      toRadius: r2,
      startEpoch: Epoch.zero,
    );
    expect(plan[0].deltaV.x, closeTo(dv1, 1e-3));
    expect(plan[1].deltaV.x, closeTo(dv2, 1e-3));
    // sanity: at used
    expect(at, closeTo(800000, 1e-6));
  });

  test('lowering orbit: burns are retrograde (negative prograde)', () {
    final plan = planner.hohmann(
      mu: mu,
      fromRadius: 900000,
      toRadius: 700000,
      startEpoch: Epoch.zero,
    );
    expect(plan[0].deltaV.x, lessThan(0));
    expect(plan[1].deltaV.x, lessThan(0));
  });

  test('circularization burn nulls the radial speed difference to circular', () {
    final r = 800000.0;
    final vCirc = math.sqrt(mu / r);
    // Currently moving slower than circular -> needs a prograde burn.
    final node = planner.circularize(
      mu: mu,
      radius: r,
      currentSpeed: vCirc - 50,
      atEpoch: const Epoch(10),
    );
    expect(node.deltaV.x, closeTo(50, 1e-6));
    expect(node.executeAt.seconds, 10);
  });
}
