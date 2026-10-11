// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What an operation reads from colonies, once, at launch
/// (docs/plans/combat.md §7.3).
///
/// Plain values, no colony behind them. The colony side fills them
/// (`city_war.dart`); the operation is built from them and never looks at a
/// colony again — after launch it hears only the events colonies post from
/// their own tick. That is what keeps a battle deterministic while the
/// colonies around it are not.
library;

/// One building that can field troopers.
class TrooperSource {
  const TrooperSource({
    required this.siteId,
    required this.type,
    required this.jobs,
    required this.ready,
    required this.available,
    required this.kitPerTrooperDay,
    this.notReadyWhy,
  });

  /// `cell:<key>` for a grid building, else the parcel id.
  final String siteId;

  /// `barracks` or `base`.
  final String type;

  /// Its job count: what a deployed share is measured against.
  final int jobs;

  /// Every input in stock: the test the production loop already applies.
  final bool ready;

  /// Troopers it can field now: half its staff (the rest are support who
  /// stay home), at the strike throttle, less any already away.
  final int available;

  /// Rations, ammo, guns (or fuel) per trooper per operation day: the
  /// building's own inputs × day / jobs, so kit tuning lives in one place.
  final Map<String, double> kitPerTrooperDay;

  /// Why it is not ready, in player words ("short of ammo").
  final String? notReadyWhy;
}

/// A colony the player can draw troopers from.
class SourceSnapshot {
  const SourceSnapshot({
    required this.colonyId,
    required this.name,
    required this.bodyId,
    required this.sources,
    required this.stock,
  });

  final String colonyId;
  final String name;
  final String bodyId;

  /// In site id order.
  final List<TrooperSource> sources;

  /// Rations, ammo, guns, fuel on hand: what kit is drawn from.
  final Map<String, double> stock;

  int get available {
    var n = 0;
    for (final s in sources) {
      if (s.ready) n += s.available;
    }
    return n;
  }
}

/// The colony being fought over, as it stood at launch.
class LaunchSnapshot {
  const LaunchSnapshot({
    required this.colonyId,
    required this.bodyId,
    required this.population,
    required this.mood,
    required this.hunger,
    required this.severity,
    required this.wish,
    required this.spaceportJobs,
    required this.gunsInStock,
    required this.portSeized,
    this.portWidth = 24,
    this.portFortification = 1.3,
  });

  final String colonyId;
  final String bodyId;
  final double population;
  final double mood;

  /// 1 − food security.
  final double hunger;

  /// How badly it was run, 0..1 (the reclaim grievance formula, on its live
  /// loyalty state for a colony that has not seceded).
  final double severity;

  /// Its wish to rejoin; 0 in standoff.
  final double wish;
  final int spaceportJobs;
  final int gunsInStock;
  final bool portSeized;

  /// The Port objective's width and the fortification its defenders fight
  /// behind (+0.3: a building stands on it).
  final double portWidth;
  final double portFortification;
}
