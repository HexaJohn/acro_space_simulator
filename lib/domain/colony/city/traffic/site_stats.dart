// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What the site traffic counted (docs/plans/t4a-implementation.md §1.8;
/// site-access.md §7.4–§7.6).
///
/// Every exceptional path in the site design is COUNTED, not hidden: a
/// forced grant, a give-up, a snap, a relocation, a garaging. The scenario
/// tests read these (A6 "forced grants counted, none within 25 s", A8
/// "replans == 0, movers snap"), and the digest folds them so a twin run
/// that took one more forced grant diverges visibly. Running totals since
/// the colony's agents started; none ever goes back.
library;

import 'traffic_rng.dart';

/// The site counters. See the library comment.
class SiteStats {
  /// Access events: ENTERs and EXITs (back-outs included).
  int enters = 0, exits = 0;

  /// Arrival gate grants given with the far-side ETA test waived after
  /// `gateForcedS` (§7.4 step 4), and arrivals that gave their stall up
  /// after `gateGiveUpS` refused on the throat's room (to D17 step 2).
  int gateForced = 0, gateGiveUps = 0;

  /// Cars parked in a lot stall, parked at a kerb slot, and garaged: taken
  /// out of the world because nowhere could place them (§7.5).
  int parkedLot = 0, parkedKerb = 0, garaged = 0;

  /// The D36 extension (§7.6): movers snapped onto a changed plan's lanes,
  /// parked cars relocated off a vanished stall or a newly masked kerb slot,
  /// cars garaged by a site change, plans held in limbo while cars still use
  /// them, and appended fixed-start legs after a join moved (`siteRetarget`).
  int snaps = 0, relocates = 0, siteGarages = 0, limboRows = 0,
      siteRetargets = 0;

  /// Home back-outs granted with the ETA terms waived after
  /// `backOutForcedS`, and tandem shuffles to a kerb slot after
  /// `tandemShuffleS` (§7.4, §7.5).
  int backOutForced = 0, shuffles = 0;

  /// Home departures given up after `backOutGiveUpS` because no gap ever
  /// came: the car back on its stall and its owner's leg asked for again
  /// (§7.5). The forced grant waives ETA and never a body, so this is what
  /// a driveway held by something that does not move reads as — one per
  /// attempt, so a wedged drive counts up steadily instead of standing
  /// silently in `backOutWait`.
  int backOutGiveUps = 0;

  /// [h] with every counter folded in, in declaration order.
  int digest(int h) {
    var x = fnv1aU32(h, enters);
    x = fnv1aU32(x, exits);
    x = fnv1aU32(x, gateForced);
    x = fnv1aU32(x, gateGiveUps);
    x = fnv1aU32(x, parkedLot);
    x = fnv1aU32(x, parkedKerb);
    x = fnv1aU32(x, garaged);
    x = fnv1aU32(x, snaps);
    x = fnv1aU32(x, relocates);
    x = fnv1aU32(x, siteGarages);
    x = fnv1aU32(x, limboRows);
    x = fnv1aU32(x, siteRetargets);
    x = fnv1aU32(x, backOutForced);
    x = fnv1aU32(x, shuffles);
    x = fnv1aU32(x, backOutGiveUps);
    return x;
  }
}
