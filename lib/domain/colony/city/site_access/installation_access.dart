// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Installations: access road, gate, forecourt, yard and staff car park
/// (docs/plans/site-access.md §3.7).
///
/// STUB (R2 core): owned by the installation / easement track, which fills in
/// [installationPlanOf] with this exact signature. Until then it returns null,
/// so the dispatcher (`planSite`) falls back to `kerbOnly` with
/// `kPlanFallback`.
///
/// The contract a filled-in generator keeps: it reads only [SiteContext] and
/// the §3.7 constants; it returns a [SiteGeneratedPlan] whose `emit` writes
/// exactly one site passing V1–V13 (the throat `K→T`, the dogleg for
/// `kJoinOffFrontage`, `Y` or `B`, bays, the staff car park, the gate `G` on
/// `y = Df`, the envelope clipped to `y ≥ Df`, the door at `G`), or null when
/// nothing fits; no platform hash, draw, clock, map iteration or
/// trigonometry (§3.9).
library;

import 'site_plan_generator.dart';

/// §3.7 on [ctx], or null when nothing fits.
SiteGeneratedPlan? installationPlanOf(SiteContext ctx) => null;
