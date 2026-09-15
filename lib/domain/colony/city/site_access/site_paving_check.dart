// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The two R2 plan checks the frozen R2a validator (V1–V13) leaves open
/// (docs/plans/site-access.md §2.4 as built, §3.7a): every pave ring lies
/// inside the site's parcel ∪ the access corridors of its cut joins, and
/// every corridor keeps its clearance (no manual parcel, at-grade road or
/// built lot inside `kAccessCorridorHalfM` of its line).
///
/// STUB (R2 core): owned by the installation / easement track, which fills in
/// [sitePavingViolations] with this exact signature. Until then it returns
/// no violation. `site_plan_contract_test` (A1, core) already calls it on
/// every generated plan, so the filled-in check gates every program the day
/// it lands.
///
/// Pure: reads the context's graph, parcel and slots and the plan's rows;
/// never the ground; no platform hash, draw, clock, map iteration or
/// trigonometry (§3.9).
library;

import 'site_access_plan.dart';
import 'site_plan_generator.dart';

/// Every paving and corridor-clearance breach of [plan], generated for [ctx],
/// one line each (`'<check> [<siteId>]: <detail>'`); empty when it has none.
List<String> sitePavingViolations(SiteContext ctx, SiteAccessPlan plan) =>
    const [];
