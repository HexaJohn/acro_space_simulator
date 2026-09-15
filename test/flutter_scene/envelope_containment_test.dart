// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// R4 track B: the massing fits INSIDE the plan's envelope, and never over
/// the site's own paving (docs/plans/site-access.md §6.1, §6.2, §8.3 R4
/// `envelope_containment_test`).
///
/// The envelope is the rectangle the plan left for a building once its
/// drives, aisles and stalls were drawn, so a wall outside it is a wall
/// standing on a driveway. Two things could put one there: a massing that
/// takes more than it was given, and an archetype bucket that ROUNDS UP —
/// which is why a plan-served building takes the min-fit bucket, never more
/// than 0.25 m over its envelope, and why 0.30 m is the tolerance here.
///
/// Tested at the tiers a building is drawn from up close (full and
/// exterior). The block tier is a silhouette from a coarser library, and a
/// half-bucket of silhouette at that range is the point of it.
library;

import 'package:acro_space_simulator/application/snapshot/city_site_frame.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/architecture/architecture_style.dart';
import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/architecture/building_massing.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'site_envelope_fixture.dart';

void main() {
  late CitySim city;

  setUpAll(() => city = envelopeTown());

  tearDown(() => SiteCapture.envelopePlacement = false);

  for (final style in ArchitectureStyle.kits) {
    for (final tier in [BuildingDetail.full, BuildingDetail.exterior]) {
      test('${style.id} ${tier.name}: every volume stands on its envelope',
          () {
        final scene = EnvelopeScene.of(city, style);
        var checked = 0, volumes = 0;
        for (final b in scene.buildings) {
          final plan = scene.planOf(b);
          if (plan == null) continue;
          checked++;
          final u = Vec2(plan.frameUE, plan.frameUN);
          final v = Vec2(plan.frameVE, plan.frameVN);
          final origin = Vec2(plan.frameE, plan.frameN);
          for (final vol in scene.builtOf(b, tier).massing.volumes) {
            volumes++;
            for (final (cx, cy) in _cornersOf(vol)) {
              final at = scene.drawn(b, cx, cy, tier) - origin;
              final x = at.dot(u), y = at.dot(v);
              expect(x, greaterThan(plan.envX0 - 0.3),
                  reason: '${b.id} (${b.type}) over its envelope\'s x0');
              expect(x, lessThan(plan.envX1 + 0.3),
                  reason: '${b.id} (${b.type}) over its envelope\'s x1');
              expect(y, greaterThan(plan.envY0 - 0.3),
                  reason: '${b.id} (${b.type}) over its envelope\'s front');
              expect(y, lessThan(plan.envY1 + 0.3),
                  reason: '${b.id} (${b.type}) over its envelope\'s back');
            }
          }
        }
        expect(checked, greaterThan(100));
        expect(volumes, greaterThan(300));
      });
    }
  }

  test('no building stands on its own drive or its own stalls', () {
    final scene = EnvelopeScene.of(city, ArchitectureStyle.masonryStreet);
    var paved = 0, stalls = 0;
    for (final b in scene.buildings) {
      final plan = scene.planOf(b);
      if (plan == null) continue;
      final foot = [
        for (final vol in scene.builtOf(b).massing.volumes)
          _footprintOf(scene, b, vol),
      ];
      // Paving: every ring vertex of every drive, aisle and pad.
      for (var p = 0; p < plan.paveCount; p++) {
        for (var i = plan.paveStart(p); i < plan.paveStart(p + 1); i++) {
          final pt = plan.pavePt(i);
          final at = Vec2(plan.ptE(pt), plan.ptN(pt));
          paved++;
          for (final f in foot) {
            expect(_inside(f, at, -0.2), isFalse,
                reason: '${b.id}: a volume stands on its own paving at $at');
          }
        }
      }
      // Stalls: the car itself, not just the paint.
      for (var s = 0; s < plan.stallCount; s++) {
        final at = Vec2(plan.stallE(s), plan.stallN(s));
        stalls++;
        for (final f in foot) {
          expect(_inside(f, at, -0.2), isFalse,
              reason: '${b.id}: a volume stands in its own stall $s');
        }
      }
    }
    expect(paved, greaterThan(100));
    expect(stalls, greaterThan(20));
  });
}

/// The plan corners of [v] in the massing's own frame. A volume turned by a
/// yaw (a plate, a vehicle) is taken at its bounding square, which is the
/// conservative reading.
List<(double, double)> _cornersOf(MassBox v) {
  final turned = v.yaw != 0;
  final hw = (turned ? _maxOf(v.width, v.depth) : v.width) / 2;
  final hd = (turned ? _maxOf(v.width, v.depth) : v.depth) / 2;
  return [
    (v.x - hw, v.y - hd),
    (v.x + hw, v.y - hd),
    (v.x + hw, v.y + hd),
    (v.x - hw, v.y + hd),
  ];
}

double _maxOf(double a, double b) => a > b ? a : b;

/// [vol]'s drawn footprint as its four colony-local corners.
List<Vec2> _footprintOf(
        EnvelopeScene scene, BuildingSnapshot b, MassBox vol) =>
    [for (final (x, y) in _cornersOf(vol)) scene.drawn(b, x, y)];

/// Whether [at] lies inside the convex quad [f], grown by [grow] metres
/// (negative shrinks it).
bool _inside(List<Vec2> f, Vec2 at, double grow) {
  var centre = const Vec2(0, 0);
  for (final p in f) {
    centre = Vec2(centre.e + p.e / f.length, centre.n + p.n / f.length);
  }
  for (var i = 0; i < f.length; i++) {
    final a = f[i], c = f[(i + 1) % f.length];
    final edge = c - a;
    final len = edge.length;
    if (len <= 1e-9) continue;
    final n = edge.perp * (1 / len);
    // Outward normal, whichever winding the quad has.
    final sign = n.dot(a - centre) >= 0 ? 1.0 : -1.0;
    if (n.dot(at - a) * sign > grow) return false;
  }
  return true;
}
