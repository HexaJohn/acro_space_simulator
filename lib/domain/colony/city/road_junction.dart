// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What controls a junction, and the rule that decides it.
///
/// A junction is a place where road ENDS meet — the layout splits every
/// road at its crossings, the sprawl plan splits its own, so the topology
/// is real and a junction is simply three or more ends on one point. What
/// it LOOKS like — a plate with stop bars, a signal mast on every corner, a
/// roundabout with an island — is decided here, once, from the classes of
/// the roads meeting, the way a traffic engineer's warrant does: a crossing
/// of two arterials gets signals whether it is downtown or at the mile
/// grid, and the renderer that draws the core and the one that draws the
/// suburbs ask the same question and get the same answer.
library;

import 'parcel.dart';

/// How a junction is controlled.
enum JunctionControl {
  /// Two ends meeting: a road carrying on round a corner, or a change of
  /// class mid-run. Nothing is drawn.
  none,

  /// A ramp leaving or joining a limited-access road: a taper and a gore,
  /// no plate, nothing to stop for.
  merge,

  /// An all-way stop: a plate, stop bars and a sign on every leg. Local
  /// streets crossing each other.
  stop,

  /// A signalised crossing: plate, stop bars, zebras and a mast per leg.
  signals,

  /// A roundabout: a circular plate round a raised island, yield lines on
  /// the approaches, no signals.
  roundabout,
}

/// The control a junction of [legs] gets.
///
/// [roundaboutPreferred] is the planner's say — a subdivision's collectors
/// cross at a roundabout because that is what a subdivision builds, not
/// because the classes demand it — and it is honoured only where a
/// roundabout is possible: three or more legs, none of them fast.
JunctionControl junctionControlFor(
  List<RoadClass> legs, {
  bool roundaboutPreferred = false,
}) {
  if (legs.length < 3) {
    // A ramp meeting an expressway end-on is a merge even as two legs: the
    // expressway is split there, so the mainline is two legs and the ramp
    // a third — but a ramp landing exactly on the end of one is still a
    // merge, not a corner.
    if (legs.length == 2 && legs.any((c) => c.limitedAccess)) {
      return JunctionControl.merge;
    }
    return JunctionControl.none;
  }
  final limited = legs.where((c) => c.limitedAccess).length;
  // An expressway ENDING at an arterial — one limited-access leg among
  // ordinary ones, none of them ramps — is where the expressway ends, and
  // a real one ends at a signal.
  if (limited == 1 &&
      legs.length >= 3 &&
      !legs.any((c) => c == RoadClass.ramp) &&
      legs.where((c) => c.arterial).length >= 2) {
    return JunctionControl.signals;
  }
  if (limited > 0) return JunctionControl.merge;
  if (roundaboutPreferred && legs.every((c) => !c.arterial || c == RoadClass.avenue)) {
    return JunctionControl.roundabout;
  }
  // Two arterial legs — the through road of a T, or both roads of a
  // crossing — warrant signals. A ramp terminal on an avenue is exactly
  // this: the avenue runs through, the ramp is the third leg.
  final arterials = legs.where((c) => c.arterial).length;
  if (arterials >= 2) return JunctionControl.signals;
  return JunctionControl.stop;
}
