// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Car parks and yards (docs/plans/site-access.md §3.5, §3.6).
///
/// STUB (R2 core): owned by the car park / yard track, which fills in the two
/// entry points below with these exact signatures. Until then both return
/// null, so the dispatcher (`planSite`) falls back to `kerbOnly` with
/// `kPlanFallback`.
///
/// The contract a filled-in generator keeps:
/// - it reads only [SiteContext] (frame, profile, slots, spec, seed) and the
///   §3.5/§3.6 constants in `site_access_constants.dart`;
/// - it computes the whole plan first and returns a [SiteGeneratedPlan]
///   whose `emit` writes exactly one site (`SiteContext.beginSite` …
///   `PlanBuilder.endSite`) that passes V1–V13; or null when nothing meets the
///   program's minimum (§3.3: throat width, `n ≥ 1`, envelope ≥ 8 × 8 m and
///   `A_min`);
/// - no platform hash, draw, clock, map iteration or trigonometry (§3.9);
///   ties by `SiteContext.tieBreak`.
library;

import 'site_plan_generator.dart';

/// §3.5: the best car park on [ctx] (families F1–F3, `k` modules, the score),
/// or null when none has a stall.
SiteGeneratedPlan? carParkPlanOf(SiteContext ctx) => null;

/// §3.6: a car park plus an 18 × 24 m truck apron (circle 12.5 m, two
/// 3.5 × 15 m bays, `kPlanAdmitsTrucks`) on [ctx]; the car park alone
/// (trucks not admitted) where the apron does not fit; null when neither
/// fits (the dispatcher then tries [carParkPlanOf]).
SiteGeneratedPlan? yardPlanOf(SiteContext ctx) => null;
