// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The gaps a car needs at a kerb cut (docs/plans/t4a-implementation.md
/// §1.6; site-access.md §7.4).
///
/// The two rules live in one place so the gate, the departure and the
/// property tests read the same predicate:
///
/// - **Far-side left-in (G2, ask 14):** turning in across the opposing
///   carriageway needs `JunctionArbiter.opposingClear` — no body across the
///   crossing point and no ETA under `kOpposingGapS`. A forced grant after
///   `AgentTuning.gateForcedS` waives the ETA term, never a body.
/// - **Home back-out:** the footprint on the target lane is
///   `[T − backOutUpM, T + backOutDownM]`; it must hold no body, nothing
///   stopped or queued within `backOutQueueM` upstream of it, and every
///   approaching vehicle must be `backOutEtaS` away, taking its speed as at
///   least [kBackOutEtaFloorMps]. The opposing lane of a 1+1 street, and any
///   adjacent same-direction lane, must be clear within ±`backOutSideM`, and
///   the far lane of a far-direction departure is checked like the target
///   lane with `backOutFarEtaS`. A forced grant after `backOutForcedS`
///   waives ONLY the ETA terms, to the `backOutEtaFloorS` floor: never a
///   body in the footprint, and never the queue behind it — a car cannot
///   reverse into a standing queue however long it has waited.
///
/// Every answer is read off the lanes' own ordered lists, head to tail, and
/// nothing here allocates: it is asked every sub-step by every waiting car.
library;

import 'junction_arbiter.dart';
import 'traffic_tuning.dart';
import 'vehicle_table.dart';

/// The lowest speed an approaching vehicle's ETA is taken at (§7.4): a car
/// crawling up to the driveway is not a gap.
const double kBackOutEtaFloorMps = 5.0;

/// At or below this a vehicle counts as stopped or queued (§7.4 term (b)):
/// a car still rolling at walking pace behind a light is a queue, and a
/// back-out never reverses into one.
const double kQueuedMps = 1.0;

/// How far upstream the approach scan reaches before it gives up: at the
/// floor speed nothing beyond this can arrive inside any ETA the design
/// asks for, so the walk is bounded whatever the lane holds.
const double kApproachScanM = 400.0;

/// The gap rules at a kerb cut. See the library comment.
class AccessGaps {
  AccessGaps(this.table, this.arbiter);

  final VehicleTable table;
  final JunctionArbiter arbiter;

  /// Whether a car [len] m long may turn in across the carriageway opposing
  /// [lane] to reach [at] lane metres (G2). [forced] waives the ETA term
  /// after `gateForcedS`, never a body across the crossing.
  bool turnInClear(int lane, double at, double len, {bool forced = false}) {
    if (!forced) return arbiter.opposingClear(lane, at, len);
    final lg = table.graph;
    final e = lg.laneEdge[lane];
    final r = lg.edgeReverse[e];
    if (r < 0) return true;
    // The same point on the opposing carriageway, which runs the other way.
    final t = lg.edgeLen[e] - (lg.edgeLaneS0[e] + at);
    final atR = t - lg.edgeLaneS0[r];
    for (var j = 0; j < lg.edgeLaneCount[r]; j++) {
      if (bodyInSpan(lg.laneOf(r, j), atR - len, atR + len)) return false;
    }
    return true;
  }

  /// Whether a home car may start backing out into [lane] at [t] travel
  /// metres (the join's `s` on that edge), [far] for a far-direction
  /// departure across the near lane, [forced] after `backOutForcedS`.
  ///
  /// The order of the tests is the order of §7.4's list, so a refusal can be
  /// read off the first one that fails.
  bool backOutClear(int lane, double t,
      {bool far = false, bool forced = false}) {
    final lg = table.graph;
    final e = lg.laneEdge[lane];
    final at = t - lg.edgeLaneS0[e];
    final eta = far ? AgentTuning.backOutFarEtaS : AgentTuning.backOutEtaS;
    if (!_laneClear(lane, at, eta, forced: forced)) return false;

    final side = AgentTuning.backOutSideM;
    if (far) {
      // The near lane is crossed on the way: its own footprint is the same
      // stretch of road read the other way round, so what is upstream on the
      // target lane is downstream on this one (§7.4 far direction).
      final n = lg.edgeReverse[e];
      if (n >= 0) {
        final tn = lg.edgeLen[e] - t;
        final an = tn - lg.edgeLaneS0[n];
        if (!_laneClear(lg.laneOf(n, 0), an, AgentTuning.backOutEtaS,
            forced: forced, mirrored: true)) {
          return false;
        }
      }
    } else {
      // A 1+1 street: the arc overhangs the one opposing lane, which must
      // hold no body either way round the cut.
      final o = lg.edgeReverse[e];
      if (o >= 0 && lg.edgeLaneCount[o] == 1 && lg.edgeLaneCount[e] == 1) {
        final to = lg.edgeLen[e] - t;
        final ao = to - lg.edgeLaneS0[o];
        if (bodyInSpan(lg.laneOf(o, 0), ao - side, ao + side)) return false;
      }
    }

    // The next same-direction lane inboard of the target: on an avenue or a
    // two-lane one-way street the swing overhangs it (acked 2026-09-15).
    final k = lg.laneIdx[lane];
    if (k + 1 < lg.edgeLaneCount[e]) {
      final adj = lg.laneOf(e, k + 1);
      if (bodyInSpan(adj, at - side, at + side)) return false;
      final need =
          forced ? AgentTuning.backOutEtaFloorS : AgentTuning.backOutEtaS;
      if (!_approachClear(adj, at - side, need)) return false;
    }
    return true;
  }

  /// Whether [lane] passes the footprint, queue and approach tests around
  /// [at] lane metres with an ETA of [etaS] (floored by a forced grant).
  ///
  /// [mirrored] reads the footprint the other way round: the same stretch of
  /// tarmac seen from the opposing carriageway, where the target lane's
  /// upstream is this lane's downstream.
  bool _laneClear(int lane, double at, double etaS,
      {required bool forced, bool mirrored = false}) {
    final up = AgentTuning.backOutUpM, down = AgentTuning.backOutDownM;
    final lo = mirrored ? at - down : at - up;
    final hi = mirrored ? at + up : at + down;
    if (bodyInSpan(lane, lo, hi)) return false;
    // (b) nothing stopped or queued just upstream of the footprint. Never
    // waived: reversing into a standing queue is not a gap, it is a crash.
    final q = AgentTuning.backOutQueueM;
    for (var w = table.elemHead[lane]; w >= 0; w = table.next[w]) {
      final s = table.s[w];
      if (s > lo) continue;
      if (s < lo - q) break;
      if (table.v[w] <= kQueuedMps) return false;
    }
    return _approachClear(lane, lo, forced ? AgentTuning.backOutEtaFloorS : etaS);
  }

  /// Whether every vehicle approaching [toS] lane metres of [lane] from
  /// upstream is at least [etaS] seconds away, its speed taken as at least
  /// [kBackOutEtaFloorMps].
  bool _approachClear(int lane, double toS, double etaS) {
    for (var w = table.elemHead[lane]; w >= 0; w = table.next[w]) {
      final s = table.s[w];
      if (s > toS) continue;
      final d = toS - s;
      if (d > kApproachScanM) break;
      final v = table.v[w];
      if (d / (v > kBackOutEtaFloorMps ? v : kBackOutEtaFloorMps) < etaS) {
        return false;
      }
    }
    return true;
  }

  /// Whether any vehicle's body lies in `[fromS, toS]` lane metres of
  /// [lane]: the footprint test on its own, which no forced grant waives. A
  /// body runs from its front back over its own length.
  bool bodyInSpan(int lane, double fromS, double toS) {
    if (lane < 0 || lane >= table.elemHead.length) return false;
    for (var w = table.elemHead[lane]; w >= 0; w = table.next[w]) {
      final s = table.s[w];
      if (s - table.len[w] > toS) continue;
      if (s < fromS) return false;
      return true;
    }
    return false;
  }
}
