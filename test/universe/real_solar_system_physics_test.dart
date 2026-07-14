// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/orbits/body_ephemeris.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final system = RealSolarSystem.build();

  test('a low Earth orbit has a ~90 minute period', () {
    final earth = system.require(const BodyId('earth'));
    final r = earth.radius + 400000; // 400 km, like the ISS
    final period = 2 * math.pi * math.sqrt(r * r * r / earth.mu);
    expect(period / 60, closeTo(92.5, 2.0)); // ~92.5 minutes
  });

  test("Earth's orbital period about the Sun is ~1 year", () {
    final sun = system.require(const BodyId('sun'));
    final earth = system.require(const BodyId('earth'));
    final a = earth.orbitRadius;
    final period = 2 * math.pi * math.sqrt(a * a * a / sun.mu);
    expect(period / (365.25 * 86400), closeTo(1.0, 0.02)); // within 2%
  });

  test('the ephemeris places the Moon at the right distance from Earth', () {
    const ephemeris = BodyEphemeris();
    final moon = system.require(const BodyId('moon'));
    final pos = ephemeris.positionRelativeToParent(moon, system, Epoch.zero);
    expect(pos.length, closeTo(moon.orbitRadius, moon.orbitRadius * 0.06));
  });
}
