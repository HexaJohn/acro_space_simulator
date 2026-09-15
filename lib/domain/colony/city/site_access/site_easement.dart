// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Access easements (docs/plans/site-access.md §3.7a): which unbuilt auto
/// lots a stored network plan's access corridor makes easements of.
///
/// STUB (R2 core): owned by the installation / easement track, which fills in
/// [easementOf] with this exact signature. Until then it returns
/// [SiteEasement.none]. The dispatcher does not depend on it: §3.3 row 0c
/// (a crossed lot that is BUILT blocks the site) is `classifyProgram`'s.
///
/// Pure: reads the plan's joins, the graph's crossed-lot columns and the
/// built bits; derived, never saved. The book (`SiteAccessBook.easementOf`)
/// keeps the lookup it builds from these at sync.
library;

import '../road_graph.dart';
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
SiteEasement easementOf(RoadGraph graph, SiteAccessPlan plan,
        bool Function(int lot) lotBuilt) =>
    SiteEasement.none;
