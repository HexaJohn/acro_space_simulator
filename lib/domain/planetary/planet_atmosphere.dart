// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A world's air as an inventory of gas (docs/plans/terraforming.md §3.1-3.2).
///
/// A body's atmosphere used to be reference data: a hand-tuned
/// `AtmosphereModel` and a gas mix, both immutable, so nothing a colony did
/// could ever change the air it breathed, the drag a craft felt or the colour
/// of the sky. This makes the air WORLD STATE — moles of each gas, plus the
/// volatiles the planet holds back — and re-derives everything else from it
/// with the same identities the air model is already built on:
///
/// ```
/// mass  = Σ moles_i × M_i
/// P     = mass × g / (4πR²)            (hydrostatic column)
/// x_i   = moles_i / Σ moles            (composition)
/// μ     = Σ x_i M_i                    (mean molar mass)
/// T     = T_eq + greenhouse − aerosol  (PlanetClimate)
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
import 'atmosphere_flows.dart';
import 'atmospheric_composition.dart';
import 'planet_climate.dart';
import 'volatile_reservoir.dart';

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
    required this.mu,
    required this.gravity,
    required this.bodyRadiusM,
    required this.solarFlux,
    required this.albedo,
    required this.climate,
    required this.referenceAir,
    required this.referenceComposition,
    required Map<AtmosphereGas, double> referenceMoles,
    required List<VolatileReservoir> reservoirs,
  })  : _referenceMoles = Map.unmodifiable(referenceMoles),
        _moles = Map.of(referenceMoles),
        reservoirs = List.unmodifiable(reservoirs) {
    _referenceMass = _massOf(_referenceMoles);
    _referenceMolarMass = _meanMolarMassOf(_referenceMoles);
    // The residual the climate model leaves on the reference sky, kept so an
    // untouched world reads back its hand-tuned temperature exactly and the
    // model only ever contributes CHANGES. Within ~3 K for every reference
    // air (see PlanetClimate); zero for a world that had none to match.
    final ref = referenceAir;
    _calibrationK = ref == null
        ? 0
        : ref.seaLevelTemperature - _modelTemperature(_referenceMoles, 0, 0);
    markPublished();
  }

  /// The inventory a body starts with: its reference composition times the
  /// total moles its reference surface pressure implies, and the volatile
  /// reservoirs it holds back (`VolatileReservoir.forBody`).
  ///
  /// An airless rocky world gets an EMPTY inventory: with escape modelled
  /// (phase 2), gas vented onto the Moon leaks away instead of staying for
  /// ever, so it can be state like any other sky. Null only for a star, and
  /// for a world with a gas mix but no air model — the giants, which have no
  /// surface to hold a sky against.
  ///
  /// [reservoirs] replaces the body's default stores — the optimistic-Mars
  /// case, or a world given ones it does not have.
  static PlanetAtmosphere? seed(CelestialBody body,
      {PlanetClimate climate = const PlanetClimate(),
      List<VolatileReservoir>? reservoirs}) {
    if (body.isStar || body.radius <= 0 || body.mu <= 0) return null;
    final g = body.mu / (body.radius * body.radius);
    final air = body.atmosphere;
    final mix = body.composition;
    PlanetAtmosphere make(AtmosphereModel? air, AtmosphericComposition? mix,
            Map<AtmosphereGas, double> moles) =>
        PlanetAtmosphere._(
          bodyId: body.id.value,
          mu: body.mu,
          gravity: g,
          bodyRadiusM: body.radius,
          solarFlux: body.solarFlux,
          albedo: PlanetClimate.albedoOf(body.id.value),
          climate: climate,
          referenceAir: air,
          referenceComposition: mix,
          referenceMoles: moles,
          reservoirs: reservoirs ?? VolatileReservoir.forBody(body.id.value),
        );
    if (air == null) {
      if (mix != null && mix.fractions.isNotEmpty) return null;
      return make(null, null, const {});
    }
    if (mix == null || mix.fractions.isEmpty || air.seaLevelPressure <= 0) {
      return null;
    }
    final total = totalMolesFor(
      surfacePressurePa: air.seaLevelPressure,
      gravity: g,
      bodyRadiusM: body.radius,
      meanMolarMassKgPerMol: mix.meanMolecularWeight,
    );
    if (total <= 0) return null;
    return make(air, mix, {
      for (final e in mix.fractions.entries) e.key: e.value * total,
    });
  }

  final String bodyId;

  /// Gravitational parameter (m³/s²): what escape is measured against.
  final double mu;

  /// Surface gravity (m/s²), from the body's mu and radius.
  final double gravity;
  final double bodyRadiusM;

  /// Sunlight at the body (W/m²) and its Bond albedo: the climate's inputs.
  final double solarFlux;
  final double albedo;
  final PlanetClimate climate;

  /// The body's air as the system definition built it — null for a world
  /// that had none. Everything derived for a world WITH reference air is a
  /// RATIO against this: every body's air is hand-tuned, and an unchanged
  /// inventory must hand back these exact objects, so the inventory can only
  /// ever change a world something has actually changed.
  final AtmosphereModel? referenceAir;
  final AtmosphericComposition? referenceComposition;

  /// The volatiles the world holds back from its air (Mars's caps and soil),
  /// in a fixed order. Their [VolatileReservoir.moles] are state.
  final List<VolatileReservoir> reservoirs;

  final Map<AtmosphereGas, double> _referenceMoles;
  final Map<AtmosphereGas, double> _moles;
  late final double _referenceMass;
  late final double _referenceMolarMass;
  late final double _calibrationK;

  /// Dimensionless aerosol/particulate loading, 0 = clean. Unlike the gases
  /// this SETTLES, so it tracks current activity rather than accumulating
  /// forever — which is why a colony that cleans up sees its sky clear within
  /// a season while its CO2 stays put. Raises the albedo a little
  /// ([GreenhouseTuning.aerosolAlbedo]).
  double aerosolBurden = 0;

  /// Super-greenhouse agent (a PFC mix) in the air, mol. A trace gas kept
  /// apart from the eight-gas enum (§3.1): it is forcing, not air — it adds
  /// nothing to the pressure or the mix a craft or a lung sees. Phase 3's
  /// Greenhouse Factory fills it.
  double greenhouseAgentMoles = 0;

  /// Molar mass of the agent: octafluoropropane (C3F8), the best single gas
  /// of Gerstell et al. 2001.
  static const double agentMolarMass = 0.188;

  /// Share of escape suppressed, 0..1. The hook the phase-3 Atmospheric
  /// Retention Array drives (§7 Q2); 0 = the world leaks at its Jeans rate.
  double escapeSuppression = 0;

  /// What the colonies on this body have produced since its air was last
  /// integrated — usually nothing between ticks, but a frame-budgeted
  /// colony's replays land after the tick's planetary phase and so always
  /// wait here for the next one. Part of the state, saved and reset with it
  /// (see [AtmosphereFlows]).
  AtmosphereFlows? _pending;

  /// The flows the next integration will take, created on first use.
  AtmosphereFlows get pendingFlows => _pending ??= AtmosphereFlows();

  /// Hand over the waiting flows (null if none) and start afresh.
  AtmosphereFlows? takePendingFlows() {
    final f = _pending;
    _pending = null;
    return f;
  }

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

  /// Drop every gas the reference air never had once fewer than [minMoles]
  /// of it remain. Leak and condensation approach zero without reaching it;
  /// pruned, an emptied Moon is its exact (empty) reference again, and rests.
  void pruneTrace(double minMoles) {
    _moles.removeWhere(
        (g, n) => !_referenceMoles.containsKey(g) && n < minMoles);
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
  /// built from that same identity. A world with no reference air has only
  /// the identity.
  double get surfacePressurePa => pressureFor(_moles);

  /// Surface pressure (Pa) an inventory [m] of this world would have.
  double pressureFor(Map<AtmosphereGas, double> m) {
    final ref = referenceAir;
    if (ref == null || _referenceMass <= 0) return gravity / _area * _massOf(m);
    return ref.seaLevelPressure * (_massOf(m) / _referenceMass);
  }

  /// Partial pressure of [gas] at the surface (Pa): its mole fraction of the
  /// surface pressure.
  double partialPressurePa(AtmosphereGas gas) =>
      partialPressureFor(_moles, gas);

  /// Partial pressure of [gas] (Pa) in an inventory [m] of this world.
  double partialPressureFor(Map<AtmosphereGas, double> m, AtmosphereGas gas) {
    final n = _sum(m);
    return n <= 0 ? 0 : pressureFor(m) * (m[gas] ?? 0) / n;
  }

  /// Partial pressure of [gas] in the reference air (Pa).
  double referencePartialPressurePa(AtmosphereGas gas) =>
      partialPressureFor(_referenceMoles, gas);

  /// The gas mix now; null for an emptied (or never-filled) sky.
  AtmosphericComposition? get composition {
    if (_matchesReferenceMoles) return referenceComposition;
    return totalMoles > 0 ? AtmosphericComposition(Map.of(_moles)) : null;
  }

  /// Mean molar mass now (kg/mol). Falls back to the reference value for an
  /// emptied atmosphere, so the derived air stays finite as it vanishes.
  double get meanMolarMass {
    final m = _meanMolarMassOf(_moles);
    return m > 0 ? m : _referenceMolarMass;
  }

  // ---- climate -------------------------------------------------------------

  /// What the climate model misses this world's reference temperature by
  /// (K), and so adds back: within ~3 K for every reference sky.
  double get climateCalibrationK => _calibrationK;

  /// Surface temperature at reference (K).
  double get referenceTemperatureK =>
      referenceAir?.seaLevelTemperature ??
      _modelTemperature(_referenceMoles, 0, 0);

  /// Mean surface temperature now (K): the reference exactly while nothing
  /// that sets it has moved, the climate model otherwise.
  double get surfaceTemperatureK =>
      _isReference ? referenceTemperatureK : temperatureFor(_moles);

  /// Surface temperature (K) an inventory [m] of this world would have, with
  /// the current agent and haze unless given.
  double temperatureFor(Map<AtmosphereGas, double> m,
          {double? agentMoles, double? aerosol}) =>
      _modelTemperature(
          m, agentMoles ?? greenhouseAgentMoles, aerosol ?? aerosolBurden) +
      _calibrationK;

  /// Radiative-equilibrium temperature (K), haze included.
  double get equilibriumTemperatureK => PlanetClimate.equilibriumTemperature(
      solarFlux, climate.effectiveAlbedo(albedo, aerosolBurden));

  /// Partial pressure of the super-greenhouse agent (Pa): its own column
  /// weight, so it reads the same on a thick sky or an empty one.
  double get agentPartialPressurePa =>
      math.max(0.0, greenhouseAgentMoles) * agentMolarMass * pascalsPerKg;

  double _modelTemperature(
      Map<AtmosphereGas, double> m, double agentMoles, double aerosol) {
    final teq = PlanetClimate.equilibriumTemperature(
        solarFlux, climate.effectiveAlbedo(albedo, aerosol));
    final p = pressureFor(m);
    final n = _sum(m);
    final tau = climate.opticalDepth(
      pressurePa: p,
      partialPressurePa: (g) => n <= 0 ? 0 : p * (m[g] ?? 0) / n,
      agentPa: math.max(0.0, agentMoles) * agentMolarMass * pascalsPerKg,
    );
    return PlanetClimate.greyTemperature(teq, tau);
  }

  // ---- derived air ---------------------------------------------------------

  /// Where a built-from-scratch sky ends (Pa, absolute): about where the
  /// hand-tuned Earth and Mars models put their tops (7e-3 Pa both).
  static const double vacuumPressurePa = 7e-3;

  /// The least surface pressure (Pa) a world that had no air publishes as a
  /// sky — about Pluto's. Below it the body stays airless for flight, the
  /// renderer and the warp limiter: one lunar colony's industry holds ~0.1
  /// Pa of CO2 against the leak, and that is not worth an atmosphere shell
  /// reaching a hundred kilometres up and clamping warp for every low orbit.
  static const double skyThresholdPa = 1.0;

  /// The air model this inventory implies (§3.2); null for no sky.
  ///
  /// For a world with reference air, as ratios against it:
  ///  * pressure follows the column mass;
  ///  * density follows `P μ / RT` — pressure, molar-mass and inverse
  ///    temperature ratios;
  ///  * scale height follows `T / μ`, the specific gas constant `1/μ`;
  ///  * the top of the atmosphere moves so it still sits at the same absolute
  ///    pressure it did: thicker air reaches higher before it counts as space.
  ///    A fixed top would cut a 30-fold-thicker Mars off at a height where its
  ///    air is still thirty times denser than the reference ever was there.
  /// A world that had none is built from the identities directly.
  AtmosphereModel? get air {
    final ref = referenceAir;
    if (_isReference) return ref;
    final t = surfaceTemperatureK;
    if (ref == null) return _airFromScratch(t);
    final pr = _referenceMass <= 0 ? 0.0 : massKg / _referenceMass;
    final mr = meanMolarMass / _referenceMolarMass;
    final tr = t / ref.seaLevelTemperature;
    final scaleHeight = ref.scaleHeight * tr / mr;
    final top = pr <= 0
        ? 0.0
        : math.max(
            0.0,
            scaleHeight *
                (ref.atmosphereHeight / ref.scaleHeight + math.log(pr)));
    return AtmosphereModel(
      seaLevelPressure: ref.seaLevelPressure * pr,
      seaLevelDensity: ref.seaLevelDensity * pr * mr / tr,
      seaLevelTemperature: t,
      scaleHeight: scaleHeight,
      atmosphereHeight: top,
      lapseRate: ref.lapseRate,
      gamma: ref.gamma,
      specificGasConstant: ref.specificGasConstant / mr,
    );
  }

  AtmosphereModel? _airFromScratch(double t) {
    final p = surfacePressurePa;
    final mu = _meanMolarMassOf(_moles);
    if (p < skyThresholdPa || mu <= 0 || t <= 0) return null;
    final rSpecific = 8.314462618 / mu;
    final h = rSpecific * t / gravity;
    return AtmosphereModel(
      seaLevelPressure: p,
      seaLevelDensity: p / (rSpecific * t),
      seaLevelTemperature: t,
      scaleHeight: h,
      atmosphereHeight: h * math.log(p / vacuumPressurePa),
      // Earth's environmental lapse rate, scaled by gravity (the adiabat is
      // g / c_p).
      lapseRate: 0.0065 * gravity / 9.80665,
      specificGasConstant: rSpecific,
    );
  }

  /// [body] carrying this inventory's air: what gets republished into the
  /// universe so flight, colonies, the renderer and snapshots all read one sky.
  /// A sky too thin to count clears both the air and the mix, so an emptied
  /// Moon is airless again rather than a vacuum with a colour.
  CelestialBody applyTo(CelestialBody body) {
    final a = air;
    final c = a == null ? null : composition;
    return body.copyWith(
      atmosphere: a,
      composition: c,
      clearAtmosphere: a == null,
      clearComposition: c == null,
    );
  }

  /// Change in [gas] since seeding, as a fraction of the reference
  /// atmosphere — the yardstick for "has anything measurably moved". A world
  /// that started airless measures against the sky it has now.
  double fractionChange(AtmosphereGas gas) {
    final n = referenceTotalMoles > 0 ? referenceTotalMoles : totalMoles;
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

  bool get _matchesReferenceMoles {
    if (_moles.length != _referenceMoles.length) return false;
    for (final e in _referenceMoles.entries) {
      if (_moles[e.key] != e.value) return false;
    }
    return true;
  }

  /// Is everything that sets the air at reference — the gases, the agent,
  /// the haze?
  bool get _isReference =>
      greenhouseAgentMoles == 0 && aerosolBurden == 0 && _matchesReferenceMoles;

  /// Nothing to integrate: the air, the haze and every reservoir are at
  /// reference and no flows are waiting. The reference is a steady state —
  /// the geological outgassing and loss that hold today's air where it is
  /// are far below anything a game can watch — so an untouched world stays
  /// bit-for-bit untouched instead of accumulating rounding.
  bool get isAtRest {
    if (_pending != null || !_isReference) return false;
    for (final r in reservoirs) {
      if (r.moles != r.referenceMoles) return false;
    }
    return true;
  }

  // ---- publishing ----------------------------------------------------------

  double _publishedMass = 0;
  double _publishedTemperature = 0;
  bool _publishedSky = false;

  /// Does the inventory make a sky [air] publishes? Always, for a world with
  /// reference air (its model only thins); for one without, from
  /// [skyThresholdPa].
  bool get _hasSky =>
      referenceAir != null || surfacePressurePa >= skyThresholdPa;
  final Map<AtmosphereGas, double> _publishedFractions = {};

  /// Has the air moved far enough from what was last published to be worth
  /// republishing the body? Relative pressure, relative temperature or any
  /// absolute mole fraction past [tolerance].
  ///
  /// Republishing swaps a body in the universe, which is cheap but not free,
  /// and the render descriptor only refreshes at ~1 Hz anyway — while a
  /// tower programme moves Mars's air by a part in a billion per tick at 1×.
  /// So the threshold, not the tick, decides when the world sees the change;
  /// under warp, where each step moves it a lot, that is every tick.
  bool needsPublish({double tolerance = 1e-6}) {
    final sky = _hasSky;
    if (sky != _publishedSky) return true;
    // Gas below a sky's worth, leaking toward nothing, changes nothing
    // anyone can see: the body is airless either way.
    if (!sky) return false;
    final mass = massKg;
    if (_publishedMass <= 0) {
      if (mass > 0) return true;
    } else if ((mass / _publishedMass - 1).abs() > tolerance) {
      return true;
    }
    final n = totalMoles;
    if (n <= 0) return false;
    if (_publishedTemperature > 0 &&
        (surfaceTemperatureK / _publishedTemperature - 1).abs() > tolerance) {
      return true;
    }
    for (final g in AtmosphereGas.values) {
      final x = molesOf(g) / n;
      if ((x - (_publishedFractions[g] ?? 0)).abs() > tolerance) return true;
    }
    return false;
  }

  /// Record the current air as published.
  void markPublished() {
    _publishedSky = _hasSky;
    _publishedMass = massKg;
    _publishedTemperature = surfaceTemperatureK;
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
  /// The flows waiting go too: they were the session's, not the save's.
  void resetToReference() {
    _moles
      ..clear()
      ..addAll(_referenceMoles);
    aerosolBurden = 0;
    greenhouseAgentMoles = 0;
    escapeSuppression = 0;
    for (final r in reservoirs) {
      r.resetToReference();
    }
    _pending = null;
  }

  /// The inventory as saved. Gases by enum NAME, so reordering or extending
  /// the enum cannot silently move moles between species; reservoirs by
  /// their stable names.
  Map<String, dynamic> toJson() => {
        'body': bodyId,
        'moles': {
          for (final g in AtmosphereGas.values)
            if (_moles.containsKey(g)) g.name: _moles[g],
        },
        if (aerosolBurden != 0) 'aerosol': aerosolBurden,
        if (greenhouseAgentMoles != 0) 'agent': greenhouseAgentMoles,
        if (escapeSuppression != 0) 'suppression': escapeSuppression,
        if (reservoirs.isNotEmpty)
          'reservoirs': {for (final r in reservoirs) r.name: r.moles},
        if (_pending case final p? when !p.isEmpty) 'pending': p.toJson(),
      };

  /// Replace the inventory with [json] (from [toJson]). A gas this build does
  /// not know is dropped rather than failing the whole load; a reservoir the
  /// save does not mention (a phase-1 save has none) keeps its reference
  /// holding.
  void restore(Map<String, dynamic> json) {
    _moles.clear();
    final saved = (json['moles'] as Map?) ?? const {};
    for (final g in AtmosphereGas.values) {
      final v = saved[g.name];
      if (v is num) _moles[g] = math.max(0.0, v.toDouble());
    }
    aerosolBurden = (json['aerosol'] as num?)?.toDouble() ?? 0;
    greenhouseAgentMoles =
        math.max(0.0, (json['agent'] as num?)?.toDouble() ?? 0);
    escapeSuppression =
        ((json['suppression'] as num?)?.toDouble() ?? 0).clamp(0.0, 1.0);
    final held = (json['reservoirs'] as Map?) ?? const {};
    for (final r in reservoirs) {
      final v = held[r.name];
      r.moles = v is num ? math.max(0.0, v.toDouble()) : r.referenceMoles;
    }
    final pending = json['pending'];
    _pending = pending is Map
        ? AtmosphereFlows.fromJson(pending.cast<String, dynamic>())
        : null;
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
  double get pascalsPerKg {
    final ref = referenceAir;
    return ref == null || _referenceMass <= 0
        ? gravity / _area
        : ref.seaLevelPressure / _referenceMass;
  }

  /// Moles of [gas] an inventory [m] would need for that gas's surface
  /// partial pressure to be [targetPa], every other gas held.
  ///
  /// Adding Δ moles raises both the gas's mole fraction and the column mass,
  /// so `p(n) = k n (m_o + M n) / (N_o + n)` with k the pascals per kilogram
  /// and m_o, N_o the other gases' mass and moles — and `p(n) = target` is a
  /// quadratic with exactly one non-negative root. Closed form, so nothing
  /// that uses it depends on how time was chopped.
  double molesForPartialPressure(
      Map<AtmosphereGas, double> m, AtmosphereGas gas, double targetPa) {
    if (targetPa <= 0) return 0;
    final k = pascalsPerKg;
    if (k <= 0) return 0;
    final n = m[gas] ?? 0;
    final others = _sum(m) - n;
    final mass = _massOf(m);
    final molar = AtmosphericComposition.molarMass[gas]!;
    final otherMass = math.max(0.0, mass - molar * n);
    final a = k * molar;
    final b = k * otherMass - targetPa;
    final c = -targetPa * math.max(0.0, others);
    if (c >= 0) {
      // No other gas: the root of `k M n = target`, if any.
      return b >= 0 ? 0 : -b / a;
    }
    final disc = math.sqrt(b * b - 4 * a * c);
    // The numerically stable form of each branch: no subtraction of nearly
    // equal terms whichever sign b has.
    return b <= 0 ? (-b + disc) / (2 * a) : (2 * c) / (-b - disc);
  }

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
