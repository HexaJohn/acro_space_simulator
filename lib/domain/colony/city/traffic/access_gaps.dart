// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The gaps a car needs at a kerb cut (docs/plans/t4a-implementation.md
/// §1.6; site-access.md §7.4).
///
/// STUB (P0). Package C implements it, and owns the shape of this file: the
/// signatures below are P0's guess at what the gate and the home back-out
/// both need, and C may change them — nothing else calls them yet.
///
/// The two rules, in one place so the gate, the departure and the property
/// tests read the same predicate:
///
/// - **Far-side left-in (G2, ask 14):** turning in across the opposing
///   carriageway needs `JunctionArbiter.opposingClear` — no body across the
///   crossing point and no ETA under `kOpposingGapS`. A forced grant after
///   `AgentTuning.gateForcedS` waives the ETA term, never a body.
/// - **Home back-out:** the footprint on the target lane is
///   `[T − backOutUpM, T + backOutDownM]`; it must hold no body, nothing
///   stopped or queued within `backOutQueueM` upstream of it, and every
///   approaching vehicle must be `backOutEtaS` away, taking its speed as at
///   least 5 m/s. The opposing lane of a 1+1 street, and any adjacent
///   same-direction lane, must be clear within ±`backOutSideM`, and the far
///   lane of a far-direction departure is checked like the target lane with
///   `backOutFarEtaS`. A forced grant after `backOutForcedS` waives only
///   the ETA terms, to the `backOutEtaFloorS` floor.
///
/// Allocation-free: asked every sub-step by every waiting car.
library;

import 'junction_arbiter.dart';
import 'vehicle_table.dart';

/// The lowest speed an approaching vehicle's ETA is taken at (§7.4): a car
/// crawling up to the driveway is not a gap.
const double kBackOutEtaFloorMps = 5.0;

/// The gap rules at a kerb cut. See the library comment.
class AccessGaps {
  AccessGaps(this.table, this.arbiter);

  final VehicleTable table;
  final JunctionArbiter arbiter;

  /// Whether a car [len] m long may turn in across the carriageway opposing
  /// [lane] to reach [at] lane metres (G2). [forced] waives the ETA term
  /// after `gateForcedS`, never a body across the crossing.
  bool turnInClear(int lane, double at, double len, {bool forced = false}) =>
      throw UnimplementedError('T4a C: AccessGaps.turnInClear');

  /// Whether a home car may start backing out into [lane] at [t] travel
  /// metres (the join's `s` on that edge), [far] for a far-direction
  /// departure across the near lane, [forced] after `backOutForcedS`. It
  /// checks the footprint, the queue behind it, the approach ETAs and the
  /// opposing and adjacent lanes.
  bool backOutClear(int lane, double t,
          {bool far = false, bool forced = false}) =>
      throw UnimplementedError('T4a C: AccessGaps.backOutClear');

  /// Whether any vehicle's body lies in `[fromS, toS]` lane metres of
  /// [lane]: the footprint test on its own, which no forced grant waives.
  bool bodyInSpan(int lane, double fromS, double toS) =>
      throw UnimplementedError('T4a C: AccessGaps.bodyInSpan');
}
