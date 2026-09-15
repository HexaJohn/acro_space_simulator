// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Access easements (docs/plans/site-access.md §3.7a): which unbuilt auto
/// lots a stored network plan's access corridor makes easements of.
///
/// The pure half of §3.7a rule 2 (the installation / easement track). The
/// book (`SiteAccessBook.easementOf`) keeps the lookup it builds from these at
/// sync; the `CityLayout` hook, the `setUse` / `placeOnParcel` / growth
/// refusals and the inspector string are the book track's. The dispatcher
/// does not depend on this: §3.3 row 0c (a crossed lot that is BUILT blocks
/// the site) is `classifyProgram`'s.
///
/// Pure: reads the plan's joins, the graph's crossed-lot columns and the
/// built bits; derived, never saved. Determinism (§3.9): no platform hash,
/// map or set iteration; the lots come out ascending.
library;

import '../road_graph.dart';
import 'site_access_constants.dart';
import 'site_access_plan.dart';

/// The easement lots of one plan.
class SiteEasement {
  const SiteEasement(this.lots);

  /// No easement.
  static const SiteEasement none = SiteEasement([]);

  /// Graph lot indices of the unbuilt auto lots the plan's cut joins'
  /// corridors cross, ascending, each once.
  final List<int> lots;

  bool get isEmpty => lots.isEmpty;
}

/// §3.7a rule 2 for [plan] resolved against [graph]: when the plan is a
/// network plan whose cut joins' slots cross only unbuilt lots ([lotBuilt]
/// false), those lots; [SiteEasement.none] for a kerbside plan, a plan whose
/// slots cross nothing, or one crossing a built lot (that plan is
/// `kPlanAccessBlocked`, row 0c).
///
/// The plan's join handles name [graph]'s joins only while its `graphStamp`
/// is [graph]'s `structureStamp` (§2.3): a plan resolved against another
/// structure has no easement here until the book re-resolves it. A footprint
/// join (`joinRef` −1) names no graph join, so it carries none either.
SiteEasement easementOf(RoadGraph graph, SiteAccessPlan plan,
    bool Function(int lot) lotBuilt) {
  if (!plan.hasNetwork || plan.graphStamp != graph.structureStamp) {
    return SiteEasement.none;
  }
  final lots = <int>[];
  for (var j = 0; j < plan.joinCount; j++) {
    if (!plan.joinIsCut(j)) continue;
    final ref = plan.joinRef(j);
    if (ref == kJoinRefNone) continue;
    final slot = graph.joinOfRef(ref);
    if (slot == null) continue;
    for (final lot in slot.crossLots) {
      if (lotBuilt(lot)) return SiteEasement.none;
      if (!lots.contains(lot)) lots.add(lot);
    }
  }
  if (lots.isEmpty) return SiteEasement.none;
  lots.sort();
  return SiteEasement(List.unmodifiable(lots));
}
