// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The operation clock: whole microseconds, run in fixed 1 s steps
/// (docs/plans/combat.md §7.4).
///
/// Each dt is rounded to whole microseconds once, as it arrives, and added to
/// an integer accumulator; the resolver runs one step whenever a whole second
/// is in it. An integer sum does not depend on how it was grouped, so
/// twenty-five ticks of 0.02 s and one of 0.5 s feed the same microseconds and
/// run the same steps — the traffic clock's rule (`traffic_time.dart`). A
/// clock kept in seconds would drift apart at the first rounding.
library;

/// One resolver step, µs.
const int kCombatStepUs = 1000000;

/// One resolver step, s.
const double kCombatStepS = 1.0;

/// A whole-microsecond accumulator that hands out fixed steps.
class OperationClock {
  OperationClock({this.accumulatedUs = 0, this.steps = 0});

  /// Microseconds fed but not yet run as a step (always < [kCombatStepUs]).
  int accumulatedUs;

  /// Steps run so far: the operation's own time, in seconds.
  int steps;

  /// Operation time, s.
  double get seconds => steps * kCombatStepS;

  /// Feeds [dt] seconds; returns how many whole steps are now due. The caller
  /// runs them and counts each with [tick].
  int feed(double dt) {
    if (!(dt > 0)) return 0;
    accumulatedUs += (dt * 1e6).round();
    final due = accumulatedUs ~/ kCombatStepUs;
    accumulatedUs -= due * kCombatStepUs;
    return due;
  }

  /// Counts one step as run.
  void tick() => steps++;

  Map<String, dynamic> toJson() => {
        if (accumulatedUs != 0) 'acc': accumulatedUs,
        if (steps != 0) 'steps': steps,
      };

  factory OperationClock.fromJson(Map<String, dynamic>? j) => OperationClock(
        accumulatedUs: (j?['acc'] as num?)?.toInt() ?? 0,
        steps: (j?['steps'] as num?)?.toInt() ?? 0,
      );
}
