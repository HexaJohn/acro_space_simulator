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
/// in the way lands where it always did. A socket whose box would touch a
/// building lot is blocked.
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

class BaseLayout {
  const BaseLayout(this.e, this.n, this.blockedModules, this.blockedTurrets, this.facing);

  /// The LZ.
  final double e, n;

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
  required double distanceM,
  required List<List<(double, double)>> obstacles,
  required List<(double, double)> pads,
}) {
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
          if (obstacles.any((o) => touches(o, ring[i].$1, ring[i].$2, half))) i
      ];
    }

    final l = BaseLayout(e, n, blocked(false), blocked(true), facing);
    if (best == null || l.free > best.free) best = l;
  }
  // Nowhere clear of the pads: straight out, as before.
  return best ??
      BaseLayout(anchorE + distanceM * math.cos(out), anchorN + distanceM * math.sin(out),
          const [], const [], out + math.pi);
}

double _d(double a, double b, double c, double d) =>
    math.sqrt((a - c) * (a - c) + (b - d) * (b - d));

/// Whether a box of half-width [half] centred on ([e], [n]) touches [poly]:
/// inside it, or nearer than [half] to an edge.
bool touches(List<(double, double)> poly, double e, double n, double half) {
  if (poly.length < 3) return false;
  var inside = false;
  for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final (xi, yi) = poly[i];
    final (xj, yj) = poly[j];
    if ((yi > n) != (yj > n) && e < (xj - xi) * (n - yi) / (yj - yi) + xi) inside = !inside;
    if (_segD(e, n, xj, yj, xi, yi) < half) return true;
  }
  return inside;
}

double _segD(double px, double py, double ax, double ay, double bx, double by) {
  final dx = bx - ax, dy = by - ay;
  final l2 = dx * dx + dy * dy;
  final t = l2 <= 0 ? 0.0 : (((px - ax) * dx + (py - ay) * dy) / l2).clamp(0.0, 1.0);
  return _d(px, py, ax + t * dx, ay + t * dy);
}
