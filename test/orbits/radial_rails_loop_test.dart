// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/orbits/state_vector_converter.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

/// A radial fall flown the way the SIM flies it: re-derived from the state
/// every tick.
///
/// radial_trajectory_test.dart converts once and evaluates the conic at a later
/// time, which a rectilinear orbit survives. The rails path does something
/// harder — state -> elements -> state, every tick — so any phase the round trip
/// loses is lost again immediately, and it compounds. On a near-radial
/// trajectory it used to compound to a standstill: the craft stopped descending
/// and hung in the air. The same zero-width degeneracy also gave it a sideways
/// shove, in whatever arbitrary plane the conversion had picked, which read in
/// the world as a craft falling dead straight suddenly veering off.
void main() {
  const conv = StateVectorOrbitConverter();
  final moon = SampleWorld.realSystem().require(SampleWorld.moon);
  final earth = SampleWorld.realSystem().require(SampleWorld.earth);

  /// One rails tick: elements from the live state, propagate, and back.
  ({Vector3 pos, Vector3 vel}) tick(
      CelestialBody body, Vector3 pos, Vector3 vel, double t, double dt) {
    final orbit =
        conv.toOrbit(position: pos, velocity: vel, body: body, epoch: Epoch(t));
    final s = conv.toStateVector(orbit, Epoch(t + dt));
    return (pos: s.position, vel: s.velocity);
  }

  ({Vector3 pos, Vector3 vel, double maxLateral}) fall(
      CelestialBody body, Vector3 v0, {int steps = 600, double dt = 0.1}) {
    final line = Vector3(1, 0, 0);
    var pos = Vector3(body.radius + 100000, 0, 0);
    var vel = v0;
    var t = 0.0;
    var maxLateral = 0.0;
    for (var i = 0; i < steps; i++) {
      final s = tick(body, pos, vel, t, dt);
      pos = s.pos;
      vel = s.vel;
      t += dt;
      final off = (pos - line * pos.dot(line)).length;
      if (off > maxLateral) maxLateral = off;
    }
    return (pos: pos, vel: vel, maxLateral: maxLateral);
  }

  for (final (name, body) in [('moon', moon), ('earth', earth)]) {
    test('on $name a straight-down fall keeps falling', () {
      final r = fall(body, const Vector3(-50, 0, 0));
      // 60 s of free fall from 100 km at 50 m/s. A craft anywhere near its
      // release altitude has frozen.
      final g = body.mu / (r.pos.length * r.pos.length);
      final expected = 100000 - 50 * 60 - 0.5 * g * 60 * 60;
      expect(r.pos.length - body.radius,
          closeTo(expected, 0.02 * expected.abs()));
      expect(r.vel.length, greaterThan(60), reason: 'still accelerating');
    });

    test('on $name it never leaves its own fall line', () {
      // ZERO, not "small". A straight-line fall has no sideways component to
      // round off; the metres-wide conic that stood in for one put the craft
      // off its line in an arbitrary plane.
      expect(fall(body, const Vector3(-50, 0, 0)).maxLateral, lessThan(1e-6));
    });
  }

  test('the handover holds across the whole near-radial band', () {
    // Cross-track from nothing up to a fifth of a metre per second: the band
    // where the general conic used to freeze solid.
    for (final cross in [0.0, 1e-3, 3e-3, 1e-2, 2e-2, 5e-2, 0.12]) {
      final r = fall(moon, Vector3(-50, cross, 0));
      final g = moon.mu / (r.pos.length * r.pos.length);
      final expected = 100000 - 50 * 60 - 0.5 * g * 60 * 60;
      expect(r.pos.length - moon.radius, closeTo(expected, 0.02 * expected.abs()),
          reason: 'froze with $cross m/s of cross-track');
    }
  });

  test('cross-track that is really there is kept', () {
    // The handover must not swallow motion the craft actually has.
    final r = fall(moon, const Vector3(-50, 20, 0));
    expect(r.pos.y, closeTo(20 * 60, 0.05 * 20 * 60));
  });

  test('a fast radial descent gets no sideways kick', () {
    // Fast enough to be an unbound conic: the hyperbolic branch carries the
    // same zero-width degeneracy as the elliptic one.
    final pos = Vector3(moon.radius + 20000, 0, 0);
    final s = tick(moon, pos, const Vector3(-2000, 0, 0), 0, 0.1);
    expect(s.pos.y.abs() + s.pos.z.abs(), lessThan(1e-6));
    expect(s.vel.y.abs() + s.vel.z.abs(), lessThan(1e-6));
  });

  test('a circular orbit is untouched by any of this', () {
    final r = earth.radius + 400000;
    final vCirc = math.sqrt(earth.mu / r);
    var pos = Vector3(r, 0, 0);
    var vel = Vector3(0, vCirc, 0);
    var t = 0.0;
    for (var i = 0; i < 600; i++) {
      final s = tick(earth, pos, vel, t, 1.0);
      pos = s.pos;
      vel = s.vel;
      t += 1.0;
    }
    expect(pos.length, closeTo(r, 1.0), reason: 'radius held');
    expect(vel.length, closeTo(vCirc, 0.01));
  });
}
