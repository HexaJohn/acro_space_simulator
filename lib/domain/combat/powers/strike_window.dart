// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// When an assigned vessel next passes over the battle (docs/plans/combat.md
/// §7E): pure scan over two closures, so the domain never depends on orbit or
/// UI code. Its answer is for the player to plan by; nothing gates on it —
/// the operation runs the overhead gate itself, tick by tick.
library;

import '../../shared/vector3.dart';
import 'overhead.dart';

class StrikeWindow {
  const StrikeWindow(this.startS, this.endS);

  /// Epoch seconds the vessel rises past 30° (or now, when it is already
  /// up), and sets again.
  final double startS, endS;

  double get lengthS => endS - startS;
}

/// The first strike window from [fromS] within [horizonS], or null.
///
/// [vesselAt] and [groundAt] give body-centred inertial positions at an epoch
/// (s). Sampled every [stepS], each crossing refined by bisection to 1 s. A
/// pass shorter than a step can be missed: the step is a fraction of the
/// orbit's period, so only grazing passes are.
StrikeWindow? nextStrikeWindow({
  required Vector3 Function(double t) vesselAt,
  required Vector3 Function(double t) groundAt,
  required double fromS,
  double horizonS = 30 * 86400,
  double stepS = 60,
}) {
  bool up(double t) => overheadOf(vesselAt(t), groundAt(t)).strike;
  double edge(double lo, double hi, bool loUp) {
    // lo has [loUp], hi the other.
    while (hi - lo > 1) {
      final mid = (lo + hi) / 2;
      if (up(mid) == loUp) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    return hi;
  }

  final end = fromS + horizonS;
  var t = fromS;
  var was = up(t);
  double? start = was ? fromS : null;
  while (t < end) {
    final next = t + stepS > end ? end : t + stepS;
    final now = up(next);
    if (now != was) {
      final at = edge(t, next, was);
      if (now) {
        start = at;
      } else if (start != null) {
        return StrikeWindow(start, at);
      }
    }
    was = now;
    t = next;
  }
  return start == null ? null : StrikeWindow(start, end);
}
