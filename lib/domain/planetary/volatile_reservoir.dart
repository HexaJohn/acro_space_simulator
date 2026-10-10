// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The volatiles a world holds back from its air — polar ice, gas bound in
/// the soil — and the pressure each would hold the sky at
/// (docs/plans/terraforming.md §3.3, phase 2).
///
/// Mars's air is not a fixed quantity: it is in equilibrium with its south
/// polar CO2 ice (the pressure is pinned by the frost point of the cap) and
/// with the CO2 adsorbed in its regolith. Warm the planet and both give gas
/// up; the gas warms the planet further. That loop — the one every serious
/// Mars proposal leans on — is why these are modelled as RESERVOIRS with an
/// equilibrium pressure that rises steeply and smoothly with temperature,
/// rather than as a trigger temperature above which gas appears. A threshold
/// switches on, overshoots, cools, switches off: under warp it oscillates. A
/// smooth equilibrium curve the air relaxes toward cannot.
///
/// Each reservoir is anchored to the world's reference state: at the
/// reference temperature, the pressure it would hold the sky at is exactly
/// the reference partial pressure, so an untouched Mars is at rest and only a
/// changed one moves.
library;

import 'dart:math' as math;

import 'atmospheric_composition.dart';

/// How a reservoir holds its gas.
enum ReservoirKind {
  /// Ice at a cold trap (a polar cap): it sublimates while the sky is below
  /// its vapour pressure and frost forms on it while the sky is above.
  ice,

  /// Gas adsorbed on regolith grains: a smooth isotherm in pressure,
  /// temperature and how much the soil still holds.
  adsorbed,
}

/// One body's store of one volatile, mutable world state.
class VolatileReservoir {
  /// Ice at a cold trap [trapOffsetK] below the mean surface temperature,
  /// with sublimation enthalpy [latentHeatK] (ΔH / R, kelvin).
  ///
  /// Its vapour pressure follows Clausius-Clapeyron from the reference:
  /// `p_ref · exp(L (1/T_trap,ref − 1/T_trap))`. For a gas the reference air
  /// carries none of (Mars's hand-tuned mix leaves out its ~0.02% water), the
  /// curve is the absolute one through [triplePointPa]/[triplePointK], and
  /// only the EXCESS over the reference trap's vapour pressure is released —
  /// the reference sky still holds none, and a warmed one gains what warming
  /// adds. Above the triple point the curve continues as evaporation
  /// ([liquidLatentHeatK]) so melting is not a kink.
  VolatileReservoir.ice({
    required this.name,
    required this.gas,
    required double moles,
    required this.latentHeatK,
    required this.trapOffsetK,
    required this.relaxSeconds,
    this.triplePointPa = 0,
    this.triplePointK = 0,
    this.liquidLatentHeatK = 0,
  })  : kind = ReservoirKind.ice,
        referenceMoles = moles,
        moles = moles,
        isothermExponent = 0,
        desorptionK = 0;

  /// Gas adsorbed in regolith, on the isotherm
  /// `held ∝ p^γ · exp(−T / T_d)` (Fanale & Cannon 1974; Zent & Quinn 1995),
  /// so the sky it holds is `p_ref (held / held_ref)^(1/γ) · exp((T − T_ref)
  /// / (γ T_d))` — about ×e per γT_d ≈ 10 K of warming, falling off steeply
  /// as the soil empties, which is what bounds a release by the reservoir.
  VolatileReservoir.adsorbed({
    required this.name,
    required this.gas,
    required double moles,
    required this.relaxSeconds,
    this.isothermExponent = 0.275,
    this.desorptionK = 35,
  })  : kind = ReservoirKind.adsorbed,
        referenceMoles = moles,
        moles = moles,
        latentHeatK = 0,
        trapOffsetK = 0,
        triplePointPa = 0,
        triplePointK = 0,
        liquidLatentHeatK = 0;

  /// Stable id, saved — never reuse one for a different store.
  final String name;
  final ReservoirKind kind;
  final AtmosphereGas gas;

  /// What the world holds at reference.
  final double referenceMoles;

  /// What it holds now (mol).
  double moles;

  /// Seconds for the sky to close most (1 − 1/e) of the gap to this
  /// reservoir's equilibrium.
  final double relaxSeconds;

  final double latentHeatK;
  final double trapOffsetK;
  final double triplePointPa;
  final double triplePointK;
  final double liquidLatentHeatK;
  final double isothermExponent;
  final double desorptionK;

  /// How much of the release curve survives as the store empties: 1 at the
  /// reference holding, falling smoothly to 0 at empty. Without it a
  /// nearly-empty cap would sublimate at full vapour pressure until the last
  /// mole and then stop dead — a step under warp.
  ///
  /// Never above 1: a cap grown past its reference (industry CO2 frozen
  /// out) would otherwise lift the release line above the frost line, and
  /// in the band between them the cap would sublimate into a sky already
  /// past saturation, holding it up to 1% over the frost point.
  double get _taper {
    const eps = 0.01;
    final ref = math.max(referenceMoles, 1.0);
    final m = math.max(0.0, moles);
    return math.min(1.0, m / (m + eps * ref) * (1 + eps));
  }

  /// Vapour pressure on the absolute curve (for [ReservoirKind.ice] with no
  /// reference gas).
  double _absoluteVapourPa(double k) {
    if (k <= 0 || triplePointK <= 0) return 0;
    final l = k < triplePointK || liquidLatentHeatK <= 0
        ? latentHeatK
        : liquidLatentHeatK;
    return triplePointPa * math.exp(l * (1 / triplePointK - 1 / k));
  }

  /// The partial pressures (Pa) of [gas] this store holds the sky at, given
  /// the surface temperature [surfaceK]: below [release] it gives gas up,
  /// above [condense] it takes gas back, in between it does nothing.
  ///
  /// The two only differ for ice: frost forms at the vapour pressure whether
  /// or not any ice is left, but an emptied cap has nothing to sublimate.
  ({double release, double condense}) equilibriumPa({
    required double surfaceK,
    required double referenceSurfaceK,
    required double referencePartialPa,
  }) {
    switch (kind) {
      case ReservoirKind.ice:
        final trap = surfaceK - trapOffsetK;
        final trapRef = referenceSurfaceK - trapOffsetK;
        if (trap <= 0 || trapRef <= 0) return (release: 0, condense: 0);
        final double sat;
        if (referencePartialPa > 0) {
          sat = referencePartialPa *
              math.exp(latentHeatK * (1 / trapRef - 1 / trap));
        } else {
          sat = math.max(
              0.0, _absoluteVapourPa(trap) - _absoluteVapourPa(trapRef));
        }
        return (release: sat * _taper, condense: sat);
      case ReservoirKind.adsorbed:
        if (referencePartialPa <= 0 || referenceMoles <= 0) {
          return (release: 0, condense: 0);
        }
        final held = math.max(0.0, moles) / referenceMoles;
        final p = referencePartialPa *
            math.pow(held, 1 / isothermExponent).toDouble() *
            math.exp((surfaceK - referenceSurfaceK) /
                (isothermExponent * desorptionK));
        return (release: p, condense: p);
    }
  }

  void resetToReference() => moles = referenceMoles;

  /// The reservoirs a body starts with. Empty for every world but Mars for
  /// now (§3.3 "start with Mars").
  ///
  /// Mars (all magnitudes tunable here; the present atmosphere is 2.4e16 kg,
  /// 5.4e17 mol, and one millibar of CO2 is ~8.8e16 mol):
  ///  * **South polar CO2 ice, 6.0e17 mol** — the buried deposit in the south
  ///    polar layered deposits, ~16,500 km³ (Phillips et al. 2011, Science
  ///    332, 838; revised by Bierson et al. 2016, GRL 43, 4172), at 1.6 g/cm³:
  ///    about one more present atmosphere. The cap sits at the CO2 frost
  ///    point, ~148 K at 6 mbar — 62 K under the 210 K mean. ΔH_sub 25.9
  ///    kJ/mol. It answers to the seasons, so it relaxes in about a Mars year.
  ///  * **Regolith-adsorbed CO2, 3.5e18 mol (40 mbar)** — the upper end of
  ///    Jakosky & Edwards (2018, Nature Astronomy 2, 634), who put the CO2 the
  ///    soil can give up at no more than ~40 mbar and probably less. The heat
  ///    has to soak down into the ground to free it; the real lag is
  ///    centuries to millennia, shortened here to 20 years in the same spirit
  ///    as the tower rate scale, so a programme sees its soil respond.
  ///    Isotherm γ 0.275, T_d 35 K (Zent & Quinn 1995).
  ///  * **Polar water ice, 1.4e20 mol** — the north and south polar layered
  ///    deposits, ~1.1e6 and ~1.6e6 km³ (Zuber et al. 1998; Plaut et al.
  ///    2007), held at a cold trap 20 K under the mean. Mostly it stays put:
  ///    the trap holds the vapour to a few pascals until Mars is warm.
  ///
  /// With these the Martian release is AMPLIFYING but bounded: a pascal of
  /// PFC that alone would warm Mars ~23 K ends ~27 K up with four times the
  /// pressure and the cap gone, and the sky falls back to ~6 mbar when the
  /// PFC goes. A SELF-SUSTAINING runaway — warm and thick with the forcing
  /// removed — needs more CO2 than Jakosky & Edwards allow: in this model
  /// about two bar of it in the soil (pass `regolithCo2Moles` ≈ 1.8e20 to
  /// [marsDefaults]), the large regolith inventories the optimistic
  /// proposals assumed (McKay, Toon & Kasting 1991, Nature 352, 489). One
  /// bar is not enough: the isotherm falls off as the soil empties.
  static List<VolatileReservoir> forBody(String bodyId) => switch (bodyId) {
        'mars' => marsDefaults(),
        _ => <VolatileReservoir>[],
      };

  static const double marsCapCo2Moles = 6.0e17;
  static const double marsRegolithCo2Moles = 3.5e18;
  static const double marsWaterIceMoles = 1.4e20;
  static const double _marsYear = 686.98 * 86400;

  /// Mars's three stores, with [regolithCo2Moles] overridable for the
  /// optimistic-inventory case.
  static List<VolatileReservoir> marsDefaults({
    double capCo2Moles = marsCapCo2Moles,
    double regolithCo2Moles = marsRegolithCo2Moles,
    double waterIceMoles = marsWaterIceMoles,
  }) =>
      [
        VolatileReservoir.ice(
          name: 'polarCo2',
          gas: AtmosphereGas.carbonDioxide,
          moles: capCo2Moles,
          latentHeatK: 25900 / 8.314462618,
          trapOffsetK: 62,
          relaxSeconds: _marsYear,
        ),
        VolatileReservoir.adsorbed(
          name: 'regolithCo2',
          gas: AtmosphereGas.carbonDioxide,
          moles: regolithCo2Moles,
          relaxSeconds: 20 * 3.15576e7,
        ),
        VolatileReservoir.ice(
          name: 'polarWater',
          gas: AtmosphereGas.water,
          moles: waterIceMoles,
          latentHeatK: 51060 / 8.314462618,
          liquidLatentHeatK: 45050 / 8.314462618,
          triplePointPa: 611.657,
          triplePointK: 273.16,
          trapOffsetK: 20,
          relaxSeconds: _marsYear,
        ),
      ];
}
