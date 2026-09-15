// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Site access on the wire (docs/plans/site-access.md §5.2, §6.4, §8.3 R3
/// `site_capture_test`, §8.4): the book's chunks go out by reference with
/// their heights, reused frame after frame with nothing asked of the ground;
/// a kerb point stands on its road's drape and a pad point on its lot's pad;
/// every road's kerb cuts land where their joins are, flipped with a reversed
/// road; and the whole of it survives a JSON frame.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/application/snapshot/city_site_frame.dart';
import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/kerb_cuts.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_book.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

import '../traffic/traffic_fixture.dart';
import 'site_town_fixture.dart';

void main() {
  final system = siteTownSystem;
  late CitySim city;
  late WorldSnapshot first;

  WorldSnapshot capture(CitySim c) => captureSiteTown(c);

  setUpAll(() {
    city = siteTown();
    first = capture(city);
  });

  test('the book\'s chunks go out by reference, one site frame a colony', () {
    final book = city.siteAccess;
    expect(first.sites, hasLength(1));
    final f = first.sites.single;
    expect(f.colonyId, city.id);
    expect(f.sitesRev, book.sitesRev);
    expect(f.chunks.length, book.chunks.length);
    for (var c = 0; c < f.chunks.length; c++) {
      expect(identical(f.chunks[c].plan, book.chunks[c]), isTrue);
      expect(f.chunks[c].chunkIndex, c);
      // ≤ 3 retained objects a geometry: itself and two typed lists.
      expect(f.chunks[c].debugRetained, hasLength(2));
    }
    // Every built lot with a plan says so; the rest are legacy.
    var served = 0;
    for (final b in first.buildings.values) {
      if (b.colonyId != city.id) continue;
      final slot = book.slotOf(b.id);
      expect(b.siteSlot, slot, reason: b.id);
      if (b.siteSlot < 0) continue;
      served++;
      final at = f.locate(b.siteSlot)!;
      expect(at.$1.plan.siteId(at.$2), b.id);
      expect(at.$1.siteSlot(at.$2), b.siteSlot);
    }
    expect(served, greaterThan(80));
    expect(served, f.siteCount);
  });

  test('a steady frame reuses every object and asks the ground nothing', () {
    final second = capture(city);
    final q0 = WorldSnapshot.groundQueries;
    final built0 = SiteCapture.geometriesBuilt;
    final cuts0 = SiteCapture.cutTablesBuilt;
    final third = capture(city);
    expect(WorldSnapshot.groundQueries - q0, 0);
    expect(SiteCapture.geometriesBuilt, built0);
    expect(SiteCapture.cutTablesBuilt, cuts0);
    expect(identical(third.sites.single, second.sites.single), isTrue);
    final cutsOf = {for (final r in second.roads) r.id: r.kerbCuts};
    var withCuts = 0;
    for (final r in third.roads) {
      if (r.kerbCuts.isEmpty) continue;
      withCuts++;
      expect(identical(r.kerbCuts, cutsOf[r.id]), isTrue, reason: r.id);
    }
    expect(withCuts, greaterThan(2));
  });

  /// Measures [city]'s steady site capture; prints and returns the median ms.
  double steadyCost(CitySim city, String name) {
    final first = capture(city);
    capture(city);
    final drapes = [
      for (final road in city.layout.roads)
        (road.reversed, city.drapeCache[road.id]!.pts),
    ];
    double groundFor(String key, Vec2 local) => city.groundCache[key]!.radius;
    double cell(int c) => city.cellGroundRadius[c]!;
    final body = system.body(city.body.id)!;
    final q0 = WorldSnapshot.groundQueries;
    final sw = Stopwatch();
    // The fixed part: the chunk set's identity compares and the held frame.
    final samples = <int>[];
    var cuts = 0;
    for (var run = 0; run < 400; run++) {
      sw
        ..reset()
        ..start();
      final cap = SiteCapture.begin(city)!;
      cap.frame(
          bodyId: body.id.value,
          datumRadiusM: body.radius,
          siteRadiusM: body.radius,
          groundFor: groundFor,
          cellRadius: cell);
      sw.stop();
      samples.add(sw.elapsedMicroseconds);
    }
    // The per-road part: the drawn cuts each road snapshot carries.
    final cap0 = SiteCapture.begin(city)!;
    const roadRuns = 2000;
    sw
      ..reset()
      ..start();
    for (var run = 0; run < roadRuns; run++) {
      for (var i = 0; i < drapes.length; i++) {
        cuts += cap0.kerbCutsFor(i, drapes[i].$1, drapes[i].$2).length;
      }
    }
    sw.stop();
    final perRoadUs = sw.elapsedMicroseconds / (roadRuns * drapes.length);
    expect(WorldSnapshot.groundQueries - q0, 0);
    samples.sort();
    final median = samples[samples.length ~/ 2] / 1000;
    // The building side, reported apart: one book lookup a building.
    final ids = [
      for (final b in first.buildings.values)
        if (b.colonyId == city.id) b.id,
    ];
    final cap = SiteCapture.begin(city)!;
    var slots = 0;
    for (var run = 0; run < 200; run++) {
      for (final id in ids) {
        slots += cap.buildingSiteOf(id).$1;
      }
    }
    sw
      ..reset()
      ..start();
    const lookupRuns = 2000;
    for (var run = 0; run < lookupRuns; run++) {
      for (final id in ids) {
        slots += cap.buildingSiteOf(id).$1;
      }
    }
    sw.stop();
    final perBuildingUs = sw.elapsedMicroseconds / (lookupRuns * ids.length);
    // And the whole capture, steady, a building: what the lookup adds to.
    for (var run = 0; run < 5; run++) {
      capture(city);
    }
    sw
      ..reset()
      ..start();
    const captureRuns = 40;
    for (var run = 0; run < captureRuns; run++) {
      capture(city);
    }
    sw.stop();
    final captureUs = sw.elapsedMicroseconds / (captureRuns * ids.length);
    // ignore: avoid_print
    print('$name site capture, steady frame: median '
        '${median.toStringAsFixed(4)} ms '
        '(p90 ${(samples[samples.length * 9 ~/ 10] / 1000).toStringAsFixed(4)} '
        'ms) for ${first.sites.single.chunks.length} chunks, '
        '${first.sites.single.siteCount} sites; kerb cuts '
        '${perRoadUs.toStringAsFixed(4)} µs a road (${drapes.length} roads, '
        '${cuts ~/ roadRuns} doubles); '
        'building site lookup ${perBuildingUs.toStringAsFixed(4)} µs a '
        'building against a whole steady capture of '
        '${captureUs.toStringAsFixed(3)} µs a building (${ids.length} '
        'buildings; slot sum $slots)');
    // The per-building part scales with the colony and sits outside the
    // 0.02 ms (§5.2 as built): it must stay a small share of the steady
    // capture it rides in (measured ~0.3–0.8 %; R4's A/B on the reference
    // town owns the absolute number).
    expect(perBuildingUs, lessThan(captureUs * 0.05));
    return median;
  }

  test('STEADY-FRAME COST: sites and kerb cuts within 0.02 ms, no query', () {
    expect(steadyCost(city, 'site town:'), lessThanOrEqualTo(0.02));
  });

  test('STEADY-FRAME COST on a generated town', () {
    final generated = const CityGenerator().generate(
        const CityGenSpec(blocksAcross: 6, seed: 5),
        bodies: fixtureBodies);
    expect(generated.siteAccess.chunks, isNotEmpty);
    expect(steadyCost(generated, 'generated town:'), lessThanOrEqualTo(0.02));
  });

  test('a pad point stands on its lot\'s pad; a kerb point on its road\'s '
      'drape, within a centimetre', () {
    final f = first.sites.single;
    var pads = 0, kerbs = 0;
    for (final g in f.chunks) {
      final c = g.plan;
      for (var k = 0; k < c.siteCount; k++) {
        final id = c.siteId(k);
        final parcel = city.layout.parcelById(id);
        if (parcel == null) continue;
        final pad = city.groundCache['lot:$id']!.radius;
        final centroid = parcel.centroid;
        for (var p = c.ptStart(k); p < c.ptStart(k + 1); p++) {
          final r = f.datumRadiusM + g.ptUp(p) - c.ptDz(p);
          switch (c.ptHRef(p)) {
            case SiteHeightRef.pad:
              final far = math.sqrt(math.pow(c.ptE(p) - centroid.e, 2) +
                      math.pow(c.ptN(p) - centroid.n, 2)) >
                  SiteCapture.padReachM;
              if (far && !parcel.graded) continue;
              expect(r, closeTo(pad, 1e-3), reason: '$id pt $p');
              pads++;
            case SiteHeightRef.kerb:
              final j = c.ptHJoin(p);
              final road = city.roadGraph.roads[c.joinRoadNo(c.joinStart(k) + j)];
              final drape = city.drapeCache[road.id]!;
              final want = _drapeRadiusNear(drape.pts, drape.radii,
                  Vec2(c.ptE(p), c.ptN(p)));
              expect(r, closeTo(want, 0.01), reason: '$id kerb pt $p');
              kerbs++;
            case SiteHeightRef.blend:
              break;
          }
        }
      }
    }
    expect(pads, greaterThan(50));
    expect(kerbs, greaterThan(20));
  });

  test('every drawn cut lies at its join, within 0.5 m along the drawn road '
      'and on its side, a reversed road\'s flipped', () {
    final f = first.sites.single;
    final up = f.up;
    // Every cut join's kerb point, body-fixed, by road id.
    final kerbsByRoad = <String, List<Vector3>>{};
    for (final g in f.chunks) {
      final c = g.plan;
      for (var k = 0; k < c.siteCount; k++) {
        final plan = c.plan(k);
        for (var j = 0; j < plan.joinCount; j++) {
          if (!plan.joinIsCut(j)) continue;
          final node = plan.joinKerbNode(j);
          final pt = c.ptStart(k) + plan.nodePt(node);
          final road =
              city.roadGraph.roads[plan.joinRoadNo(j)];
          (kerbsByRoad[road.id] ??= []).add(
              f.localToBodyFixed(c.ptE(pt), c.ptN(pt), g.ptUp(pt)));
        }
      }
    }
    var reversedChecked = 0, checked = 0;
    for (final r in first.roads) {
      if (r.kerbCuts.isEmpty) continue;
      final road = city.layout.roadById(r.id!)!;
      final kerbs = kerbsByRoad[r.id]!;
      final pts = [
        for (var i = 0; i + 2 < r.points.length; i += 3)
          Vector3(r.points[i], r.points[i + 1], r.points[i + 2]),
      ];
      for (var e = 0; e < r.kerbCuts.length; e += KerbCuts.stride) {
        final side = r.kerbCuts[e].round();
        final c = r.kerbCuts[e + 1];
        final sigma = r.kerbCuts[e + 3];
        final kind = r.kerbCuts[e + 4].round();
        if (road.oneWay) expect(sigma, 1.0, reason: 'a one-way runs first to last');
        if (kind == KerbCuts.kindHomeFarSwing) continue;
        // The kerb point on the cut's side nearest arc c along the drawn
        // points (homes face each other across a street at the same arc).
        var best = double.infinity;
        for (final k in kerbs) {
          final (arc, right) = _projectArc(pts, k, up);
          if ((right ? 1 : 0) != side) continue;
          final d = (arc - c).abs();
          if (d < best) best = d;
        }
        expect(best, lessThanOrEqualTo(0.5), reason: '${r.id} cut at $c');
        checked++;
        if (road.reversed) reversedChecked++;
      }
    }
    expect(checked, greaterThan(20));
    expect(reversedChecked, greaterThan(4));
  });

  test('the canonical form, rescaled and flipped, and back', () {
    final canon = Float64List.fromList([
      1, 10, 4, 1, 1, //
      0, 10, 4, -1, 2, //
      0, 50, 3.5, -1, 0,
    ]);
    final drawn = KerbCuts.toDrawn(canon,
        indexLengthM: 100, drawnLengthM: 200, reversed: false);
    // Ordered by (side, c, kind); centres rescaled, half widths kept.
    expect(drawn, [0, 20, 4, -1, 2, 0, 100, 3.5, -1, 0, 1, 20, 4, 1, 1]);
    final flipped = KerbCuts.toDrawn(canon,
        indexLengthM: 100, drawnLengthM: 100, reversed: true);
    // Mirrored: c → L − c, side swapped, σ negated, ordered by (side, c, kind).
    expect(flipped, [0, 90, 4, -1, 1, 1, 50, 3.5, 1, 0, 1, 90, 4, 1, 2]);
    expect(KerbCuts.sigmaOf(false, false, 1), 1);
    expect(KerbCuts.sigmaOf(false, false, 0), -1);
    expect(KerbCuts.sigmaOf(true, true, 1), -1);
    expect(KerbCuts.sigmaOf(true, false, 0), 1);
  });

  test('the frame goes round JSON: sites, slots, gates and kerb cuts', () {
    final json = jsonDecode(jsonEncode(first.toJson())) as Map<String, dynamic>;
    final back = WorldSnapshot.fromJson(json);
    expect(back.sites, hasLength(1));
    final a = first.sites.single, b = back.sites.single;
    expect(b.colonyId, a.colonyId);
    expect(b.bodyId, a.bodyId);
    expect(b.sitesRev, a.sitesRev);
    expect(b.geometryStamp, a.geometryStamp);
    expect(b.datumRadiusM, a.datumRadiusM);
    expect([b.up.x, b.up.y, b.up.z, b.east.x, b.north.z],
        [a.up.x, a.up.y, a.up.z, a.east.x, a.north.z]);
    expect(b.chunks.length, a.chunks.length);
    for (var c = 0; c < a.chunks.length; c++) {
      final x = a.chunks[c], y = b.chunks[c];
      expect(y.chunkIndex, x.chunkIndex);
      expect(y.plan.siteIds, x.plan.siteIds);
      for (var i = 0; i < 5; i++) {
        expect(_bytes(y.plan.debugRetained[i]), _bytes(x.plan.debugRetained[i]),
            reason: 'chunk $c list $i');
      }
      for (var i = 0; i < 2; i++) {
        expect(_bytes(y.debugRetained[i]), _bytes(x.debugRetained[i]));
      }
    }
    var slots = 0;
    for (final e in first.buildings.entries) {
      final x = e.value, y = back.buildings[e.key]!;
      expect([y.siteSlot, y.gateXM, y.gateWM], [x.siteSlot, x.gateXM, x.gateWM]);
      if (x.siteSlot >= 0) slots++;
      final j = x.toJson();
      expect(j.containsKey('ss'), x.siteSlot != -1);
      expect(j.containsKey('gw'), x.gateWM != 0);
    }
    expect(slots, greaterThan(0));
    expect(first.buildings.values.any((x) => x.gateWM > 0), isTrue,
        reason: 'the installations have gates');
    for (var i = 0; i < first.roads.length; i++) {
      expect(back.roads[i].kerbCuts, orderedEquals(first.roads[i].kerbCuts));
      expect(first.roads[i].toJson().containsKey('kc'),
          first.roads[i].kerbCuts.isNotEmpty);
    }
    // Not in the fingerprint.
    expect(back.fingerprint, first.fingerprint);
    // A frame with no sites writes none.
    expect(WorldSnapshot(tick: 0, vessels: const {}).toJson().containsKey('sites'),
        isFalse);
  });

  test('after a road edit, plans not yet re-resolved keep their cuts on the '
      'roads that stayed (§4.2 step 3)', () {
    final c = siteTown();
    Map<String, List<double>> cutsOf(WorldSnapshot s) => {
          for (final r in s.roads)
            if (r.kerbCuts.isNotEmpty) r.id!: List.of(r.kerbCuts),
        };
    final before = cutsOf(capture(c));
    expect(before, isNotEmpty);
    commit(c, const FixtureRoad([Vec2(-2600, 2400), Vec2(-2000, 2400)]));
    // Captured before the book has seen the edit, and again after a budgeted
    // sync that only diffed it: every plan still names the old graph.
    final early = cutsOf(capture(c));
    c.siteAccess.sync(c, c.roadGraph, maxUnits: 1, maxChecks: 1);
    final book = c.siteAccess;
    var stale = 0;
    for (final ch in book.chunks) {
      for (var k = 0; k < ch.siteCount; k++) {
        if (ch.graphStamp(k) != c.roadGraph.structureStamp) stale++;
      }
    }
    expect(stale, greaterThan(0));
    final late = cutsOf(capture(c));
    expect(early, before);
    expect(late, before);
  });

  test('the geometry stamp moves with the cut table when the book swaps its '
      'graph under unchanged chunks', () {
    // A street of houses on a reversed one-way and nothing else: no
    // easement-priority site, so a deferred sync re-resolves no plan and
    // republishes no chunk when the graph changes.
    final c = foundFlat(id: 'one-way', roads: const [
      FixtureRoad([Vec2(0, -200), Vec2(0, 200)],
          roadClass: RoadClass.streetOneWay, reversed: true),
    ])
      ..funds = 1e12
      ..ignoreUnlocks = true;
    for (final p in List.of(c.layout.autoParcels)) {
      c.placeOnParcel(p.id, siteTownHouse);
    }
    c.advance(0.5);
    expect(
        c.siteAccess.sync(c, c.roadGraph,
            maxUnits: SiteAccessBook.unlimited,
            maxChecks: SiteAccessBook.unlimited),
        isTrue);
    final oneWay = c.layout.roads.firstWhere((r) => r.oneWay && r.reversed);
    Map<String, List<double>> cutsOf(WorldSnapshot s) => {
          for (final r in s.roads)
            if (r.kerbCuts.isNotEmpty) r.id!: List.of(r.kerbCuts),
        };
    capture(c);
    // Reversed: the capture sees the new roads revision before the book
    // has synced the new graph, then again once it has (every chunk kept).
    expect(c.reverseRoad(oneWay.id), isTrue);
    final seen = capture(c);
    final chunks = List.of(c.siteAccess.chunks);
    final cuts0 = SiteCapture.cutTablesBuilt;
    final stampBefore = c.siteAccess.graph!.structureStamp;
    c.siteAccess.sync(c, c.roadGraph, maxUnits: 1, maxChecks: 1);
    expect(c.roadGraph.structureStamp, isNot(stampBefore));
    expect(c.siteAccess.graph!.structureStamp, c.roadGraph.structureStamp);
    final kept = c.siteAccess.chunks;
    expect(kept.length, chunks.length);
    for (var i = 0; i < kept.length; i++) {
      expect(identical(kept[i], chunks[i]), isTrue,
          reason: 'the deferred sync republishes nothing');
    }
    final swapped = capture(c);
    expect(SiteCapture.cutTablesBuilt, greaterThan(cuts0));
    expect(cutsOf(swapped)[oneWay.id], isNot(cutsOf(seen)[oneWay.id]),
        reason: 'the reversed one-way\'s cut directions flipped');
    expect(swapped.sites.single.sitesRev, seen.sites.single.sitesRev);
    expect(swapped.sites.single.geometryStamp,
        isNot(seen.sites.single.geometryStamp));
  });

  test('a building whose slot row no longer matches the held chunks is '
      'legacy until the next begin', () {
    final c = siteTown();
    capture(c);
    final book = c.siteAccess;
    final chunk = book.chunks.first;
    // Two lots in consecutive rows of the first chunk.
    var row = -1;
    for (var k = 0; k + 1 < chunk.siteCount; k++) {
      if (c.parcelBuildings.containsKey(chunk.siteId(k)) &&
          c.parcelBuildings.containsKey(chunk.siteId(k + 1))) {
        row = k;
        break;
      }
    }
    expect(row, greaterThanOrEqualTo(0));
    final gone = chunk.siteId(row), next = chunk.siteId(row + 1);
    final cap = SiteCapture.begin(c)!;
    expect(cap.buildingSiteOf(next).$1, book.slotOf(next));
    // The book drops a row (its chunk re-packs) while the capture still
    // holds the old chunks: `next`'s row now names another site there.
    c.clearParcel(gone);
    expect(book.slotOf(next), greaterThanOrEqualTo(0));
    expect(book.rowOfSlot(book.slotOf(next)), row);
    expect(cap.buildingSiteOf(next), (-1, 0.0, 0.0));
    // A fresh begin reads the re-packed chunk and serves it again.
    final again = SiteCapture.begin(c)!;
    expect(again.buildingSiteOf(next).$1, book.slotOf(next));
  });

  test('the geometry stamp holds on a frame that changed no plan, and moves '
      'with one', () {
    final c = siteTown();
    final a = capture(c).sites.single;
    c.advance(0.5);
    final b = capture(c).sites.single;
    expect(b.geometryStamp, a.geometryStamp);
    expect(b.sitesRev, a.sitesRev);
    // One house demolished: its plan goes.
    final lot = c.parcelBuildings.keys
        .firstWhere((id) => c.siteAccess.slotOf(id) >= 0 && id.startsWith('lot-r'));
    c.clearParcel(lot);
    c.advance(0.5);
    expect(c.siteAccess.slotOf(lot), -1);
    final d = capture(c).sites.single;
    expect(d.sitesRev, isNot(a.sitesRev));
    expect(d.geometryStamp, isNot(a.geometryStamp));
  });
}

List<int> _bytes(Object list) => switch (list) {
      Float64List l => l.buffer.asUint8List(l.offsetInBytes, l.lengthInBytes),
      Float32List l => l.buffer.asUint8List(l.offsetInBytes, l.lengthInBytes),
      Int32List l => l.buffer.asUint8List(l.offsetInBytes, l.lengthInBytes),
      Uint8List l => l,
      _ => throw ArgumentError('$list'),
    };

/// The drape radius at the drape point nearest [p]'s projection.
double _drapeRadiusNear(List<Vec2> pts, Float64List radii, Vec2 p) {
  var best = double.infinity, bestR = radii.first;
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i];
    final ab = b - a;
    final l2 = ab.e * ab.e + ab.n * ab.n;
    final t = l2 == 0
        ? 0.0
        : (((p.e - a.e) * ab.e + (p.n - a.n) * ab.n) / l2).clamp(0.0, 1.0);
    final q = Vec2(a.e + ab.e * t, a.n + ab.n * t);
    final d = q.distanceTo(p);
    if (d < best) {
      best = d;
      bestR = radii[i - 1] + (radii[i] - radii[i - 1]) * t;
    }
  }
  return bestR;
}

/// [k]'s arc along the polyline [pts] at its nearest point, and whether it
/// lies right of the first → last direction there ([up] outward).
(double, bool) _projectArc(List<Vector3> pts, Vector3 k, Vector3 up) {
  var best = double.infinity;
  var bestArc = 0.0;
  var right = false;
  var at = 0.0;
  for (var i = 1; i < pts.length; i++) {
    final a = pts[i - 1], b = pts[i];
    final ab = b - a;
    final len = ab.length;
    final t = len == 0 ? 0.0 : ((k - a).dot(ab) / (len * len)).clamp(0.0, 1.0);
    final q = a + ab * t;
    final d = (k - q).length;
    if (d < best) {
      best = d;
      bestArc = at + len * t;
      right = ab.cross(k - q).dot(up) < 0;
    }
    at += len;
  }
  return (bestArc, right);
}
