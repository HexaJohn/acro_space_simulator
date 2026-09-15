// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/hash32.dart' show fnv1a32;
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/sprawl_plan.dart'
    show kMileM;
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_bucketing.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_columns.dart';
import 'package:flutter_test/flutter_test.dart';

import '../application/site_town_fixture.dart';

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

    int key([double? deck]) => CityTileBucketer.endKeyOf(p.x, p.y, p.z, deck);
    (double, int)? entry(CityBucketPlan plan, [double? deck]) =>
        plan.endHalf['moon']![key(deck)];

    test('the roads on the ground share a key; each deck end has its own',
        () {
      // A deck laid flush is still a deck.
      expect(key(0), isNot(key()));
      // The tool's steps — 3, 6, 12 m — never fall on the ground's key.
      for (final lift in [3.0, 6.0, 12.0, -6.0, -12.0]) {
        expect(key(lift), isNot(key()), reason: '$lift m');
      }
      expect(key(12), isNot(key(6)));
      expect(key(12), key(12));
    });

    test('a raised road ending over a street is its own end entry', () {
      final street = road([(1000, 1600), (1300, 1600), (1600, 1600)]);
      final raised = road([(1600, 1600), (1900, 1600), (2200, 1600)],
          lifts: const [12, 12, 12]);
      final flatOne = road([(1600, 1600), (1900, 1600), (2200, 1600)]);
      final table = cut(frame([street, raised]));
      expect(entry(table), (4.0, 1));
      expect(entry(table, 12), (4.0, 1));
      // On the ground the two ends are one meeting of two.
      expect(entry(cut(frame([street, flatOne]))), (4.0, 2));
    });

    test('ends meet by the grade-separation rule, pair by pair', () {
      RoadSnapshot west([List<double> lifts = const []]) =>
          road([(1000, 1600), (1300, 1600), (1600, 1600)], lifts: lifts);
      RoadSnapshot east([List<double> lifts = const []]) =>
          road([(1600, 1600), (1900, 1600), (2200, 1600)], lifts: lifts);
      RoadSnapshot south([List<double> lifts = const []]) =>
          road([(1600, 1000), (1600, 1300), (1600, 1600)], lifts: lifts);
      RoadSnapshot north([List<double> lifts = const []]) =>
          road([(1600, 1600), (1600, 1900), (1600, 2200)], lifts: lifts);
      List<double> deck(double lift) => [lift, lift, lift];

      // Two decks crossing on their piers four metres apart: one junction
      // in the air, as the layout cut it — every leg pulls back from it.
      final decks = cut(frame(
          [west(deck(20)), east(deck(20)), south(deck(24)), north(deck(24))]));
      expect(entry(decks, 20), (4.0, 4));
      expect(entry(decks, 24), (4.0, 4));
      // At the grade separation they pass: two roads carrying on.
      final passing = cut(frame([
        west(deck(20)),
        east(deck(20)),
        south(deck(24.5)),
        north(deck(24.5)),
      ]));
      expect(entry(passing, 20), (4.0, 2));
      expect(entry(passing, 24.5), (4.0, 2));

      // A road sunk three metres into a cutting, ending on a street: graded
      // into the ground, it meets both the street's pieces and they it.
      final cutting = cut(frame([west(), east(), north(deck(-3))]));
      expect(entry(cutting), (4.0, 3));
      expect(entry(cutting, -3), (4.0, 3));
      // In its tunnel it passes under.
      final tunnel = cut(frame([west(), east(), north(deck(-9))]));
      expect(entry(tunnel), (4.0, 2));
      expect(entry(tunnel, -9), (4.0, 1));

      // A deck laid flush meets the street, and a deck three metres up;
      // the street does not meet the one on its piers.
      final flush = cut(frame([west(), east(deck(0)), north(deck(3))]));
      expect(entry(flush), (4.0, 2));
      expect(entry(flush, 0), (4.0, 3));
      expect(entry(flush, 3), (4.0, 2));
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

    test('ends carry whether their road has a deck, through the columns',
        () {
      final flush = road([(1600, 1600), (1900, 1600), (2200, 1600)],
          lifts: const [0, 0, 0]);
      final ground = road([(1000, 1600), (1300, 1600), (1600, 1600)]);
      final ends = cut(frame([flush, ground])).tiles[tileA]!.ends;
      expect(ends, hasLength(4));
      // A deck laid flush is a deck, at a lift of 0.
      final decked = ends.where((e) => e.onDeck).toList();
      expect(decked, hasLength(2));
      expect(decked.map((e) => e.liftM), [0, 0]);
      final back = CityTileColumns.fromSnapshots(
        buildings: const [],
        roads: const [],
        patches: CityPatchColumns.empty,
        ends: ends,
        roadEnds: const [],
        transitEnds: const [],
      ).toSnapshots().ends;
      expect([for (final e in back) e.onDeck], [for (final e in ends) e.onDeck]);
      expect([for (final e in back) e.liftM], [for (final e in ends) e.liftM]);
    });

    test('a deck laid flush re-keys the tiles it meets', () {
      // The same line on the ground and as a flush deck: the same points,
      // the same lift of 0 — only the deck tells them apart.
      final street = road([(1000, 1600), (1300, 1600), (1600, 1600)]);
      final before = keys(cut(frame([
        street,
        road([(1600, 1600), (1900, 1600), (2200, 1600)]),
      ])));
      final d = CityTileBucketer.diff(
          before,
          cut(frame([
            street,
            road([(1600, 1600), (1900, 1600), (2200, 1600)],
                lifts: const [0, 0, 0]),
          ])));
      expect(d.rekeyed, [tileA]);
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

  group('a deck keeps its piers out of the roads of the tiles round it', () {
    // The first tile ends at `tileM` eastward. A street raised 12 m runs
    // north 70 m inside that edge; an avenue belonging to the next tile
    // east — its middle and both its ends are there — hooks back west
    // under the deck and out again.
    const edge = tileM;
    final deckPts = [for (var k = 0; k <= 12; k++) (edge - 70, 1000 + k * 100.0)];
    final deck = road(deckPts, lifts: List.filled(13, 12.0));
    RoadSnapshot hook({double west = edge - 150}) => road([
          (edge + 300, 1400),
          (west, 1550),
          (edge + 50, 1650),
          (edge + 300, 1800),
        ], cls: RoadClass.avenue);
    final deckTile = tileOf(edge - 70, 1600);
    final hookTile = tileOf(edge + 50, 1650);

    test("the deck's tile takes the neighbour's road beneath it", () {
      expect(deckTile, isNot(hookTile));
      final beneath = hook();
      final plan = cut(frame([deck, beneath]));
      final t = plan.tiles[deckTile]!;
      expect(t.roads, [deck]);
      expect(t.ends, hasLength(2), reason: "none of the avenue's ends");
      expect(t.corridors, hasLength(1));
      expect(t.corridors.single.pointsBF, orderedEquals(beneath.points));
      expect(t.corridors.single.halfWidthM, beneath.halfWidthM);
      // The avenue's own tile has no deck, and takes nothing.
      expect(plan.tiles[hookTile]!.corridors, isEmpty);
    });

    test('only a deck on piers takes any, and only of roads in its reach',
        () {
      // Within a structure's clearance of the ground: no pier to keep out.
      final atGrade = road(deckPts, lifts: List.filled(13, 2.0));
      expect(cut(frame([atGrade, hook()])).tiles[deckTile]!.corridors,
          isEmpty);
      // A road of the next tile that stays well clear of the deck.
      final clear = road([
        (edge + 200, 2600),
        (edge + 600, 2600),
        (edge + 1000, 2600),
      ]);
      expect(cut(frame([deck, clear])).tiles[deckTile]!.corridors, isEmpty);
    });

    test('a colony nobody raised a road in: no tile takes any', () {
      const pts = [(7000.0, 1600.0), (7600.0, 1600.0), (8200.0, 1600.0)];
      final plan = cut(frame(
          [a, b, c, hook(), road(pts, bridges: const [100, 300])]));
      for (final t in plan.tiles.values) {
        expect(t.corridors, isEmpty, reason: t.key);
      }
    });

    test("the road beneath moved re-keys the deck's tile", () {
      final before = keys(cut(frame([deck, hook(), c])));
      // Only its bend under the deck moves: every end, and so every end
      // entry, stays where it was.
      final d = CityTileBucketer.diff(
          before, cut(frame([deck, hook(west: edge - 140), c])));
      expect(d.rekeyed.toSet(), {deckTile, hookTile});
      expect(d.kept, [tileC]);
    });

    test('a road near two of a tile\'s decks is taken once', () {
      // A second deck well west: the short hook comes near the first deck
      // only, the long one near both.
      final west = road(
          [for (var k = 0; k <= 12; k++) (edge - 600, 1000 + k * 100.0)],
          lifts: List.filled(13, 12.0));
      expect(tileOf(edge - 600, 1600), deckTile);
      for (final (reach, hooked) in [(edge - 150, hook()), (edge - 700, null)]) {
        final beneath = hooked ?? hook(west: reach);
        final t = cut(frame([deck, west, beneath])).tiles[deckTile]!;
        expect(t.corridors, hasLength(1), reason: '$reach');
        expect(t.corridors.single.pointsBF, orderedEquals(beneath.points));
      }
    });

    test('an unkeyed cut gathers none until it is keyed', () {
      // A cut the renderer culls for range goes no further than finding
      // its tiles: holding every road to every deck is no part of that.
      final s = frame([deck, hook(), c]);
      final plan = CityTileBucketer.bucket(s,
          anchors: {'moon': anchor}, tileM: tileM, keyed: false);
      expect(plan.tiles.values.expand((t) => t.corridors), isEmpty);
      CityTileBucketer.keyTiles(plan);
      expect(plan.tiles[deckTile]!.corridors, hasLength(1));
      // Keyed again, nothing is gathered twice.
      CityTileBucketer.keyTiles(plan);
      expect(plan.tiles[deckTile]!.corridors, hasLength(1));
      expect(keys(plan), keys(cut(s)));
    });
  });

  group('a deck turning at a joint, whichever tile the other leg is', () {
    // A street raised 12 m runs east across the first tile's east edge
    // (3218.688 m) to a corner just past it: its middle is the first
    // tile's, and its corner — and whatever meets it there — the next's.
    const legPts = [(2400.0, 1600.0), (2800.0, 1600.0), (3300.0, 1600.0)];
    const turnedPts = [(3300.0, 1600.0), (3300.0, 2000.0), (3300.0, 2400.0)];
    const onPts = [(3300.0, 1600.0), (3700.0, 1600.0), (4100.0, 1600.0)];
    final up = List.filled(3, 12.0);
    final leg = road(legPts, lifts: up);
    final turned = road(turnedPts, lifts: up);
    final on = road(onPts, lifts: up);
    final legTile = tileOf(2800, 1600);
    final cornerTile = tileOf(3300, 1600);

    test('the cut reads the turn off the whole body', () {
      expect(legTile, isNot(cornerTile));
      expect(tileOf(3300, 2000), cornerTile);
      expect(tileOf(3700, 1600), cornerTile);
      final plan = cut(frame([leg, turned]));
      final bends = plan.endBends['moon']!;
      expect(CityTileBucketer.bendsOf(leg, bends), (false, true));
      expect(CityTileBucketer.bendsOf(turned, bends), (true, false));
      // Nothing of the corner is in the deck's own tile.
      expect(plan.tiles[legTile]!.roads, [leg]);
      expect(plan.tiles[legTile]!.ends.map((e) => e.at), [at(2400, 1600)]);
      // Going on straight is no turn.
      final straight = cut(frame([leg, on])).endBends['moon'] ?? const <int>{};
      expect(CityTileBucketer.bendsOf(leg, straight), (false, false));
      // Nor is an unkeyed cut's: it has not looked.
      final unkeyed = CityTileBucketer.bucket(frame([leg, turned]),
          anchors: {'moon': anchor}, tileM: tileM, keyed: false);
      expect(unkeyed.endBends, isEmpty);
    });

    test('the turn is read off whichever end meets the deck by the rule',
        () {
      // A deck end has an end-table entry of its own, keyed by its lift, so
      // the other leg of its corner shares no key with it unless it stands
      // at that very lift. The one end that meets it is found by the rule
      // the table counted it by: a deck two metres off its lift, or the
      // street it is graded into.
      Set<int> bendsIn(List<RoadSnapshot> roads) =>
          cut(frame(roads)).endBends['moon'] ?? const <int>{};
      final higher = road(turnedPts, lifts: List.filled(3, 14.0));
      final offLift = bendsIn([leg, higher]);
      expect(CityTileBucketer.bendsOf(leg, offLift), (false, true));
      expect(CityTileBucketer.bendsOf(higher, offLift), (true, false));
      // Graded into the ground at the corner, it meets the street there.
      final low = road(legPts, lifts: const [12.0, 6.0, 1.0]);
      final street = road(turnedPts);
      expect(CityTileBucketer.bendsOf(low, bendsIn([low, street])),
          (false, true));
      // Grade-separated, nothing meets it there, and nothing turns.
      final apart = road(turnedPts, lifts: List.filled(3, 20.0));
      expect(CityTileBucketer.bendsOf(leg, bendsIn([leg, apart])),
          (false, false));
      expect(CityTileBucketer.bendsOf(leg, bendsIn([leg, street])),
          (false, false));
      // Going on straight off a deck two metres up is no turn.
      final onHigher = road(onPts, lifts: List.filled(3, 14.0));
      expect(CityTileBucketer.bendsOf(leg, bendsIn([leg, onHigher])),
          (false, false));
    });

    test("the other leg turned re-keys the deck's tile", () {
      final before = keys(cut(frame([leg, on, c])));
      final d = CityTileBucketer.diff(before, cut(frame([leg, turned, c])));
      expect(d.rekeyed.toSet(), {legTile, cornerTile});
      expect(d.kept, [tileC]);
    });

    test("the turn is in the deck's tile's key, as its build reads it", () {
      // The deck's piers take the other leg as a corridor as well, but the
      // parapets read the turn itself: the key holds what the build reads.
      final plan = cut(frame([leg, turned, c]));
      final table = plan.endHalf['moon']!;
      final bends = plan.endBends['moon']!;
      final deckTile = plan.tiles[legTile]!;
      expect(
          CityTileBucketer.structureKeyOf(deckTile,
              endHalf: table, endBends: bends),
          isNot(CityTileBucketer.structureKeyOf(deckTile, endHalf: table)));
      // A tile of roads on the ground keys the same whatever turns.
      final ground = plan.tiles[tileC]!;
      expect(
          CityTileBucketer.structureKeyOf(ground,
              endHalf: table, endBends: bends),
          CityTileBucketer.structureKeyOf(ground, endHalf: table));
    });

    test("on the ground a turn holds no parapet back, and moves no key", () {
      final plan = cut(frame([road(legPts), road(turnedPts), c]));
      expect(plan.endBends, isEmpty);
      final d = CityTileBucketer.diff(
          keys(cut(frame([road(legPts), road(onPts), c]))), plan);
      expect(d.kept.toSet(), {legTile, tileC});
      expect(d.rekeyed, [cornerTile]);
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

  test('an unkeyed cut keys the same once keyed', () {
    final s = frame([a, b, c], junctions: [junction(2600, 1600, lights: 1)]);
    final plan = CityTileBucketer.bucket(s,
        anchors: {'moon': anchor}, tileM: tileM, keyed: false);
    expect(plan.tiles.values.map((t) => t.structureKey), everyElement(''));
    expect(plan.tiles.values.expand((t) => t.roadHashes), isEmpty);
    CityTileBucketer.keyTiles(plan);
    expect(keys(plan), keys(cut(s)));
  });

  group('the hash is 32-bit arithmetic, the same on the web', () {
    test('the web\'s split product is the product modulo 2^32', () {
      final rnd = math.Random(7);
      final mod = BigInt.one << 32;
      final samples = <int>[
        0, 1, 0xFFFF, 0x10000, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, //
        for (var i = 0; i < 2000; i++) rnd.nextInt(1 << 32),
      ];
      for (final x in samples) {
        for (final y in [0x85EBCA6B, 0xC2B2AE35, 0xFFFFFFFF, 5, x]) {
          final want = ((BigInt.from(x) * BigInt.from(y)) % mod).toInt();
          expect(CityHash32.mulSplit(x, y), want, reason: '$x * $y');
        }
      }
    });

    test('a step stays below 2^32 and is one to one in the running value',
        () {
      for (final v in [0, 1, -1, 0xFFFFFFFF, 1 << 40, -(1 << 45)]) {
        final seen = <int>{};
        for (var h = 0; h < 5000; h++) {
          final x = CityHash32.mix(h * 858993, v);
          expect(x, inInclusiveRange(0, 0xFFFFFFFF));
          seen.add(x);
        }
        expect(seen, hasLength(5000), reason: 'word $v');
      }
    });

    test('a paired step moves with either half of a double alone', () {
      final rnd = math.Random(11);
      for (var i = 0; i < 2000; i++) {
        final h = rnd.nextInt(1 << 32);
        final lo = rnd.nextInt(1 << 32);
        final hi = rnd.nextInt(1 << 32);
        final x = CityHash32.mixPair(h, lo, hi);
        expect(x, inInclusiveRange(0, 0xFFFFFFFF));
        // Any other value of the one half.
        final lo2 = (lo + 1 + rnd.nextInt(0xFFFFFFFE)) & 0xFFFFFFFF;
        final hi2 = (hi + 1 + rnd.nextInt(0xFFFFFFFE)) & 0xFFFFFFFF;
        expect(CityHash32.mixPair(h, lo2, hi), isNot(x));
        expect(CityHash32.mixPair(h, lo, hi2), isNot(x));
      }
    });

    test('keys and road hashes stay within what the web holds exactly', () {
      final plan = cut(frame([a, b, c], junctions: [junction(2600, 1600)]));
      for (final t in plan.tiles.values) {
        expect(int.parse(t.structureKey.split('|').last, radix: 16),
            inInclusiveRange(0, 0xFFFFFFFF));
        expect(t.roadHashes, everyElement(inInclusiveRange(0, 0xFFFFFFFF)));
      }
      expect(
          CityTileBucketer.roadsSignature(
              frame([a], roadsRevision: {'c': 3}, junctions: [junction(0, 0)])),
          inInclusiveRange(0, 0xFFFFFFFF));
    });

    test('points are read off their own buffer, from their own offset', () {
      RoadSnapshot withPoints(List<double> pts) => RoadSnapshot(
            colonyId: 'c',
            body: 'moon',
            points: pts,
            halfWidthM: 4,
            roadClassIndex: RoadClass.street.index,
            id: 'a',
          );
      final n = a.points.length;
      final copy = Float64List.fromList(a.points);
      final buffer = Float64List(n + 5)..setRange(3, 3 + n, a.points);
      final view = Float64List.sublistView(buffer, 3, 3 + n);
      final h = CityTileBucketer.roadHash(withPoints(copy));
      expect(CityTileBucketer.roadHash(withPoints(view)), h);
      // A whole metre moves it: the low word of a round coordinate is the
      // same either side, so both words of every double must go in.
      for (var i = 0; i < n; i++) {
        final moved = Float64List.fromList(a.points)..[i] += 1;
        expect(CityTileBucketer.roadHash(withPoints(moved)), isNot(h),
            reason: 'point value $i');
      }
    });
  });

  group('the cut gate', () {
    const rangeM = 400e3;
    final plan = cut(frame([a, b, c]));
    // Over the colony, and a thousand kilometres up from it.
    final near = at(1600, 1600);
    final far = basis.up * (radius + 1000e3);
    Vector3? focusNear(String _) => near;
    Vector3? focusFar(String _) => far;

    test('the bounds measure a tile the way the renderer does', () {
      final bounds = CityCullBounds.ofPlan(plan);
      expect(bounds.length, 3);
      final focus = at(5000, 1600) + basis.up * 2000;
      var want = double.infinity;
      for (final t in plan.tiles.values) {
        want = math.min(want,
            math.max(0.0, (t.centreBF - focus).length - t.halfDiagonalM));
      }
      expect(bounds.nearestM((_) => focus), want);
      expect(bounds.lastNearestM, want);
      // A body the frame does not carry has no tiles to measure.
      expect(bounds.nearestM((_) => null), double.infinity);
    });

    test('cuts a new structure, never the same one in new lists', () {
      final g = CityCutGate();
      expect(g.wantsCut(frame([a]), 'S1', rangeM: rangeM, focusBF: focusNear),
          isTrue);
      g.cut('S1');
      expect(g.signature, 'S1');
      // What the flight view hands over every frame: fresh lists, the
      // same content.
      expect(g.wantsCut(frame([a]), 'S1', rangeM: rangeM, focusBF: focusNear),
          isFalse);
      expect(
          g.wantsCut(frame([a, b]), 'S2', rangeM: rangeM, focusBF: focusNear),
          isTrue);
    });

    test('a colony culled for range is not cut again while it stays out', () {
      final g = CityCutGate();
      expect(
          g.wantsCut(frame([a, b, c]), 'S', rangeM: rangeM, focusBF: focusFar),
          isTrue);
      g
        ..cut('S')
        ..cull(CityCullBounds.ofPlan(plan));
      // The renderer used to forget the signature with the tiles, and cut
      // the colony again on every one of these frames.
      for (var i = 0; i < 3; i++) {
        expect(
            g.wantsCut(frame([a, b, c]), 'S',
                rangeM: rangeM, focusBF: focusFar),
            isFalse);
      }
      expect(g.culled!.lastNearestM, greaterThan(rangeM));
      expect(g.signature, 'S');
      // The camera comes back within range: cut again.
      expect(
          g.wantsCut(frame([a, b, c]), 'S', rangeM: rangeM, focusBF: focusNear),
          isTrue);
      g.cut('S');
      expect(g.culled, isNull);
    });

    test('a culled colony is cut again when its structure changes', () {
      final g = CityCutGate()
        ..cut('S')
        ..cull(CityCullBounds.ofPlan(plan));
      // A colony founded somewhere else would be missed by the old bounds.
      expect(
          g.wantsCut(frame([a, b, c]), 'S2',
              rangeM: rangeM, focusBF: focusFar),
          isTrue);
    });

    test('with no body to measure against, the colony stays culled', () {
      final g = CityCutGate()
        ..cut('S')
        ..cull(CityCullBounds.ofPlan(plan));
      expect(
          g.wantsCut(frame([a, b, c]), 'S', rangeM: rangeM, focusBF: (_) => null),
          isFalse);
    });

    test('a reset cuts the next frame, even the very same lists', () {
      final g = CityCutGate();
      final s = frame([a]);
      g.wantsCut(s, 'S', rangeM: rangeM, focusBF: focusNear);
      g.cut('S');
      expect(g.wantsCut(s, 'S', rangeM: rangeM, focusBF: focusNear), isFalse);
      g.reset();
      expect(g.signature, '');
      expect(g.culled, isNull);
      expect(g.wantsCut(s, 'S', rangeM: rangeM, focusBF: focusNear), isTrue);
    });
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

  _siteAccessKeys();
}

/// Site access in the cut (docs/plans/site-access.md §5.3, §8.3 R3), on a
/// real colony's frame: with the knob off, membership and every key are what
/// a frame without site access gives; on, the sites are cut in and keyed, a
/// tile without them keys as before, one plan change re-keys exactly the
/// site's tile and its join road's tile, and the gate sees the change.
void _siteAccessKeys() {
  group('site access keys', () {
    late CitySim city;
    late WorldSnapshot snap;
    late Map<String, Vector3> anchors;
    // Small tiles, so a site, its road and their neighbours part.
    const tileM = 160.0;

    setUpAll(() {
      city = siteTown();
      snap = captureSiteTown(city);
      final b = snap.buildings.values.first;
      anchors = {b.body: Vector3(b.px, b.py, b.pz)};
    });

    /// [s] without anything site access put on it.
    WorldSnapshot stripped(WorldSnapshot s) => WorldSnapshot(
          tick: s.tick,
          vessels: s.vessels,
          bodies: s.bodies,
          buildings: {
            for (final e in s.buildings.entries) e.key: _legacy(e.value),
          },
          roads: [for (final r in s.roads) _uncut(r)],
          patches: s.patches,
          roadsRevision: s.roadsRevision,
          junctions: s.junctions,
        );

    Map<String, String> keysOf(CityBucketPlan p) =>
        {for (final t in p.tiles.values) t.key: t.structureKey};

    CityBucketPlan cutOf(WorldSnapshot s, {bool on = false}) =>
        CityTileBucketer.bucket(s,
            anchors: anchors, tileM: tileM, siteAccess: on);

    test('off: membership and keys are exactly a frame without site access',
        () {
      expect(snap.sites, isNotEmpty);
      expect(snap.roads.where((r) => r.kerbCuts.isNotEmpty), isNotEmpty);
      final off = cutOf(snap), plain = cutOf(stripped(snap));
      expect(keysOf(off), keysOf(plain));
      for (final t in off.tiles.values) {
        final p = plain.tiles[t.key]!;
        expect(t.sites, isEmpty);
        expect([for (final b in t.buildings) b.id], [for (final b in p.buildings) b.id]);
        expect(t.roads.length, p.roads.length);
        expect(t.roadHashes, p.roadHashes);
      }
    });

    test('on: every site cut in once, its tile keyed; the rest as before', () {
      final off = cutOf(snap), on = cutOf(snap, on: true);
      final frame = snap.sites.single;
      expect(on.tiles.values.fold<int>(0, (n, t) => n + t.sites.length),
          frame.siteCount);
      // A road's content hash never takes its cuts.
      for (final t in on.tiles.values) {
        final o = off.tiles[t.key];
        if (o != null) expect(t.roadHashes, o.roadHashes);
      }
      var moved = 0, same = 0;
      for (final t in on.tiles.values) {
        final touched = t.sites.isNotEmpty ||
            t.buildings.any((b) => b.siteSlot >= 0) ||
            t.roads.any((r) => r.kerbCuts.isNotEmpty);
        final was = off.tiles[t.key]?.structureKey;
        if (touched) {
          expect(t.structureKey, isNot(was), reason: t.key);
          moved++;
        } else {
          expect(t.structureKey, was, reason: t.key);
          same++;
        }
      }
      expect(moved, greaterThan(0));
      expect(same, greaterThan(0));
    });

    test('one plan change re-keys exactly its tile and its join road\'s', () {
      final frame = snap.sites.single;
      final before = cutOf(snap, on: true);
      // A house on a street: its plan's key and its road's cut move.
      final g = frame.chunks.single;
      final k = [
        for (var i = 0; i < g.siteCount; i++)
          if (g.plan.program(i).name == 'homeDriveway') i,
      ].first;
      final siteTile = before.tiles.values
          .firstWhere((t) => t.sites.any((s) => s.site == k))
          .key;
      final plan = g.plan.plan(k);
      final join = [
        for (var j = 0; j < plan.joinCount; j++)
          if (plan.joinIsCut(j)) j,
      ].first;
      final roadId = city.roadGraph.roads[plan.joinRoadNo(join)].id;
      expect(snap.roads.firstWhere((r) => r.id == roadId).kerbCuts, isNotEmpty);
      final changed = CitySiteFrame(
        colonyId: frame.colonyId,
        bodyId: frame.bodyId,
        sitesRev: frame.sitesRev + 1,
        geometryStamp: frame.geometryStamp + 1,
        datumRadiusM: frame.datumRadiusM,
        up: frame.up,
        east: frame.east,
        north: frame.north,
        chunks: [g.debugWithSiteKey(k, g.siteKey(k) ^ 0x5A5A)],
      );
      final after = WorldSnapshot(
        tick: snap.tick,
        vessels: snap.vessels,
        bodies: snap.bodies,
        buildings: snap.buildings,
        roads: [
          for (final r in snap.roads)
            r.id == roadId ? _withCuts(r, [...r.kerbCuts]..[1] += 0.25) : r,
        ],
        patches: snap.patches,
        roadsRevision: snap.roadsRevision,
        junctions: snap.junctions,
        sites: [changed],
      );
      final cut = cutOf(after, on: true);
      final roadTile = cut.tiles.values
          .firstWhere((t) => t.roads.any((r) => r.id == roadId))
          .key;
      final diff = CityTileBucketer.diff(keysOf(before), cut);
      expect(diff.added, isEmpty);
      expect(diff.removed, isEmpty);
      expect(diff.rekeyed.toSet(), {siteTile, roadTile});
      // Off, the same change moves nothing.
      expect(CityTileBucketer.diff(keysOf(cutOf(snap)), cutOf(after)).rekeyed,
          isEmpty);
      // And the gate: the frame's sites signature moved.
      expect(CityTileBucketer.sitesSignature(after),
          isNot(CityTileBucketer.sitesSignature(snap)));
    });

    test('the gate\'s sites signature holds on a steady frame and moves on '
        'a plan change', () {
      final city = siteTown();
      final a = captureSiteTown(city);
      city.advance(0.5);
      final b = captureSiteTown(city);
      expect(CityTileBucketer.sitesSignature(b), CityTileBucketer.sitesSignature(a));
      final lot = city.parcelBuildings.keys.firstWhere(
          (id) => city.siteAccess.slotOf(id) >= 0 && id.startsWith('lot-r'));
      city.clearParcel(lot);
      city.advance(0.5);
      final c = captureSiteTown(city);
      expect(CityTileBucketer.sitesSignature(c),
          isNot(CityTileBucketer.sitesSignature(a)));
      // A gate keyed with it cuts again; without it (the knob off) the
      // counts alone decide.
      final gate = CityCutGate();
      String sig(WorldSnapshot s) => 'x|${CityTileBucketer.sitesSignature(s)}';
      expect(gate.wantsCut(a, sig(a), rangeM: 1e9, focusBF: (_) => null), isTrue);
      gate.cut(sig(a));
      expect(gate.wantsCut(b, sig(b), rangeM: 1e9, focusBF: (_) => null), isFalse);
      expect(gate.wantsCut(c, sig(c), rangeM: 1e9, focusBF: (_) => null), isTrue);
    });

    test('the sites signature hashes ids with fnv1a32, never hashCode', () {
      // The workspace rule for site-access keys and signatures: no platform
      // hash. The expected value is the documented mix over fnv1a32 ids.
      var want = 0x3C6EF372;
      for (final f in snap.sites) {
        want = CityHash32.mix(want, fnv1a32(f.colonyId));
        want = CityHash32.mix(want, fnv1a32(f.bodyId));
        want = CityHash32.mix(want, f.sitesRev);
        want = CityHash32.mix(want, f.geometryStamp);
      }
      expect(snap.sites, isNotEmpty);
      expect(CityTileBucketer.sitesSignature(snap), want);
    });

    test('a detail job packs the sites of the buildings it gathered', () {
      final frame = snap.sites.single;
      final served = [
        for (final b in snap.buildings.values)
          if (b.siteSlot >= 0) b,
      ].take(7).toList();
      final sites = CityTileBucketer.sitesOfBuildings(snap.sites, served);
      expect([for (final s in sites) s.geometry.plan.siteId(s.site)],
          [for (final b in served) b.id]);
      final packed = CityTileBucketer.siteFramesOf(sites);
      expect(packed, hasLength(1));
      expect(packed.single.siteCount, 7);
      expect(packed.single.chunks.single.plan.siteIds,
          [for (final b in served) b.id]);
      expect(identical(packed.single.up, frame.up), isTrue);
    });
  });
}

BuildingSnapshot _legacy(BuildingSnapshot b) => BuildingSnapshot(
      id: b.id,
      type: b.type,
      colonyId: b.colonyId,
      body: b.body,
      px: b.px,
      py: b.py,
      pz: b.pz,
      qw: b.qw,
      qx: b.qx,
      qy: b.qy,
      qz: b.qz,
      lat: b.lat,
      lon: b.lon,
      siteWidthM: b.siteWidthM,
      siteDepthM: b.siteDepthM,
      siteKindIndex: b.siteKindIndex,
      corner: b.corner,
      colorArgb: b.colorArgb,
    );

RoadSnapshot _withCuts(RoadSnapshot r, List<double> cuts) => RoadSnapshot(
      colonyId: r.colonyId,
      body: r.body,
      points: r.points,
      halfWidthM: r.halfWidthM,
      roadClassIndex: r.roadClassIndex,
      sealed: r.sealed,
      soundWalls: r.soundWalls,
      collector: r.collector,
      bridges: r.bridges,
      startHalfWidthM: r.startHalfWidthM,
      endHalfWidthM: r.endHalfWidthM,
      id: r.id,
      decoration: r.decoration,
      lifts: r.lifts,
      kerbCuts: cuts,
    );

RoadSnapshot _uncut(RoadSnapshot r) => _withCuts(r, const []);
