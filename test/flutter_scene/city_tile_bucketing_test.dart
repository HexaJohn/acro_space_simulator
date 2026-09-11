// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/sprawl_plan.dart'
    show kMileM;
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_bucketing.dart';
import 'package:flutter_test/flutter_test.dart';

/// The cut is incremental: a tile whose structure key held is kept as
/// built, nodes and all. So the key must move for every change the tile's
/// build can see — a road's class, flags, widths, lifts, decoration, point
/// order, the ends of other tiles' roads that fall in it, the end-table
/// entries its roads read, its junction overrides — and for nothing else,
/// or one road drawn re-meshes the colony.
void main() {
  const radius = 1737.4e3; // the Moon
  final anchor = Vector3(radius, 0, 0);
  final basis = ColonyTangentBasis.at(anchor);
  const tileM = 2 * kMileM;

  /// A point [e] metres east and [n] north of the anchor, on the surface.
  Vector3 at(double e, double n) {
    final v = basis.up +
        basis.east * math.tan(e / radius) +
        basis.north * math.tan(n / radius);
    return v.normalized * radius;
  }

  List<double> flat(List<(double, double)> pts) {
    final out = Float64List(pts.length * 3);
    for (var i = 0; i < pts.length; i++) {
      final p = at(pts[i].$1, pts[i].$2);
      out[3 * i] = p.x;
      out[3 * i + 1] = p.y;
      out[3 * i + 2] = p.z;
    }
    return out;
  }

  RoadSnapshot road(
    List<(double, double)> pts, {
    RoadClass cls = RoadClass.street,
    double? halfWidthM,
    List<double> lifts = const [],
    List<double> bridges = const [],
    int decoration = 0,
    bool soundWalls = false,
    bool collector = false,
    double? startHalfWidthM,
    String? id,
  }) =>
      RoadSnapshot(
        colonyId: 'c',
        body: 'moon',
        points: flat(pts),
        halfWidthM: halfWidthM ?? cls.halfWidth,
        roadClassIndex: cls.index,
        lifts: lifts,
        bridges: bridges,
        decoration: decoration,
        soundWalls: soundWalls,
        collector: collector,
        startHalfWidthM: startHalfWidthM,
        id: id,
      );

  CityPatchSnapshot patch(double e, double n, int kind) {
    final p = at(e, n);
    return CityPatchSnapshot(
      colonyId: 'c',
      body: 'moon',
      px: p.x,
      py: p.y,
      pz: p.z,
      qw: 1,
      qx: 0,
      qy: 0,
      qz: 0,
      sizeM: 24,
      kind: kind,
    );
  }

  BuildingSnapshot building(double e, double n, String type) {
    final p = at(e, n);
    return BuildingSnapshot(
      id: 'b1',
      type: type,
      colonyId: 'c',
      body: 'moon',
      px: p.x,
      py: p.y,
      pz: p.z,
      qw: 1,
      qx: 0,
      qy: 0,
      qz: 0,
      lat: 0,
      lon: 0,
    );
  }

  JunctionSnapshot junction(double e, double n, {int lights = -1}) {
    final p = at(e, n);
    return JunctionSnapshot(
        colonyId: 'c', body: 'moon', px: p.x, py: p.y, pz: p.z, lights: lights);
  }

  WorldSnapshot frame(
    List<RoadSnapshot> roads, {
    List<BuildingSnapshot> buildings = const [],
    List<CityPatchSnapshot> patches = const [],
    List<JunctionSnapshot> junctions = const [],
    Map<String, int> roadsRevision = const {},
  }) =>
      WorldSnapshot(
        tick: 0,
        vessels: const {},
        roads: roads,
        buildings: {for (final b in buildings) b.id: b},
        patches: CityPatchColumns.of(patches),
        junctions: junctions,
        roadsRevision: roadsRevision,
      );

  CityBucketPlan cut(WorldSnapshot s) =>
      CityTileBucketer.bucket(s, anchors: {'moon': anchor}, tileM: tileM);

  Map<String, String> keys(CityBucketPlan p) =>
      {for (final t in p.tiles.values) t.key: t.structureKey};

  String tileOf(double e, double n) {
    final (ie, iN) = basis.cellOf(at(e, n), tileM);
    return 'moon/$ie/$iN';
  }

  // Three roads, each wholly inside a tile of its own.
  final a = road([(1000, 1600), (1600, 1600), (2200, 1600)], id: 'a');
  final b = road([(7000, 1600), (7600, 1600), (8200, 1600)], id: 'b');
  final c = road([(1000, 7600), (1600, 7600), (2200, 7600)], id: 'c');
  final tileA = tileOf(1600, 1600);
  final tileB = tileOf(7600, 1600);
  final tileC = tileOf(1600, 7600);

  test('the three roads are in three tiles', () {
    expect({tileA, tileB, tileC}, hasLength(3));
    expect(cut(frame([a, b, c])).tiles.keys.toSet(), {tileA, tileB, tileC});
  });

  test('two cuts of the same content key every tile the same', () {
    final first = cut(frame([a, b, c]));
    // A fresh frame: new lists, new snapshot objects, the same content —
    // what the flight view captures every frame.
    final again = cut(frame([
      road([(1000, 1600), (1600, 1600), (2200, 1600)], id: 'a'),
      road([(7000, 1600), (7600, 1600), (8200, 1600)], id: 'b'),
      road([(1000, 7600), (1600, 7600), (2200, 7600)], id: 'c'),
    ]));
    final d = CityTileBucketer.diff(keys(first), again);
    expect(d.kept.toSet(), {tileA, tileB, tileC});
    expect(d.rekeyed, isEmpty);
    expect(d.added, isEmpty);
    expect(d.removed, isEmpty);
  });

  test('an upgraded road re-keys its own tile and nothing else', () {
    final before = keys(cut(frame([a, b, c])));
    final upgraded = road([(7000, 1600), (7600, 1600), (8200, 1600)],
        cls: RoadClass.avenue, id: 'b');
    final d = CityTileBucketer.diff(before, cut(frame([a, upgraded, c])));
    expect(d.rekeyed, [tileB]);
    expect(d.kept.toSet(), {tileA, tileC});
    expect(d.added, isEmpty);
    expect(d.removed, isEmpty);
  });

  test('every attribute a tile draws moves its key; the road id does not', () {
    final before = keys(cut(frame([a, b, c])));
    const pts = [(7000.0, 1600.0), (7600.0, 1600.0), (8200.0, 1600.0)];
    final variants = <String, RoadSnapshot>{
      'class': road(pts, cls: RoadClass.avenue),
      'width': road(pts, halfWidthM: 5),
      'decoration': road(pts, decoration: RoadDecoration.trees.index),
      'lifts': road(pts, lifts: const [0, 6, 0]),
      'bridges': road(pts, bridges: const [100, 300]),
      'sound walls': road(pts, soundWalls: true),
      'collector': road(pts, collector: true),
      'taper': road(pts, startHalfWidthM: 3),
      'point order': road(pts.reversed.toList()),
      'a point moved a centimetre': road(
          [(7000, 1600), (7600.01, 1600), (8200, 1600)]),
    };
    variants.forEach((what, v) {
      final d = CityTileBucketer.diff(before, cut(frame([a, v, c])));
      expect(d.rekeyed, [tileB], reason: what);
      expect(d.kept.toSet(), {tileA, tileC}, reason: what);
    });
    // The id is the road tool's handle on a road, not something drawn.
    final renamed = road(pts, id: 'b-renamed');
    expect(CityTileBucketer.diff(before, cut(frame([a, renamed, c]))).kept,
        hasLength(3));
  });

  test('a neighbour-owned end and a road meeting end to end re-key theirs',
      () {
    // D belongs to the first tile (its middle point is there) but ends in
    // the next one east, where E starts and runs north into a third.
    final d = road([(2000, 1600), (3000, 1600), (3400, 1600)]);
    final e = road([
      (3400, 1600),
      (3400, 2600),
      (3400, 3600),
      (3400, 4600),
      (3400, 5600),
    ]);
    final owner = tileOf(3000, 1600);
    final endTile = tileOf(3400, 1600);
    final eTile = tileOf(3400, 3600);
    expect({owner, endTile, eTile, tileC}, hasLength(4));
    final before = keys(cut(frame([d, e, c])));

    final wider = road([(2000, 1600), (3000, 1600), (3400, 1600)],
        cls: RoadClass.avenue);
    final diff = CityTileBucketer.diff(before, cut(frame([wider, e, c])));
    // The owner holds D; the next tile holds D's end (its class and width
    // ride the end record); E's own tile holds nothing of D, but E reads
    // the end table's widest carriageway where it meets D — a sidewalk's
    // pull-back — and that moved.
    expect(diff.rekeyed.toSet(), {owner, endTile, eTile});
    expect(diff.kept, [tileC]);
  });

  test('a lot zoned or built re-keys nothing; a road cell moved re-keys',
      () {
    final lot = patch(1500, 1500,
        CityPatchSnapshot.packKind(CityPatchSnapshot.kindResidential,
            built: false, lot: true));
    final cell = patch(1700, 1500, CityPatchSnapshot.kindRoad);
    final before = keys(cut(frame([a, b, c], patches: [lot, cell])));

    final zoned = patch(1500, 1500,
        CityPatchSnapshot.packKind(CityPatchSnapshot.kindCommercial,
            built: true, lot: true));
    expect(
        CityTileBucketer.diff(
                before, cut(frame([a, b, c], patches: [zoned, cell])))
            .kept,
        hasLength(3),
        reason: 'the zoning node paints lots; the tiles never draw them');

    final moved = patch(1710, 1500, CityPatchSnapshot.kindRoad);
    expect(
        CityTileBucketer.diff(
                before, cut(frame([a, b, c], patches: [lot, moved])))
            .rekeyed,
        [tileA]);
  });

  test('a building grown in place re-keys its tile', () {
    // A lot's building keeps its id as it grows: an id-only key never
    // saw it.
    final before =
        keys(cut(frame([a, b, c], buildings: [building(1500, 1500, 'r-low')])));
    final d = CityTileBucketer.diff(before,
        cut(frame([a, b, c], buildings: [building(1500, 1500, 'r-med')])));
    expect(d.rekeyed, [tileA]);
    expect(d.kept.toSet(), {tileB, tileC});
  });

  test('a road removed drops only its tile; one added adds only its own', () {
    final before = keys(cut(frame([a, b, c])));
    final less = CityTileBucketer.diff(before, cut(frame([a, c])));
    expect(less.removed, [tileB]);
    expect(less.kept.toSet(), {tileA, tileC});
    expect(less.rekeyed, isEmpty);

    final h = road([(14000, 1600), (14600, 1600), (15200, 1600)]);
    final more = CityTileBucketer.diff(before, cut(frame([a, b, c, h])));
    expect(more.added, [tileOf(14600, 1600)]);
    expect(more.kept.toSet(), {tileA, tileB, tileC});
    expect(more.rekeyed, isEmpty);
  });

  group('an overpass end is tabled apart from the crossing under it', () {
    final p = at(1600, 1600);

    test('the lift term: zero at grade, otherwise never zero', () {
      expect(CityTileBucketer.liftTermOf(0), 0);
      expect(CityTileBucketer.liftTermOf(1.9), 0);
      expect(CityTileBucketer.liftTermOf(-1.9), 0);
      expect(CityTileBucketer.liftTermOf(2.1), isNot(0));
      expect(CityTileBucketer.liftTermOf(-2.1), isNot(0));
      expect(CityTileBucketer.liftTermOf(6), 3);
      expect(CityTileBucketer.liftTermOf(-6), -3);
    });

    test('keys fuse at grade and at one deck height, not across heights',
        () {
      int key(double lift) => CityTileBucketer.endKeyOf(p.x, p.y, p.z, lift);
      // A deck end at grade meets the ground roads there.
      expect(key(1.5), key(0));
      // Two decks at the same height meet each other.
      expect(key(6.4), key(6));
      // The tool's steps — 3, 6, 12 m — never fall on the ground's key.
      for (final lift in [3.0, 6.0, 12.0, -6.0, -12.0]) {
        expect(key(lift), isNot(key(0)), reason: '$lift m');
      }
      expect(key(12), isNot(key(6)));
    });

    test('a raised road ending over a street is its own end entry', () {
      final street = road([(1000, 1600), (1300, 1600), (1600, 1600)]);
      final raised = road([(1600, 1600), (1900, 1600), (2200, 1600)],
          lifts: const [12, 12, 12]);
      final flatOne = road([(1600, 1600), (1900, 1600), (2200, 1600)]);
      final table = cut(frame([street, raised])).endHalf['moon']!;
      expect(table[CityTileBucketer.endKeyOf(p.x, p.y, p.z, 0)], (4.0, 1));
      expect(table[CityTileBucketer.endKeyOf(p.x, p.y, p.z, 12)], (4.0, 1));
      // On the ground the two ends are one meeting of two.
      final fused = cut(frame([street, flatOne])).endHalf['moon']!;
      expect(fused[CityTileBucketer.endKeyOf(p.x, p.y, p.z, 0)], (4.0, 2));
    });

    test('ends carry which is the start of travel, and their deck lift', () {
      final raised = road([(1600, 1600), (1900, 1600), (2200, 1600)],
          lifts: const [6, 9, 12]);
      final ends = cut(frame([raised])).tiles[tileA]!.ends;
      expect(ends, hasLength(2));
      final first = ends.firstWhere((e) => e.isStart);
      final last = ends.firstWhere((e) => !e.isStart);
      expect(first.liftM, 6);
      expect(last.liftM, 12);
      expect(first.at, at(1600, 1600));
      expect(last.at, at(2200, 1600));
    });
  });

  group('junction overrides', () {
    // Two tiles either side of the east edge at 3218.688 m.
    final west = road([(2400, 1600), (2800, 1600), (3200, 1600)]);
    final east = road([(3240, 1600), (3800, 1600), (4400, 1600)]);
    final westTile = tileOf(2800, 1600);
    final eastTile = tileOf(3800, 1600);

    test('go to the tile they lie in, and across an edge they are near', () {
      expect(westTile, isNot(eastTile));
      final plan = cut(frame([west, east], junctions: [
        junction(2600, 1600, lights: 1),
        junction(3210, 1600, lights: 0), // 8.7 m short of the edge
        junction(20000, 20000), // over bare ground: no tile of its own
      ]));
      expect(plan.tiles[westTile]!.junctions.map((j) => j.lights), [1, 0]);
      expect(plan.tiles[eastTile]!.junctions.map((j) => j.lights), [0]);
      expect(plan.tiles.keys.toSet(), {westTile, eastTile});
    });

    test('an override switched re-keys the tiles that hold it', () {
      final before = keys(cut(frame([west, east], junctions: [
        junction(2600, 1600, lights: 1),
      ])));
      final d = CityTileBucketer.diff(
          before,
          cut(frame([west, east], junctions: [
            junction(2600, 1600, lights: 0),
          ])));
      expect(d.rekeyed, [westTile]);
      expect(d.kept, [eastTile]);
    });
  });

  test('the roads signature moves with a revision or an override only', () {
    int sig(WorldSnapshot s) => CityTileBucketer.roadsSignature(s);
    final base = frame([a], roadsRevision: {'c': 3});
    // A fresh frame of the same content: the same signature.
    expect(sig(frame([a, b], roadsRevision: {'c': 3})), sig(base));
    expect(sig(frame([a], roadsRevision: {'c': 4})), isNot(sig(base)));
    final withLight =
        frame([a], roadsRevision: {'c': 3}, junctions: [junction(0, 0)]);
    expect(sig(withLight), isNot(sig(base)));
    expect(
        sig(frame([a],
            roadsRevision: {'c': 3}, junctions: [junction(0, 0, lights: 1)])),
        isNot(sig(withLight)));
  });

  test('a new body is anchored by the cut; a held anchor is kept', () {
    final fresh = CityTileBucketer.bucket(frame([a, b]),
        anchors: const {}, tileM: tileM);
    // No buildings, no patches: the middle of the first road.
    expect(fresh.anchors['moon'], at(1600, 1600));
    expect(cut(frame([a, b])).anchors['moon'], anchor);
  });

  test('a cut of a big colony costs a bounded time (printed for the record)',
      () {
    // Five thousand roads of forty points and ten thousand buildings: a
    // quarter of the generated twenty-mile city's roads. Printed so a run
    // shows what a structural change costs the UI thread; bounded loosely,
    // as a JIT test run on a busy machine is no benchmark.
    final roads = <RoadSnapshot>[];
    for (var i = 0; i < 5000; i++) {
      final e0 = (i % 70) * 400.0, n0 = (i ~/ 70) * 400.0;
      roads.add(road([
        for (var k = 0; k < 40; k++) (e0 + k * 9.0, n0),
      ]));
    }
    final buildings = <BuildingSnapshot>[];
    for (var i = 0; i < 10000; i++) {
      final p = at((i % 100) * 250.0, (i ~/ 100) * 250.0 + 30);
      buildings.add(BuildingSnapshot(
        id: 'b$i',
        type: 'r-low',
        colonyId: 'c',
        body: 'moon',
        px: p.x,
        py: p.y,
        pz: p.z,
        qw: 1,
        qx: 0,
        qy: 0,
        qz: 0,
        lat: 0,
        lon: 0,
      ));
    }
    final big = frame(roads, buildings: buildings);
    cut(big); // warm the JIT
    final sw = Stopwatch()..start();
    final plan = cut(big);
    final ms = sw.elapsedMicroseconds / 1000;
    // ignore: avoid_print
    print('city cut: 5000 roads x 40 points + 10000 buildings -> '
        '${plan.tiles.length} tiles in ${ms.toStringAsFixed(1)} ms');
    expect(ms, lessThan(5000));
  });
}
