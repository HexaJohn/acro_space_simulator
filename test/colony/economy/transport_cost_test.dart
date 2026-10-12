// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/economy/transport_cost.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Δv transport model (docs/plans/factory-floors.md §3): every import
/// ceiling is built on it, so these pin that it gives physically sensible
/// answers from the real body data.
void main() {
  final t = DeltaVTransportModel();

  /// The documented era (mature reusable methalox fleet) lands cargo on Mars
  /// for hundreds of credits per kg — not tens, not a million.
  test('Earth to Mars surface costs hundreds of credits per kg', () {
    final r = t.route('earth', 'mars');
    expect(r.flyable, isTrue);
    expect(r.perKg, inInclusiveRange(150, 3000));
    // Δv near the textbook ~14-15 km/s surface-to-surface with aerobraking.
    expect(r.totalDv, inInclusiveRange(13000, 16000));
  });

  /// Earth's gravity well dominates every Earth export: the ascent is most of
  /// the Δv, and the launcher lifts the ship plus all its propellant, so the
  /// trip OUT of Earth costs several times the trip back IN.
  test('Earth ascent dominates; the return trip is far cheaper', () {
    final out = t.route('earth', 'mars');
    expect(out.ascentDv / out.totalDv, greaterThan(0.55));
    expect(out.ascentDv, inInclusiveRange(8800, 9800),
        reason: 'LEO from the surface is ~9-9.5 km/s with losses');
    final back = t.route('mars', 'earth');
    expect(back.perKg * 4, lessThan(out.perKg));
    expect(t.route('moon', 'earth').perKg * 4,
        lessThan(t.route('earth', 'moon').perKg));
  });

  /// What physics says about the Moon vs Mars: the Moon is closer in TIME
  /// but not in Δv. Without air every m/s of the lunar landing is burned,
  /// while Mars' atmosphere takes most of the arrival for free, so Earth →
  /// Moon surface needs slightly MORE Δv than Earth → Mars surface, and the
  /// landed cost per kg is about the same. The Moon's advantage is cadence
  /// (days, not a 26-month synodic period), visible in the mission time.
  test('Earth to Moon: more Δv than Mars, similar cost, far shorter trip', () {
    final moon = t.route('earth', 'moon');
    final mars = t.route('earth', 'mars');
    expect(moon.totalDv, greaterThan(mars.totalDv));
    expect(moon.totalDv, inInclusiveRange(14000, 16500));
    expect(moon.perKg / mars.perKg, inInclusiveRange(0.7, 1.4));
    expect(moon.missionDays, lessThan(30));
    expect(mars.missionDays, greaterThan(700),
        reason: 'a Mars ship is tied up for a synodic period per trip');
  });

  /// Shallow wells export cheaply: Mars, climbing out of a third of
  /// Earth's well and aerocapturing at Earth, lands cargo on the Moon for
  /// less than Earth can — the case for off-world supply chains.
  test('Mars supplies the Moon cheaper than Earth does', () {
    final fromMars = t.route('mars', 'moon');
    final fromEarth = t.route('earth', 'moon');
    expect(fromMars.totalDv, lessThan(fromEarth.totalDv));
    expect(fromMars.perKg, lessThan(fromEarth.perKg));
  });

  /// Aerobraking is worth real Δv: landing on Mars from its low orbit costs
  /// far less than taking off from it.
  test('an atmosphere aerobrakes most of the arrival away', () {
    final r = t.route('earth', 'mars');
    final up = t.route('mars', 'earth').ascentDv;
    expect(r.arrivalDv, lessThan(up * 0.6));
  });

  /// Degenerate routes: same body is free; a gas giant has no surface to
  /// lift off from (unflyable, infinite), and unknown bodies are unflyable
  /// rather than a crash.
  test('same body is free; gas giants and unknown bodies are unflyable', () {
    expect(t.perKg('mars', 'mars'), 0);
    expect(t.perKg('earth', 'jupiter').isInfinite, isTrue);
    expect(t.perKg('earth', 'atlantis').isInfinite, isTrue);
  });

  /// Cached and deterministic: the same route twice is the same number, and
  /// a fresh model agrees bit for bit.
  test('routes are deterministic across models', () {
    final a = t.perKg('earth', 'ceres');
    expect(t.perKg('earth', 'ceres'), a);
    expect(DeltaVTransportModel().perKg('earth', 'ceres'), a);
  });

  /// A source with cheap propellant (a Martian ISRU depot) ships cheaper:
  /// the override reaches the propellant line and nothing else.
  test('a source propellant price override changes only propellant cost', () {
    final base = t.route('mars', 'earth');
    final isru = DeltaVTransportModel(propellantPricePerKg: {'mars': 0})
        .route('mars', 'earth');
    expect(isru.propellantCost, 0);
    expect(isru.vehicleCost, base.vehicleCost);
    expect(isru.perKg, lessThan(base.perKg));
  });
}
