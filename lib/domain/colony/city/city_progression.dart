// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Milestones: the shape a colony grows through, as the city-builder mode
/// reads it.
///
/// The building catalogue ALREADY gates each entry behind an `unlockPop`, and
/// [CitySim.unlocked] is the one place that gate is asked about. Milestones are
/// therefore named BANDS over those same numbers — never a second gate. A tier
/// exists to give the player a name for where they are, a list of what the next
/// one opens, and a payout for getting there; if it invented its own thresholds
/// the palette and the milestone panel would disagree about what is buildable,
/// which is the exact bug this comment exists to prevent.
///
/// Pure data + arithmetic: no [CitySim] import, so the dependency runs one way
/// (the sim claims milestones, the milestones know nothing about the sim).
library;

import 'city_building_spec.dart';

/// One rung of the ladder: a population the colony passes, what passing it pays
/// out, and (derived) what the catalogue opens at that population.
class CityMilestone {
  /// Rank in [CityProgression.all], and the id a save persists. Stable:
  /// appending a tier is safe, re-ordering is not.
  final int tier;

  /// What the colony is called once it reaches this size.
  final String name;

  /// Population that reaches this tier.
  final int population;

  /// One-off treasury grant (§) for reaching it — the "milestone reward".
  final double fundsGrant;

  /// One-off materials drop (ore). Ore is what construction actually costs, so
  /// this is the half of the reward that lets the player build something with
  /// what they just unlocked rather than look at it.
  final double oreGrant;

  /// One line on what this rung is FOR, shown under its name.
  final String blurb;

  const CityMilestone({
    required this.tier,
    required this.name,
    required this.population,
    required this.fundsGrant,
    required this.oreGrant,
    required this.blurb,
  });
}

/// A milestone actually collected: the rung, and what the treasury and the
/// stockpile REALLY received.
///
/// The ore half is not always the ore promised. Ore is a physical commodity
/// under a storage cap, so a grant bigger than the colony's remaining space
/// spills — and a banner claiming 3,200 ore when 400 arrived is the kind of
/// small lie that makes a player stop trusting the readouts. Recording the
/// credited amount lets the banner say what happened, and teaches the storage
/// mechanic at the exact moment it bites.
class CityMilestoneAward {
  const CityMilestoneAward(this.milestone, this.funds, this.ore);

  final CityMilestone milestone;
  final double funds;

  /// Ore that FITTED. Short of [CityMilestone.oreGrant] when storage was full.
  final double ore;

  /// Whether storage clipped the delivery.
  bool get spilled => ore + 1e-6 < milestone.oreGrant;
}

/// The milestone ladder, and the queries the HUD and the sim ask of it.
class CityProgression {
  const CityProgression._();

  /// The ladder. Thresholds are chosen to land ON the catalogue's `unlockPop`
  /// values so that every tier above the first opens something — a milestone
  /// that unlocks nothing reads as a bug even when the payout is real.
  static const List<CityMilestone> all = [
    CityMilestone(
      tier: 0,
      name: 'Landing Site',
      population: 0,
      fundsGrant: 0,
      oreGrant: 0,
      blurb: 'A pad, a road and a crew. Zone something and connect it.',
    ),
    CityMilestone(
      tier: 1,
      name: 'Outpost',
      population: 60,
      fundsGrant: 1500,
      oreGrant: 250,
      blurb: 'Enough people to be worth feeding and policing.',
    ),
    CityMilestone(
      tier: 2,
      name: 'Waystation',
      population: 80,
      fundsGrant: 2500,
      oreGrant: 350,
      blurb: 'Power and water stop being an afterthought.',
    ),
    CityMilestone(
      tier: 3,
      name: 'Settlement',
      population: 120,
      fundsGrant: 4000,
      oreGrant: 500,
      blurb: 'Industry arrives, and with it the first real pollution.',
    ),
    CityMilestone(
      tier: 4,
      name: 'Township',
      population: 200,
      fundsGrant: 6500,
      oreGrant: 750,
      blurb: 'Schools, medicine, and somewhere to put the dead.',
    ),
    CityMilestone(
      tier: 5,
      name: 'Small Town',
      population: 300,
      fundsGrant: 10000,
      oreGrant: 1100,
      blurb: 'Heavy industry and the storage to feed it.',
    ),
    CityMilestone(
      tier: 6,
      name: 'Town',
      population: 400,
      fundsGrant: 15000,
      oreGrant: 1600,
      blurb: 'Refineries, mines and a police force to watch them.',
    ),
    CityMilestone(
      tier: 7,
      name: 'City',
      population: 600,
      fundsGrant: 22000,
      oreGrant: 2300,
      blurb: 'Compute, research and a skyline worth the name.',
    ),
    CityMilestone(
      tier: 8,
      name: 'Metropolis',
      population: 800,
      fundsGrant: 32000,
      oreGrant: 3200,
      blurb: 'Everything a world capital needs, and the problems with it.',
    ),
    CityMilestone(
      tier: 9,
      name: 'Capital',
      population: 1000,
      fundsGrant: 50000,
      oreGrant: 5000,
      blurb: 'The seat of a world. Nothing in the catalogue is closed to you.',
    ),
  ];

  /// The highest tier [population] has reached. Never null — tier 0 is the
  /// founding state, so a colony always sits somewhere on the ladder.
  static CityMilestone reached(double population) {
    var best = all.first;
    for (final m in all) {
      if (population + 1e-9 >= m.population) best = m;
    }
    return best;
  }

  /// The rung being climbed toward, or null at the top of the ladder.
  static CityMilestone? next(double population) {
    for (final m in all) {
      if (population + 1e-9 < m.population) return m;
    }
    return null;
  }

  /// Progress toward [next], 0..1. Returns 1 at the top of the ladder so a
  /// progress bar reads "done" rather than "empty" for a finished city.
  static double fractionToNext(double population) {
    final to = next(population);
    if (to == null) return 1;
    final from = reached(population).population;
    final span = to.population - from;
    if (span <= 0) return 1;
    return ((population - from) / span).clamp(0.0, 1.0);
  }

  /// Catalogue entries this tier puts within reach: everything gated above the
  /// PREVIOUS tier's population and at or below this one's.
  ///
  /// Derived rather than listed so the panel cannot drift from the catalogue —
  /// adding a building with a new `unlockPop` files it under the right tier
  /// with no second edit here.
  static List<CityBuildingSpec> unlockedBy(CityMilestone m) {
    final floor = m.tier == 0 ? -1 : all[m.tier - 1].population;
    return [
      for (final s in kUtilCatalog)
        if (s.unlockPop > floor && s.unlockPop <= m.population) s,
    ];
  }

  /// Tiers [population] has reached that are not yet in [claimed], lowest
  /// first — a colony that jumps two rungs in one tick collects both, in order.
  static List<CityMilestone> claimable(double population, Set<int> claimed) => [
        for (final m in all)
          if (population + 1e-9 >= m.population && !claimed.contains(m.tier)) m,
      ];
}
