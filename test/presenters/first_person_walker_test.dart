// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/adapters/presenters/first_person_walker.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

/// The on-foot camera: a figure standing on a SPHERE, not on a plane. What is
/// pinned here is everything that separates the two —
///   * the eye rides terrain height + eye height, and gravity glues it there;
///   * motion is tangential, so looking at the sky never lifts you off the
///     ground and never slows the walk;
///   * a jump is Earth-calibrated legs under LOCAL gravity, so the Moon hop is
///     high and slow without any per-body tuning;
///   * the ground is sampled where you LAND, not where you left, so walking
///     into a hill climbs it instead of clipping through.
void main() {
  // A featureless 1000 km ball with 1.6 m/s² surface gravity (Moon-ish).
  const groundR = 1.0e6;
  double flatGround(Vector3 _) => groundR;
  const g = 1.62;

  Vector3 standing({double lift = 0}) =>
      Vector3(0, 0, groundR + walkEyeHeight + lift);
  // Camera looking north (+Y) along the tangent plane at the north pole... the
  // pole's up is +Z, so a level heading there is any horizontal direction.
  final fwdNorth = Vector3(0, 1, 0);
  final rightEast = Vector3(1, 0, 0);

  WalkStep step(
    Vector3 pos, {
    double vert = 0,
    bool grounded = true,
    double f = 0,
    double r = 0,
    bool jump = false,
    double dt = 1 / 60,
    Vector3? forward,
    double Function(Vector3)? ground,
    double speed = walkSpeed,
  }) =>
      stepFirstPersonWalk(
        posLocal: pos,
        vertVel: vert,
        grounded: grounded,
        forwardLocal: forward ?? fwdNorth,
        rightLocal: rightEast,
        moveForward: f,
        moveRight: r,
        jump: jump,
        dt: dt,
        gravity: g,
        groundRadiusAt: ground ?? flatGround,
        speed: speed,
      );

  test('standing still stays standing at exactly eye height', () {
    var s = step(standing());
    for (var i = 0; i < 120; i++) {
      s = step(s.posLocal, vert: s.vertVel, grounded: s.grounded);
    }
    expect(s.grounded, isTrue);
    expect(s.posLocal.length - groundR, closeTo(walkEyeHeight, 1e-9));
    expect(s.vertVel, 0);
  });

  test('a step off a cliff falls, and lands on the lower ground', () {
    // Ground drops 50 m past 10 m of northing.
    double cliff(Vector3 p) => p.y > 10 ? groundR - 50 : groundR;
    var s = step(standing(), f: 1, ground: cliff, speed: 20);
    var fell = false;
    for (var i = 0; i < 600; i++) {
      s = step(s.posLocal,
          vert: s.vertVel, grounded: s.grounded, f: 1, ground: cliff, speed: 20);
      if (!s.grounded) fell = true;
    }
    expect(fell, isTrue, reason: 'walking off the edge must leave the ground');
    expect(s.grounded, isTrue, reason: 'and must land again');
    expect(s.posLocal.length, closeTo(groundR - 50 + walkEyeHeight, 1e-6));
  });

  test('walking into a rising slope climbs it (ground sampled where you land)',
      () {
    // 1-in-2 ramp starting at y = 0: sampling the OLD position would leave the
    // eye buried in the hillside.
    double ramp(Vector3 p) => groundR + math.max(0.0, p.y) * 0.5;
    var s = step(standing(), f: 1, ground: ramp);
    for (var i = 0; i < 300; i++) {
      s = step(s.posLocal,
          vert: s.vertVel, grounded: s.grounded, f: 1, ground: ramp);
      final expected = ramp(s.posLocal) + walkEyeHeight;
      expect(s.posLocal.length, greaterThanOrEqualTo(expected - 1e-6),
          reason: 'eye must never sink into the slope');
    }
    expect(s.posLocal.y, greaterThan(1.0), reason: 'and it must make progress');
  });

  test('pace is the commanded speed, and diagonals are not faster', () {
    const dt = 0.5;
    final straight = step(standing(), f: 1, dt: dt);
    final diagonal = step(standing(), f: 1, r: 1, dt: dt);
    final dStraight = (straight.posLocal - standing()).length;
    final dDiagonal = (diagonal.posLocal - standing()).length;
    expect(dStraight, closeTo(walkSpeed * dt, 1e-3));
    expect(dDiagonal, closeTo(walkSpeed * dt, 1e-3));
  });

  test('looking at the sky does not slow the walk or lift the eye', () {
    const dt = 0.5;
    final level = step(standing(), f: 1, dt: dt);
    // Steeply up: 20 degrees of heading left in the tangent plane.
    final up = Vector3(0, math.sin(20 * math.pi / 180), math.cos(20 * math.pi / 180));
    final tilted = step(standing(), f: 1, dt: dt, forward: up);
    expect((tilted.posLocal - standing()).length,
        closeTo((level.posLocal - standing()).length, 1e-9));
    expect(tilted.posLocal.length, closeTo(groundR + walkEyeHeight, 1e-9));
    expect(tilted.grounded, isTrue);
  });

  test('looking straight down still walks — the heading comes from right', () {
    final downward = step(standing(), f: 1, dt: 0.5, forward: Vector3(0, 0, -1));
    expect((downward.posLocal - standing()).length, closeTo(walkSpeed * 0.5, 1e-6));
  });

  test('a jump leaves the ground and comes back, higher under low gravity', () {
    double apex(double gravity) {
      var s = stepFirstPersonWalk(
        posLocal: standing(),
        vertVel: 0,
        grounded: true,
        forwardLocal: fwdNorth,
        rightLocal: rightEast,
        moveForward: 0,
        moveRight: 0,
        jump: true,
        dt: 1 / 60,
        gravity: gravity,
        groundRadiusAt: flatGround,
      );
      var high = s.posLocal.length;
      for (var i = 0; i < 2000 && !s.grounded; i++) {
        s = stepFirstPersonWalk(
          posLocal: s.posLocal,
          vertVel: s.vertVel,
          grounded: s.grounded,
          forwardLocal: fwdNorth,
          rightLocal: rightEast,
          moveForward: 0,
          moveRight: 0,
          jump: false, // held-space must not re-fire mid-air
          dt: 1 / 60,
          gravity: gravity,
          groundRadiusAt: flatGround,
        );
        high = math.max(high, s.posLocal.length);
      }
      expect(s.grounded, isTrue, reason: 'what goes up must come down');
      expect(s.posLocal.length, closeTo(groundR + walkEyeHeight, 1e-6));
      return high - (groundR + walkEyeHeight);
    }

    final earth = apex(9.80665);
    final moon = apex(1.62);
    expect(earth, closeTo(walkJumpHeightEarth, 0.05));
    expect(moon, greaterThan(earth * 4),
        reason: 'the same legs clear far more in one sixth g');
  });

  test('jump is unavailable in mid-air (no double jump)', () {
    final airborne = step(standing(lift: 20), vert: 0, grounded: false, jump: true);
    expect(airborne.vertVel, lessThan(0), reason: 'gravity only, no impulse');
  });

  test('degenerate inputs are no-ops rather than NaN', () {
    final atCentre = step(Vector3.zero, f: 1);
    expect(atCentre.posLocal.length, 0);
    final noTime = step(standing(), f: 1, dt: 0);
    expect(noTime.posLocal.length, closeTo(groundR + walkEyeHeight, 1e-9));
  });
}
