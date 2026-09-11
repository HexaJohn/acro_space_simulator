// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What the agent simulation costs on the wall clock, for REPORTING only
/// (docs/plans/agent-traffic.md §12.2 step 9, §15.1).
///
/// The one file under traffic/ allowed to read a clock. What it measures
/// goes to the perf panel, the `ext.acro.citygame` status and the frame
/// budget, and never back into the simulation: every budget the simulation
/// obeys is counted in expansions, agents or sub-steps (D9), because a limit
/// read off this would make a colony's history depend on the machine it
/// ran on.
library;

/// Timings of `CityAgents.advance`, one tick at a time.
class TrafficMetrics {
  final Stopwatch _watch = Stopwatch();
  int _startUs = 0;
  int _depth = 0;

  /// How many ticks [avgTickMs] averages over, roughly: a second of play at
  /// the fixed step.
  static const double averageTicks = 50;

  /// The last tick's cost, the worst since [reset], and a running average,
  /// all in milliseconds.
  double lastTickMs = 0;
  double maxTickMs = 0;
  double avgTickMs = 0;

  /// Ticks timed since [reset].
  int ticks = 0;

  /// Starts timing a tick. A tick replayed from inside another (the frame
  /// hold replays through the colony's own advance) is timed once, as part
  /// of the outer one.
  void beginTick() {
    if (_depth++ > 0) return;
    if (!_watch.isRunning) _watch.start();
    _startUs = _watch.elapsedMicroseconds;
  }

  /// Ends the tick [beginTick] started.
  void endTick() {
    if (_depth == 0 || --_depth > 0) return;
    final ms = (_watch.elapsedMicroseconds - _startUs) / 1000.0;
    lastTickMs = ms;
    if (ms > maxTickMs) maxTickMs = ms;
    avgTickMs = ticks == 0 ? ms : avgTickMs + (ms - avgTickMs) / averageTicks;
    ticks++;
  }

  /// Forgets every timing.
  void reset() {
    lastTickMs = maxTickMs = avgTickMs = 0;
    ticks = 0;
  }
}
