// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The control gate (docs/plans/colony-secession.md §5): whether the player
/// may give a colony orders, and why not.
///
/// One question, asked at every place a player's hand reaches into a colony
/// — the editor's tools, the road tool, the panels' levers, the site sheet,
/// the flat builder. The answer lives here, once, so the toolbar that greys a
/// tool and the click handler that refuses it cannot disagree about whether
/// the colony is the player's.
///
/// The gate is a UI-level gate on purpose. The domain mutators it guards are
/// also the sim's own hands — the starter kit lays roads, growth zones lots,
/// the independent governor builds farms — and a gate on the mutators would
/// stop the colony governing itself the moment it stopped taking the
/// player's orders, which is exactly when it has to.
library;

import 'city_loyalty.dart';
import 'city_sim.dart';

/// The gate's answer: allowed, or refused with a reason the player can read.
class ControlState {
  const ControlState.allowed()
      : allowed = true,
        reason = null;

  const ControlState.refused(String this.reason) : allowed = false;

  /// Whether the player's orders reach the colony.
  final bool allowed;

  /// Why they do not, worded for a tooltip or a snack bar; null when
  /// [allowed].
  final String? reason;

  @override
  String toString() => allowed ? 'ControlState.allowed' : 'refused: $reason';
}

/// The gate on the colony.
extension CityControl on CitySim {
  /// Whether the player may act on this colony now (§5).
  ///
  /// * colonial: yes — a restless, defiant or standing-off colony still
  ///   takes orders; it strikes and grumbles, it does not refuse the
  ///   bulldozer (§3.5).
  /// * independent: no — it governs itself (§4) until a way back (§6,
  ///   phases 3–4) brings it home.
  /// * occupied: yes for now. Occupation is phase 4's, and what an occupying
  ///   garrison may and may not order is that phase's to say; until then a
  ///   colony retaken by force is the player's to run.
  ControlState get playerControl => switch (loyalty.allegiance) {
        Allegiance.colonial || Allegiance.occupied =>
          const ControlState.allowed(),
        Allegiance.independent => ControlState.refused(_independentReason),
      };

  String get _independentReason {
    final day = independentSinceDay;
    return day == null
        ? 'This colony is independent and takes no orders.'
        : 'This colony has been independent since day $day and takes no '
            'orders.';
  }

  /// The colony day it declared independence on, counting from day 1, or
  /// null if it never has. On the loyalty calendar ([CityLoyaltyTuning.daySec]),
  /// the one every loyalty readout counts in.
  int? get independentSinceDay {
    final at = loyalty.independentAtS;
    if (at == null) return null;
    return (at / loyalty.tuning.daySec).floor() + 1;
  }

  /// Ask the gate before a player act: true when the act may go ahead.
  /// Refused, [onRefused] hears why — the host's toolbar line, snack bar or
  /// banner — so a refused click is never silently dead.
  bool mayAct([void Function(String reason)? onRefused]) {
    final c = playerControl;
    if (c.allowed) return true;
    onRefused?.call(c.reason!);
    return false;
  }
}
