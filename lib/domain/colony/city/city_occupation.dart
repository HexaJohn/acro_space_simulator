// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A colony held by force (docs/plans/combat.md §7A): what a garrison in its
/// streets does to it.
///
/// The transitions — taken, thrown out, withdrawn, its charter restored — are
/// the loyalty model's (`CityLoyalty.occupy` and its neighbours), and the
/// garrison's upkeep is the war state's (`city_war.dart`). Here is the weight
/// of it: suppression, which holds rebellion and misrule down, and the mood it
/// costs. Neglect is not suppressed. Occupation is ruling under guard, not a
/// timer: past the grace days the colony must be governed like any other to
/// be kept.
library;

import 'dart:math' as math;

import 'city_sim.dart';

extension CityOccupation on CitySim {
  /// The most a garrison can suppress.
  static const double suppressionCap = 0.8;

  /// One trooper sits on this share of the population: s = n / (0.05·pop).
  static const double peoplePerTrooperShare = 0.05;

  /// Mood a full garrison costs (×s), and what requisitioning its kit from
  /// the colony's own stores adds.
  static const double moodCost = 0.1;
  static const double requisitionMood = 0.05;

  /// Troopers of an occupation garrison holding the colony.
  int get occupationTroopers {
    final g = war.garrison;
    return g != null && g.occupation ? g.count : 0;
  }

  /// The troopers the occupation sits on the colony with: its garrison, and
  /// the base turrets it kept as its post (combat.md §7D).
  int get occupationSuppressing {
    final g = war.garrison;
    return g != null && g.occupation ? g.suppressing : 0;
  }

  /// 0..[suppressionCap]: how hard the garrison sits on the colony. Zero for
  /// a colony not occupied.
  double get suppression {
    if (!loyalty.occupied) return 0;
    final n = occupationSuppressing;
    if (n <= 0) return 0;
    final pop = population;
    if (pop <= 1e-9) return suppressionCap;
    return math.min(suppressionCap, n / (peoplePerTrooperShare * pop));
  }

  /// What the occupation takes off the colony's mood target this tick.
  double get occupationMoodCost => loyalty.occupied
      ? moodCost * suppression + (war.requisitioning ? requisitionMood : 0.0)
      : 0.0;
}
