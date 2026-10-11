// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The planner's preview: the same resolver, run headless on copies
/// (docs/plans/combat.md §7.5).
///
/// It shows the player a spread — outcome bands, how long, how many dead —
/// never one exact answer, which would turn the decision into paperwork. It
/// runs at the real 1 s step: the width cap, whole-member removal and the
/// morale lines all depend on step size, so a coarser preview would promise a
/// different battle. It never touches the operation it was made from, and it
/// runs in counted steps so a host can spread it over frames.
library;

import '../colony/city/hash32.dart';
import 'combat_rng.dart';
import 'operation.dart';
import 'resolver_tuning.dart';

/// One previewed run's result.
typedef PreviewRun = ({
  OperationOutcome outcome,
  OutcomeBand band,
  int seconds,
  int attackerLost,
  int defenderLost,
});

class OperationPreview {
  /// Previews [source] over [runs] seeds, none of them the real one.
  OperationPreview(Operation source, {this.runs = 32})
      : _source = source.toJson(),
        _seed = source.seed,
        _tuning = source.tuning,
        _counters = source.counters;

  final Map<String, dynamic> _source;
  final int _seed;
  final ResolverTuning _tuning;
  final CounterTuning _counters;
  final int runs;

  final List<PreviewRun> results = [];
  Operation? _current;

  bool get done => results.length >= runs;

  /// The longest a run can take: mustering, transit and the ceasefire cap.
  int get _maxSteps {
    final t = _tuning;
    final cease = t.ceasefireDays > t.assaultCeasefireDays
        ? t.ceasefireDays
        : t.assaultCeasefireDays;
    return ((t.musteringDays + t.transitDaysOtherBody + cease) *
                t.daySec)
            .ceil() +
        10;
  }

  /// Runs at most [stepBudget] resolver steps; returns whether all runs are
  /// done. Counted, never timed.
  bool advance(int stepBudget) {
    var budget = stepBudget;
    while (budget > 0 && !done) {
      final op = _current ??= Operation.fromJson(_source,
          tuning: _tuning,
          counters: _counters,
          seedOverride:
              combatMix32(_seed ^ mul32(0x9E3779B9, results.length + 1)));
      final cap = _maxSteps;
      while (budget > 0 && !op.resolved && op.clock.steps < cap) {
        op.advance(1.0);
        budget--;
      }
      if (op.resolved || op.clock.steps >= cap) {
        results.add((
          outcome: op.outcome ?? OperationOutcome.ceasefire,
          band: op.band,
          seconds: op.resolvedAtStep - op.engagedAtStep,
          attackerLost: op.attackerRemoved,
          defenderLost: op.defenderRemoved,
        ));
        _current = null;
      }
    }
    return done;
  }

  /// Runs everything at once (tests, headless tools).
  void runAll() {
    while (!advance(1 << 20)) {}
  }

  /// How many runs ended in [band].
  int countOf(OutcomeBand band) =>
      results.where((r) => r.band == band).length;

  /// How many runs the attacker won.
  int get wins =>
      results.where((r) => r.outcome == OperationOutcome.won).length;

  /// The [p]-quantile (0..1) of [of] over the finished runs.
  int quantile(int Function(PreviewRun) of, double p) {
    if (results.isEmpty) return 0;
    final v = [for (final r in results) of(r)]..sort();
    final i = (p * (v.length - 1)).round().clamp(0, v.length - 1);
    return v[i];
  }
}
