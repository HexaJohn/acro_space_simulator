// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The arithmetic of a stall manoeuvre and a home back-out
/// (docs/plans/site-access.md §7.4; docs/plans/t4a-implementation.md §1.6).
///
/// The simulation and the capture (package F) share these curves, so what
/// is pinned here is what a car is drawn doing as much as what it does:
///
/// - the ends are EXACT — `u = 1` IS the stall pose, which is why §7.4 can
///   call "within 0.05 m and 2°" a snap rather than a tolerance;
/// - the pose never folds back on itself, so a car never appears to lurch;
/// - the curve's own walk of a site lane agrees with `SiteGeometry`'s, so
///   the two definitions of a lane can never drift apart;
/// - there is no trigonometry anywhere in the file (D27).
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_lane_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/access_points.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_geometry.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/site_manoeuvre.dart';
import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_tuning.dart';
import 'package:flutter_test/flutter_test.dart';

import '../colony/site_access/site_plan_fixtures.dart';
import 'site_fixture.dart';

/// A car's length, the one every pose below is measured for.
const double kCarM = 4.9;

void main() {
  late SiteWorld world;

  setUpAll(() {
    world = SiteWorld(everyTemplate())..sync();
  });

  tearDown(AgentTuning.reset);

  group('the stall manoeuvre', () {
    test('u = 1 is the stall pose, to the last bit', () {
      final out = Float64List(4);
      var stalls = 0;
      for (final t in SyntheticTemplate.values) {
        final lot = lotOf(t);
        final row = world.rowOf(lot);
        if (row < 0) continue;
        final p = world.planOf(lot);
        for (var i = 0; i < p.stallCount; i++) {
          final dir = _dirOf(world, lot, i);
          SiteManoeuvre.stallPose(p, i, dir, 1, out, 0);
          expect(out[0], closeTo(p.stallE(i), 1e-9), reason: '$lot stall $i');
          expect(out[1], closeTo(p.stallN(i), 1e-9), reason: '$lot stall $i');
          // The direction is the curve's own tangent, which is the stall's
          // re-normalised: the plan holds it in 32 bits, so it agrees to
          // about 1e-8 — a millionth of the 2° §7.4 allows.
          expect(out[2], closeTo(p.stallDirE(i), 1e-6));
          expect(out[3], closeTo(p.stallDirN(i), 1e-6));
          stalls++;
        }
      }
      expect(stalls, greaterThan(20), reason: 'the fixtures have stalls');
    });

    test('u = 0 is the aisle at the mouth, exactly where SiteGeometry puts it',
        () {
      final mine = Float64List(4);
      final theirs = Float64List(5);
      for (final t in SyntheticTemplate.values) {
        final lot = lotOf(t);
        final row = world.rowOf(lot);
        if (row < 0) continue;
        final p = world.planOf(lot);
        final g = world.lanesOf(lot);
        for (var i = 0; i < p.stallCount; i++) {
          final dir = _dirOf(world, lot, i);
          final lane = SiteManoeuvre.entryLane(p, i, dir);
          final s = SiteManoeuvre.mouthS(p, i, dir);
          SiteManoeuvre.stallPose(p, i, dir, 0, mine, 0);
          SiteGeometry.pointAt(g, lane, s, theirs, 0);
          for (var k = 0; k < 4; k++) {
            expect(mine[k], closeTo(theirs[k], 1e-9),
                reason: '$lot stall $i component $k');
          }
        }
      }
    });

    test('the mouth is on the lane, and a stall across its aisle takes a '
        'run-up', () {
      final home = world.planOf(lotOf(SyntheticTemplate.home));
      // An inline stall lies ON its pad, so it is met where it begins.
      expect(home.stallAngle(0), StallAngle.inline);
      expect(SiteManoeuvre.mouthS(home, 0, kSiteDirFwd),
          closeTo(home.stallS(0), 1e-9));
      final strip = world.planOf(lotOf(SyntheticTemplate.strip));
      expect(strip.stallAngle(0), isNot(StallAngle.inline));
      final dir = _dirOf(world, lotOf(SyntheticTemplate.strip), 0);
      final mouth = SiteManoeuvre.mouthS(strip, 0, dir);
      final seg = strip.stallSeg(0);
      final meet = dir == kSiteDirFwd
          ? strip.stallS(0)
          : strip.segLenM(seg) - strip.stallS(0);
      expect(mouth, lessThanOrEqualTo(meet));
      expect(meet - mouth, closeTo(math.min(kStallRunUpM, meet), 1e-9));
      expect(mouth, greaterThanOrEqualTo(0));
    });

    test('the pose is monotone in u and never folds back', () {
      for (final t in SyntheticTemplate.values) {
        final lot = lotOf(t);
        final row = world.rowOf(lot);
        if (row < 0) continue;
        final p = world.planOf(lot);
        for (var i = 0; i < p.stallCount; i++) {
          final dir = _dirOf(world, lot, i);
          _expectMonotone(
              (u, out) => SiteManoeuvre.stallPose(p, i, dir, u, out, 0),
              '$lot stall $i');
        }
      }
    });

    test('the curve is at least as long as its chord, and finite', () {
      final a = Float64List(4), b = Float64List(4);
      for (final t in SyntheticTemplate.values) {
        final lot = lotOf(t);
        if (world.rowOf(lot) < 0) continue;
        final p = world.planOf(lot);
        for (var i = 0; i < p.stallCount; i++) {
          final dir = _dirOf(world, lot, i);
          SiteManoeuvre.stallPose(p, i, dir, 0, a, 0);
          SiteManoeuvre.stallPose(p, i, dir, 1, b, 0);
          final chord = _dist(a, b);
          final len = SiteManoeuvre.stallCurveM(p, i, dir);
          expect(len, greaterThanOrEqualTo(chord - 1e-9));
          expect(len, lessThan(chord + 12));
          expect(len.isFinite, isTrue);
        }
      }
    });
  });

  group('the home back-out', () {
    test('u = 0 is the stall and u = 1 is the lane, nose downstream with its '
        "front on the join's T", () {
      final out = Float64List(4);
      final road = Float64List(4);
      final axis = Float64List(4);
      for (final t in [SyntheticTemplate.home, SyntheticTemplate.homeTandem]) {
        final lot = lotOf(t);
        final p = world.planOf(lot);
        final lane = _targetLane(world, lot);
        for (var i = 0; i < p.stallCount; i++) {
          SiteManoeuvre.backOutPose(p, 0, i, lane, world.lg, 0, out, 0,
              lenM: kCarM);
          expect(out[0], closeTo(p.stallE(i), 1e-9));
          expect(out[1], closeTo(p.stallN(i), 1e-9));
          expect(out[2], closeTo(p.stallDirE(i), 1e-9));
          expect(out[3], closeTo(p.stallDirN(i), 1e-9));
          SiteManoeuvre.backOutPose(p, 0, i, lane, world.lg, 1, out, 0,
              lenM: kCarM);
          // `restLaneS` answers where the car's FRONT rests — the arc the
          // mover hands to `VehicleTable.attach`, whose `s` is a front
          // (§2.3) — so the POSE that ends the swing, a centre, is half a
          // length behind it.
          final rest = SiteManoeuvre.restLaneS(p, 0, lane, world.lg);
          SiteManoeuvre.roadPose(world.lg, lane, rest - kCarM / 2, road, 0);
          for (var k = 0; k < 4; k++) {
            expect(out[k], closeTo(road[k], 1e-9), reason: '$lot stall $i');
          }
          // And that front really is on `T`: the nose of the body the pose
          // describes, projected onto the lane at the join, lands on the
          // join's own arc. Centimetres, not a bit, because the lane may
          // curve under the length the nose reaches over.
          final e = world.lg.laneEdge[lane];
          SiteManoeuvre.roadPose(
              world.lg,
              lane,
              world.lg.travelArc(e, p.joinRoadS(0)) - world.lg.edgeLaneS0[e],
              axis,
              0);
          final noseE = out[0] + out[2] * kCarM / 2;
          final noseN = out[1] + out[3] * kCarM / 2;
          final along =
              (noseE - axis[0]) * axis[2] + (noseN - axis[1]) * axis[3];
          expect(along, closeTo(0, 0.02),
              reason: '$lot stall $i rests with its front on T');
        }
      }
    });

    test('at the commit the rear is exactly on the kerb line', () {
      final out = Float64List(4);
      for (final t in [SyntheticTemplate.home, SyntheticTemplate.homeTandem]) {
        final lot = lotOf(t);
        final p = world.planOf(lot);
        final lane = _targetLane(world, lot);
        final kn = p.joinKerbNode(0);
        for (var i = 0; i < p.stallCount; i++) {
          final u =
              SiteManoeuvre.backOutCommitU(p, 0, i, lane, world.lg, kCarM);
          expect(u, inInclusiveRange(0.0, 1.0));
          SiteManoeuvre.backOutPose(p, 0, i, lane, world.lg, u, out, 0,
              lenM: kCarM);
          // The rear leads on the way out: centre minus half a car along the
          // nose. Its distance into the lot from the kerb line must be 0.
          final de = out[2], dn = out[3];
          final re = out[0] - de * kCarM / 2, rn = out[1] - dn * kCarM / 2;
          final into = (re - p.nodeE(kn)) * de + (rn - p.nodeN(kn)) * dn;
          expect(into, closeTo(0, 1e-6), reason: '$lot stall $i');
        }
      }
    });

    test('the reverse is straight, the swing turns the nose the short way',
        () {
      final out = Float64List(4);
      final lot = lotOf(SyntheticTemplate.home);
      final p = world.planOf(lot);
      final lane = _targetLane(world, lot);
      final uk = SiteManoeuvre.backOutCommitU(p, 0, 0, lane, world.lg, kCarM);
      expect(uk, greaterThan(0.1), reason: 'a real drive to reverse down');
      for (var i = 0; i <= 10; i++) {
        final u = uk * i / 10;
        SiteManoeuvre.backOutPose(p, 0, 0, lane, world.lg, u, out, 0,
            lenM: kCarM);
        expect(out[2], closeTo(p.stallDirE(0), 1e-9));
        expect(out[3], closeTo(p.stallDirN(0), 1e-9));
      }
      // Through the swing the heading turns monotonically from the stall's
      // to the lane's: its dot with the stall's only ever falls.
      var last = 1.0;
      for (var i = 0; i <= 20; i++) {
        final u = uk + (1 - uk) * i / 20;
        SiteManoeuvre.backOutPose(p, 0, 0, lane, world.lg, u, out, 0,
            lenM: kCarM);
        final dot = out[2] * p.stallDirE(0) + out[3] * p.stallDirN(0);
        expect(dot, lessThanOrEqualTo(last + 1e-9));
        expect(math.sqrt(out[2] * out[2] + out[3] * out[3]), closeTo(1, 1e-9));
        last = dot;
      }
    });

    test('the pose is monotone in u, and the body stays inside the footprint',
        () {
      final out = Float64List(4);
      for (final t in [SyntheticTemplate.home, SyntheticTemplate.homeTandem]) {
        final lot = lotOf(t);
        final p = world.planOf(lot);
        final lane = _targetLane(world, lot);
        for (var i = 0; i < p.stallCount; i++) {
          _expectMonotone(
              (u, o) => SiteManoeuvre.backOutPose(
                  p, 0, i, lane, world.lg, u, o, 0,
                  lenM: kCarM),
              '$lot back-out $i');
          // Once the rear is over the kerb line, nothing the car occupies may
          // lie outside `[T − backOutUpM, T + backOutDownM]` along the road.
          final uk =
              SiteManoeuvre.backOutCommitU(p, 0, i, lane, world.lg, kCarM);
          final e = world.lg.laneEdge[lane];
          final tArc = world.lg.travelArc(e, p.joinRoadS(0));
          final axis = Float64List(4);
          SiteManoeuvre.roadPose(
              world.lg, lane, tArc - world.lg.edgeLaneS0[e], axis, 0);
          for (var k = 0; k <= 40; k++) {
            final u = uk + (1 - uk) * k / 40;
            SiteManoeuvre.backOutPose(p, 0, i, lane, world.lg, u, out, 0,
                lenM: kCarM);
            for (final end in [kCarM / 2, -kCarM / 2]) {
              final pe = out[0] + out[2] * end, pn = out[1] + out[3] * end;
              final along =
                  (pe - axis[0]) * axis[2] + (pn - axis[1]) * axis[3];
              expect(along, greaterThan(-AgentTuning.backOutUpM - 1e-6),
                  reason: '$lot stall $i at u $u');
              expect(along, lessThan(AgentTuning.backOutDownM + 1e-6),
                  reason: '$lot stall $i at u $u');
            }
          }
        }
      }
    });
  });

  test('no trigonometry in the manoeuvre (D27)', () {
    final src = File('lib/domain/colony/city/traffic/site_manoeuvre.dart')
        .readAsStringSync();
    final banned = RegExp(r'\b(?:sin|cos|tan|asin|acos|atan|atan2)\s*\(');
    expect(banned.hasMatch(src), isFalse,
        reason: 'the curves are Béziers and sqrt, nothing else');
  });
}

/// The direction bit a car enters stall [i] of [lot] by, as the site table
/// picked its entry lane.
int _dirOf(SiteWorld w, String lot, int i) {
  final row = w.rowOf(lot);
  final lane = w.sites.laneOfTarget(row, w.sites.stallTarget(row, i));
  return SiteLaneGraph.isForward(lane) ? kSiteDirFwd : kSiteDirBwd;
}

/// The near kerb lane a home on [lot] backs out into: the lane of the edge
/// that has the lot on its right.
int _targetLane(SiteWorld w, String lot) {
  final p = w.planOf(lot);
  final a = AccessPoints.ofPlanJoin(w.lg, p, 0)!;
  for (final e in [a.fwdEdge, a.bwdEdge]) {
    if (e >= 0 && a.rightOfTravel(w.lg, e)) return w.lg.laneOf(e, 0);
  }
  throw StateError('$lot has no near edge');
}

double _dist(Float64List a, Float64List b) =>
    math.sqrt((b[0] - a[0]) * (b[0] - a[0]) + (b[1] - a[1]) * (b[1] - a[1]));

/// A pose function that never stalls and never turns back on itself: every
/// sample moves, and never more than a right angle away from the last step.
void _expectMonotone(
    void Function(double u, Float64List out) pose, String what) {
  final a = Float64List(4), b = Float64List(4);
  var lastE = 0.0, lastN = 0.0;
  var moved = 0.0;
  const n = 200;
  pose(0, a);
  for (var i = 1; i <= n; i++) {
    pose(i / n, b);
    final de = b[0] - a[0], dn = b[1] - a[1];
    final len = math.sqrt(de * de + dn * dn);
    expect(len, greaterThan(0), reason: '$what stalls at u ${i / n}');
    if (i > 1) {
      expect(de * lastE + dn * lastN, greaterThan(0),
          reason: '$what folds back at u ${i / n}');
    }
    lastE = de;
    lastN = dn;
    moved += len;
    a.setAll(0, b);
  }
  expect(moved, greaterThan(0.1), reason: '$what goes nowhere');
}
