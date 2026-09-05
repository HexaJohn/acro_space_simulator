// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/adapters/presenters/rover_buggy.dart';
import 'package:flutter_test/flutter_test.dart';

/// The dune buggy: a sprung body on a height field. What is pinned here —
///   * parked, it stays parked: the resting constructor settles the springs
///     and a second of integration does not make it drift or bounce;
///   * throttle moves it along its heading, steering turns that heading, and
///     letting go coasts it to a stop;
///   * a hill under the front wheels compresses the front springs and pitches
///     the nose up; a slope rolls it back with no throttle;
///   * a cliff puts it in the air, gravity brings it down, and the landing is
///     reported once per wheel;
///   * dust is nothing at rest and something on the move.
void main() {
  const g = 9.81;
  const spec = RoverSpec();
  double flat(double e, double n) => 0;

  RoverState parked({double yaw = 0, double Function(double, double)? ground}) =>
      RoverState.resting(
        e: 0,
        n: 0,
        yaw: yaw,
        groundHeight: (ground ?? flat)(0, 0),
        gravity: g,
      );

  void run(RoverState s, RoverInput input, double seconds,
      {double Function(double, double)? ground, double dt = 1 / 60}) {
    final steps = (seconds / dt).round();
    for (var i = 0; i < steps; i++) {
      stepRover(s, input, dt: dt, gravity: g, heightAt: ground ?? flat);
    }
  }

  test('parked on the flat it sits still with all four wheels down', () {
    final s = parked();
    final h0 = s.height;
    run(s, RoverInput.none, 2.0);
    expect(s.wheelsDown, 4);
    expect(s.speed, 0);
    expect(s.e, 0);
    expect(s.n, 0);
    expect(s.height, closeTo(h0, 1e-3),
        reason: 'the resting constructor must match the integrator\'s '
            'own equilibrium — a mismatch is a bounce on entry');
    expect(s.pitch.abs(), lessThan(1e-3));
    expect(s.roll.abs(), lessThan(1e-3));
    for (final c in s.compression) {
      expect(c, closeTo(spec.staticCompression(g), 1e-3));
    }
    expect(s.dust.every((d) => d == 0), isTrue);
  });

  test('throttle drives it north, and the wheels turn with the ground', () {
    final s = parked();
    run(s, const RoverInput(throttle: 1), 3.0);
    expect(s.speed, greaterThan(8));
    expect(s.speed, lessThan(spec.topSpeedMs));
    expect(s.n, greaterThan(10));
    expect(s.e.abs(), lessThan(1e-6), reason: 'yaw 0 is due north');
    expect(s.wheelSpin[0], greaterThan(0));
    expect(s.dust.every((d) => d > 0), isTrue);
    // Full throttle squats the tail: nose up.
    expect(s.pitch, greaterThan(0));
  });

  test('flat out it tops out, and coasting stops it', () {
    final s = parked();
    run(s, const RoverInput(throttle: 1), 40.0);
    expect(s.speed, closeTo(spec.topSpeedMs, spec.topSpeedMs * 0.3));
    final v = s.speed;
    run(s, RoverInput.none, 60.0);
    expect(s.speed, 0, reason: 'rolling resistance and drag stop it dead');
    expect(s.n, greaterThan(v * 5), reason: 'it rolled on a good way first');
  });

  test('brake stops it fast and never reverses it', () {
    final s = parked();
    run(s, const RoverInput(throttle: 1), 5.0);
    expect(s.speed, greaterThan(10));
    run(s, const RoverInput(brake: true), 3.0);
    expect(s.speed, 0);
  });

  test('steering right turns the heading toward east', () {
    final s = parked();
    run(s, const RoverInput(throttle: 1, steer: 1), 4.0);
    expect(s.yaw, greaterThan(0.5));
    expect(s.e, greaterThan(1));
    expect(s.roll, lessThan(0), reason: 'a right turn leans the body left');
    // Let go of the stick: the wheels centre and the yaw rate dies.
    run(s, const RoverInput(throttle: 1), 1.0);
    expect(s.steer.abs(), lessThan(1e-3));
    expect(s.yawRate.abs(), lessThan(1e-3));
  });

  test('a hard turn at speed is held to tyre grip, on four wheels', () {
    final s = parked();
    run(s, const RoverInput(throttle: 1), 6.0);
    expect(s.speed, greaterThan(14));
    var maxLatG = 0.0;
    var minWheels = 4;
    for (var i = 0; i < 60 * 3; i++) {
      stepRover(s, const RoverInput(throttle: 1, steer: 1),
          dt: 1 / 60, gravity: g, heightAt: flat);
      maxLatG = math.max(maxLatG, (s.speed * s.yawRate).abs() / g);
      minWheels = math.min(minWheels, s.wheelsDown);
    }
    expect(maxLatG, lessThanOrEqualTo(spec.gripG + 0.02),
        reason: 'the bicycle model must not corner harder than the tyres');
    expect(minWheels, 4, reason: 'no wheel lifts at 0.9 g');
    expect(s.roll.abs(), lessThan(0.1));
    expect(s.dust[0], greaterThan(0.5), reason: 'sliding tyres throw dust');
  });

  test('a step under the front wheels pitches the nose up onto it', () {
    // A 0.15 m kerb across the front axle's ground only. Parked flat, the
    // buggy finds the kerb the moment it is integrated.
    double kerb(double e, double n) => n > 0.5 ? 0.15 : 0.0;
    final s = parked();
    // The FIRST frame: the kerb loads the front springs before the body has
    // had time to tilt onto it.
    stepRover(s, RoverInput.none, dt: 1 / 60, gravity: g, heightAt: kerb);
    expect(s.compression[0], greaterThan(s.compression[2]),
        reason: 'front-left rides the kerb, rear-left does not');
    expect(s.compression[1], greaterThan(s.compression[3]));
    // Settled: the body has tilted onto the ground plane and the springs
    // share the weight again — a tilted body, not a permanently squashed
    // front.
    run(s, RoverInput.none, 4.0, ground: kerb);
    expect(s.wheelsDown, 4);
    expect(s.pitch, closeTo(math.atan(0.15 / spec.wheelBaseM), 0.01),
        reason: 'the body follows the ground plane, no more, no less');
    for (final c in s.compression) {
      expect(c, closeTo(spec.staticCompression(g), 5e-3));
    }
  });

  test('a slope rolls it backward with no throttle', () {
    // Climbing north: ground rises 1 m per 8 m — about 7 degrees.
    double hill(double e, double n) => n / 8;
    final s = parked(ground: hill);
    run(s, RoverInput.none, 3.0, ground: hill);
    expect(s.speed, lessThan(-1));
    expect(s.n, lessThan(-1));
  });

  test('driving off a cliff goes airborne, falls, and lands once', () {
    double cliff(double e, double n) => n > 20 ? -6.0 : 0.0;
    final s = parked(ground: cliff);
    var sawAir = false;
    var landings = 0;
    var maxAir = 0.0;
    for (var i = 0; i < 60 * 8; i++) {
      stepRover(s, const RoverInput(throttle: 1),
          dt: 1 / 60, gravity: g, heightAt: cliff);
      if (!s.grounded) sawAir = true;
      if (s.airTime > maxAir) maxAir = s.airTime;
      landings += s.landing.where((l) => l > 0).length;
    }
    expect(sawAir, isTrue, reason: 'a 6 m drop at speed leaves the ground');
    expect(maxAir, greaterThan(0.3));
    // Every wheel reports its touchdown; a drop that hard bottoms the springs
    // and bounces, so a second round is allowed — a stream of them is not.
    expect(landings, inInclusiveRange(4, 12),
        reason: 'one report per wheel per touchdown');
    expect(s.grounded, isTrue, reason: 'it came back down');
    expect(s.height, closeTo(-6.0 + spec.restMountHeight(g), 0.3));
    expect(s.pitch.abs(), lessThan(0.15), reason: 'landed on its wheels');
  });

  test('a stalled frame is clamped: no launch from a long dt', () {
    final s = parked();
    stepRover(s, const RoverInput(throttle: 1),
        dt: 3.0, gravity: g, heightAt: flat);
    expect(s.speed, lessThan(2));
    expect(s.n, lessThan(0.5));
    expect(s.height.isFinite, isTrue);
  });

  test('wrapAngle folds a turn into a half-turn either way', () {
    expect(wrapAngle(0.1), closeTo(0.1, 1e-12));
    expect(wrapAngle(2 * math.pi + 0.1), closeTo(0.1, 1e-12));
    expect(wrapAngle(-2 * math.pi - 0.1), closeTo(-0.1, 1e-12));
    expect(wrapAngle(math.pi + 0.5), closeTo(-math.pi + 0.5, 1e-12));
  });
}
