// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../universe/celestial_body.dart';
import 'atmospheric_composition.dart';
import 'planet_surface.dart';

/// Physical surface conditions for a colony, derived from a body's real physics
/// (insolation, atmosphere, composition, gravity) and the colony's LIVE damage
/// state (pollution / nuclear winter / radiation drag it down).
///
/// The ONE definition of what the air does for a person
/// (docs/plans/terraforming.md §3.4): breathable, the sky's oxygen cover and
/// the toxicity all come from here, and the pressure, temperature and gas mix
/// come from the body — which carries its DERIVED air (the planet's gas
/// inventory, its greenhouse temperature) since terraforming phase 2. The
/// colony's old terraform slider no longer fakes any of them: towers change
/// the real air, and these read it.
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

  /// Build from a body + the colony's live environment knobs: [pollution]
  /// (~0..200), [nuclearWinter] 0..1 and [radiationLevel] 0..1 push it toward
  /// hostile.
  ///
  /// There is no terraform blend: a colony's old slider used to pull the
  /// pressure, temperature, humidity, oxygen and toxicity toward Earth's,
  /// which let it breathe a sky its own planet did not have. Towers change
  /// the planet's real air now, and the body carries it.
  factory SurfaceConditions.of(
    CelestialBody body, {
    Biome biome = Biome.barren,
    double waterTable = 1.0, // colony aquifer level 0..1 (drains the ground dry)
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
    final pressureAtm = basePa / _earthPressurePa;

    // --- Temperature ---
    // The body's modelled surface temperature, which already carries its
    // greenhouse (the derived air's PlanetClimate temperature, or the
    // hand-tuned reference); a crude radiative estimate from insolation for
    // an airless world. A greenhouse term added on top here counted it
    // twice — Venus read 11,000 K.
    var t = atmo?.seaLevelTemperature ??
        (278.0 * math.pow(insol.clamp(0.0001, 100), 0.25));
    final co2 = comp?.fractions[AtmosphereGas.carbonDioxide] ?? 0;
    // Nuclear winter cools.
    t -= nuclearWinter * 40;

    // --- Liquid-water band: must be warm enough + have pressure to keep liquid.
    final liquid = t > 268 && t < (373 + pressureAtm * 10) ? 1.0 : 0.0;
    final pressureOk = (pressureAtm / 0.3).clamp(0.0, 1.0);

    // --- Atmospheric humidity: condensable water vapour (Option C input #1). ---
    final h2o = comp?.fractions[AtmosphereGas.water] ?? 0;
    final humidity = (h2o * 10 * liquid * pressureOk).clamp(0.0, 1.0);

    // --- Surface moisture: wet GROUND from the biome, dried by a low water
    //     table, and only "wet" if it's warm enough for liquid (Option C #2).
    final tableFactor = (0.25 + 0.75 * waterTable).clamp(0.0, 1.0);
    final surfaceMoisture =
        (biome.surfaceMoisture * tableFactor * liquid).clamp(0.0, 1.0);

    // --- Water activity = mostly the wet ground, topped up by humid air. ---
    final water = (surfaceMoisture * 0.7 + humidity * 0.3).clamp(0.0, 1.0);

    // --- Composition ---
    final o2 = comp?.fractions[AtmosphereGas.oxygen] ?? 0;
    final ch4 = comp?.fractions[AtmosphereGas.methane] ?? 0;
    // Pollution adds to toxicity only when EXTREME. The build-style gate flips at
    // toxic >= 0.2, and the UI meter maxes near 200, so ordinary operating smog
    // (tens up to ~120) must contribute ~nothing — otherwise a normal growing
    // colony seals itself. A quadratic above a HIGH floor (120) reaching toward
    // 250 gives: ~0 at 120, ~0.05 at 150, ~0.21 at 180 (near max), ~0.61 at 250.
    final pollToxic = math.pow(
            ((pollution - 120) / 130).clamp(0.0, 1.0), 2)
        .toDouble();
    final toxic = ((co2 + ch4).clamp(0.0, 1.0) + pollToxic).clamp(0.0, 1.0);

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

  /// Oxygen partial pressure at the surface, atm.
  double get o2PressureAtm => o2Fraction * pressureAtm;

  /// How far this air has come toward [breathable], 0..1: 1 only when it
  /// is, and otherwise the geometric mean of its three tests' progress —
  /// oxygen toward 15%, pressure toward half an atmosphere, toxicity under
  /// 0.2 (scaled down from 1 as it rises past it).
  ///
  /// The colony's terraforming readout since phase 3 (`CitySim.terraform`),
  /// the honest successor of the slider: it moves only as the planet's air
  /// does. Geometric, so a sky that passes two tests and fails the third —
  /// a Mars of thin, pure oxygen — reads well short of done rather than two
  /// thirds of the way; capped under 1 until the air really is breathable,
  /// so the meter never claims a full bar the colonists cannot breathe.
  double get breathableProgress {
    if (breathable) return 1;
    final o2 = (o2Fraction / 0.15).clamp(0.0, 1.0);
    final p = (pressureAtm / 0.5).clamp(0.0, 1.0);
    final tox = toxicFraction < 0.2
        ? 1.0
        : ((1 - toxicFraction) / 0.8).clamp(0.0, 1.0);
    final g = math.pow(o2 * p * tox, 1 / 3).toDouble();
    return math.min(g, 0.99);
  }

  /// The oxygen partial pressure (atm) at which the sky supplies ALL of a
  /// person's oxygen (§3.4): about sea-level-equivalent for a lung.
  static const double fullCoverO2Atm = 0.16;

  /// The Armstrong limit, near enough (atm): below ~0.063 atm body fluids
  /// boil, and no amount of oxygen in the air helps an unsuited person.
  static const double armstrongAtm = 0.063;

  /// The share of a colonist's oxygen the sky supplies, 0..1 (§3.4):
  /// `pO2 / 0.16 atm` while the total pressure is above the Armstrong limit
  /// and the air is not poisonous, else nothing. A thin, oxygen-rich sky is a
  /// breathing-mask world, not a breathable one — the compressors draw what
  /// the colony would otherwise have had to make, which is what this
  /// measures — so it is partial long before [breathable].
  double get oxygenCover {
    if (pressureAtm < armstrongAtm || toxicFraction >= 0.2) return 0;
    return (o2PressureAtm / fullCoverO2Atm).clamp(0.0, 1.0);
  }

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
