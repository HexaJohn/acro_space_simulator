// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// How fast a floor really runs, measured the way Factorio's production
/// stats would show it (docs/plans/factory-floors.md §3 "Off-screen =
/// measured steady state", phase 6).
///
/// Dozens of plants can't all run at full fidelity every frame, so a floor
/// nobody is looking at runs as a handful of per-second rates instead. Those
/// rates come from here: run the floor headless, throw away the start-up
/// (belts filling, handlers walking out to their first pickups, buffers
/// priming), then step it in equal sub-windows and read each window's
/// [FactoryLedger]. The answer is the ledger totals over the measured time.
///
/// Steady-state detection: a floor with a short cycle settles long before
/// the [MeasureSettings.windowS] cap, so measurement stops as soon as the
/// latest sub-window agrees, within [MeasureSettings.tolerance] on every
/// dock rate and on power, with the mean of all the sub-windows before it
/// (and at least [kMeasureMinWindows] have run). That is the plan's "two
/// consecutive sub-windows agree", made stricter on purpose. A floor that
/// ships in lumps (a 7 s craft against 30 s windows ships 4 or 5 lumps a
/// window) can show
/// two equal windows by chance — 4 and 4 — and stopping there would report
/// 7% low. Against the running mean a lumpy window always disagrees, so
/// such a floor runs to the cap, which is the honest answer for it: the
/// quantisation error then shrinks to one lump over the whole window.
/// Windows that shipped nothing never count as agreement: that is a floor
/// still filling, not a dead one, and a truly dead layout costs only the cap
/// to discover.
///
/// Takes any [FactorySim], never a concrete floor, so the colony store and
/// the off-thread runner can measure whatever a builder returns. Pure and
/// deterministic: same floor, same settings, same rates.
library;

import 'factory_colony_port.dart';
import 'factory_ledger.dart';
import 'factory_sim_api.dart';
import 'floor_blueprint.dart';

/// Sim seconds of start-up discarded before measuring. A minute sees a
/// template-sized hall's first deliveries reach its last machine. A floor
/// that primes slower is not stopped early (its filling windows disagree
/// with the running mean), so it runs longer and the fill it still carries
/// is a smaller share of the total.
const double kMeasureWarmupS = 60;

/// Hard cap on measured sim seconds: the plan's "~5 min of sim headless".
const double kMeasureWindowS = 300;

/// One comparison window. Thirty seconds holds several cycles of every
/// phase-1 recipe (2-8 s crafts), so a settled floor's windows agree.
const double kMeasureSubWindowS = 30;

/// Relative disagreement two sub-windows may show and still be "settled":
/// 2%, well inside the ±5% template-match budget, so an early stop never
/// costs a template its pass.
const double kMeasureTolerance = 0.02;

/// Fewest sub-windows before an early stop: 90 s, so a chance run of equal
/// lumpy windows right after warm-up can't end the measurement.
const int kMeasureMinWindows = 3;

/// Rates below this (units/s, kW) count as equal to zero when comparing
/// windows, so float dust on an idle commodity can't hold the run open.
const double kMeasureAbsEps = 1e-6;

/// How a measurement runs. Plain numbers so a request can cross to a
/// worker isolate as JSON.
class MeasureSettings {
  const MeasureSettings({
    this.warmupS = kMeasureWarmupS,
    this.windowS = kMeasureWindowS,
    this.subWindowS = kMeasureSubWindowS,
    this.tolerance = kMeasureTolerance,
    this.earlyStop = true,
  });

  static const MeasureSettings standard = MeasureSettings();

  final double warmupS;

  /// The most sim seconds measured (after warm-up).
  final double windowS;
  final double subWindowS;
  final double tolerance;

  /// False = always measure the whole [windowS].
  final bool earlyStop;

  Map<String, Object?> toJson() => {
    'warm': warmupS,
    'win': windowS,
    'sub': subWindowS,
    'tol': tolerance,
    if (!earlyStop) 'full': true,
  };

  static MeasureSettings fromJson(Map<String, Object?> j) => MeasureSettings(
    warmupS: (j['warm'] as num?)?.toDouble() ?? kMeasureWarmupS,
    windowS: (j['win'] as num?)?.toDouble() ?? kMeasureWindowS,
    subWindowS: (j['sub'] as num?)?.toDouble() ?? kMeasureSubWindowS,
    tolerance: (j['tol'] as num?)?.toDouble() ?? kMeasureTolerance,
    earlyStop: j['full'] != true,
  );
}

/// Runs [sim] against [port] (default: an [InfiniteColonyPort], i.e. the
/// floor's own capability, not the colony's luck) and returns its
/// steady-state rates. [sim] is consumed: it is left stepped forward.
MeasuredRates measureFloor(
  FactorySim sim, {
  FactoryColonyPort? port,
  MeasureSettings settings = MeasureSettings.standard,
}) {
  final p = port ?? InfiniteColonyPort();
  final sub = settings.subWindowS > 0
      ? settings.subWindowS
      : kMeasureSubWindowS;

  // Warm-up, in sub-window chunks so a huge warm-up never asks one step
  // call for millions of sub-steps at once.
  var warm = settings.warmupS;
  while (warm > 0) {
    final dt = warm < sub ? warm : sub;
    sim.step(dt, p);
    warm -= dt;
  }
  sim.takeLedger(); // discard the start-up

  final total = FactoryLedger();
  var windows = 0;
  var measured = 0.0;
  while (measured < settings.windowS - 1e-9) {
    final left = settings.windowS - measured;
    final dt = left < sub ? left : sub;
    // The mean of every window so far, before this one joins it.
    final before = windows > 0 ? _Window.of(total) : null;
    sim.step(dt, p);
    final l = sim.takeLedger();
    // A floor runs whole sub-steps; trust its own clock when it reports one.
    if (l.seconds <= 0) l.seconds = dt;
    measured += dt;
    total.absorb(l);
    windows++;
    if (settings.earlyStop &&
        before != null &&
        windows >= kMeasureMinWindows &&
        _Window.of(l).agrees(before, settings.tolerance)) {
      break;
    }
  }

  return ratesOf(total, jobs: sim.jobDemand);
}

/// [measureFloor] on a fresh sim built from [bp].
MeasuredRates measureBlueprint(
  FloorBlueprint bp,
  FactorySim Function(FloorBlueprint) build, {
  FactoryColonyPort? port,
  MeasureSettings settings = MeasureSettings.standard,
}) => measureFloor(build(bp), port: port, settings: settings);

/// [measureFloor] on a sim restored from a saved runtime state.
MeasuredRates measureSaved(
  Map<String, Object?> json,
  FactorySim Function(Map<String, Object?> json) load, {
  FactoryColonyPort? port,
  MeasureSettings settings = MeasureSettings.standard,
}) => measureFloor(load(json), port: port, settings: settings);

/// A ledger period as per-second rates. Commodities are listed in key order
/// so equal measurements serialise identically.
MeasuredRates ratesOf(FactoryLedger l, {required double jobs}) {
  final s = l.seconds;
  if (s <= 0) return MeasuredRates.none;
  Map<String, double> per(Map<String, double> m) => {
    for (final k in (m.keys.toList()..sort())) k: m[k]! / s,
  };
  return MeasuredRates(
    inPerS: per(l.received),
    outPerS: per(l.shipped),
    powerKw: l.energyKJ / s,
    jobs: jobs,
    seconds: s,
  );
}

/// One period's rates (a sub-window, or the running total), for the
/// settled test.
class _Window {
  _Window(this.inPerS, this.outPerS, this.kw);

  factory _Window.of(FactoryLedger l) {
    final r = ratesOf(l, jobs: 0);
    return _Window(r.inPerS, r.outPerS, r.powerKw);
  }

  final Map<String, double> inPerS;
  final Map<String, double> outPerS;
  final double kw;

  bool get shippedAnything {
    for (final v in outPerS.values) {
      if (v > kMeasureAbsEps) return true;
    }
    return false;
  }

  bool agrees(_Window o, double tol) {
    if (!shippedAnything || !o.shippedAnything) return false;
    return _close(kw, o.kw, tol) &&
        _mapsClose(inPerS, o.inPerS, tol) &&
        _mapsClose(outPerS, o.outPerS, tol);
  }

  static bool _mapsClose(
    Map<String, double> a,
    Map<String, double> b,
    double tol,
  ) {
    for (final k in a.keys) {
      if (!_close(a[k]!, b[k] ?? 0, tol)) return false;
    }
    for (final k in b.keys) {
      if (!a.containsKey(k) && !_close(0, b[k]!, tol)) return false;
    }
    return true;
  }

  static bool _close(double a, double b, double tol) {
    final d = (a - b).abs();
    if (d <= kMeasureAbsEps) return true;
    final m = a.abs() > b.abs() ? a.abs() : b.abs();
    return d <= tol * m;
  }
}
