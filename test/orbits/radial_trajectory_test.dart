// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/orbits/state_vector_converter.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

/// A rectilinear (radial) trajectory has zero angular momentum, so it has no
/// orbital plane and its true anomaly carries no position. The converter used
/// to answer that by handing back a CIRCULAR orbit at the current radius, which
/// meant a craft dropped straight at an airless body never descended — it
/// silently entered orbit at its release altitude and hung there.
void main() {
  const converter = StateVectorOrbitConverter();
  final moon = SampleWorld.realSystem().require(SampleWorld.moon);
  final earth = SampleWorld.realSystem().require(SampleWorld.earth);

  /// Propagate a state forward by [seconds] through the element set.
  ({Vector3 position, Vector3 velocity}) rails(
    Vector3 position,
    Vector3 velocity,
    double seconds, {
    dynamic body,
  }) {
    final b = body ?? moon;
    final orbit = converter.toOrbit(
      position: position,
      velocity: velocity,
      body: b,
      epoch: Epoch.zero,
    );
    final s = converter.toStateVector(orbit, Epoch(seconds));
    return (position: s.position, velocity: s.velocity);
  }

  group('a craft dropped straight down', () {
    final start = Vector3(moon.radius + 50000, 0, 0);
    const drop = Vector3(-300, 0, 0);

    test('descends instead of entering orbit', () {
      final after = rails(start, drop, 10);
      expect(after.position.length, lessThan(start.length),
          reason: 'it should have fallen');
      // Regression: the old fallback pinned the radius and swapped the radial
      // velocity for the circular speed at that radius.
      expect(after.velocity.length, isNot(closeTo(math.sqrt(moon.mu / start.length), 1)));
    });

    test('stays on the radial line it was dropped along', () {
      for (final t in [1.0, 10.0, 60.0, 200.0]) {
        final after = rails(start, drop, t);
        final off = (after.position - start.normalized * after.position.length).length;
        expect(off, lessThan(1.0),
            reason: 'drifted $off m off the radial after ${t}s');
      }
    });

    test('matches free fall over a short step', () {
      // Over one tick the exact conic and constant-acceleration agree closely.
      const dt = 0.5;
      final g = moon.mu / (start.length * start.length);
      final expected = start.length - 300 * dt - 0.5 * g * dt * dt;
      expect(rails(start, drop, dt).position.length, closeTo(expected, 0.5));
    });

    test('speeds up as it falls', () {
      final a = rails(start, drop, 5).velocity.length;
      final b = rails(start, drop, 60).velocity.length;
      expect(a, greaterThan(300));
      expect(b, greaterThan(a));
    });

    test('reaches the surface', () {
      // Keep stepping until it is below the datum; it must get there.
      var hit = false;
      for (var t = 0.0; t <= 1200; t += 10) {
        if (rails(start, drop, t).position.length <= moon.radius) {
          hit = true;
          break;
        }
      }
      expect(hit, isTrue, reason: 'a dropped craft must reach the ground');
    });

    test('reports a real conic, not a circle', () {
      final orbit = converter.toOrbit(
        position: start,
        velocity: drop,
        body: moon,
        epoch: Epoch.zero,
      );
      // Rectilinear: periapsis at the centre, apoapsis above the release point.
      expect(orbit.elements.eccentricity, closeTo(1.0, 1e-9));
      expect(orbit.periapsis, lessThan(1.0));
      expect(orbit.apoapsis, greaterThan(start.length));
      expect(orbit.period.isFinite, isTrue);
      expect(orbit.elements.semiMajorAxis, greaterThan(0));
    });
  });

  test('a craft thrown straight up comes back down', () {
    final start = Vector3(0, moon.radius + 1000, 0);
    const up = Vector3(0, 400, 0);
    final peak = rails(start, up, 200).position.length;
    expect(peak, greaterThan(start.length), reason: 'still rising at 200 s');
    // Ballistic apex for 400 m/s under ~1.62 m/s^2 is ~250 s up, ~500 s round
    // trip, so by 900 s it is back below the release altitude.
    expect(rails(start, up, 900).position.length, lessThan(start.length));
  });

  test('a radial escape keeps climbing and stays hyperbolic', () {
    final start = Vector3(0, 0, moon.radius + 1000);
    // Escape speed here is ~2.37 km/s.
    const out = Vector3(0, 0, 3000);
    final orbit = converter.toOrbit(
      position: start,
      velocity: out,
      body: moon,
      epoch: Epoch.zero,
    );
    expect(orbit.elements.semiMajorAxis, lessThan(0), reason: 'unbound');
    expect(orbit.elements.eccentricity, greaterThanOrEqualTo(1.0));
    var previous = start.length;
    for (final t in [10.0, 100.0, 1000.0]) {
      final r = rails(start, out, t).position.length;
      expect(r, greaterThan(previous));
      previous = r;
    }
  });

  test('works off-axis and on a different body', () {
    final dir = const Vector3(0.42, -0.58, 0.70).normalized;
    final start = dir * (earth.radius + 200000);
    final after = rails(start, dir * -500, 20, body: earth);
    expect(after.position.length, lessThan(start.length));
    expect((after.position.normalized - dir).length, lessThan(1e-6),
        reason: 'must fall along its own radial, not drift to another');
  });

  test('a polar drop does not degenerate', () {
    // +Z is where the synthesised orbital plane has to pick its fallback: the
    // usual r x Z is zero there.
    final start = Vector3(0, 0, moon.radius + 20000);
    final after = rails(start, const Vector3(0, 0, -250), 30);
    expect(after.position.length, lessThan(start.length));
    expect(after.position.x.abs(), lessThan(1.0));
    expect(after.position.y.abs(), lessThan(1.0));
    expect(after.position.z, greaterThan(0));
  });

  group('near-radial trajectories', () {
    // Not exactly radial, but eccentric enough that `e` rounds to 1.0 while the
    // orbit is still bound. Those used to take the hyperbolic branch, which
    // assumes a < 0 and returns negative radii.
    test('stay bound and keep descending', () {
      final start = Vector3(moon.radius + 50000, 0, 0);
      for (final sideways in [1e-6, 1e-3, 0.1, 1.0]) {
        final v = Vector3(-300, sideways, 0);
        final orbit = converter.toOrbit(
          position: start,
          velocity: v,
          body: moon,
          epoch: Epoch.zero,
        );
        expect(orbit.elements.semiMajorAxis, greaterThan(0),
            reason: 'bound at sideways=$sideways');
        expect(orbit.elements.eccentricity, lessThan(1.0),
            reason: 'e must agree with a at sideways=$sideways');
        final after = rails(start, v, 10);
        expect(after.position.length.isFinite, isTrue);
        expect(after.position.length, lessThan(start.length),
            reason: 'descending at sideways=$sideways');
      }
    });
  });

  test('ordinary orbits are untouched by the fix', () {
    // A circular orbit still round-trips: the guard must not have widened into
    // the normal path.
    final r = Vector3(moon.radius + 100000, 0, 0);
    final vCirc = Vector3(0, math.sqrt(moon.mu / r.length), 0);
    final orbit = converter.toOrbit(
      position: r,
      velocity: vCirc,
      body: moon,
      epoch: Epoch.zero,
    );
    expect(orbit.elements.eccentricity, closeTo(0, 1e-6));
    final quarter = converter.toStateVector(orbit, Epoch(orbit.period / 4));
    expect(quarter.position.length, closeTo(r.length, 1));
    expect(quarter.position.y, greaterThan(0), reason: 'moved prograde');
  });
}
