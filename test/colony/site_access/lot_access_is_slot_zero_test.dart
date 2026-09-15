// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/city_generator.dart';
import 'package:acro_space_simulator/domain/colony/city/city_layout.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/hash32.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_join.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../traffic/traffic_fixture.dart';

/// Acceptance test A3 (docs/plans/site-access.md §7.9, slice R1): a lot's
/// access IS its join slot 0.
///
/// `lotPiece / lotS / lotDirs` equal slot 0's columns on every lot, `accessOf`
/// reports it, the starter kit's four utility sites get exactly the §3.2
/// table, the sprawl has exactly as many lots without access as before the
/// slots, and the layouts the slots are placed over are byte for byte what
/// they were.
void main() {
  late CitySim starter;
  late CitySim core;
  late CitySim sprawl;
  setUpAll(() {
    starter = starterKit();
    core = const CityGenerator()
        .generate(const CityGenSpec(blocksAcross: 4, seed: 5),
            bodies: fixtureBodies);
    sprawl = const CityGenerator().generate(
        const CityGenSpec(blocksAcross: 4, seed: 5, sprawlMiles: 12),
        bodies: fixtureBodies);
  });

  void expectSlotZero(RoadGraph g, String name) {
    expect(g.lotJoinStart, hasLength(g.lotCount + 1));
    expect(g.lotJoinStart.last, g.joinCount);
    expect(g.joinCrossStart, hasLength(g.joinCount + 1));
    for (var i = 0; i < g.lotCount; i++) {
      final k = g.lotJoinStart[i], n = g.lotJoinStart[i + 1] - k;
      final why = '$name ${g.lotIds[i]}';
      expect(n, inInclusiveRange(0, kMaxJoinSlots), reason: why);
      final access = g.accessOf(g.lotIds[i]);
      if (n == 0) {
        expect(g.lotPiece[i], -1, reason: why);
        expect(g.lotS[i], 0, reason: why);
        expect(g.lotDirs[i], 0, reason: why);
        expect(access, isNull, reason: why);
        continue;
      }
      expect(g.lotPiece[i], g.joinPiece[k], reason: why);
      expect(g.lotS[i], g.joinS[k], reason: why);
      expect(g.lotDirs[i], g.joinDirs[k], reason: why);
      expect(access, isNotNull, reason: why);
      expect(access!.roadId, g.roads[g.pieceRoad[g.joinPiece[k]]].id,
          reason: why);
      expect(access.sM, g.joinS[k], reason: why);
      expect(access.forward, g.joinDirs[k] & RoadGraph.forwardBit != 0,
          reason: why);
      expect(access.backward, g.joinDirs[k] & RoadGraph.backwardBit != 0,
          reason: why);
      for (var j = k; j < k + n; j++) {
        final road = g.roads[g.pieceRoad[g.joinPiece[j]]];
        // V2: the directions follow the side, and the side the geometry.
        expect(g.joinDirs[j], joinDirsFor(road, g.joinRight[j] == 1),
            reason: why);
        expect(g.joinS[j], inInclusiveRange(g.pieceS0[g.joinPiece[j]] - 1e-9,
            g.pieceS1[g.joinPiece[j]] + 1e-9), reason: why);
        final f = g.joinFlags[j];
        expect(f & kJoinCut != 0, f & kJoinLegacy == 0, reason: why);
        if (f & kJoinCut != 0) {
          expect((g.joinS[j] / kJoinQuantumM).roundToDouble() * kJoinQuantumM,
              g.joinS[j], reason: '$why: on the quantum');
          expect(g.joinRoomM[j], greaterThanOrEqualTo(kJoinMinRoomM - 1e-4),
              reason: why);
        } else {
          expect(g.joinRoomM[j], 0, reason: why);
          expect(j, k, reason: '$why: a legacy slot is alone');
        }
        final cross = g.joinCrossStart[j + 1] - g.joinCrossStart[j];
        expect(f & kJoinEasement != 0, cross > 0, reason: why);
      }
    }
  }

  test('lotPiece / lotS / lotDirs are slot 0, and accessOf reports it', () {
    expectSlotZero(starter.roadGraph, 'starter');
    expectSlotZero(core.roadGraph, 'core');
    expectSlotZero(grid(3).roadGraph, 'grid');
    expectSlotZero(sprawl.roadGraph, 'sprawl');
  });

  test('the starter kit\'s utility sites: the §3.2 table exactly', () {
    final g = starter.roadGraph;
    final layout = starter.layout;
    // (site parcel corner, road, slot 0 arc, kerb e, n, right, easement lot)
    final table = [
      ('spaceport', const Vec2(60, 60), 'r0x1', 264.0, 4.0, 264.0, true,
          'lot-r0x1-l10'),
      ('solar farm', const Vec2(60, -60), 'r0x0', 24.0, 4.0, -276.0, true,
          'lot-r0x0-l0'),
      ('farm', const Vec2(-60, -60), 'r0x0', 48.0, -4.0, -252.0, false,
          'lot-r0x0-r1'),
      ('pump', const Vec2(-60, 60), 'r0x1', 144.0, -4.0, 144.0, false,
          'lot-r0x1-r5'),
    ];
    final easements = <String>{};
    for (final (name, corner, road, s, ke, kn, right, lot) in table) {
      final site = layout.manualParcels
          .singleWhere((p) => p.polygon.any((v) => v.distanceTo(corner) < 1e-9));
      final i = g.lotNoOf(site.id)!;
      final k = g.lotJoinStart[i];
      expect(g.roads[g.pieceRoad[g.joinPiece[k]]].id, road, reason: name);
      expect(g.joinS[k], s, reason: name);
      expect(g.lotS[i], s, reason: name);
      expect(g.joinKerbE[k], closeTo(ke, 1e-9), reason: name);
      expect(g.joinKerbN[k], closeTo(kn, 1e-9), reason: name);
      expect(g.joinRight[k] == 1, right, reason: name);
      expect(g.joinDirs[k], RoadGraph.forwardBit | RoadGraph.backwardBit,
          reason: '$name: both directions on a two-lane street');
      expect(g.joinFlags[k], kJoinCut | kJoinClamped | kJoinEasement,
          reason: name);
      expect(g.joinRoomM[k], greaterThanOrEqualTo(kWideCutHalfM), reason: name);
      final crossed = [
        for (var c = g.joinCrossStart[k]; c < g.joinCrossStart[k + 1]; c++)
          g.lotIds[g.joinCrossLot[c]]
      ];
      expect(crossed, [lot], reason: name);
      easements.add(lot);
    }
    expect(easements,
        {'lot-r0x1-l10', 'lot-r0x0-l0', 'lot-r0x0-r1', 'lot-r0x1-r5'});
  });

  test('the sprawl has exactly the lots without access it had', () {
    final g = sprawl.roadGraph;
    var without = 0;
    for (var i = 0; i < g.lotCount; i++) {
      if (g.lotPiece[i] < 0) without++;
    }
    // Before the join slots: 2 of 54,257 (sprawl_topology_audit_test).
    expect(g.lotCount, 54257);
    expect(without, 2);
  });

  test('sprawl audit: slot 0 by flag, and the slots offered', () {
    final g = sprawl.roadGraph;
    final counts = <String, int>{
      'lots': g.lotCount,
      'slots': g.joinCount,
      'legacy': 0,
      'cut': 0,
      'clamped': 0,
      'sideStreet': 0,
      'offFrontage': 0,
      'easement': 0,
      'corridorBlocked': 0,
      'slot1': 0,
      'slot2': 0,
    };
    void bump(String k) => counts[k] = counts[k]! + 1;
    for (var i = 0; i < g.lotCount; i++) {
      final k = g.lotJoinStart[i], end = g.lotJoinStart[i + 1];
      if (k == end) continue;
      final f = g.joinFlags[k];
      if (f & kJoinLegacy != 0) bump('legacy');
      if (f & kJoinCut != 0) bump('cut');
      if (f & kJoinClamped != 0) bump('clamped');
      if (f & kJoinSideStreet != 0) bump('sideStreet');
      if (f & kJoinOffFrontage != 0) bump('offFrontage');
      if (f & kJoinEasement != 0) bump('easement');
      if (f & kJoinCorridorBlocked != 0) bump('corridorBlocked');
      for (var j = k + 1; j < end; j++) {
        bump(g.joinFlags[j] & kJoinSideStreet != 0 ? 'slot2' : 'slot1');
      }
    }
    // ignore: avoid_print
    print('sprawl join slots (site-access R1 audit): $counts');
    expect(counts, _sprawlAudit);
  });

  test('a footprint\'s access is slot 0 of its footprint\'s slots', () {
    // Every lot of the core, taken as a footprint off the plat (a grid
    // building's: no frontage), and a few far from any road.
    final g = core.roadGraph;
    var attached = 0, cuts = 0;
    final footprints = [
      for (final p in core.layout.parcels) p.polygon,
      const [Vec2(5e4, 5e4), Vec2(5e4 + 20, 5e4), Vec2(5e4 + 20, 5e4 + 20)],
    ];
    for (final poly in footprints) {
      final slots = g.attachFootprintJoins(poly);
      final a = g.attachFootprint(poly);
      if (slots.isEmpty) {
        expect(a, isNull);
        continue;
      }
      attached++;
      if (slots.first.flags & kJoinCut != 0) cuts++;
      expect(a!.piece, slots.first.piece);
      expect(a.sM, slots.first.s);
      expect(a.dirs, slots.first.dirs);
      expect(slots.first.dirs,
          joinDirsFor(g.roads[g.pieceRoad[slots.first.piece]], slots.first.right));
    }
    expect(attached, greaterThan(100));
    expect(cuts, greaterThan(attached ~/ 2));
    expect(attached, lessThan(footprints.length), reason: 'the far one');
  });

  test('the layouts are byte for byte what they were before the slots', () {
    // Pinned before slice R1 changed anything: the slots are derived from
    // the plat and never re-cut it.
    expect(_layoutDigest(starter.layout), _starterDigest);
    expect(_layoutDigest(core.layout), _coreDigest);
    expect(_layoutDigest(sprawl.layout), _sprawlDigest);
  });
}

/// The 12-mile sprawl's slot counts, pinned (§8.3 R1 sprawl audit).
const Map<String, int> _sprawlAudit = {
  'lots': 54257,
  'slots': 72038,
  'legacy': 48,
  'cut': 54207,
  'clamped': 268,
  'sideStreet': 53,
  'offFrontage': 63,
  'easement': 5,
  'corridorBlocked': 62,
  'slot1': 550,
  'slot2': 17233,
};

const int _starterDigest = 0x18c52794;
const int _coreDigest = 0xc088e21a;
const int _sprawlDigest = 0xd0f00ee0;

/// FNV-1a over every lot's id, flags and exact coordinates, and every road's
/// id, class and exact samples.
int _layoutDigest(CityLayout layout) {
  final bytes = ByteData(8);
  var h = kFnvOffset32;
  void f64(double x) {
    bytes.setFloat64(0, x, Endian.little);
    h = fnv1aU32(h, bytes.getUint32(0, Endian.little));
    h = fnv1aU32(h, bytes.getUint32(4, Endian.little));
  }

  void str(String s) => h = fnv1aU32(h, fnv1a32(s));
  final parcels = layout.parcels;
  h = fnv1aU32(h, parcels.length);
  for (final p in parcels) {
    str(p.id);
    str(p.roadId ?? '-');
    h = fnv1aU32(h, (p.manual ? 1 : 0) | (p.graded ? 2 : 0) | p.use.index << 2);
    h = fnv1aU32(h, p.polygon.length);
    for (final v in p.polygon) {
      f64(v.e);
      f64(v.n);
    }
    for (final e in [p.frontage, p.sideStreet]) {
      if (e == null) {
        h = fnv1aU32(h, 0);
        continue;
      }
      f64(e.$1.e);
      f64(e.$1.n);
      f64(e.$2.e);
      f64(e.$2.n);
    }
  }
  for (final (_, rec) in layout.roadIndex.indexed) {
    str(rec.road.id);
    h = fnv1aU32(h, rec.road.roadClass.index);
    h = fnv1aU32(h, rec.sampleCount);
    for (var i = 0; i < rec.sampleCount; i++) {
      f64(rec.e[i]);
      f64(rec.n[i]);
    }
  }
  return h;
}
