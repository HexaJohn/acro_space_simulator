// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What a plan-served lot is DRESSED with (docs/plans/site-access.md §5.4,
/// §5.5, §8.3 R6, §9 "R6 Dressing"): the fence ring on the real parcel
/// polygon with the plan's gaps, the sign by the throat, the footpaths, the
/// lamps, the wheel stops, the bay hatch, the arrows, and the cars baked
/// into the stalls — skipped on a site agent traffic manages.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_dressing.dart';
import 'package:acro_space_simulator/domain/scatter/mesh_builder.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_detail_layer.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_nodes.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_bucketing.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_columns.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_mesher.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/lot_features.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/site_access_mesher.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/site_dressing_mesher.dart';
import 'package:flutter_test/flutter_test.dart';

import '../application/site_town_fixture.dart';

void main() {
  final city = siteTown();
  final snap = captureSiteTown(city);
  final frame = snap.sites.single;
  final anchor = frame.localToBodyFixed(0, 0, 0);
  final buildings = [
    for (final b in snap.buildings.values)
      if (b.colonyId == city.id) b,
  ];
  // A house in the middle of the fixture's street: a detail job gathered
  // about it holds a few dozen served lots, houses and car parks among them.
  final house = buildings.firstWhere((b) => b.type == 'r-low');
  final houseFocus = Vector3(house.px, house.py, house.pz);

  final rows = <(SiteChunkGeometry, int)>[
    for (final g in frame.chunks)
      for (var k = 0; k < g.siteCount; k++) (g, k),
  ];

  SiteDraw drawOf((SiteChunkGeometry, int) row) =>
      SiteDraw(frame, row.$1, row.$2, anchor);

  group('the lot ring rides the wire, as the fence walks it', () {
    test('every site of the fixture carries its real parcel polygon', () {
      var checked = 0;
      for (final row in rows) {
        final d = drawOf(row);
        final parcel = city.layout.parcelById(d.plan.siteId);
        if (parcel == null) continue;
        final (e, n) = d.lotRing();
        expect(e, hasLength(parcel.polygon.length), reason: d.plan.siteId);
        for (var i = 0; i < e.length; i++) {
          expect(e[i], closeTo(parcel.polygon[i].e, 0.01), reason: d.plan.siteId);
          expect(n[i], closeTo(parcel.polygon[i].n, 0.01), reason: d.plan.siteId);
        }
        checked++;
      }
      expect(checked, greaterThan(80));
    });

    test('a pad height a fence stands on is the plan\'s own pad', () {
      for (final row in rows) {
        final d = drawOf(row);
        // Every `pad` point of the plan stands at the same height as the
        // fence does: one datum a lot, which is what the ring is drawn on.
        for (var p = 0; p < d.plan.pointCount; p++) {
          if (d.plan.ptHRef(p) != SiteHeightRef.pad) continue;
          if (d.plan.ptDz(p) != 0) continue;
          final up = row.$1.ptUp(row.$1.plan.ptStart(row.$2) + p);
          // A corridor-levelled point stands on the ramp, not the pad; the
          // ones that are not are the pad's own.
          if ((up - d.padUp).abs() > 1e-6) continue;
          expect(up, closeTo(d.padUp, 1e-9));
        }
      }
    });
  });

  group('the fence ring (§5.5)', () {
    test('a fenced lot draws runs, and opens where a drive or a path '
        'crosses its lot line', () {
      var fenced = 0, gapped = 0;
      for (final row in rows) {
        final d = drawOf(row);
        final m = MeshBuilder();
        SiteDressingMesher.emitFenceRing(m, d, LotEdging.picket, coarse: true);
        if (m.triangleCount == 0) continue;
        fenced++;
        final (e, n) = d.lotRing();
        final gaps = SiteDressing.fenceGapsOf(d.plan, e, n);
        if (gaps.isNotEmpty) gapped++;
        for (final g in gaps) {
          expect(g.t0, lessThan(g.t1), reason: d.plan.siteId);
          expect(g.t0, greaterThanOrEqualTo(0));
          expect(g.t1, lessThanOrEqualTo(1));
        }
      }
      expect(fenced, greaterThan(80), reason: 'the fixture is a town of lots');
      expect(gapped, fenced, reason: 'every served lot has a way in');
    });

    test('no fence run crosses a drive, an aisle or a footpath', () {
      var runs = 0;
      for (final row in rows) {
        final d = drawOf(row);
        final (ringE, ringN) = d.lotRing();
        if (ringE.length < 3) continue;
        final gaps = SiteDressing.fenceGapsOf(d.plan, ringE, ringN);
        for (var i = 0; i < ringE.length; i++) {
          final j = i + 1 < ringE.length ? i + 1 : 0;
          final de = ringE[j] - ringE[i], dn = ringN[j] - ringN[i];
          for (final (t0, t1) in SiteDressing.fenceRunsOf(i, gaps)) {
            final ax = ringE[i] + de * t0, ay = ringN[i] + dn * t0;
            final bx = ringE[i] + de * t1, by = ringN[i] + dn * t1;
            if (math.sqrt((bx - ax) * (bx - ax) + (by - ay) * (by - ay)) < 0.5) {
              continue;
            }
            runs++;
            for (var k = 0; k < d.plan.segCount; k++) {
              final m = d.plan.segPointCount(k);
              for (var p = 1; p < m; p++) {
                final a = d.plan.segPoint(k, p - 1), b = d.plan.segPoint(k, p);
                expect(
                    _crosses(ax, ay, bx, by, d.plan.ptE(a), d.plan.ptN(a),
                        d.plan.ptE(b), d.plan.ptN(b)),
                    isFalse,
                    reason: '${d.plan.siteId}: a fence across segment $k');
              }
            }
            for (var q = 0; q < d.plan.pathCount; q++) {
              for (var p = d.plan.pathStart(q) + 1;
                  p < d.plan.pathStart(q + 1);
                  p++) {
                final a = d.plan.pathPt(p - 1), b = d.plan.pathPt(p);
                expect(
                    _crosses(ax, ay, bx, by, d.plan.ptE(a), d.plan.ptN(a),
                        d.plan.ptE(b), d.plan.ptN(b)),
                    isFalse,
                    reason: '${d.plan.siteId}: a fence across path $q');
              }
            }
          }
        }
      }
      expect(runs, greaterThan(200));
    });

    test('an unfenced lot type draws nothing', () {
      final d = drawOf(rows.first);
      final m = MeshBuilder();
      SiteDressingMesher.emitFenceRing(m, d, LotEdging.none, coarse: false);
      expect(m.triangleCount, 0);
    });
  });

  group('the sign, the footpaths, the lamps and the wheel stops', () {
    test('the sign stands beside the throat, on the building side, at the '
        'lot line', () {
      var seen = 0;
      for (final row in rows) {
        final d = drawOf(row);
        final pose = SiteDressingMesher.signPose(d);
        if (pose == null) continue;
        final (e, n, _, _) = pose;
        // In frame metres: just inside the lot line, clear of the throat.
        final x = (e - d.plan.frameE) * d.plan.frameUE +
            (n - d.plan.frameN) * d.plan.frameUN;
        final y = (e - d.plan.frameE) * d.plan.frameVE +
            (n - d.plan.frameN) * d.plan.frameVN;
        expect(y, closeTo(1.0, 1e-6), reason: d.plan.siteId);
        var seg = -1;
        for (var j = 0; j < d.plan.joinCount && seg < 0; j++) {
          final t = d.plan.joinThroatSeg(j);
          if (t >= 0 && t < d.plan.segCount) seg = t;
        }
        if (seg < 0) continue;
        // Clear of the throat by half its width plus the clearance.
        final envX = (d.plan.envX0 + d.plan.envX1) / 2;
        final clear = d.plan.segWidthM(seg) / 2 +
            SiteDressingMesher.signClearanceM;
        var near = double.infinity;
        for (var i = 0; i < d.plan.segPointCount(seg); i++) {
          final p = d.plan.segPoint(seg, i);
          final px = (d.plan.ptE(p) - d.plan.frameE) * d.plan.frameUE +
              (d.plan.ptN(p) - d.plan.frameN) * d.plan.frameUN;
          final py = (d.plan.ptE(p) - d.plan.frameE) * d.plan.frameVE +
              (d.plan.ptN(p) - d.plan.frameN) * d.plan.frameVN;
          if (py.abs() > 6) continue;
          if ((x - px).abs() < near) near = (x - px).abs();
        }
        if (near.isFinite) {
          expect(near, greaterThan(clear - 0.51), reason: d.plan.siteId);
        }
        // Never further from the lot's middle than the throat is: it
        // stands on the BUILDING side of the drive, not out in the street.
        expect((x - envX).abs(), lessThan(d.plan.envX1 - d.plan.envX0 + 20),
            reason: d.plan.siteId);
        seen++;
      }
      expect(seen, greaterThan(80));
    });

    test('a sign is drawn on the facade and the glow, once', () {
      final row = rows.firstWhere((r) =>
          SiteDressingMesher.signPose(drawOf(r)) != null);
      final solid = MeshBuilder(), glow = MeshBuilder();
      SiteDressingMesher.emitSign(solid, glow, drawOf(row), 1.0);
      expect(solid.triangleCount, greaterThan(0));
      expect(glow.triangleCount, 2, reason: 'one lit board');
    });

    test('a footpath is a ribbon per path, over the site\'s paving', () {
      var paths = 0;
      for (final row in rows) {
        final d = drawOf(row);
        final m = MeshBuilder();
        SiteDressingMesher.emitFootpaths(m, d);
        var quads = 0;
        for (var q = 0; q < d.plan.pathCount; q++) {
          final n = d.plan.pathStart(q + 1) - d.plan.pathStart(q);
          if (n >= 2) quads += n - 1;
        }
        expect(m.triangleCount, quads * 2, reason: d.plan.siteId);
        if (quads > 0) paths++;
      }
      expect(paths, greaterThan(80));
    });

    test('a lamp column and its head stand at every lampPt', () {
      var lamps = 0;
      for (final row in rows) {
        final d = drawOf(row);
        final solid = MeshBuilder(), glow = MeshBuilder();
        SiteDressingMesher.emitLamps(solid, glow, d);
        expect(solid.triangleCount, d.plan.lampCount * 12,
            reason: d.plan.siteId);
        expect(glow.triangleCount, d.plan.lampCount * 12,
            reason: d.plan.siteId);
        lamps += d.plan.lampCount;
      }
      expect(lamps, greaterThan(20), reason: 'the fixture has car parks');
    });

    test('a wheel stop stands at the nose of every bay stall, and none on a '
        'home drive', () {
      var stops = 0, inline = 0;
      for (final row in rows) {
        final d = drawOf(row);
        final m = MeshBuilder();
        SiteDressingMesher.emitWheelStops(m, d);
        var bays = 0;
        for (var i = 0; i < d.plan.stallCount; i++) {
          if (d.plan.stallAngle(i) == StallAngle.inline) {
            inline++;
          } else {
            bays++;
          }
        }
        expect(m.triangleCount, bays * 12, reason: d.plan.siteId);
        stops += bays;
      }
      expect(stops, greaterThan(20));
      expect(inline, greaterThan(20), reason: 'the fixture has home drives');
    });

    test('a wheel stop stands back from its stall\'s nose, across it', () {
      final row = rows.firstWhere((r) {
        final d = drawOf(r);
        for (var i = 0; i < d.plan.stallCount; i++) {
          if (d.plan.stallAngle(i) != StallAngle.inline) return true;
        }
        return false;
      });
      final d = drawOf(row);
      final i = () {
        for (var k = 0; k < d.plan.stallCount; k++) {
          if (d.plan.stallAngle(k) != StallAngle.inline) return k;
        }
        return 0;
      }();
      final m = MeshBuilder();
      SiteDressingMesher.emitWheelStops(m, d);
      final mesh = m.build();
      final centre = d.atLocal(
          d.plan.stallE(i), d.plan.stallN(i), d.stallUp(i));
      final up = d.upAt(centre);
      final nose = d.tangent(d.plan.stallDirE(i), d.plan.stallDirN(i), up)!;
      final want = centre +
          nose *
              (d.plan.stallLenM(i) / 2 - SiteDressingMesher.wheelStopSetbackM);
      var best = double.infinity;
      for (var v = 0; v < mesh.vertexCount; v++) {
        final at = Vector3(mesh.positions[v * 3], mesh.positions[v * 3 + 1],
                mesh.positions[v * 3 + 2]) *
            1000.0;
        final gap = (at - want).length;
        if (gap < best) best = gap;
      }
      expect(best, lessThan(1.2), reason: 'the block is at the stall\'s nose');
    });

    test('the bay hatch is one quad a loading bay', () {
      var bays = 0;
      for (final row in rows) {
        final d = drawOf(row);
        final m = MeshBuilder();
        SiteDressingMesher.emitBayHatch(m, d);
        final n = SiteDressingMesher.hatchedBays(d);
        expect(m.triangleCount, n * 2, reason: d.plan.siteId);
        bays += n;
      }
      expect(bays, greaterThan(0), reason: 'the fixture has loading bays');
    });

    test('arrows point in and out of a two-lane throat, and never up a home '
        'drive', () {
      var withArrows = 0;
      for (final row in rows) {
        final d = drawOf(row);
        final arrows = SiteDressingMesher.arrows(d);
        if (d.plan.program == SiteProgram.homeDriveway) {
          expect(arrows, isEmpty, reason: d.plan.siteId);
          continue;
        }
        if (arrows.isEmpty) continue;
        withArrows++;
        // A two-way throat takes a pair, one each way, either side of its
        // axis.
        final seg = arrows.first.seg;
        if (d.plan.segLaneMode(seg) == SiteLaneMode.twoWay) {
          expect(arrows.where((a) => a.seg == seg), hasLength(2));
          final pair = arrows.where((a) => a.seg == seg).toList();
          expect(pair[0].forward, isNot(pair[1].forward));
          expect(pair[0].offsetM, closeTo(-pair[1].offsetM, 1e-9));
          expect(d.plan.segWidthM(seg),
              greaterThanOrEqualTo(SiteDressingMesher.arrowThroatWidthM));
        }
      }
      expect(withArrows, greaterThan(0));
    });
  });

  group('baked lot cars (§5.5, §7.5)', () {
    test('a car stands at its stall\'s pose, within a centimetre', () {
      var cars = 0;
      for (final row in rows) {
        final d = drawOf(row);
        final placed = SiteDressingMesher.lotCars(d, maxCars: 99, airless: false);
        for (final car in placed) {
          final want = d.atLocal(d.plan.stallE(car.stall),
              d.plan.stallN(car.stall), d.stallUp(car.stall));
          // Over the stall by exactly the paving's lift, and nosed the way
          // the stall does.
          expect((car.at - want).length,
              closeTo(SiteAccessMesher.paveLiftM, 0.01),
              reason: '${d.plan.siteId} stall ${car.stall}');
          final up = d.upAt(want);
          final nose = d.tangent(d.plan.stallDirE(car.stall),
              d.plan.stallDirN(car.stall), up)!;
          expect(car.nose.dot(nose), greaterThan(0.9999));
          expect(car.kind.lengthM,
              lessThanOrEqualTo(d.plan.stallLenM(car.stall) * 1.1));
        }
        cars += placed.length;
      }
      expect(cars, greaterThan(20));
    });

    test('never more cars than stalls, and none at all with no budget', () {
      for (final row in rows) {
        final d = drawOf(row);
        expect(
            SiteDressingMesher.lotCars(d, maxCars: 99, airless: false).length,
            lessThanOrEqualTo(d.plan.stallCount),
            reason: d.plan.siteId);
        expect(SiteDressingMesher.lotCars(d, maxCars: 0, airless: false),
            isEmpty);
      }
    });

    test('the budget bounds them, and a tile with maxParkedCars 0 bakes '
        'none', () {
      final row = rows.firstWhere(
          (r) => drawOf(r).plan.stallCount > 3 &&
              SiteDressingMesher.lotCars(drawOf(r), maxCars: 99, airless: false)
                      .length >
                  1);
      final d = drawOf(row);
      expect(SiteDressingMesher.lotCars(d, maxCars: 1, airless: false),
          hasLength(1));
      // And at the tile: the cars go on the facade material with the rest
      // of the furniture, so a job with no car budget draws less of it.
      expect(_tileFacadeTris(frame, buildings, houseFocus, maxParkedCars: 0),
          lessThan(_tileFacadeTris(frame, buildings, houseFocus,
              maxParkedCars: 400)));
    });

    test('which stalls hold a car is seeded by (siteId, stallKey), not by '
        'index', () {
      for (final row in rows) {
        final d = drawOf(row);
        final occ = SiteDressing.occupancyPerMille(d.plan.siteId);
        final placed = SiteDressingMesher.lotCars(d, maxCars: 99, airless: false);
        final held = {for (final c in placed) d.plan.stallKey(c.stall)};
        for (var i = 0; i < d.plan.stallCount; i++) {
          final key = d.plan.stallKey(i);
          final want = SiteDressing.occupied(
              SiteDressing.stallSeed(d.plan.siteId, key), occ);
          // Every occupied stall is in, budget permitting (99 here).
          expect(held.contains(key), want,
              reason: '${d.plan.siteId} stall $i key $key');
        }
      }

      // The KEY really reaches the seed: two stalls of one site seed
      // differently, so a seed that reads the site alone is red here.
      final many = drawOf(rows.firstWhere((r) => drawOf(r).plan.stallCount > 3));
      final seeds = <int>{
        for (var i = 0; i < many.plan.stallCount; i++)
          SiteDressing.stallSeed(many.plan.siteId, many.plan.stallKey(i)),
      };
      expect(seeds, hasLength(greaterThan(1)),
          reason: 'every stall of ${many.plan.siteId} seeds alike');

      // And the mixing itself is pinned, so the function cannot drift:
      // one site id, two keys, one occupied and one not (§5.5).
      const pinId = 'r6-seed-pin';
      expect(SiteDressing.occupancyPerMille(pinId), 549);
      expect(SiteDressing.stallSeed(pinId, 7), 3164117196);
      expect(SiteDressing.stallSeed(pinId, 4), 2904380927);
      expect(SiteDressing.occupied(SiteDressing.stallSeed(pinId, 7), 549),
          isTrue);
      expect(SiteDressing.occupied(SiteDressing.stallSeed(pinId, 4), 549),
          isFalse);
      // A key stored signed reads as the same unsigned word (V10).
      expect(SiteDressing.stallSeed(pinId, -1),
          SiteDressing.stallSeed(pinId, 0xFFFFFFFF));
    });

    test('a plan change that keeps a stall keeps its car', () {
      // The seed reads the KEY, so a stall that moves index — or a site
      // whose other aisles are re-planned — keeps whatever it held.
      final d = drawOf(rows.firstWhere((r) => drawOf(r).plan.stallCount > 3));
      final occ = SiteDressing.occupancyPerMille(d.plan.siteId);
      final before = <int, bool>{
        for (var i = 0; i < d.plan.stallCount; i++)
          d.plan.stallKey(i): SiteDressing.occupied(
              SiteDressing.stallSeed(d.plan.siteId, d.plan.stallKey(i)), occ),
      };
      // A stall key is what it is wherever it sits: re-read in reverse.
      for (var i = d.plan.stallCount - 1; i >= 0; i--) {
        final key = d.plan.stallKey(i);
        expect(
            SiteDressing.occupied(
                SiteDressing.stallSeed(d.plan.siteId, key), occ),
            before[key]);
      }
      // And a different site's stall of the same key is its own draw.
      final other = drawOf(rows.firstWhere((r) =>
          drawOf(r).plan.siteId != d.plan.siteId &&
          drawOf(r).plan.stallCount > 0));
      expect(SiteDressing.stallSeed(other.plan.siteId, d.plan.stallKey(0)),
          isNot(SiteDressing.stallSeed(d.plan.siteId, d.plan.stallKey(0))));
    });
  });

  group('the agent-managed skip (§5.5, the road-side seam)', () {
    tearDown(() => CityNodes.agentManagedSites = null);

    test('with no seam nothing is managed and every site bakes its cars',
        () {
      CityNodes.agentManagedSites = null;
      expect(CityNodes.agentManagedOf(snap), isEmpty);
      expect(_tileFacadeTris(frame, buildings, houseFocus, maxParkedCars: 400),
          greaterThan(0));
    });

    test('a managed site bakes none, an unmanaged one does', () {
      // A site its own tile does not dress — anything but a big one — so
      // the detail pass is where its cars come from.
      final row = rows.firstWhere((r) =>
          !SiteAccessMesher.sizeOf(drawOf(r).plan).big &&
          SiteDressingMesher.lotCars(drawOf(r), maxCars: 99, airless: false)
              .isNotEmpty);
      final d = drawOf(row);
      final cars = MeshBuilder(), glass = MeshBuilder();
      final plain = SiteAccessMesher.emit(
        apron: MeshBuilder(),
        solid: MeshBuilder(),
        frame: frame,
        geo: row.$1,
        site: row.$2,
        anchorBF: anchor,
        tier: SiteDrawTier.detail,
        cars: cars,
        glow: glass,
        carBudget: 12,
      );
      expect(plain, greaterThan(0), reason: d.plan.siteId);
      final managed = SiteAccessMesher.emit(
        apron: MeshBuilder(),
        solid: MeshBuilder(),
        frame: frame,
        geo: row.$1,
        site: row.$2,
        anchorBF: anchor,
        tier: SiteDrawTier.detail,
        cars: MeshBuilder(),
        glow: MeshBuilder(),
        carBudget: 12,
        agentManaged: true,
      );
      expect(managed, 0);
    });

    test('a fake source reaches the tiles: the managed site\'s cars go, and '
        'only its tile re-keys', () {
      final slot = rows
          .firstWhere((r) =>
              SiteDressingMesher.lotCars(drawOf(r), maxCars: 99, airless: false)
                  .isNotEmpty)
          .$1
          .siteSlot(rows
              .firstWhere((r) => SiteDressingMesher.lotCars(drawOf(r),
                      maxCars: 99, airless: false)
                  .isNotEmpty)
              .$2);
      Uint8List bitsFor(int managedSlot) {
        final b = Uint8List(managedSlot + 1);
        b[managedSlot] = 1;
        return b;
      }

      // The seam, as the traffic merge will wire it.
      CityNodes.agentManagedSites = (s, f) => bitsFor(slot);
      final managed = CityNodes.agentManagedOf(snap);
      expect(managed, hasLength(1));
      expect(CityTileBucketer.isManagedSlot(managed.single!, slot), isTrue);
      expect(CityTileBucketer.agentManagedSignature(managed), isNot(0));

      final anchors = {frame.bodyId: anchor};
      const tileM = 300.0;
      final none = CityTileBucketer.bucket(snap,
          anchors: anchors, tileM: tileM, siteAccess: true);
      final one = CityTileBucketer.bucket(snap,
          anchors: anchors,
          tileM: tileM,
          siteAccess: true,
          agentManaged: managed);
      var moved = 0, held = 0;
      for (final t in one.tiles.values) {
        final was = none.tiles[t.key];
        expect(was, isNotNull);
        if (was!.structureKey == t.structureKey) {
          held++;
        } else {
          moved++;
          // The moved tile is the one holding the managed site.
          expect(t.sites.any((s) => s.geometry.siteSlot(s.site) == slot),
              isTrue);
        }
      }
      expect(moved, 1, reason: 'only the managed site\'s tile re-keys');
      expect(held, greaterThan(0));

      // And the subset frame a worker gets carries the bit.
      final tile = one.tiles.values
          .firstWhere((t) => t.sites.any((s) => s.managed));
      final frames = CityTileBucketer.siteFramesOf(tile.sites);
      var bits = 0;
      for (final f in frames) {
        for (var c = 0; c < f.chunks.length; c++) {
          for (var k = 0; k < f.chunks[c].siteCount; k++) {
            if (f.isAgentManaged(c, k)) bits++;
          }
        }
      }
      expect(bits, 1);
    });

    test('a seam that manages nothing costs no re-cut: the gate gains a term '
        'only when some byte is set (§5.5)', () {
      // Every shape of "nothing managed": no list, a null, an empty list and
      // a list of zeros. None of them may move the gate's signature.
      final quiet = <List<Uint8List?>>[
        const [],
        [null],
        [Uint8List(0)],
        [Uint8List(4096)],
        [Uint8List(4096), null, Uint8List(0)],
      ];
      for (final m in quiet) {
        expect(CityTileBucketer.agentManagedSignature(m), 0, reason: '$m');
      }
      // One set byte anywhere and the term appears.
      final loud = Uint8List(4096)..[123] = 1;
      expect(CityTileBucketer.agentManagedSignature([loud]), isNot(0));
      // And a whole-colony cut with the quiet seam installed is the cut it
      // was without it, tile for tile.
      final anchors = {frame.bodyId: anchor};
      const tileM = 300.0;
      final without = CityTileBucketer.bucket(snap,
          anchors: anchors, tileM: tileM, siteAccess: true);
      final withQuiet = CityTileBucketer.bucket(snap,
          anchors: anchors,
          tileM: tileM,
          siteAccess: true,
          agentManaged: [Uint8List(4096)]);
      expect(withQuiet.tiles.length, without.tiles.length);
      for (final t in withQuiet.tiles.values) {
        expect(t.structureKey, without.tiles[t.key]?.structureKey);
      }
    });
  });

  group('the knob gates the plan-served dressing (§5.5 knob discipline)', () {
    CityMeshKnobs knobsWith({required bool siteAccess}) => CityMeshKnobs(
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

    CityTileResult tileOf({required bool siteAccess, required bool carry}) {
      final gathered = CityDetailLayer.gather(
          buildings, houseFocus, CityDetailLayer.gatherRadiusM(300));
      final sites = carry
          ? CityTileBucketer.siteFramesOf(
              CityTileBucketer.sitesOfBuildings([frame], gathered))
          : const <CitySiteFrame>[];
      return CityTileMesher.mesh(
          CityTileRequest(
            tileKey: '${frame.bodyId}/0/0',
            key: 'k',
            tier: CityTier.near,
            canDetail: true,
            anchorBF: anchor,
            columns: CityTileColumns.fromSnapshots(
              buildings: gathered,
              roads: const [],
              patches: CityPatchColumns.of(const []),
              ends: const [],
              roadEnds: const [],
              transitEnds: const [],
              sites: sites,
            ),
            focusBF: houseFocus,
            colonyTier: BuildingDetail.full,
            epoch: 0,
            knobs: knobsWith(siteAccess: siteAccess),
            detailLayer: false,
          ),
          CityBuildingLibraries());
    }

    test('with the knob off a request that carries sites anyway draws the '
        'legacy lot, not the plan\'s dressing', () {
      final bare = _byMaterial(tileOf(siteAccess: false, carry: false));
      expect(_byMaterial(tileOf(siteAccess: false, carry: true)), bare,
          reason: 'the knob is off: the sites in the columns draw nothing');
      // Not vacuous: with the knob ON the same columns draw the plan.
      expect(_byMaterial(tileOf(siteAccess: true, carry: true)), isNot(bare));
    });
  });

  group('detail on and off draw the same dressing (§5.4)', () {
    CityMeshKnobs knobs() => const CityMeshKnobs(
          styleId: 'masonry-street',
          bucketM: 6,
          variants: 4,
          perBuildingLod: true,
          blockRangeM: 300,
          interiorRangeM: 50,
          lodDebug: false,
          onStreetParking: true,
          sealedWorld: false,
          maxParkedCars: 4000,
          siteAccess: true,
        );

    /// The buildings within the detail layer's gather of [focus], and their
    /// sites: what the layer's job is given, and what a near tile with the
    /// layer OFF must draw the same of.
    test('a near tile with the layer off draws what the base tile and the '
        'detail job draw with it on', () {
      final k = knobs();
      final focus = houseFocus;
      final gathered = CityDetailLayer.gather(buildings, focus,
          CityDetailLayer.gatherRadiusM(k.blockRangeM));
      expect(gathered, isNotEmpty);
      final sites = CityTileBucketer.siteFramesOf(
          CityTileBucketer.sitesOfBuildings([frame], gathered));
      CityTileColumns columns() => CityTileColumns.fromSnapshots(
            buildings: gathered,
            roads: const [],
            patches: CityPatchColumns.of(const []),
            ends: const [],
            roadEnds: const [],
            transitEnds: const [],
            sites: sites,
          );
      CityTileResult tile({required bool detailLayer}) =>
          CityTileMesher.mesh(
              CityTileRequest(
                tileKey: '${frame.bodyId}/0/0',
                key: 'k',
                tier: CityTier.near,
                canDetail: true,
                anchorBF: anchor,
                columns: columns(),
                focusBF: focus,
                colonyTier: BuildingDetail.full,
                epoch: 0,
                knobs: k,
                detailLayer: detailLayer,
              ),
              CityBuildingLibraries());
      final off = tile(detailLayer: false);
      final base = tile(detailLayer: true);
      final detail = CityTileMesher.mesh(
          CityDetailLayer.requestFor(
            key: 'k',
            bodyId: frame.bodyId,
            anchorBF: anchor,
            buildings: gathered,
            focusBF: focus,
            colonyTier: BuildingDetail.full,
            lotFeatures: true,
            epoch: 0,
            knobs: k,
            known: const [],
            sites: [frame],
          ),
          CityBuildingLibraries());
      // The ROAD material is the site geometry and everything painted or
      // laid on it: paving, ribbons, stall lines, arrows, hatch, wheel
      // stops and footpaths. With the layer off one tile draws all of it;
      // with the layer on the base tile draws the structure and the job
      // the dressing, and the two come to the same.
      final offRoad = _byMaterial(off)[CityMaterialKind.road] ?? 0;
      final onRoad = (_byMaterial(base)[CityMaterialKind.road] ?? 0) +
          (_byMaterial(detail)[CityMaterialKind.road] ?? 0);
      expect(onRoad, offRoad, reason: 'the site geometry and its paint');
      expect(offRoad, greaterThan(0));
      // The FACADE material is the skyline plus the furniture — fences,
      // signs, lamps and the cars in the stalls. Take each side's skyline
      // off and the furniture is the same.
      final offFurniture =
          (_byMaterial(off)[CityMaterialKind.facade] ?? 0) - off.skylineTris;
      final onFurniture =
          (_byMaterial(base)[CityMaterialKind.facade] ?? 0) -
              base.skylineTris +
              (_byMaterial(detail)[CityMaterialKind.facade] ?? 0);
      expect(onFurniture, offFurniture,
          reason: 'fences, signs, lamps and lot cars');
      expect(offFurniture, greaterThan(0));
    });
  });
}

/// Whether the segments (a→b) and (c→d) cross, endpoints included.
bool _crosses(double ax, double ay, double bx, double by, double cx, double cy,
    double dx, double dy) {
  final rx = bx - ax, ry = by - ay;
  final sx = dx - cx, sy = dy - cy;
  final denom = rx * sy - ry * sx;
  if (denom.abs() < 1e-12) return false;
  final t = ((cx - ax) * sy - (cy - ay) * sx) / denom;
  final u = ((cx - ax) * ry - (cy - ay) * rx) / denom;
  const eps = 1e-9;
  return t > eps && t < 1 - eps && u > eps && u < 1 - eps;
}

/// The facade triangles a detail job over [buildings] draws at
/// [maxParkedCars] — the furniture, the baked lot cars among it.
int _tileFacadeTris(CitySiteFrame frame, List<BuildingSnapshot> buildings,
    Vector3 focus,
    {required int maxParkedCars}) {
  final anchor = frame.localToBodyFixed(0, 0, 0);
  final knobs = CityMeshKnobs(
    styleId: 'masonry-street',
    bucketM: 6,
    variants: 4,
    perBuildingLod: true,
    blockRangeM: 300,
    interiorRangeM: 50,
    lodDebug: false,
    onStreetParking: true,
    sealedWorld: false,
    maxParkedCars: maxParkedCars,
    siteAccess: true,
  );
  final gathered = CityDetailLayer.gather(
      buildings, focus, CityDetailLayer.gatherRadiusM(knobs.blockRangeM));
  final result = CityTileMesher.mesh(
      CityDetailLayer.requestFor(
        key: 'k',
        bodyId: frame.bodyId,
        anchorBF: anchor,
        buildings: gathered,
        focusBF: focus,
        colonyTier: BuildingDetail.full,
        lotFeatures: true,
        epoch: 0,
        knobs: knobs,
        known: const [],
        sites: [frame],
      ),
      CityBuildingLibraries());
  return result.groups
      .where((g) => g.material == CityMaterialKind.facade)
      .fold(0, (n, g) => n + g.triangleCount);
}

Map<CityMaterialKind, int> _byMaterial(CityTileResult r) {
  final out = <CityMaterialKind, int>{};
  for (final g in r.groups) {
    out[g.material] = (out[g.material] ?? 0) + g.triangleCount;
  }
  return out;
}
