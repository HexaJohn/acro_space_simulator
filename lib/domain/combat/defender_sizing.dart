// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Who turns out to defend a colony, sized once at launch
/// (docs/plans/combat.md §7.3; the reference's §4.2).
///
/// Resolve replaces the secession plan's `pop × (1 − happiness)`, which read a
/// colony's unhappiness under its own rebels as hostility to the player. Here a
/// content colony with a real grievance fights hardest, one that wants to come
/// home fights badly, and a hungry one folds — so force and winning hearts
/// point the same way.
library;

import 'dart:math' as math;

/// Resolve r ∈ [0.05, 0.95].
///
/// [severity] the colony's grievance (for a standoff colony, the same formula
/// on its live loyalty state); [mood] its happiness; [wish] its pressure to
/// rejoin (0 in standoff); [hunger] 1 − food security.
double colonyResolve({
  required double severity,
  required double mood,
  required double wish,
  required double hunger,
}) =>
    (0.2 + 0.5 * severity + 0.3 * mood - 0.6 * wish - 0.3 * hunger)
        .clamp(0.05, 0.95);

/// The rebels holding a seized port: its own staff and a share of the town.
int portHolders({
  required int spaceportJobs,
  required double population,
  required double resolve,
}) =>
    (spaceportJobs * 0.5 + population * 0.03 * resolve).ceil();

/// Everyone the town can send in waves while the port is fought over.
int militiaRaised({required double population, required double resolve}) =>
    (population * (0.04 + 0.20 * resolve)).floor();

/// How many of [militia] carry a real gun: the stock, plus the 30% who bring a
/// hunting rifle, a mining charge or a tool. The rest are improvised.
int militiaArmed({required int militia, required int gunsInStock}) =>
    math.min(militia, gunsInStock + (0.3 * militia).floor());

/// Morale a militia wave turns out with.
double militiaMorale(double resolve) => 0.45 + 0.35 * resolve;
