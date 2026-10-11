// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What a colony's panels can ask of the war, set by the host that runs one
/// (docs/plans/combat.md §7A).
///
/// The colony panels — the independence panel's Force row, the occupation
/// panel's buttons — are shared by every host, and most hosts have no world
/// and no war: a lone colony in the city studio cannot be invaded from
/// anywhere. The in-world view, which owns the operation registry, sets these
/// while it is mounted; with them unset the panels say force is unavailable
/// and show no orders. Static rather than inherited because the panels open
/// in dialogs, on the root navigator, above any widget the view could provide.
/// The orders themselves are commands the host enqueues: nothing here touches
/// a colony.
library;

import 'package:flutter/widgets.dart';

import '../../../../domain/colony/city/city_sim.dart';

abstract final class CombatHooks {
  /// Opens the force planner against [city].
  static void Function(BuildContext context, CitySim city)? openForce;

  /// A one-line status of the operation already running against [city], or
  /// null with none — the Force row reads it instead of offering a second.
  static String? Function(CitySim city)? forceStatus;

  /// Orders the occupied [city]'s charter restored.
  static void Function(CitySim city)? restoreCharter;

  /// Orders the garrison holding [city] home.
  static void Function(CitySim city)? withdrawGarrison;

  static void clear() {
    openForce = null;
    forceStatus = null;
    restoreCharter = null;
    withdrawGarrison = null;
  }
}
