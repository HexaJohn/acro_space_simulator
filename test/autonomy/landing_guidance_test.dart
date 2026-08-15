// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/autonomy/landing_guidance.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

/// Colony shuttles fly a real powered descent onto a real pad, so these fly one
/// in a plain integrator and check where it ends up.
void main() {
  const guidance = LandingGuidance();

  // A small airless moon: strong enough gravity to matter, no drag to hide
  // guidance errors behind.
  const bodyRadius = 600000.0;
  const mu = 6.0e11; // g ~= 1.67 m/s^2 at the surface

  /// Fly [steps] of powered descent and report where it finished.
  ({
    Vector3 pos,
    Vector3 vel,
    LandingPhase phase,
    double fuel,
    double crossRange,
  }) fly({
    required Vector3 pos,
    required Vector3 vel,
    required Vector3 pad,
    double dryMass = 4000,
    double fuel = 6000,
    double maxThrust = 90000,
    double exhaustVelocity = 3000,
    double dt = 0.05,
    int maxSteps = 400000,
  }) {
    var p = pos, v = vel, f = fuel;
    var phase = LandingPhase.coast;
    var crossRange = 0.0;
    for (var i = 0; i < maxSteps; i++) {
      final mass = dryMass + f;
      final cmd = guidance.command(
        posBF: p,
        velBF: v,
        padBF: pad,
        mu: mu,
        mass: mass,
        maxThrust: maxThrust,
      );
      phase = cmd.phase;
      crossRange = cmd.crossRangeM;
      if (cmd.isDown || phase == LandingPhase.unrecoverable) break;

      final throttle = f > 0 ? cmd.throttle : 0.0;
      final thrust = cmd.facing * (maxThrust * throttle);
      final g = p.normalized * (-mu / p.lengthSquared);
      final a = g + thrust * (1 / mass);
      v = v + a * dt;
      p = p + v * dt;
      f = math.max(0.0, f - maxThrust * throttle / exhaustVelocity * dt);

      // Ground.
      if (p.length <= pad.length) break;
    }
    return (pos: p, vel: v, phase: phase, fuel: f, crossRange: crossRange);
  }

  Vector3 surfacePoint(double lonRad) => Vector3(
        bodyRadius * math.cos(lonRad),
        bodyRadius * math.sin(lonRad),
        0,
      );

  test('a vertical drop lands softly on the pad', () {
    final pad = surfacePoint(0);
    final start = pad.normalized * (bodyRadius + 6000);

    final r = fly(pos: start, vel: Vector3.zero, pad: pad);

    expect(r.phase, LandingPhase.touchdown);
    expect(r.vel.length, lessThan(4),
        reason: 'must arrive at walking pace, not crater');
    expect(r.crossRange, lessThan(20));
    expect(r.fuel, greaterThan(0));
  });

  test('a suborbital arrival kills its horizontal speed and hits the pad', () {
    final pad = surfacePoint(0);
    // 8 km up, 12 km downrange, closing on the pad at 250 m/s — a arrival the
    // vehicle can actually stop from (250^2 / 2a is ~4 km of braking).
    final start = surfacePoint(-0.02).normalized * (bodyRadius + 8000);
    final east = Vector3(-start.normalized.y, start.normalized.x, 0);
    final vel = east * 250;

    final r = fly(pos: start, vel: vel, pad: pad);

    expect(r.phase, LandingPhase.touchdown);
    expect(r.vel.length, lessThan(5));
    expect(r.crossRange, lessThan(120),
        reason: 'the braking burn is biased toward the pad');
  });

  test('the braking burn starts late, not immediately', () {
    final pad = surfacePoint(0);
    final start = pad.normalized * (bodyRadius + 30000);

    // High up and barely moving, the engine stays off.
    final early = guidance.command(
      posBF: start,
      velBF: Vector3.zero,
      padBF: pad,
      mu: mu,
      mass: 10000,
      maxThrust: 90000,
    );
    expect(early.phase, LandingPhase.coast);
    expect(early.throttle, 0);

    // Falling fast and low, it commits.
    final late = guidance.command(
      posBF: pad.normalized * (bodyRadius + 1500),
      velBF: pad.normalized * -230,
      padBF: pad,
      mu: mu,
      mass: 10000,
      maxThrust: 90000,
    );
    expect(late.phase, LandingPhase.brake);
    expect(late.throttle, 1);
    // Thrust opposes the fall.
    expect(late.facing.dot(pad.normalized), greaterThan(0.9));
  });

  test('a vehicle that cannot outfight gravity is flagged, not flown', () {
    final pad = surfacePoint(0);
    final cmd = guidance.command(
      posBF: pad.normalized * (bodyRadius + 3000),
      velBF: pad.normalized * -100,
      padBF: pad,
      mu: mu,
      mass: 100000, // 1.67 m/s^2 needed, 0.9 available
      maxThrust: 90000,
    );
    expect(cmd.phase, LandingPhase.unrecoverable);
  });

  test('an orbiting shuttle deorbits before it descends', () {
    final pad = surfacePoint(0);
    final r = bodyRadius + 120000;
    final pos = Vector3(r, 0, 0);
    final circular = math.sqrt(mu / r);
    final cmd = guidance.command(
      posBF: pos,
      velBF: Vector3(0, circular, 0),
      padBF: pad,
      mu: mu,
      mass: 10000,
      maxThrust: 90000,
    );

    expect(cmd.phase, LandingPhase.deorbit);
    expect(cmd.throttle, 1);
    // Retrograde: against the orbital motion.
    expect(cmd.facing.dot(Vector3(0, 1, 0)), lessThan(-0.9));
  });

  test('guidance closes cross-range instead of landing beside the pad', () {
    final pad = surfacePoint(0);
    // 200 m up, descending on profile, but 900 m off to the side.
    final off = surfacePoint(0.0015).normalized * (bodyRadius + 200);
    final cmd = guidance.command(
      posBF: off,
      velBF: off.normalized * -36,
      padBF: pad,
      mu: mu,
      mass: 10000,
      maxThrust: 90000,
    );

    expect(cmd.phase, LandingPhase.terminal);
    expect(cmd.crossRangeM, greaterThan(800));
    // Thrust tilts toward the pad.
    final toPad = (pad - off);
    final up = off.normalized;
    final lateral = (toPad - up * toPad.dot(up)).normalized;
    expect(cmd.facing.dot(lateral), greaterThan(0.05));
    expect(cmd.facing.dot(up), greaterThan(0.5), reason: 'still holding it up');
  });
}
