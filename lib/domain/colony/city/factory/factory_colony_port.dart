// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The ONLY way a floor touches its colony (docs/plans/factory-floors.md §3
/// "Coupling to the colony", §6).
///
/// Every track builds and tests against this interface; integration (phase
/// 3) is one real implementation inside `CitySim`. Docks [take] raw goods
/// from the colony's stock and [give] products back; the colony's power and
/// staffing throttles scale how fast the floor runs (a brownout is a slow
/// factory, not a stopped one).
library;

abstract interface class FactoryColonyPort {
  /// Withdraws up to [units] of [commodity]; returns what was granted
  /// (never more than asked, never negative).
  double take(String commodity, double units);

  /// Deposits up to [units] of [commodity]; returns what was accepted
  /// (the colony's storage cap may refuse the rest).
  double give(String commodity, double units);

  /// 0..1 share of the floor's power demand the colony can meet now.
  double get powerShare;

  /// 0..1 share of the floor's job demand the colony can staff now.
  double get staffingShare;
}

/// The editor's sandbox (phase 2): receiving never runs dry, shipping never
/// fills, and everything is fully powered and staffed. Tallies what crossed
/// the docks so a sandbox floor still reports its rates.
class InfiniteColonyPort implements FactoryColonyPort {
  final Map<String, double> taken = {};
  final Map<String, double> given = {};

  @override
  double take(String commodity, double units) {
    if (units <= 0) return 0;
    taken[commodity] = (taken[commodity] ?? 0) + units;
    return units;
  }

  @override
  double give(String commodity, double units) {
    if (units <= 0) return 0;
    given[commodity] = (given[commodity] ?? 0) + units;
    return units;
  }

  @override
  double get powerShare => 1;
  @override
  double get staffingShare => 1;
}

/// A finite colony for tests and headless measurement: a stock map with an
/// optional per-commodity cap, and settable throttles.
class StockColonyPort implements FactoryColonyPort {
  StockColonyPort({
    Map<String, double>? stock,
    this.cap = double.infinity,
    this.powerShare = 1,
    this.staffingShare = 1,
  }) : stock = stock ?? {};

  final Map<String, double> stock;

  /// The most of any one commodity the colony can hold.
  double cap;

  @override
  double powerShare;
  @override
  double staffingShare;

  @override
  double take(String commodity, double units) {
    if (units <= 0) return 0;
    final have = stock[commodity] ?? 0;
    final got = units < have ? units : have;
    stock[commodity] = have - got;
    return got;
  }

  @override
  double give(String commodity, double units) {
    if (units <= 0) return 0;
    final have = stock[commodity] ?? 0;
    final room = cap - have;
    final put = units < room ? units : (room > 0 ? room : 0.0);
    stock[commodity] = have + put;
    return put;
  }
}
