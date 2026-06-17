import 'dart:math' as math;

import '../universe/celestial_body.dart';
import 'atmospheric_composition.dart';
import 'planet_surface.dart';

/// Physical surface conditions for a colony, derived from a body's real physics
/// (insolation, atmosphere, composition, gravity) blended with the colony's
/// LIVE terraforming + damage state (terraform progress raises it toward
/// Earthlike; pollution / nuclear winter / radiation drag it down).
///
/// Biome + flora are then a function of these scalars rather than a hand-picked
/// enum — so a Martian desert has no cacti until it's warm + wet enough, Earth's
/// plants die if its air is ruined, and terraforming Mars grows life. Rocks are
/// scalar-invariant (geology, not climate).
///
/// Pure value object — no Flutter/IO.
class SurfaceConditions {
  /// Mean surface temperature, Kelvin.
  final double temperatureK;

  /// Surface pressure relative to Earth sea level (1.0 = 1 atm; 0 = vacuum).
  final double pressureAtm;

  /// Liquid-water activity 0..1: needs water vapour in the air AND a temperature
  /// in the liquid band at this pressure. 0 on a frozen or boiling/airless world.
  final double waterActivity;

  /// Breathable-oxygen fraction (mole fraction of O2).
  final double o2Fraction;

  /// Greenhouse / toxic gas load (CO2 + CH4 + similar), 0..1.
  final double toxicFraction;

  /// Insolation relative to Earth (solarFlux / 1361).
  final double insolation;

  /// Surface gravity in g (9.81 m/s^2 = 1).
  final double gravityG;

  /// Background radiation 0..1 (unshielded thin-atmosphere worlds run hotter).
  final double radiation;

  /// Atmospheric density relative to Earth (drives wind + drag), 0..~.
  final double airDensity;

  /// Surface (ground) moisture 0..1 — wet soil/standing water, from the biome
  /// scaled by the colony's water table. Independent of air humidity.
  final double surfaceMoisture;

  /// Atmospheric humidity 0..1 — water vapour able to condense (vapour fraction
  /// × pressure × being in the liquid temperature band).
  final double humidity;

  /// Biome's intrinsic flora ceiling 0..1 (forest high, desert low, barren 0).
  final double floraPotential;

  const SurfaceConditions({
    required this.temperatureK,
    required this.pressureAtm,
    required this.waterActivity,
    required this.o2Fraction,
    required this.toxicFraction,
    required this.insolation,
    required this.gravityG,
    required this.radiation,
    required this.airDensity,
    required this.surfaceMoisture,
    required this.humidity,
    required this.floraPotential,
  });

  static const double _earthFlux = 1361;
  static const double _earthPressurePa = 101325;
  static const double _earthDensity = 1.225;

  /// Build from a body + the colony's live environment knobs. [terraform] 0..1
  /// pushes the world toward Earthlike; [pollution] (~0..200), [nuclearWinter]
  /// 0..1 and [radiationLevel] 0..1 push it the other way.
  factory SurfaceConditions.of(
    CelestialBody body, {
    Biome biome = Biome.barren,
    double waterTable = 1.0, // colony aquifer level 0..1 (drains the ground dry)
    double terraform = 0,
    double pollution = 0,
    double nuclearWinter = 0,
    double radiationLevel = 0,
  }) {
    final atmo = body.atmosphere;
    final comp = body.composition;
    final insol = (body.solarFlux / _earthFlux);
    final g = body.mu / (body.radius * body.radius) / 9.80665;

    // --- Pressure ---
    final basePa = atmo?.seaLevelPressure ?? 0;
    var pressureAtm = basePa / _earthPressurePa;
    // Terraforming thickens a thin atmosphere toward 1 atm.
    pressureAtm = pressureAtm + terraform * math.max(0, 1.0 - pressureAtm);

    // --- Temperature ---
    // Equilibrium-ish: from the body's modelled sea-level T if present, else a
    // crude radiative estimate from insolation. Greenhouse from CO2 + pressure.
    var t = atmo?.seaLevelTemperature ??
        (278.0 * math.pow(insol.clamp(0.0001, 100), 0.25));
    final co2 = comp?.fractions[AtmosphereGas.carbonDioxide] ?? 0;
    t += co2 * pressureAtm * 120; // greenhouse warming
    // Terraform nudges temperature toward a comfortable 288 K.
    t += terraform * (288 - t) * 0.8;
    // Nuclear winter cools.
    t -= nuclearWinter * 40;

    // --- Liquid-water band: must be warm enough + have pressure to keep liquid.
    final liquid = t > 268 && t < (373 + pressureAtm * 10) ? 1.0 : 0.0;
    final pressureOk = (pressureAtm / 0.3).clamp(0.0, 1.0);

    // --- Atmospheric humidity: condensable water vapour (Option C input #1). ---
    final h2o = comp?.fractions[AtmosphereGas.water] ?? 0;
    final humidity =
        ((h2o * 10 + terraform * 0.5) * liquid * pressureOk).clamp(0.0, 1.0);

    // --- Surface moisture: wet GROUND from the biome, dried by a low water
    //     table, and only "wet" if it's warm enough for liquid (Option C #2).
    final tableFactor = (0.25 + 0.75 * waterTable).clamp(0.0, 1.0);
    final surfaceMoisture =
        (biome.surfaceMoisture * tableFactor * liquid).clamp(0.0, 1.0);

    // --- Water activity = mostly the wet ground, topped up by humid air. ---
    final water = (surfaceMoisture * 0.7 + humidity * 0.3).clamp(0.0, 1.0);

    // --- Composition ---
    final o2 = (comp?.fractions[AtmosphereGas.oxygen] ?? 0) +
        terraform * 0.2 * (1 - (comp?.fractions[AtmosphereGas.oxygen] ?? 0));
    final ch4 = comp?.fractions[AtmosphereGas.methane] ?? 0;
    // Pollution adds to toxicity only when EXTREME. The build-style gate flips at
    // toxic >= 0.2, and the UI meter maxes near 200, so ordinary operating smog
    // (tens up to ~120) must contribute ~nothing — otherwise a normal growing
    // colony seals itself. A quadratic above a HIGH floor (120) reaching toward
    // 250 gives: ~0 at 120, ~0.05 at 150, ~0.21 at 180 (near max), ~0.61 at 250.
    final pollToxic = math.pow(
            ((pollution - 120) / 130).clamp(0.0, 1.0), 2)
        .toDouble();
    final toxic = ((co2 + ch4).clamp(0.0, 1.0) * (1 - terraform) + pollToxic)
        .clamp(0.0, 1.0);

    final density = (atmo?.seaLevelDensity ?? 0) / _earthDensity;
    final rad = math.max(
        radiationLevel, (1 - density.clamp(0.0, 1.0)) * 0.15); // thin air = more

    return SurfaceConditions(
      temperatureK: t,
      pressureAtm: pressureAtm.clamp(0.0, 100),
      waterActivity: water,
      o2Fraction: o2.clamp(0.0, 1.0),
      toxicFraction: toxic,
      insolation: insol,
      gravityG: g,
      radiation: rad.clamp(0.0, 1.0),
      airDensity: density,
      surfaceMoisture: surfaceMoisture,
      humidity: humidity,
      floraPotential: biome.floraPotential,
    );
  }

  /// Can a person breathe the ambient air unaided? Earthlike O2 + real pressure
  /// + not chemically poisonous. (Pollution can push [toxicFraction] up, so heavy
  /// smog counts as un-breathable — wear a mask / seal the hab.)
  bool get breathable => o2Fraction >= 0.15 && pressureAtm >= 0.5 && toxicFraction < 0.2;

  /// STRUCTURALLY hostile air — the world's atmosphere can't physically hold a
  /// person/open building together: near-vacuum OR no breathable oxygen at all.
  /// This is what causes explosive decompression of un-sealed structures.
  /// Crucially it does NOT include pollution: a dirty but thick, oxygenated sky
  /// is bad for HEALTH, not a structural failure — only vacuum/anoxia is.
  bool get vacuumHostile => pressureAtm < 0.25 || o2Fraction < 0.05;

  double get temperatureC => temperatureK - 273.15;

  /// How comfortable the temperature is for life, 0..1 (peak ~288 K / 15 °C).
  double get _tempComfort {
    final d = (temperatureK - 288).abs();
    return (1 - d / 60).clamp(0.0, 1.0);
  }

  /// Climate gate 0..1 — can ANY unprotected life survive the *atmosphere* here?
  /// Pure climate (pressure, temperature, non-toxicity); independent of the
  /// biome. ~1 on Earth, ~0 on the Moon / raw Mars, climbs with terraforming.
  double get _climateGate {
    final pressureOk = (pressureAtm / 0.5).clamp(0.0, 1.0);
    final core = (pressureOk * 0.45 + _tempComfort * 0.45 +
            (1 - toxicFraction) * 0.1)
        .clamp(0.0, 1.0);
    // No liquid possible at all (airless / frozen) => no surface life.
    return waterActivity > 0.02 || humidity > 0.02 ? core : core * 0.1;
  }

  /// Master habitability 0..1 (UI headline): the climate gate. "How Earthlike."
  double get habitability => _climateGate;

  /// Actual plant cover the surface supports 0..1 — climate × the biome's flora
  /// potential × how wet it is. This is what the scatter density reads, so a
  /// living Earth forest is dense, a dry desert sparse, raw Mars empty.
  double get floraDensity =>
      (_climateGate * floraPotential * (0.3 + 0.7 * waterActivity))
          .clamp(0.0, 1.0);

  /// A short human-readable climate band for the UI.
  String get summary {
    if (habitability > 0.7) return 'Habitable';
    if (habitability > 0.35) return 'Marginal';
    if (pressureAtm < 0.05) return 'Airless';
    if (temperatureK < 240) return 'Frozen';
    if (temperatureK > 330) return 'Scorching';
    if (toxicFraction > 0.3) return 'Toxic';
    return 'Hostile';
  }
}
