// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Agent time: whole microseconds, advanced in one fixed sub-step.
///
/// The colony ticks with whatever dt its host hands it — 0.02 s from the
/// fixed-step loop, 0.5 s at the warp clamp, a wall-clock dt from the old 2D
/// host — and the agents must not care. So they keep time as an INTEGER count
/// of microseconds: each dt is rounded to whole microseconds once, as it
/// arrives, and added to an accumulator, and the agents run one sub-step of
/// exactly [kStepUs] whenever the accumulator holds one. An integer sum does
/// not depend on how it was grouped, so 25 ticks of 0.02 s and one of 0.5 s
/// feed the same 500,000 µs and run the same sub-steps
/// (docs/plans/agent-traffic.md §5.1). A clock kept in seconds would drift
/// apart at the first rounding.
///
/// Also the lookup tables that stand in for `exp` and `log` inside a sub-step
/// (D27): built once with the platform's maths, then only read.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// One sub-step, µs. 0.2 s: half the cost of 0.1 s, and still stable for the
/// car-following at street speeds (D8).
const int kStepUs = 200000;

/// Microseconds in a second.
const int kUsPerSecond = 1000000;

/// One sub-step in seconds, for the integrators that need h as a double.
const double kStepS = kStepUs / kUsPerSecond;

/// [seconds] as whole microseconds, rounded to nearest — the one place a
/// double enters agent time.
int usOf(double seconds) => (seconds * kUsPerSecond).round();

/// [us] microseconds in seconds.
double secondsOf(int us) => us / kUsPerSecond;

// ---- Clocks that only count up ---------------------------------------------
//
// A wait is a clock: it starts at zero, adds a sub-step for as long as what
// it measures is still true, and is read against a threshold — the 25 s
// before a junction grant is forced (§5.4), the 60 s before a wedge is
// broken (§5.8), the 120 s before a home back-out is forced (§7.5). Every
// one of them lives in an `Int32List` cell, which holds 2³¹ − 1: in
// MICROseconds that is 35 minutes 47 seconds, and a wait that runs past it
// wraps NEGATIVE. Nothing crashes; the threshold silently un-fires, and the
// car that has waited longest reads as the one that has waited least. So a
// clock that can run for hours counts MILLISECONDS, and every clock adds
// through [addClock], which saturates rather than wraps.

/// One sub-step in whole milliseconds. [kStepUs] is a whole number of them,
/// so a millisecond clock counts sub-steps exactly as a microsecond one
/// does: 0.2 s is 200 ms, and nothing is rounded away.
const int kStepMs = kStepUs ~/ 1000;

/// Milliseconds in a second.
const int kMsPerSecond = 1000;

/// [seconds] as whole milliseconds, rounded to nearest: what a millisecond
/// clock's thresholds are written in.
int msOf(double seconds) => (seconds * kMsPerSecond).round();

/// [ms] milliseconds in seconds, for readouts.
double secondsOfMs(int ms) => ms / kMsPerSecond;

/// Where a counting clock stops. Two thousand million, which is inside the
/// 2³¹ − 1 an `Int32List` cell holds with a whole sub-step to spare in
/// either unit, so no add can step over the top and wrap: 23 days of agent
/// time in milliseconds, 33 minutes in microseconds.
const int kClockMax = 2000000000;

/// [was] plus [add], held at [kClockMax]: a clock that has passed its
/// threshold stays past it for ever, which is what every rule that reads one
/// assumes. [add] is a sub-step's worth, never negative.
int addClock(int was, int add) {
  final now = was + add;
  return now > kClockMax ? kClockMax : now;
}

/// The agents' clock: the time of the last sub-step run, and what the ticks
/// have fed that has not been run yet.
class AgentClock {
  /// Agent time at the end of the last sub-step run, µs: always a whole
  /// number of [kStepUs]. Signals read their state from it (§3.7).
  int timeUs = 0;

  /// Time fed and not yet run, µs. Below [kStepUs] between advances: the
  /// fraction of a sub-step a tick leaves over, at most 0.2 s of lag, which
  /// the renderer's own clock absorbs.
  int accumUs = 0;

  /// Feeds one tick's [dt] seconds, rounded to whole µs. A dt that is not a
  /// positive finite number — a paused tick, a NaN from upstream — feeds
  /// nothing.
  void feed(double dt) {
    if (dt > 0 && dt.isFinite) accumUs += usOf(dt);
  }

  /// Runs the clock over one sub-step, if a whole one has been fed: true, and
  /// [timeUs] moves on by [kStepUs]; false, and nothing changes.
  bool takeStep() {
    if (accumUs < kStepUs) return false;
    accumUs -= kStepUs;
    timeUs += kStepUs;
    return true;
  }

  /// Whole sub-steps fed and not yet run.
  int get pendingSteps => accumUs ~/ kStepUs;

  /// How many sub-steps would be ready after feeding [dt], counted exactly as
  /// [feed] and [takeStep] would count them — so the frame hold can price a
  /// queued tick before it runs it (§5.7).
  int stepsOnFeed(double dt) =>
      (accumUs + (dt > 0 && dt.isFinite ? usOf(dt) : 0)) ~/ kStepUs;

  /// Whether the last sub-step ended on a whole agent second: the one
  /// sub-step in five that runs dispatch and the schedules (§5.2).
  bool get onWholeSecond => timeUs % kUsPerSecond == 0;

  /// [timeUs] in seconds, for readouts. Never for the step itself: seconds
  /// are where the rounding lives.
  double get timeS => secondsOf(timeUs);
}

/// Tables for the functions a sub-step may not call (D27).
///
/// `exp` and `log` are the platform's maths library, free to round
/// differently from one build target to the next. A table built from them
/// once and then only read is at least one table for the whole run — and
/// cheaper than the call. Each is built on first use.
class Lut {
  Lut._();

  /// Samples of e^-x per unit of x.
  static const int expNegPerUnit = 128;

  /// Where the e^-x table ends. e^-16 is about 1e-7: no EMA can tell it
  /// from nothing.
  static const double expNegMaxX = 16;

  static final Float64List _expNeg = _buildExpNeg();

  static Float64List _buildExpNeg() {
    final n = (expNegMaxX * expNegPerUnit).round();
    final t = Float64List(n + 1);
    for (var i = 0; i <= n; i++) {
      t[i] = math.exp(-i / expNegPerUnit);
    }
    return t;
  }

  /// e^-[x], interpolated linearly between samples 1/128 apart: within 1e-5
  /// of the function. At or below 0 it reads 1; past [expNegMaxX], the last
  /// sample.
  static double expNeg(double x) {
    if (!(x > 0)) return 1.0;
    final t = _expNeg;
    final f = x * expNegPerUnit;
    final last = t.length - 1;
    if (f >= last) return t[last];
    final i = f.floor();
    final a = t[i];
    return a + (t[i + 1] - a) * (f - i);
  }

  /// Entries in the Gumbel table. An index is the top ten bits of a draw,
  /// `rng.nextU32() >> 22`.
  static const int gumbelSize = 1024;

  static final Float64List _gumbel = _buildGumbel();

  static Float64List _buildGumbel() {
    final t = Float64List(gumbelSize);
    for (var i = 0; i < gumbelSize; i++) {
      t[i] = math.log(-math.log((i + 0.5) / gumbelSize));
    }
    return t;
  }

  /// A minimum-type Gumbel variate for table index [i] (taken modulo
  /// [gumbelSize]): ln(−ln p) at the midpoint p = (i + ½)/1024 of the
  /// index's slice.
  ///
  /// Minimum-type, so the mode choice can be written the way the design
  /// writes it, argmin(cost + β·G) (§4.9): with this G that is the
  /// multinomial logit, P(mode) ∝ e^(−cost/β), exactly as
  /// argmax(utility + β·G′) is with the usual maximum-type G′ = −G. The mean
  /// is −γ (−0.5772); the values fall from +2.03 at index 0 to −7.62 at 1023.
  static double gumbel(int i) => _gumbel[i & (gumbelSize - 1)];
}
