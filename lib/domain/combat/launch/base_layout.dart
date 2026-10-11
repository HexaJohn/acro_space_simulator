// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Where a forward base stands (docs/plans/combat.md §7D): a pure function,
/// computed once at launch.
///
/// The LZ is 450 m out from its anchor (the port, else the seat). Of eight
/// bearings, starting from straight out from the colony centre, it takes the
/// one whose socket rings have the most free ground and which keeps 400 m
/// from every pad; a tie keeps the earlier bearing, so a colony with nothing
/// in the way lands where it always did. Where no bearing is wholly clear —
/// a spaceport's apron can reach past 450 m — it tries 600, 800 and 1,000 m
/// too, and lands at the nearest that is (found live, §7D). A socket whose box would touch a
/// building's footprint is blocked; open ground on a big lot is not.
library;

import 'dart:math' as math;

/// Rings: modules at 45 m, turrets at 75 m; their boxes' half-widths.
const double kModuleRingM = 45;
const double kTurretRingM = 75;
const double kModuleHalfM = 12;
const double kTurretHalfM = 6;
const int kLayoutModuleSockets = 7;
const int kLayoutTurretSockets = 4;
const double kPadClearM = 400;

/// How far out an LZ may be put, in the order tried.
const List<double> kLzDistancesM = [450, 600, 800, 1000];

class BaseLayout {
  const BaseLayout(this.e, this.n, this.blockedModules, this.blockedTurrets, this.facing,
      {this.distanceM = 450});

  /// The LZ.
  final double e, n;

  /// How far it is from the anchor.
  final double distanceM;

  /// Socket indices with no room.
  final List<int> blockedModules;
  final List<int> blockedTurrets;

  /// Radians from east toward the enemy (the anchor).
  final double facing;

  int get free =>
      kLayoutModuleSockets - blockedModules.length + kLayoutTurretSockets - blockedTurrets.length;
}

/// The positions of a ring's sockets round ([e], [n]), facing [facing].
List<(double, double)> socketRing(double e, double n, double facing, {required bool turrets}) {
  if (turrets) {
    const offs = [-60.0, -20.0, 20.0, 60.0];
    return [
      for (final d in offs)
        (
          e + kTurretRingM * math.cos(facing + d * math.pi / 180),
          n + kTurretRingM * math.sin(facing + d * math.pi / 180)
        )
    ];
  }
  // Modules evenly round, starting behind the LZ (away from the enemy).
  return [
    for (var i = 0; i < kLayoutModuleSockets; i++)
      (
        e + kModuleRingM * math.cos(facing + math.pi + 2 * math.pi * i / kLayoutModuleSockets),
        n + kModuleRingM * math.sin(facing + math.pi + 2 * math.pi * i / kLayoutModuleSockets)
      )
  ];
}

BaseLayout layoutBase({
  required double anchorE,
  required double anchorN,
  required List<(double, double, double)> obstacles,
  required List<(double, double)> pads,
  List<double> distancesM = kLzDistancesM,
}) {
  BaseLayout? best;
  for (final d in distancesM) {
    final l = _layoutAt(anchorE, anchorN, d, obstacles, pads);
    if (l.free == kLayoutModuleSockets + kLayoutTurretSockets) return l;
    if (best == null || l.free > best.free) best = l;
  }
  return best!;
}

BaseLayout _layoutAt(double anchorE, double anchorN, double distanceM,
    List<(double, double, double)> obstacles, List<(double, double)> pads) {
  var outE = anchorE, outN = anchorN;
  var len = math.sqrt(outE * outE + outN * outN);
  if (len < 1) {
    outE = 1;
    outN = 0;
    len = 1;
  }
  final out = math.atan2(outN / len, outE / len);
  BaseLayout? best;
  for (var k = 0; k < 8; k++) {
    final bearing = out + k * math.pi / 4;
    final e = anchorE + distanceM * math.cos(bearing);
    final n = anchorN + distanceM * math.sin(bearing);
    if (pads.any((p) => _d(p.$1, p.$2, e, n) < kPadClearM)) continue;
    final facing = math.atan2(anchorN - n, anchorE - e);
    List<int> blocked(bool turrets) {
      final half = turrets ? kTurretHalfM : kModuleHalfM;
      final ring = socketRing(e, n, facing, turrets: turrets);
      return [
        for (var i = 0; i < ring.length; i++)
          if (obstacles.any((o) => _d(o.$1, o.$2, ring[i].$1, ring[i].$2) < o.$3 + half)) i
      ];
    }

    final l = BaseLayout(e, n, blocked(false), blocked(true), facing, distanceM: distanceM);
    if (best == null || l.free > best.free) best = l;
  }
  // Nowhere clear of the pads: straight out, as before.
  return best ??
      BaseLayout(anchorE + distanceM * math.cos(out), anchorN + distanceM * math.sin(out),
          const [], const [], out + math.pi, distanceM: distanceM);
}

double _d(double a, double b, double c, double d) =>
    math.sqrt((a - c) * (a - c) + (b - d) * (b - d));
