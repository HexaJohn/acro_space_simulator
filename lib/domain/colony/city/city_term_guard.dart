// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The demolition ban (docs/plans/colony-secession.md §6.1) held against the
/// edits that tear buildings down WITHOUT a bulldozer.
///
/// Demolish is one act and the gate refuses it by name. But a road laid,
/// upgraded or re-laid by its end re-cuts the lots along it, and so does a
/// plot staked for a sprawling installation, and whatever stood on a lot the
/// new cut gives up is torn down with it (`CitySim._dropLostLots`) — up to
/// seventeen buildings for one dragged road end. No test of the corridor
/// against the lots can say which: a road split at a junction re-orders the
/// plat, and the re-cut is the only thing that knows what it keeps. So the
/// edit runs ON TRIAL: the plat is copied first, the edit runs, and at the
/// one place every re-plat carries its lots across, before anything else
/// moves, [CityTermGuard.guardBuiltLots] asks whether a built lot would be
/// lost. If one would, the plat is put back and the edit unwinds — no road,
/// no charge, no building gone — and the player is told why.
library;

import 'city_control.dart';
import 'city_reclaim.dart';
import 'city_sim.dart';

/// Thrown out of a re-plat on trial that would lose a built lot, caught by
/// [CityTermGuard.keepingBuiltLots]. Never escapes it.
class BuiltLotsWouldBeLost implements Exception {
  const BuiltLotsWouldBeLost(this.lots);

  /// The built lots the edit would have torn down.
  final List<String> lots;

  @override
  String toString() => 'BuiltLotsWouldBeLost(${lots.join(', ')})';
}

extension CityTermGuard on CitySim {
  /// Run [edit] — a player's act that may re-cut the plat — held to a term
  /// that forbids demolition: refused, nothing changed, when its re-cut would
  /// tear a built lot down, [onRefused] told why (and [CitySim.blocked] set
  /// to it). Returns what [edit] returned, or null when refused. With no
  /// such term in force it is just [edit] — no copy, no cost.
  T? keepingBuiltLots<T>(T Function() edit,
      {void Function(String why)? onRefused}) {
    if (demolitionRefusal == null) return edit();
    // Nested (a commit inside a commit) runs inside the outer trial.
    if (lotGuard != null) return edit();
    final crossings = lastCommitCrossings;
    lotGuard = layout.copy();
    try {
      return edit();
    } on BuiltLotsWouldBeLost catch (e) {
      lastCommitCrossings = crossings;
      final n = e.lots.length;
      final why = '${termRefusal('forbid demolitions')} This would tear '
          'down ${n == 1 ? 'a building' : '$n buildings'}.';
      blocked = why;
      onRefused?.call(why);
      return null;
    } finally {
      lotGuard = null;
    }
  }

  /// The trial's check, asked by every lot carry before it moves anything:
  /// with [renamed] (old lot id -> the lot now on its ground), would any
  /// built lot — a placed building or a grown one — be left with no lot, or
  /// share one with another (only one building survives the carry)? If so,
  /// put the plat back and unwind. Outside a trial it does nothing.
  void guardBuiltLots(Map<String, String> renamed) {
    final saved = lotGuard;
    if (saved == null) return;
    final live = {for (final p in layout.parcels) p.id};
    final landed = <String>{};
    final lost = <String>[];
    for (final id in {...parcelBuildings.keys, ...grownParcels.keys}) {
      if (CitySim.cellOfSiteId(id) != null) continue; // a grid site, not a lot
      // A key already dangling before the edit is not this edit's to lose:
      // counting it would refuse every edit while the terms run.
      if (saved.parcelById(id) == null) continue;
      final now = renamed[id] ?? id;
      if (!live.contains(now) || !landed.add(now)) lost.add(id);
    }
    if (lost.isEmpty) return;
    layout.restoreFrom(saved);
    throw BuiltLotsWouldBeLost(lost);
  }
}
