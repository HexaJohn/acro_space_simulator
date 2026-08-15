// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

/// A sample of atmospheric conditions at one altitude. Value object consumed by
/// the aerodynamics and thermal contexts.
class AtmosphereSample {
  final double pressure; // Pa
  final double density; // kg/m^3
  final double temperature; // K
  final double speedOfSound; // m/s

  const AtmosphereSample({
    required this.pressure,
    required this.density,
    required this.temperature,
    required this.speedOfSound,
  });

  static const AtmosphereSample vacuum = AtmosphereSample(
    pressure: 0,
    density: 0,
    temperature: 2.7, // cosmic background
    speedOfSound: 0,
  );
}

/// Exponential isothermal-ish atmosphere model. Pressure and density fall off
/// with scale height; temperature follows a simple lapse profile. Good enough
/// for gameplay aero/thermal; can be swapped for a tabulated model later
/// without touching callers.
class AtmosphereModel {
  /// Sea-level (datum) values.
  final double seaLevelPressure; // Pa
  final double seaLevelDensity; // kg/m^3
  final double seaLevelTemperature; // K

  /// e-folding height for pressure/density, metres.
  final double scaleHeight;

  /// Altitude above the datum at which the atmosphere is treated as vacuum.
  final double atmosphereHeight;

  /// Temperature lapse rate, K per metre (positive = cools with altitude).
  final double lapseRate;

  /// Ratio of specific heats (gamma) and specific gas constant — for the
  /// speed of sound a = sqrt(gamma * R * T).
  final double gamma;
  final double specificGasConstant; // J/(kg*K)

  const AtmosphereModel({
    required this.seaLevelPressure,
    required this.seaLevelDensity,
    required this.seaLevelTemperature,
    required this.scaleHeight,
    required this.atmosphereHeight,
    this.lapseRate = 0.0065,
    this.gamma = 1.4,
    this.specificGasConstant = 287.05,
  });

  /// This model re-derived for a CHANGED gas mix.
  ///
  /// Composition and the air model were decoupled: a body's mix drove reentry
  /// heating and the sky's colour, but not a single number a wing feels. So a
  /// colony could thicken a world's CO2 for a century and the drag would not
  /// budge.
  ///
  /// The coupling is through scale height, which is `R*T / (M*g)` — inversely
  /// proportional to mean molar mass. Applying it as a RATIO against the
  /// model's existing scale height rather than recomputing from scratch is
  /// deliberate: every body's air is hand-tuned, and an unpolluted mix must
  /// come back bit-identical (the ratio is exactly 1), so this can only ever
  /// change a world a colony has actually changed.
  ///
  /// Heavier air sits lower — denser at the surface, thinner aloft — which is
  /// the right sign for a CO2-loaded atmosphere.
  AtmosphereModel withMeanMolarMass({
    required double baselineKgPerMol,
    required double currentKgPerMol,
  }) {
    if (baselineKgPerMol <= 0 || currentKgPerMol <= 0) return this;
    final ratio = baselineKgPerMol / currentKgPerMol;
    if ((ratio - 1).abs() < 1e-9) return this;
    return AtmosphereModel(
      seaLevelPressure: seaLevelPressure,
      // Surface density follows the molar mass directly at fixed pressure and
      // temperature (ideal gas): heavier molecules, more kilograms per cubic
      // metre.
      seaLevelDensity: seaLevelDensity / ratio,
      seaLevelTemperature: seaLevelTemperature,
      scaleHeight: scaleHeight * ratio,
      atmosphereHeight: atmosphereHeight,
      lapseRate: lapseRate,
      gamma: gamma,
      specificGasConstant: specificGasConstant,
    );
  }

  bool hasAtmosphere(double altitude) =>
      altitude >= 0 && altitude < atmosphereHeight;

  AtmosphereSample sampleAt(double altitude) {
    if (!hasAtmosphere(altitude)) return AtmosphereSample.vacuum;
    final factor = math.exp(-altitude / scaleHeight);
    final t = math.max(
      2.7,
      seaLevelTemperature - lapseRate * altitude,
    );
    final a = math.sqrt(gamma * specificGasConstant * t);
    return AtmosphereSample(
      pressure: seaLevelPressure * factor,
      density: seaLevelDensity * factor,
      temperature: t,
      speedOfSound: a,
    );
  }
}
