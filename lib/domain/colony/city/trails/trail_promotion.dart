// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// When a trail has been driven enough to be a road (docs/plans/desire-paths.md
/// §5 phase 2): the beaten runs of the routes people take, as polylines a
/// dirt road can be laid along.
///
/// Read off ROUTES, not off the worn cells alone: a route is already a line
/// from one door to another, so a run of it is a road with a direction and
/// two ends; the cells by themselves are a smear a few wide with no order.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../parcel.dart';
import 'trail_field.dart';
import 'trail_router.dart';

/// Wear past which a cell is a beaten track: eight legs or so, net of fading.
const double kTrailBeatenWear = 0.8;

/// The shortest run worth a road, metres. Shorter, and the trail is a
/// doorstep, not a way.
const double kTrailRoadMinM = 80;

/// The steepest step a dirt road takes ([RoadClass.path]'s 20%): a run is
/// cut where its route climbs harder, and the rovers keep that stretch.
const double kTrailRoadMaxGrade = 0.20;

/// How far a laid road may stray from the trail's cells, metres: the
/// simplification's tolerance.
const double _simplifyM = 4;

/// The beaten runs of [routes] that are not road already, longest first,
/// each a simplified polyline in colony metres. A run another run has
/// already covered by half or more is left out, so two routes along one
/// trail ask for one road.
List<List<Vec2>> beatenRuns(TrailField f, Iterable<TrailRoute> routes) {
  final runs = <List<int>>[];
  for (final r in routes) {
    final cells = r.cells;
    var run = <int>[];
    void close() {
      if (run.length >= 2) runs.add(run);
      run = <int>[];
    }

    for (var k = 0; k < cells.length; k++) {
      final i = cells[k];
      final ok = f.wear[i] >= kTrailBeatenWear &&
          !f.road(i) &&
          !f.blocked(i) &&
          (run.isEmpty || _gradeOk(f, run.last, i));
      if (ok) {
        run.add(i);
      } else {
        close();
        // A steep step ends one run; the cell itself may start the next.
        if (f.wear[i] >= kTrailBeatenWear && !f.road(i) && !f.blocked(i)) {
          run.add(i);
        }
      }
    }
    close();
  }
  runs.sort((a, b) => b.length.compareTo(a.length));
  final taken = <int>{};
  final out = <List<Vec2>>[];
  for (final run in runs) {
    final pts = [for (final i in run) f.centreOf(i)];
    if (_length(pts) < kTrailRoadMinM) continue;
    var shared = 0;
    for (final i in run) {
      if (taken.contains(i)) shared++;
    }
    if (shared * 2 >= run.length) continue;
    taken.addAll(run);
    out.add(simplify(pts, _simplifyM));
  }
  return out;
}

bool _gradeOk(TrailField f, int a, int b) {
  final de = f.centreE(a) - f.centreE(b), dn = f.centreN(a) - f.centreN(b);
  final d = math.sqrt(de * de + dn * dn);
  return d <= 0 || (f.height[b] - f.height[a]).abs() / d <= kTrailRoadMaxGrade;
}

double _length(List<Vec2> pts) {
  var s = 0.0;
  for (var k = 1; k < pts.length; k++) {
    s += pts[k].distanceTo(pts[k - 1]);
  }
  return s;
}

/// Douglas–Peucker: the fewest of [pts] that stay within [tolM] of them all.
List<Vec2> simplify(List<Vec2> pts, double tolM) {
  if (pts.length <= 2) return List.of(pts);
  final keep = List<bool>.filled(pts.length, false)
    ..[0] = true
    ..[pts.length - 1] = true;
  final stack = <(int, int)>[(0, pts.length - 1)];
  while (stack.isNotEmpty) {
    final (a, b) = stack.removeLast();
    var worst = -1.0;
    var at = -1;
    for (var k = a + 1; k < b; k++) {
      final d = _offLine(pts[k], pts[a], pts[b]);
      if (d > worst) {
        worst = d;
        at = k;
      }
    }
    if (at >= 0 && worst > tolM) {
      keep[at] = true;
      stack
        ..add((a, at))
        ..add((at, b));
    }
  }
  return [
    for (var k = 0; k < pts.length; k++)
      if (keep[k]) pts[k]
  ];
}

double _offLine(Vec2 p, Vec2 a, Vec2 b) {
  final de = b.e - a.e, dn = b.n - a.n;
  final l2 = de * de + dn * dn;
  if (l2 <= 1e-12) return p.distanceTo(a);
  final t = (((p.e - a.e) * de + (p.n - a.n) * dn) / l2).clamp(0.0, 1.0);
  return p.distanceTo(Vec2(a.e + de * t, a.n + dn * t));
}

/// Foot wear past which a walked line is a tube's (desire-paths.md §9).
const double kTubeWear = 0.7;

/// The shortest tube worth building, metres.
const double kTubeMinM = 20;

/// The walked runs of [walks] beaten enough to be tubes, longest first, as
/// simplified polylines. A run is offered only when BOTH its ends attach,
/// each to a built site's door ([doorCells]) or to a tube: a tube must lead
/// from somewhere to somewhere, never stand alone in the open.
List<List<Vec2>> tubeRuns(
    TrailField f, Iterable<TrailRoute> walks, Set<int> doorCells) {
  bool attaches(Int32List cells, int k) {
    final i = cells[k];
    // A door, or a tube in the cells around it: the cell before a run that
    // continues a tube is that tube, and is one of them.
    return doorCells.contains(i) || f.nearTube(i);
  }

  final runs = <List<int>>[];
  for (final r in walks) {
    final cells = r.cells;
    var start = -1;
    void close(int end) {
      if (start < 0) return;
      final a = start, b = end;
      start = -1;
      if (b - a < 1) return;
      if (!attaches(cells, a) || !attaches(cells, b)) return;
      runs.add([for (var k = a; k <= b; k++) cells[k]]);
    }

    for (var k = 0; k < cells.length; k++) {
      final i = cells[k];
      final ok = f.footWear[i] >= kTubeWear && !f.tube(i) && !f.blocked(i);
      if (ok) {
        if (start < 0) start = k;
      } else {
        close(k - 1);
      }
    }
    close(cells.length - 1);
  }
  runs.sort((a, b) => b.length.compareTo(a.length));
  final taken = <int>{};
  final out = <List<Vec2>>[];
  for (final run in runs) {
    if (run.any(taken.contains)) continue;
    final pts = [for (final i in run) f.centreOf(i)];
    if (_length(pts) < kTubeMinM) continue;
    taken.addAll(run);
    out.add(simplify(pts, 2));
  }
  return out;
}
