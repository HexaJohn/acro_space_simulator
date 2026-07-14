// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/orbits/state_vector_converter.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/epoch.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:flutter_test/flutter_test.dart';

/// Hyperbolic (escape) trajectories on rails. The elliptical-only Kepler
/// solver produced NaN for e >= 1 (sqrt(1 - e^2)), and the tick's NaN guard
/// then froze the vessel every tick — "the sim just stops" once AP reads
/// infinity. These tests pin the hyperbolic propagation path.
void main() {
  const conv = StateVectorOrbitConverter();
  final earth = CelestialBody(
    id: const BodyId('earth'),
    name: 'Earth',
    mu: 3.986e14,
    radius: 6371000,
    soiRadius: 9.24e8,
    siderealRotationPeriod: 86164,
    parent: null,
  );

  /// Escape state: 1.3x escape speed, prograde, at 3000 km altitude —
  /// e > 1, AP infinite, PE below the surface for a suitably flat angle.
  (Vector3, Vector3) escapeState() {
    final r = earth.radius + 3000000;
    final vEsc = math.sqrt(2 * earth.mu / r);
    return (Vector3(r, 0, 0), Vector3(0, 1.3 * vEsc, 0));
  }

  test('hyperbolic toOrbit classifies the conic (e > 1, AP infinite)', () {
    final (pos, vel) = escapeState();
    final orbit =
        conv.toOrbit(position: pos, velocity: vel, body: earth, epoch: Epoch.zero);
    expect(orbit.elements.eccentricity, greaterThan(1.0));
    expect(orbit.elements.semiMajorAxis, lessThan(0.0));
    expect(orbit.apoapsis, double.infinity);
  });

  test('hyperbolic round-trip returns the anchor state', () {
    final (pos, vel) = escapeState();
    final orbit =
        conv.toOrbit(position: pos, velocity: vel, body: earth, epoch: Epoch.zero);
    final s = conv.toStateVector(orbit, Epoch.zero);
    expect((s.position - pos).length, lessThan(pos.length * 1e-6));
    expect((s.velocity - vel).length, lessThan(vel.length * 1e-6));
  });

  test('hyperbolic on-rails advances every tick (does not freeze)', () {
    var (pos, vel) = escapeState();
    var epochS = 0.0;
    const step = 200.0;

    // Re-derive the orbit from state each step and propagate forward —
    // exactly what AdvanceSimulationTick._onRails does on rails.
    for (var i = 0; i < 20; i++) {
      final orbit = conv.toOrbit(
          position: pos, velocity: vel, body: earth, epoch: Epoch(epochS));
      final s = conv.toStateVector(orbit, Epoch(epochS + step));
      expect(s.position.x.isFinite && s.position.y.isFinite && s.position.z.isFinite,
          isTrue,
          reason: 'NaN position at step $i');
      // Escaping: radius must strictly grow, meaningfully (v > v_esc).
      expect(s.position.length, greaterThan(pos.length + 1000),
          reason: 'frozen at step $i');
      pos = s.position;
      vel = s.velocity;
      epochS += step;
    }

    // Energy conservation across the whole re-anchored chain.
    final e0 = _energy(escapeState().$2, escapeState().$1, earth.mu);
    final e1 = _energy(vel, pos, earth.mu);
    expect((e1 - e0).abs() / e0.abs(), lessThan(1e-6));
  });

  test('inbound hyperbola falls toward periapsis (M < 0 branch)', () {
    // Same conic flipped: moving toward the planet (r dot v < 0).
    final r = earth.radius + 8000000;
    final vEsc = math.sqrt(2 * earth.mu / r);
    final pos = Vector3(r, 0, 0);
    final vel = Vector3(-0.9 * vEsc, 0.9 * vEsc, 0); // inbound + sideways
    final orbit =
        conv.toOrbit(position: pos, velocity: vel, body: earth, epoch: Epoch.zero);
    expect(orbit.elements.eccentricity, greaterThan(1.0));
    final s = conv.toStateVector(orbit, const Epoch(100));
    expect(s.position.x.isFinite, isTrue);
    expect(s.position.length, lessThan(r)); // still descending
  });

  test('near-parabolic state stays finite (no infinity semi-major axis)', () {
    final r = earth.radius + 3000000;
    final vEsc = math.sqrt(2 * earth.mu / r);
    final pos = Vector3(r, 0, 0);
    final vel = Vector3(0, vEsc, 0); // exactly escape speed: e == 1
    final orbit =
        conv.toOrbit(position: pos, velocity: vel, body: earth, epoch: Epoch.zero);
    expect(orbit.elements.semiMajorAxis.isFinite, isTrue);
    final s = conv.toStateVector(orbit, const Epoch(500));
    expect(s.position.x.isFinite && s.position.y.isFinite, isTrue);
    expect(s.position.length, greaterThan(r));
  });
}

double _energy(Vector3 v, Vector3 r, double mu) =>
    v.lengthSquared / 2 - mu / r.length;
