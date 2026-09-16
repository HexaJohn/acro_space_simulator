// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What a site access plan draws, tier by tier (docs/plans/site-access.md
/// §5.4, §8.3 R4): the mid rule, the structural surfaces, the knob, and the
/// instant path.
library;

import 'dart:math' as math;

import 'package:acro_space_simulator/application/snapshot/city_site_frame.dart';
import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_bucketing.dart';
import 'package:acro_space_simulator/application/snapshot/city_patch_columns.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_columns.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_mesher.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_mesher.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/site_access_mesher.dart';
import 'package:flutter_test/flutter_test.dart';

import '../application/site_town_fixture.dart';

void main() {
  final city = siteTown();
  final snap = captureSiteTown(city);
  final frame = snap.sites.single;
  final anchor = frame.localToBodyFixed(0, 0, 0);

  /// Every (geometry, row) of the frame.
  final rows = <(SiteChunkGeometry, int)>[
    for (final g in frame.chunks)
      for (var k = 0; k < g.siteCount; k++) (g, k),
  ];

  /// [site]'s triangles at [tier], and the vertices they were built from.
  (int, MeshBuilder, MeshBuilder) drawn(
      SiteChunkGeometry g, int site, SiteDrawTier tier) {
    final apron = MeshBuilder(), solid = MeshBuilder();
    SiteAccessMesher.emit(
      apron: apron,
      solid: solid,
      frame: frame,
      geo: g,
      site: site,
      anchorBF: anchor,
      tier: tier,
    );
    return (apron.triangleCount + solid.triangleCount, apron, solid);
  }

  int tris(SiteChunkGeometry g, int site, SiteDrawTier tier) =>
      drawn(g, site, tier).$1;

  /// The triangles a fan over every pave ring comes to.
  int ringTris(SiteAccessPlan p) {
    var n = 0;
    for (var r = 0; r < p.paveCount; r++) {
      final c = p.paveStart(r + 1) - p.paveStart(r);
      if (c >= 3) n += c - 2;
    }
    return n;
  }

  group('the fixture is the mix the rule is about', () {
    test('four big installations, car parks at mid only, houses at neither',
        () {
      var big = 0, midOnly = 0, small = 0;
      for (final (g, k) in rows) {
        final s = SiteAccessMesher.sizeOf(g.plan.plan(k));
        if (s.big) {
          big++;
        } else if (s.midVisible) {
          midOnly++;
        } else {
          small++;
        }
      }
      expect(big, 4, reason: 'the starter kit\'s four utility sites');
      expect(midOnly, greaterThan(20), reason: 'the car parks');
      expect(small, greaterThan(50), reason: 'the houses');
    });
  });

  group('the §5.4 tier rule', () {
    test('a house draws nothing at far or mid and its drive at near', () {
      var homes = 0;
      for (final (g, k) in rows) {
        final plan = g.plan.plan(k);
        if (plan.program != SiteProgram.homeDriveway) continue;
        final size = SiteAccessMesher.sizeOf(plan);
        expect(size.midVisible, isFalse,
            reason: '${plan.siteId} pave ${size.paveAreaM2} m²');
        expect(tris(g, k, SiteDrawTier.far), 0);
        expect(tris(g, k, SiteDrawTier.mid), 0);
        expect(tris(g, k, SiteDrawTier.near), greaterThan(0));
        homes++;
      }
      expect(homes, greaterThan(50));
    });

    test('a mid-visible site draws its rings at mid and nothing at far', () {
      var seen = 0;
      for (final (g, k) in rows) {
        final plan = g.plan.plan(k);
        final size = SiteAccessMesher.sizeOf(plan);
        if (size.big || !size.midVisible) continue;
        expect(tris(g, k, SiteDrawTier.far), 0);
        // Rings only: no ribbons, no turnaround pads.
        expect(tris(g, k, SiteDrawTier.mid), ringTris(plan),
            reason: plan.siteId);
        expect(tris(g, k, SiteDrawTier.near),
            greaterThan(tris(g, k, SiteDrawTier.mid)),
            reason: plan.siteId);
        seen++;
      }
      expect(seen, greaterThan(20));
    });

    test('a big site draws at every tier, more of it the nearer it is', () {
      var seen = 0;
      for (final (g, k) in rows) {
        final plan = g.plan.plan(k);
        if (!SiteAccessMesher.sizeOf(plan).big) continue;
        final far = tris(g, k, SiteDrawTier.far);
        final mid = tris(g, k, SiteDrawTier.mid);
        final near = tris(g, k, SiteDrawTier.near);
        expect(far, greaterThan(0), reason: plan.siteId);
        expect(mid, far, reason: '${plan.siteId}: far is mid, bare');
        expect(near, greaterThan(mid), reason: plan.siteId);
        // Its rings and its ribbons both.
        expect(far, greaterThan(ringTris(plan)), reason: plan.siteId);
        seen++;
      }
      expect(seen, 4);
    });

    test('the detail pass draws the small sites only, and only paint', () {
      var painted = 0;
      for (final (g, k) in rows) {
        final plan = g.plan.plan(k);
        final size = SiteAccessMesher.sizeOf(plan);
        final (n, apron, solid) = drawn(g, k, SiteDrawTier.detail);
        expect(solid.triangleCount, 0, reason: 'paint is flat');
        if (size.big) {
          expect(n, 0, reason: '${plan.siteId} is its tile\'s');
          continue;
        }
        // Paint only where there are bays to mark: a house's stalls are
        // `inline` on its own drive.
        var bays = 0;
        for (var i = 0; i < plan.stallCount; i++) {
          if (plan.stallAngle(i) != StallAngle.inline) bays++;
        }
        expect(apron.triangleCount, bays * 4, reason: plan.siteId);
        if (bays > 0) painted++;
      }
      expect(painted, greaterThan(20));
    });
  });

  group('the paving is drawn once (§5.4: the ribbons are cut at the rings)',
      () {
    /// The drawn surface of [plan]'s pave rings at colony-local ([e], [n]):
    /// the radius of the ring fan there, barycentric over the very triangle
    /// the mesher fans, or null when no ring covers the point.
    double? ringRadiusAt(
        SiteChunkGeometry g, int site, SiteAccessPlan plan, double e,
        double n) {
      final p0 = g.plan.ptStart(site);
      for (var r = 0; r < plan.paveCount; r++) {
        final a = plan.paveStart(r), b = plan.paveStart(r + 1);
        if (b - a < 3) continue;
        (double, double, double) vert(int i) {
          final p = plan.pavePt(i);
          return (
            plan.ptE(p),
            plan.ptN(p),
            frame.localToBodyFixed(plan.ptE(p), plan.ptN(p), g.ptUp(p0 + p))
                    .length +
                SiteAccessMesher.paveLiftM,
          );
        }

        final o = vert(a);
        for (var i = a + 1; i + 1 < b; i++) {
          final u = vert(i), v = vert(i + 1);
          // Barycentric of (e, n) in the fan triangle (o, u, v).
          final d = (u.$2 - v.$2) * (o.$1 - v.$1) + (v.$1 - u.$1) * (o.$2 - v.$2);
          if (d.abs() < 1e-12) continue;
          final l0 = ((u.$2 - v.$2) * (e - v.$1) + (v.$1 - u.$1) * (n - v.$2)) / d;
          final l1 = ((v.$2 - o.$2) * (e - v.$1) + (o.$1 - v.$1) * (n - v.$2)) / d;
          final l2 = 1 - l0 - l1;
          if (l0 < -1e-9 || l1 < -1e-9 || l2 < -1e-9) continue;
          return o.$3 * l0 + u.$3 * l1 + v.$3 * l2;
        }
      }
      return null;
    }

    /// How far colony-local ([e], [n]) lies INSIDE the deepest ring that
    /// holds it, metres; negative when no ring does. A quad is cut by its
    /// centre, so a triangle that straddles a ring's edge may still overlap
    /// it by a sliver: what must never be drawn again is paving well inside.
    double paveDepth(SiteAccessPlan plan, double e, double n) {
      var best = double.negativeInfinity;
      for (var r = 0; r < plan.paveCount; r++) {
        final a = plan.paveStart(r), b = plan.paveStart(r + 1);
        if (b - a < 3) continue;
        var twice = 0.0;
        for (var i = a; i < b; i++) {
          final p = plan.pavePt(i);
          final q = plan.pavePt(i + 1 < b ? i + 1 : a);
          twice += plan.ptE(p) * plan.ptN(q) - plan.ptE(q) * plan.ptN(p);
        }
        if (twice.abs() < 1e-9) continue;
        final want = twice > 0 ? 1.0 : -1.0;
        var depth = double.infinity;
        for (var i = a; i < b; i++) {
          final p = plan.pavePt(i);
          final q = plan.pavePt(i + 1 < b ? i + 1 : a);
          final ex = plan.ptE(q) - plan.ptE(p), nx = plan.ptN(q) - plan.ptN(p);
          final len = math.sqrt(ex * ex + nx * nx);
          if (len < 1e-9) continue;
          final d =
              (ex * (n - plan.ptN(p)) - nx * (e - plan.ptE(p))) * want / len;
          if (d < depth) depth = d;
        }
        if (depth > best) best = depth;
      }
      return best;
    }

    test('nothing a site draws stands on the surface of its own pave rings',
        () {
      var checked = 0, deep = 0, lying = 0;
      for (final (g, k) in rows) {
        final plan = g.plan.plan(k);
        final (_, apron, _) = drawn(g, k, SiteDrawTier.near);
        final mesh = apron.build();
        final fans = ringTris(plan);
        expect(mesh.triangleCount, greaterThan(fans),
            reason: '${plan.siteId}: the throat crossing is never cut');
        for (var t = fans; t < mesh.triangleCount; t++) {
          checked++;
          // A triangle every corner of which lies on the ring surface, well
          // inside the ring, is the paving drawn a second time — the z-fight
          // the cut exists to stop. A surface that CROSSES the ring (the
          // throat landing on it, an access road's kerb face) has corners
          // above and below, and is what the tiers are meant to draw.
          var on = 0, inside = 0;
          for (var c = 0; c < 3; c++) {
            final i = mesh.indices[t * 3 + c];
            final at = Vector3(mesh.positions[i * 3], mesh.positions[i * 3 + 1],
                        mesh.positions[i * 3 + 2]) *
                    1000.0 +
                anchor;
            final e = at.dot(frame.east), n = at.dot(frame.north);
            if (paveDepth(plan, e, n) < 1.0) continue;
            inside++;
            final ring = ringRadiusAt(g, k, plan, e, n);
            if (ring != null && (at.length - ring).abs() <= 0.02) on++;
          }
          if (inside == 3) deep++;
          if (on == 3) lying++;
          expect(on, lessThan(3),
              reason: '${plan.siteId}: a surface on its own paving '
                  '(tri $t of ${mesh.triangleCount}, fans $fans)');
        }
      }
      expect(checked, greaterThan(200));
      expect(lying, 0);
      expect(deep, greaterThan(0),
          reason: 'the fixture draws inside its rings, so the check bites');
    });

    test('the fixture has turnaround pads its own paving already carries', () {
      var pads = 0, cut = 0;
      for (final (g, k) in rows) {
        final plan = g.plan.plan(k);
        for (var n = 0; n < plan.nodeCount; n++) {
          if (plan.nodeTurnKind(n) == TurnaroundKind.none) continue;
          if (!(plan.nodeTurnR(n) > 0)) continue;
          pads++;
          final row = plan.nodePt(n);
          if (SiteAccessMesher.insidePave(
              plan, plan.ptE(row), plan.ptN(row))) {
            cut++;
          }
        }
      }
      expect(pads, greaterThan(0));
      expect(cut, greaterThan(0), reason: 'the fixture has pads on paving');
      // A pad on a ring draws nothing: the near count is the same whether or
      // not the plan has one, which the triangle audit above proves point by
      // point. Here only that the fixture exercises the branch.
    });
  });

  group('the throat rides over the walk it crosses (§5.4, §5.5)', () {
    /// The walk's top [d] metres in from the kerb edge across a dropped
    /// kerb: `cutTopLiftM` at the kerb easing to `walkTopLiftM` at the back
    /// of the 3 m pavement band (road_mesher `sidewalks`).
    double walkTopAt(double d) =>
        RoadMesher.cutTopLiftM +
        (RoadMesher.walkTopLiftM - RoadMesher.cutTopLiftM) * (d / 3.0);

    test('at 0, 1.5 and 3 m from the kerb it stands one paint over the flags',
        () {
      for (final d in const [0.0, 1.5, 3.0]) {
        expect(SiteAccessMesher.throatLiftAt(d), greaterThan(walkTopAt(d)),
            reason: '$d m in');
        expect(SiteAccessMesher.throatLiftAt(d) - walkTopAt(d),
            closeTo(RoadMesher.paintLiftM, 1e-9));
      }
      // Inside the lot line it settles onto the site's own paving.
      expect(
          SiteAccessMesher.throatLiftAt(
              SiteAccessMesher.throatRampM + SiteAccessMesher.throatSettleM),
          SiteAccessMesher.paveLiftM);
    });

    test('every drawn throat has a station at each knee, at the knee height',
        () {
      var throats = 0;
      for (final (g, k) in rows) {
        final plan = g.plan.plan(k);
        final p0 = g.plan.ptStart(k);
        final (_, apron, _) = drawn(g, k, SiteDrawTier.near);
        final mesh = apron.build();
        for (var s = 0; s < plan.segCount; s++) {
          if (plan.segFlags(s) & kSegThroat == 0) continue;
          final n = plan.segPointCount(s);
          // The throat's own points, body-fixed at their heights: the drape
          // the mesher rides, sampled where it samples it.
          final pts = [
            for (var i = 0; i < n; i++)
              () {
                final p = plan.segPoint(s, i);
                return frame.localToBodyFixed(
                    plan.ptE(p), plan.ptN(p), g.ptUp(p0 + p));
              }(),
          ];
          var whole = 0.0;
          for (var i = 1; i < pts.length; i++) {
            whole += (pts[i] - pts[i - 1]).length;
          }
          final from = plan.segFrom(s);
          final fromKerb = from >= 0 &&
              from < plan.nodeCount &&
              plan.nodeFlags(from) & kNodeKerb != 0;
          for (final d in [
            0.0,
            SiteAccessMesher.throatRampM,
            SiteAccessMesher.throatRampM + SiteAccessMesher.throatSettleM,
          ]) {
            if (d >= whole - 1e-3) continue;
            final want = fromKerb ? d : whole - d;
            // The point at that arc, and the radius the mesher draws there.
            var run = 0.0;
            var ground = pts.first;
            for (var i = 1; i < pts.length; i++) {
              final seg = pts[i] - pts[i - 1];
              final len = seg.length;
              if (len < 1e-6) continue;
              if (want <= run + len) {
                ground = pts[i - 1] + seg * ((want - run) / len);
                break;
              }
              run += len;
            }
            final target =
                ground.length + SiteAccessMesher.throatLiftAt(d);
            var best = double.infinity;
            for (var i = 0; i < mesh.vertexCount; i++) {
              final at = Vector3(
                          mesh.positions[i * 3],
                          mesh.positions[i * 3 + 1],
                          mesh.positions[i * 3 + 2]) *
                      1000.0 +
                  anchor;
              // The ribbon's edges lie half a width either side of the
              // centre, so a knee station is found by its arc, not its
              // point: take the nearest vertex within half the width.
              final across = (at - ground).length;
              if (across > plan.segWidthM(s) / 2 + 0.3) continue;
              final gap = (at.length - target).abs();
              if (gap < best) best = gap;
            }
            expect(best, lessThan(0.01),
                reason: '${plan.siteId}: no station $d m from the kerb');
          }
          throats++;
        }
      }
      expect(throats, greaterThan(50));
    });
  });

  group('what it draws stands where the plan is', () {
    test('every vertex is inside the plan, its widest ribbon and a margin',
        () {
      for (final (g, k) in rows) {
        final plan = g.plan.plan(k);
        var widest = 0.0;
        for (var s = 0; s < plan.segCount; s++) {
          if (plan.segWidthM(s) > widest) widest = plan.segWidthM(s);
        }
        for (var n = 0; n < plan.nodeCount; n++) {
          if (plan.nodeTurnR(n) > widest) widest = plan.nodeTurnR(n);
        }
        final margin = widest + 2.0;
        var loE = double.infinity, hiE = -double.infinity;
        var loN = double.infinity, hiN = -double.infinity;
        for (var p = 0; p < plan.pointCount; p++) {
          loE = loE < plan.ptE(p) ? loE : plan.ptE(p);
          hiE = hiE > plan.ptE(p) ? hiE : plan.ptE(p);
          loN = loN < plan.ptN(p) ? loN : plan.ptN(p);
          hiN = hiN > plan.ptN(p) ? hiN : plan.ptN(p);
        }
        final (_, apron, solid) = drawn(g, k, SiteDrawTier.near);
        for (final b in [apron, solid]) {
          final mesh = b.build();
          for (var i = 0; i < mesh.vertexCount; i++) {
            // Scene units back to metres, and back into colony-local.
            final at = Vector3(mesh.positions[i * 3], mesh.positions[i * 3 + 1],
                    mesh.positions[i * 3 + 2]) *
                    (1 / 0.001) +
                anchor;
            final e = at.dot(frame.east), n = at.dot(frame.north);
            expect(e, greaterThan(loE - margin), reason: plan.siteId);
            expect(e, lessThan(hiE + margin), reason: plan.siteId);
            expect(n, greaterThan(loN - margin), reason: plan.siteId);
            expect(n, lessThan(hiN + margin), reason: plan.siteId);
          }
        }
      }
    });
  });

  group('the tile draws them only with the knob on', () {
    const body = 'moon';
    final bigRows = [
      for (final (g, k) in rows)
        if (SiteAccessMesher.sizeOf(g.plan.plan(k)).big) (g, k),
    ];

    CityTileColumns columns({required bool withSites}) =>
        CityTileColumns.fromSnapshots(
          buildings: const [],
          roads: const [],
          patches: CityPatchColumns.of(const []),
          ends: const [],
          roadEnds: const [],
          transitEnds: const [],
          sites: withSites ? [frame.subset(bigRows)] : const [],
        );

    CityMeshKnobs knobs(bool siteAccess) => CityMeshKnobs(
          styleId: 'masonry-street',
          bucketM: 6,
          variants: 4,
          perBuildingLod: true,
          blockRangeM: 300,
          interiorRangeM: 50,
          lodDebug: false,
          onStreetParking: true,
          sealedWorld: false,
          maxParkedCars: 400,
          siteAccess: siteAccess,
        );

    int roadTris(CityTier tier, {required bool on}) {
      final result = CityTileMesher.mesh(
        CityTileRequest(
          tileKey: '$body/0/0',
          key: 'k',
          tier: tier,
          canDetail: false,
          anchorBF: anchor,
          columns: columns(withSites: on),
          focusBF: anchor,
          colonyTier: BuildingDetail.block,
          epoch: 0,
          knobs: knobs(on),
        ),
        CityBuildingLibraries(),
      );
      return result.groups
          .where((g) => g.material == CityMaterialKind.road)
          .fold(0, (n, g) => n + g.triangleCount);
    }

    test('off: no site geometry at any tier', () {
      for (final tier in CityTier.values) {
        expect(roadTris(tier, on: false), 0, reason: tier.name);
      }
    });

    test('on: the four big sites are drawn at every tier', () {
      for (final tier in CityTier.values) {
        expect(roadTris(tier, on: true), greaterThan(0), reason: tier.name);
      }
      expect(roadTris(CityTier.near, on: true),
          greaterThan(roadTris(CityTier.far, on: true)));
    });

    test('the sites step is planned at every tier, and only with the knob',
        () {
      for (final on in [false, true]) {
        for (final tier in CityTier.values) {
          final job = CityTileMeshJob(
            CityTileRequest(
              tileKey: '$body/0/0',
              key: 'k',
              tier: tier,
              canDetail: false,
              anchorBF: anchor,
              columns: columns(withSites: on),
              focusBF: anchor,
              colonyTier: BuildingDetail.block,
              epoch: 0,
              knobs: knobs(on),
            ),
            CityBuildingLibraries(),
          );
          final has =
              job.steps.any((s) => s.kind == CityMeshStepKind.sites);
          expect(has, on, reason: '${tier.name} knob $on');
        }
      }
    });
  });

  group('the instant path', () {
    /// One tile of sites, as a cut hands them over.
    List<(String, String, List<CityTileSite>)> cut(
            List<(SiteChunkGeometry, int)> of) =>
        [
          ('moon', 'moon/0/0', [
            for (final (g, k) in of) CityTileSite(frame, g, k),
          ]),
        ];

    test("a body's first cut counts every site as new", () {
      final t = InstantSiteTracker();
      t.noteCut(cut(rows.take(4).toList()));
      // A body's first cut IS every site: the road tracker's rule, so a
      // colony loaded draws at once.
      expect(t.pendingCount, 4);
      expect(t.bodies, {'moon'});
    });

    test('a re-published plan that draws the same is not new', () {
      final t = InstantSiteTracker();
      t.noteCut(cut(rows.take(4).toList()));
      t.retire((_) => true);
      expect(t.pendingCount, 0);
      final was = t.revisionOf('moon');
      t.noteCut(cut(rows.take(4).toList()));
      expect(t.pendingCount, 0);
      expect(t.revisionOf('moon'), was);
    });

    test('a changed key is pending until its tile shows current', () {
      final t = InstantSiteTracker();
      t.noteCut(cut(rows.take(4).toList()));
      t.retire((_) => true);
      final (g, k) = rows.first;
      final moved = g.debugWithSiteKey(k, g.siteKey(k) ^ 0x5bd1e995);
      t.noteCut(cut([(moved, k), ...rows.skip(1).take(3)]));
      expect(t.pendingCount, 1);
      expect(t.pendingOn('moon').single.site, k);
      expect(t.retire((key) => false), isFalse);
      expect(t.pendingCount, 1);
      expect(t.retire((key) => key == 'moon/0/0'), isTrue);
      expect(t.pendingCount, 0);
    });

    test('a pending site draws the same triangles the near tile would', () {
      final t = InstantSiteTracker();
      final (g, k) = rows.firstWhere(
          (r) => SiteAccessMesher.sizeOf(r.$1.plan.plan(r.$2)).big);
      t.noteCut(cut([(g, k)]));
      final e = t.pendingOn('moon').single;
      final apron = MeshBuilder(), solid = MeshBuilder();
      SiteAccessMesher.emit(
        apron: apron,
        solid: solid,
        frame: e.frame,
        geo: e.geometry,
        site: e.site,
        anchorBF: anchor,
        tier: SiteDrawTier.near,
      );
      expect(apron.triangleCount + solid.triangleCount,
          tris(g, k, SiteDrawTier.near));
    });
  });
}
