// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What a colony's traffic laws ask of its vehicles, and what its roads cost
/// it in crashes (docs/plans/desire-paths.md §4, §8).
///
/// [TrafficPolicy] is the laws read once into numbers the agents' consumers
/// take (junction penalties, lane speed, kerb parking, car ownership): one
/// per colony, never a global knob, so two colonies under different laws
/// drive differently in one world. [TrafficSafety] is the crash model:
/// aggregate, deterministic, read off the distance the colony drives.
library;

import 'city_sim.dart' show Law;

class TrafficPolicy {
  const TrafficPolicy({
    this.junctionScale = 1,
    this.speedScale = 1,
    this.ownershipScale = 1,
    this.crashScale = 1,
    this.injuryScale = 1,
    this.kerbParking = true,
  });

  /// No traffic law at all: every number at its neutral value, which is how
  /// every colony drove before the laws existed.
  static const TrafficPolicy lawless = TrafficPolicy();

  /// Multiplies every junction's routing penalty: right-of-way makes a
  /// junction quicker to cross (Traffic Code), walkers' priority slower.
  final double junctionScale;

  /// Multiplies every lane's speed (Speed Limits). Free-flow times are NOT
  /// scaled, so a slower town reads as a slower commute.
  final double speedScale;

  /// Multiplies the share of arrivals who bring a car (Vehicle Licensing).
  final double ownershipScale;

  /// Multiply the crash rate, and the harm each crash does.
  final double crashScale, injuryScale;

  /// Whether a car may park at the kerb (Parking Ordinance bans it).
  final bool kerbParking;

  factory TrafficPolicy.of(Set<Law> laws) {
    if (!laws.any(_traffic.contains)) return lawless;
    var junction = 1.0, speed = 1.0, own = 1.0, crash = 1.0, injury = 1.0;
    if (laws.contains(Law.trafficCode)) {
      junction *= 0.7;
      crash *= 0.35;
    }
    if (laws.contains(Law.speedLimits)) {
      speed *= 0.8;
      crash *= 0.6;
      injury *= 0.6;
    }
    if (laws.contains(Law.pedestrianPriority)) {
      junction *= 1.25;
      crash *= 0.8;
    }
    if (laws.contains(Law.vehicleLicensing)) {
      own *= 0.75;
      crash *= 0.7;
    }
    return TrafficPolicy(
      junctionScale: junction,
      speedScale: speed,
      ownershipScale: own,
      crashScale: crash,
      injuryScale: injury,
      kerbParking: !laws.contains(Law.parkingOrdinance),
    );
  }

  static const _traffic = {
    Law.trafficCode,
    Law.speedLimits,
    Law.parkingOrdinance,
    Law.pedestrianPriority,
    Law.vehicleLicensing,
  };

  @override
  bool operator ==(Object other) =>
      other is TrafficPolicy &&
      other.junctionScale == junctionScale &&
      other.speedScale == speedScale &&
      other.ownershipScale == ownershipScale &&
      other.crashScale == crashScale &&
      other.injuryScale == injuryScale &&
      other.kerbParking == kerbParking;

  @override
  int get hashCode => Object.hash(junctionScale, speedScale, ownershipScale,
      crashScale, injuryScale, kerbParking);
}

/// Crashes per kilometre driven with no law at all. A game's rate, not a
/// road safety statistic: a town of a thousand driving ten kilometres a day
/// each has five a day, enough to be felt and to argue for a Traffic Code.
const double kCrashesPerKm = 0.0005;

/// An off-road kilometre is unmarked, unlit and steep: it counts as this
/// many on a road.
const double kOffRoadCrashWeight = 1.5;

/// The share of crashes that kill someone.
const double kCrashFatalShare = 0.05;

/// Colony seconds the crashes-a-day reading averages over.
const double _dayS = 86400;

/// The crash model (§8 "Crashes"). Fed the metres driven each tick; owes
/// whole crashes as the expected count crosses each integer, so a run is
/// the same run every time (no draw).
class TrafficSafety {
  /// Crashes so far, and the dead and injured they left.
  int crashes = 0;
  double injured = 0, killed = 0;

  /// An exponential average of crashes per colony day.
  double crashesPerDay = 0;

  double _owed = 0;

  /// Deaths this tick, to join the colony's death rate as a rate.
  double _deathsThisTick = 0;

  /// [roadM] metres driven on roads and [offRoadM] across open ground over
  /// [dtS] colony seconds, under [policy]. Returns the crashes it owed.
  int advance(double dtS, double roadM, double offRoadM, TrafficPolicy policy) {
    _deathsThisTick = 0;
    if (dtS <= 0) return 0;
    final km = (roadM + offRoadM * kOffRoadCrashWeight) / 1000;
    _owed += km * kCrashesPerKm * policy.crashScale;
    var n = 0;
    // A hair under 1: ten thousand thousandths add up to 0.99999…, and
    // the crash they make is owed all the same.
    while (_owed >= 1 - 1e-9) {
      _owed -= 1;
      n++;
    }
    if (n > 0) {
      crashes += n;
      injured += n * policy.injuryScale;
      final dead = n * kCrashFatalShare * policy.injuryScale;
      killed += dead;
      _deathsThisTick = dead;
    }
    // An instantaneous rate, averaged over a day.
    final rate = n / dtS * _dayS;
    final a = (dtS / _dayS).clamp(0.0, 1.0);
    crashesPerDay += a * (rate - crashesPerDay);
    return n;
  }

  /// This tick's crash deaths as a rate over [dtS], people per second.
  double deathRate(double dtS) => dtS > 0 ? _deathsThisTick / dtS : 0;

  Map<String, dynamic>? toJson() => crashes == 0 && _owed == 0
      ? null
      : {
          'n': crashes,
          'inj': injured,
          'dead': killed,
          'day': crashesPerDay,
          'owed': _owed,
        };

  static TrafficSafety fromJson(Map<String, dynamic>? j) {
    final s = TrafficSafety();
    if (j == null) return s;
    s.crashes = (j['n'] as num?)?.toInt() ?? 0;
    s.injured = (j['inj'] as num?)?.toDouble() ?? 0;
    s.killed = (j['dead'] as num?)?.toDouble() ?? 0;
    s.crashesPerDay = (j['day'] as num?)?.toDouble() ?? 0;
    s._owed = (j['owed'] as num?)?.toDouble() ?? 0;
    return s;
  }
}
