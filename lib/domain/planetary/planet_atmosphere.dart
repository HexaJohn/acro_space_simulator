// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A world's air as an inventory of gas (docs/plans/terraforming.md §3.1-3.2).
///
/// A body's atmosphere used to be reference data: a hand-tuned
/// `AtmosphereModel` and a gas mix, both immutable, so nothing a colony did
/// could ever change the air it breathed, the drag a craft felt or the colour
/// of the sky. This makes the air WORLD STATE — moles of each gas — and
/// re-derives everything else from it with the same identities the air model
/// is already built on:
///
/// ```
/// mass  = Σ moles_i × M_i
/// P     = mass × g / (4πR²)            (hydrostatic column)
/// x_i   = moles_i / Σ moles            (composition)
/// μ     = Σ x_i M_i                    (mean molar mass)
/// ρ     = P μ / (R T)
/// H     = R T / (μ g)
/// ```
///
/// It supersedes the old pollution ledger (`AtmospherePollution`), whose total
/// mole count was fixed: that could tilt the gas MIX but never the PRESSURE,
/// which is the one thing terraforming is actually about.
library;

import 'dart:math' as math;

import '../universe/atmosphere_model.dart';
import '../universe/celestial_body.dart';
import 'atmospheric_composition.dart';

/// One body's mutable gas inventory, seeded from its reference air.
///
/// Kept apart from [AtmosphericComposition] (an immutable mix) and from
/// [CelestialBody] (immutable reference data) because this is mutable world
/// state: it belongs to the simulation, it is saved, and it goes into the
/// determinism fingerprint. The body is only ever a PUBLISHED VIEW of it —
/// see [applyTo].
class PlanetAtmosphere {
  PlanetAtmosphere._({
    required this.bodyId,
    required this.gravity,
    required this.bodyRadiusM,
    required this.referenceAir,
    required this.referenceComposition,
    required Map<AtmosphereGas, double> referenceMoles,
  })  : _referenceMoles = Map.unmodifiable(referenceMoles),
        _moles = Map.of(referenceMoles) {
    _referenceMass = _massOf(_referenceMoles);
    _referenceMolarMass = _meanMolarMassOf(_referenceMoles);
    markPublished();
  }

  /// The inventory a body starts with: its reference composition times the
  /// total moles its reference surface pressure implies.
  ///
  /// Null for a body with no reference air. An airless world has no hand-tuned
  /// model to derive a sky from (no top of atmosphere, no lapse rate), and
  /// until escape exists (phase 2) whatever was vented onto the Moon would
  /// stay there forever — which is exactly backwards.
  static PlanetAtmosphere? seed(CelestialBody body) {
    final air = body.atmosphere;
    final mix = body.composition;
    if (air == null || mix == null || mix.fractions.isEmpty) return null;
    if (air.seaLevelPressure <= 0 || body.radius <= 0 || body.mu <= 0) {
      return null;
    }
    final g = body.mu / (body.radius * body.radius);
    final total = totalMolesFor(
      surfacePressurePa: air.seaLevelPressure,
      gravity: g,
      bodyRadiusM: body.radius,
      meanMolarMassKgPerMol: mix.meanMolecularWeight,
    );
    if (total <= 0) return null;
    return PlanetAtmosphere._(
      bodyId: body.id.value,
      gravity: g,
      bodyRadiusM: body.radius,
      referenceAir: air,
      referenceComposition: mix,
      referenceMoles: {
        for (final e in mix.fractions.entries) e.key: e.value * total,
      },
    );
  }

  final String bodyId;

  /// Surface gravity (m/s²), from the body's mu and radius.
  final double gravity;
  final double bodyRadiusM;

  /// The body's air as the system definition built it. Everything derived is a
  /// RATIO against this: every body's air is hand-tuned, and an unchanged
  /// inventory must hand back these exact objects, so the inventory can only
  /// ever change a world something has actually changed.
  final AtmosphereModel referenceAir;
  final AtmosphericComposition referenceComposition;

  final Map<AtmosphereGas, double> _referenceMoles;
  final Map<AtmosphereGas, double> _moles;
  late final double _referenceMass;
  late final double _referenceMolarMass;

  /// Dimensionless aerosol/particulate loading, 0 = clean. Unlike the gases
  /// this SETTLES, so it tracks current activity rather than accumulating
  /// forever — which is why a colony that cleans up sees its sky clear within
  /// a season while its CO2 stays put. Not yet fed into the derived air
  /// (aerosol cooling is phase 2).
  double aerosolBurden = 0;

  /// Moles of [gas] in the whole atmosphere now.
  double molesOf(AtmosphereGas gas) => _moles[gas] ?? 0;

  /// Moles of [gas] the body started with.
  double referenceMolesOf(AtmosphereGas gas) => _referenceMoles[gas] ?? 0;

  /// The inventory, read-only, in gas-enum order.
  Map<AtmosphereGas, double> get moles => {
        for (final g in AtmosphereGas.values)
          if (_moles.containsKey(g)) g: _moles[g]!,
      };

  /// Add [delta] moles of [gas] (negative removes) and return what was really
  /// applied. Removal stops at zero: an atmosphere cannot owe a gas, and a
  /// sink that asks for more than is there takes only what is there — which
  /// is also what keeps a long warp step from driving an inventory negative.
  double add(AtmosphereGas gas, double delta) {
    if (delta == 0 || delta.isNaN) return 0;
    final before = _moles[gas] ?? 0;
    final after = math.max(0.0, before + delta);
    _moles[gas] = after;
    return after - before;
  }

  /// Total moles in the atmosphere.
  double get totalMoles => _sum(_moles);

  /// Total moles the body started with.
  double get referenceTotalMoles => _sum(_referenceMoles);

  /// Mass of the whole atmosphere (kg).
  double get massKg => _massOf(_moles);

  double get _area => 4 * math.pi * bodyRadiusM * bodyRadiusM;

  /// Surface pressure (Pa), as the reference air would read it.
  ///
  /// A ratio against the reference mass rather than `mass × g / A` from
  /// scratch, so the reference inventory reads back exactly the hand-tuned
  /// pressure — the two agree to float precision anyway, since the seed is
  /// built from that same identity.
  double get surfacePressurePa => _referenceMass <= 0
      ? 0
      : referenceAir.seaLevelPressure * (massKg / _referenceMass);

  /// Partial pressure of [gas] at the surface (Pa): its mole fraction of the
  /// surface pressure.
  double partialPressurePa(AtmosphereGas gas) {
    final n = totalMoles;
    return n <= 0 ? 0 : surfacePressurePa * molesOf(gas) / n;
  }

  /// The gas mix now.
  AtmosphericComposition get composition => _isReference
      ? referenceComposition
      : AtmosphericComposition(Map.of(_moles));

  /// Mean molar mass now (kg/mol). Falls back to the reference value for an
  /// emptied atmosphere, so the derived air stays finite as it vanishes.
  double get meanMolarMass {
    final m = _meanMolarMassOf(_moles);
    return m > 0 ? m : _referenceMolarMass;
  }

  /// The air model this inventory implies (§3.2).
  ///
  /// Temperature is held at the reference value in phase 1: the greenhouse
  /// response (§3.2's `T_eq + greenhouse − aerosol`) arrives with the
  /// feedbacks in phase 2, and a half-model that warmed Mars on CO2 alone
  /// would be worse than none. So, at fixed T and g:
  ///  * pressure follows the column mass;
  ///  * density follows `P μ / RT` — pressure ratio times molar-mass ratio;
  ///  * scale height and the specific gas constant follow `1/μ`;
  ///  * the top of the atmosphere moves so it still sits at the same absolute
  ///    pressure it did: thicker air reaches higher before it counts as space.
  ///    A fixed top would cut a 30-fold-thicker Mars off at a height where its
  ///    air is still thirty times denser than the reference ever was there.
  AtmosphereModel get air {
    if (_isReference) return referenceAir;
    final pr = _referenceMass <= 0 ? 0.0 : massKg / _referenceMass;
    final mr = meanMolarMass / _referenceMolarMass;
    final ref = referenceAir;
    final scaleHeight = ref.scaleHeight / mr;
    final top = pr <= 0
        ? 0.0
        : math.max(
            0.0,
            scaleHeight *
                (ref.atmosphereHeight / ref.scaleHeight + math.log(pr)));
    return AtmosphereModel(
      seaLevelPressure: ref.seaLevelPressure * pr,
      seaLevelDensity: ref.seaLevelDensity * pr * mr,
      seaLevelTemperature: ref.seaLevelTemperature,
      scaleHeight: scaleHeight,
      atmosphereHeight: top,
      lapseRate: ref.lapseRate,
      gamma: ref.gamma,
      specificGasConstant: ref.specificGasConstant / mr,
    );
  }

  /// [body] carrying this inventory's air: what gets republished into the
  /// universe so flight, colonies, the renderer and snapshots all read one sky.
  CelestialBody applyTo(CelestialBody body) =>
      body.copyWith(atmosphere: air, composition: composition);

  /// Change in [gas] since seeding, as a fraction of the reference
  /// atmosphere — the yardstick for "has anything measurably moved".
  double fractionChange(AtmosphereGas gas) {
    final n = referenceTotalMoles;
    return n <= 0 ? 0 : (molesOf(gas) - referenceMolesOf(gas)) / n;
  }

  /// Has the GLOBAL gas inventory changed measurably (a part in a million of
  /// the atmosphere, in any gas)? Deliberately excludes [aerosolBurden], which
  /// is regional haze over a colony rather than a change to the planet — a
  /// smoggy city on Earth is a local fact, not a new atmosphere.
  bool get isMeasurable {
    for (final g in AtmosphereGas.values) {
      if (fractionChange(g).abs() > 1e-6) return true;
    }
    return false;
  }

  bool get _isReference {
    if (_moles.length != _referenceMoles.length) return false;
    for (final e in _referenceMoles.entries) {
      if (_moles[e.key] != e.value) return false;
    }
    return true;
  }

  // ---- publishing ----------------------------------------------------------

  double _publishedMass = 0;
  final Map<AtmosphereGas, double> _publishedFractions = {};

  /// Has the air moved far enough from what was last published to be worth
  /// republishing the body? Relative pressure or any absolute mole fraction
  /// past [tolerance].
  ///
  /// Republishing swaps a body in the universe, which is cheap but not free,
  /// and the render descriptor only refreshes at ~1 Hz anyway — while a
  /// tower programme moves Mars's air by a part in a billion per tick at 1×.
  /// So the threshold, not the tick, decides when the world sees the change;
  /// under warp, where each step moves it a lot, that is every tick.
  bool needsPublish({double tolerance = 1e-6}) {
    final mass = massKg;
    if (_publishedMass <= 0) {
      if (mass > 0) return true;
    } else if ((mass / _publishedMass - 1).abs() > tolerance) {
      return true;
    }
    final n = totalMoles;
    if (n <= 0) return false;
    for (final g in AtmosphereGas.values) {
      final x = molesOf(g) / n;
      if ((x - (_publishedFractions[g] ?? 0)).abs() > tolerance) return true;
    }
    return false;
  }

  /// Record the current air as published.
  void markPublished() {
    _publishedMass = massKg;
    _publishedFractions.clear();
    final n = totalMoles;
    if (n <= 0) return;
    for (final e in _moles.entries) {
      _publishedFractions[e.key] = e.value / n;
    }
  }

  // ---- persistence ---------------------------------------------------------

  /// Back to the reference inventory: a world loaded from a save that predates
  /// the inventory, or that never touched this body, breathes reference air.
  void resetToReference() {
    _moles
      ..clear()
      ..addAll(_referenceMoles);
    aerosolBurden = 0;
  }

  /// The inventory as saved. Gases by enum NAME, so reordering or extending
  /// the enum cannot silently move moles between species.
  Map<String, dynamic> toJson() => {
        'body': bodyId,
        'moles': {
          for (final g in AtmosphereGas.values)
            if (_moles.containsKey(g)) g.name: _moles[g],
        },
        if (aerosolBurden != 0) 'aerosol': aerosolBurden,
      };

  /// Replace the inventory with [json] (from [toJson]). A gas this build does
  /// not know is dropped rather than failing the whole load.
  void restore(Map<String, dynamic> json) {
    _moles.clear();
    final saved = (json['moles'] as Map?) ?? const {};
    for (final g in AtmosphereGas.values) {
      final v = saved[g.name];
      if (v is num) _moles[g] = math.max(0.0, v.toDouble());
    }
    aerosolBurden = (json['aerosol'] as num?)?.toDouble() ?? 0;
  }

  // ---- maths ---------------------------------------------------------------

  /// Total moles of an atmosphere from its surface conditions.
  ///
  /// Mass per unit area is `P / g` (hydrostatic), so the column mass over the
  /// whole sphere divided by the mean molar mass gives the mole count. Doing it
  /// from pressure rather than from a scale-height integral keeps it correct
  /// for the thick cases where the exponential approximation drifts.
  static double totalMolesFor({
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

  /// Surface pressure per kilogram of atmosphere: `g / 4πR²`, read off the
  /// reference so it agrees exactly with [surfacePressurePa].
  double get pascalsPerKg => _referenceMass <= 0
      ? gravity / _area
      : referenceAir.seaLevelPressure / _referenceMass;

  static double _sum(Map<AtmosphereGas, double> m) {
    var s = 0.0;
    for (final g in AtmosphereGas.values) {
      s += m[g] ?? 0;
    }
    return s;
  }

  static double _massOf(Map<AtmosphereGas, double> m) {
    var s = 0.0;
    for (final g in AtmosphereGas.values) {
      s += (m[g] ?? 0) * AtmosphericComposition.molarMass[g]!;
    }
    return s;
  }

  static double _meanMolarMassOf(Map<AtmosphereGas, double> m) {
    final n = _sum(m);
    return n <= 0 ? 0 : _massOf(m) / n;
  }
}
