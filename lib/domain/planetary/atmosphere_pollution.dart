// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Colony emissions changing a world's air.
///
/// The colony already tracked pollution and already READ the host body's gas
/// mix — but only one way: nothing a city did ever changed the atmosphere it
/// was breathing. This closes that loop, and does it against the real mass of
/// air involved, which is what makes the result interesting rather than
/// arbitrary: Earth's atmosphere is about 1.8e20 moles, so no colony is going
/// to shift it, while Mars has roughly a four-thousandth of that per square
/// metre and a serious industrial base there measurably thickens the CO2.
library;

import 'dart:math' as math;

import 'atmospheric_composition.dart';

/// Accumulated anthropogenic change to one body's atmosphere.
///
/// Kept separate from [AtmosphericComposition] (an immutable value object
/// describing a mix) and from `CelestialBody` (immutable reference data)
/// because this is mutable WORLD state: it belongs to the simulation, is part
/// of the save, and is replicated to clients.
class AtmospherePollution {
  AtmospherePollution({
    required this.bodyId,
    required this.totalMoles,
    this.co2Moles = 0,
    this.o2Moles = 0,
    this.aerosolBurden = 0,
  });

  final String bodyId;

  /// Total moles of gas in the whole atmosphere. The denominator that decides
  /// whether a colony's output is a rounding error or a climate event.
  final double totalMoles;

  /// Net CO2 added by industry (moles). Negative once scrubbers win.
  double co2Moles;

  /// Net O2 added by terraforming / electrolysis venting, or removed by
  /// combustion (moles).
  double o2Moles;

  /// Dimensionless aerosol/particulate loading, 0 = clean. Unlike the gases
  /// this SETTLES, so it tracks current activity rather than accumulating
  /// forever — which is why a colony that cleans up sees its sky clear within
  /// a season while its CO2 stays put.
  double aerosolBurden;

  /// Fractional change this represents against the whole atmosphere.
  double get co2Fraction => totalMoles <= 0 ? 0 : co2Moles / totalMoles;
  double get o2Fraction => totalMoles <= 0 ? 0 : o2Moles / totalMoles;

  /// Has the colony changed the GLOBAL gas mix measurably (a part in a
  /// million)? Deliberately excludes [aerosolBurden], which is regional haze
  /// over the colony rather than a change to the planet's composition — a
  /// smoggy city on Earth is a local fact, not a new atmosphere.
  bool get isMeasurable => co2Fraction.abs() > 1e-6;

  /// [base] with this body's accumulated emissions folded in.
  AtmosphericComposition applyTo(AtmosphericComposition base) {
    if (totalMoles <= 0) return base;
    final f = Map<AtmosphereGas, double>.from(base.fractions);
    // Work in moles, then let the composition renormalise: adding a fraction
    // directly would silently dilute every other gas by the wrong amount.
    final moles = <AtmosphereGas, double>{
      for (final e in f.entries) e.key: e.value * totalMoles,
    };
    moles[AtmosphereGas.carbonDioxide] =
        math.max(0.0, (moles[AtmosphereGas.carbonDioxide] ?? 0) + co2Moles);
    moles[AtmosphereGas.oxygen] =
        math.max(0.0, (moles[AtmosphereGas.oxygen] ?? 0) + o2Moles);
    return AtmosphericComposition(moles);
  }

  /// Total moles of an atmosphere from its surface conditions.
  ///
  /// Mass per unit area is `P / g` (hydrostatic), so the column mass over the
  /// whole sphere divided by the mean molar mass gives the mole count. Doing it
  /// from pressure rather than from a scale-height integral keeps it correct
  /// for the thick cases where the exponential approximation drifts.
  static double molesOf({
    required double surfacePressurePa,
    required double gravity,
    required double bodyRadiusM,
    required double meanMolarMassKgPerMol,
  }) {
    if (surfacePressurePa <= 0 ||
        gravity <= 0 ||
        meanMolarMassKgPerMol <= 0) {
      return 0;
    }
    final area = 4 * math.pi * bodyRadiusM * bodyRadiusM;
    final massKg = surfacePressurePa / gravity * area;
    return massKg / meanMolarMassKgPerMol;
  }
}

/// Converts a colony's pollution rate into atmospheric change.
class AtmospherePollutionService {
  const AtmospherePollutionService({
    this.molesPerPollutionSecond = 5.0e3,
    this.aerosolRisePerPollution = 4.0e-5,
    this.aerosolSettleRate = 0.004,
    this.o2PerScrubbedPollution = 0.35,
  });

  /// Moles of CO2 released per unit of the city's pollution rate per second.
  ///
  /// The city's pollution number is an abstract rate, so this is the one place
  /// that gives it physical units. Calibrated against the real thing: a heavy
  /// industrial colony emitting at rate ~40 works out near 6e12 mol/yr, about
  /// a hundredth of all human industry. That keeps Earth unmovable by one city
  /// (a few tenths of a ppm per decade) while a Mars-thin atmosphere shifts
  /// measurably over the same span, which is the interesting result.
  final double molesPerPollutionSecond;

  /// Particulate loading added per unit pollution per second.
  final double aerosolRisePerPollution;

  /// Fraction of the aerosol burden that settles out per second.
  final double aerosolSettleRate;

  /// Moles of O2 returned per mole of CO2 a scrubber removes — photosynthesis
  /// and Sabatier-type processing both release oxygen when they take carbon
  /// out, so a terraforming colony brightens its own air twice over.
  final double o2PerScrubbedPollution;

  /// Advance [state] by [dt] seconds under a colony emitting [pollutionRate]
  /// (the city's own units; negative scrubs).
  void advance(
    AtmospherePollution state, {
    required double pollutionRate,
    required double dt,
  }) {
    if (dt <= 0) return;
    final moles = pollutionRate * molesPerPollutionSecond * dt;
    state.co2Moles += moles;
    if (moles < 0) {
      // Scrubbing releases oxygen as it takes the carbon out.
      state.o2Moles += -moles * o2PerScrubbedPollution;
    }

    // Aerosols track current activity: they rise with emissions and settle out
    // continuously, so they cannot ratchet upward the way the gases do.
    //
    // Relaxed toward equilibrium EXPONENTIALLY rather than by an explicit
    // rise-minus-settle step, so the result does not depend on how the caller
    // chops up time. Under warp a single step can be years long, and the
    // explicit form goes unstable (and then negative) the moment
    // `settleRate * dt` exceeds 1.
    final riseRate = math.max(0.0, pollutionRate) * aerosolRisePerPollution;
    final equilibrium =
        aerosolSettleRate > 0 ? riseRate / aerosolSettleRate : riseRate;
    final decay = math.exp(-aerosolSettleRate * dt);
    state.aerosolBurden =
        math.max(0.0, equilibrium + (state.aerosolBurden - equilibrium) * decay);
  }
}
