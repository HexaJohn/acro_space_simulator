// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_tile_columns.dart';
import 'package:flutter_test/flutter_test.dart';

/// The columns are the tile's members in another shape: everything the
/// snapshots hold comes back from them, field for field — and the shape
/// exists for one reason, that a send copies it as blocks, which the
/// micro-benchmark at the end checks against the object graph it replaced.
void main() {
  const r = 1.7374e6;
  final rng = math.Random(7);
  double d([double scale = 1000]) => (rng.nextDouble() * 2 - 1) * scale;

  BuildingSnapshot building(int i) => BuildingSnapshot(
        id: 'b$i',
        type: ['r-low', 'r-med', 'c-high', 'i-low'][i % 4],
        colonyId: i % 3 == 0 ? 'c-b' : 'c-a',
        body: i % 5 == 0 ? 'mars' : 'moon',
        px: d(),
        py: d(),
        pz: r + d(10),
        qw: d(1),
        qx: d(1),
        qy: d(1),
        qz: d(1),
        lat: d(math.pi / 2),
        lon: d(math.pi),
        siteWidthM: 12 + rng.nextInt(60).toDouble(),
        siteDepthM: 12 + rng.nextInt(60).toDouble(),
        siteKindIndex: rng.nextInt(4),
        corner: i % 7 == 0,
        // The top bit set and clear: ARGB is an unsigned word.
        colorArgb: i.isEven ? 0xFF9E9E9E : 0x1234ABCD,
      );

  RoadSnapshot road(int i, {int points = 4}) => RoadSnapshot(
        colonyId: i % 3 == 0 ? 'c-b' : 'c-a',
        body: 'moon',
        points: [for (var k = 0; k < points * 3; k++) d()],
        halfWidthM: 2 + rng.nextInt(12).toDouble(),
        roadClassIndex: i % RoadClass.values.length,
        sealed: i % 2 == 0,
        soundWalls: i % 3 == 0,
        collector: i % 4 == 0,
        bridges: i % 3 == 0 ? const [] : [for (var k = 0; k < 4; k++) d(100)],
        startHalfWidthM: i % 4 == 1 ? null : d(8),
        endHalfWidthM: i % 4 == 2 ? null : d(8),
      );

  CityPatchSnapshot patch(int i) => CityPatchSnapshot(
        colonyId: 'c-a',
        body: i % 2 == 0 ? 'moon' : 'mars',
        px: d(),
        py: d(),
        pz: r,
        qw: d(1),
        qx: d(1),
        qy: d(1),
        qz: d(1),
        sizeM: 10 + rng.nextInt(300).toDouble(),
        kind: i % 5,
        // Both the square patch (depth defaulting to the size) and the lot.
        depthM: i % 2 == 0 ? null : 10 + rng.nextInt(300).toDouble(),
      );

  CityTileEnd end(int i) => CityTileEnd(
        Vector3(d(), d(), r),
        Vector3(d(), d(), r),
        2 + rng.nextInt(12).toDouble(),
        RoadClass.values[i % RoadClass.values.length],
        i % 2 == 0,
        i % 3 == 0,
      );

  test('the members round-trip field for field', () {
    final buildings = [for (var i = 0; i < 40; i++) building(i)];
    final roads = [for (var i = 0; i < 17; i++) road(i, points: 2 + i % 5)];
    final patches = [for (var i = 0; i < 10; i++) patch(i)];
    final ends = [for (var i = 0; i < 12; i++) end(i)];
    final roadEnds = <(double, int)?>[
      for (var i = 0; i < roads.length * 2; i++)
        i % 3 == 0 ? null : (d(8), 1 + rng.nextInt(4)),
    ];
    final transitEnds = [for (var i = 0; i < 6; i++) Vector3(d(), d(), r)];

    final columns = CityTileColumns.fromSnapshots(
      buildings: buildings,
      roads: roads,
      patches: patches,
      ends: ends,
      roadEnds: roadEnds,
      transitEnds: transitEnds,
    );
    expect(columns.buildingCount, buildings.length);
    expect(columns.roadCount, roads.length);
    expect(columns.patchCount, patches.length);
    expect(columns.endCount, ends.length);
    // The string table holds each name once, whatever repeats it.
    expect(columns.strings.where((s) => s == 'moon').length, 1);
    expect(columns.strings.toSet().length, columns.strings.length);

    final back = columns.toSnapshots();

    expect(back.buildings.length, buildings.length);
    for (var i = 0; i < buildings.length; i++) {
      final a = buildings[i], b = back.buildings[i];
      expect(b.id, a.id);
      expect(b.type, a.type);
      expect(b.colonyId, a.colonyId);
      expect(b.body, a.body);
      expect([b.px, b.py, b.pz], [a.px, a.py, a.pz]);
      expect([b.qw, b.qx, b.qy, b.qz], [a.qw, a.qx, a.qy, a.qz]);
      expect([b.lat, b.lon], [a.lat, a.lon]);
      expect([b.siteWidthM, b.siteDepthM], [a.siteWidthM, a.siteDepthM]);
      expect(b.siteKindIndex, a.siteKindIndex);
      expect(b.corner, a.corner);
      expect(b.colorArgb, a.colorArgb);
    }

    expect(back.roads.length, roads.length);
    for (var i = 0; i < roads.length; i++) {
      final a = roads[i], b = back.roads[i];
      expect(b.colonyId, a.colonyId);
      expect(b.body, a.body);
      expect(b.points, orderedEquals(a.points));
      expect(b.halfWidthM, a.halfWidthM);
      expect(b.roadClassIndex, a.roadClassIndex);
      expect(b.sealed, a.sealed);
      expect(b.soundWalls, a.soundWalls);
      expect(b.collector, a.collector);
      expect(b.bridges, orderedEquals(a.bridges));
      expect(b.startHalfWidthM, a.startHalfWidthM);
      expect(b.endHalfWidthM, a.endHalfWidthM);
    }
    // Both flavours of null went round: one road with neither end
    // tapered, one with only the start.
    expect(back.roads.any((x) => x.startHalfWidthM == null), isTrue);
    expect(back.roads.any((x) => x.endHalfWidthM == null), isTrue);
    expect(back.roads.any((x) => x.bridges.isEmpty), isTrue);
    expect(back.roads.any((x) => x.bridges.isNotEmpty), isTrue);

    expect(back.patches.length, patches.length);
    for (var i = 0; i < patches.length; i++) {
      final a = patches[i], b = back.patches[i];
      expect(b.colonyId, a.colonyId);
      expect(b.body, a.body);
      expect([b.px, b.py, b.pz], [a.px, a.py, a.pz]);
      expect([b.qw, b.qx, b.qy, b.qz], [a.qw, a.qx, a.qy, a.qz]);
      expect(b.sizeM, a.sizeM);
      expect(b.depthM, a.depthM);
      expect(b.kind, a.kind);
    }
    expect(back.patches.map((p) => p.kind).toSet(), {0, 1, 2, 3, 4});

    expect(back.ends.length, ends.length);
    for (var i = 0; i < ends.length; i++) {
      final a = ends[i], b = back.ends[i];
      expect([b.at.x, b.at.y, b.at.z], [a.at.x, a.at.y, a.at.z]);
      expect([b.next.x, b.next.y, b.next.z], [a.next.x, a.next.y, a.next.z]);
      expect(b.halfWidthM, a.halfWidthM);
      expect(b.roadClass, a.roadClass);
      expect(b.paved, a.paved);
      expect(b.collector, a.collector);
    }

    expect(back.roadEnds.length, roadEnds.length);
    for (var i = 0; i < roadEnds.length; i++) {
      expect(back.roadEnds[i], roadEnds[i]);
    }
    expect(back.transitEnds.length, transitEnds.length);
    for (var i = 0; i < transitEnds.length; i++) {
      expect([back.transitEnds[i].x, back.transitEnds[i].y,
          back.transitEnds[i].z],
          [transitEnds[i].x, transitEnds[i].y, transitEnds[i].z]);
    }
  });

  test('an empty tile round-trips', () {
    final columns = CityTileColumns.fromSnapshots(
      buildings: const [],
      roads: const [],
      patches: const [],
      ends: const [],
      roadEnds: const [],
      transitEnds: const [],
    );
    final back = columns.toSnapshots();
    expect(back.buildings, isEmpty);
    expect(back.roads, isEmpty);
    expect(back.patches, isEmpty);
    expect(back.ends, isEmpty);
    expect(back.roadEnds, isEmpty);
    expect(back.transitEnds, isEmpty);
  });

  test('a road-end list of the wrong length is refused', () {
    expect(
        () => CityTileColumns.fromSnapshots(
              buildings: const [],
              roads: [road(0)],
              patches: const [],
              ends: const [],
              roadEnds: const [null],
              transitEnds: const [],
            ),
        throwsArgumentError);
  });

  test('the columns survive a send, and go as blocks', () async {
    // Plain typed lists, not a transferable: the tile sends the same
    // columns on every re-key, so a send must leave them whole.
    final columns = CityTileColumns.fromSnapshots(
      buildings: [for (var i = 0; i < 5; i++) building(i)],
      roads: [for (var i = 0; i < 3; i++) road(i)],
      patches: [patch(0)],
      ends: [end(0)],
      roadEnds: const [null, null, null, null, null, null],
      transitEnds: const [],
    );
    final before = columns.toSnapshots();
    final there = await Isolate.run(() {
      final m = columns.toSnapshots();
      return [m.buildings.length, m.roads.length, m.roads[1].points.length];
    });
    expect(there, [5, 3, 12]);
    // Still whole here.
    expect(columns.roadPoints.length, before.roads.fold(0, (n, x) => n + x.points.length));
    expect(columns.toSnapshots().roads[1].points,
        orderedEquals(before.roads[1].points));
  });

  test('MICRO-BENCHMARK: a near tile sends in well under 5 ms as columns',
      () async {
    // The number this whole shape exists for. A near tile of the sweep —
    // five hundred and fifty buildings, two hundred roads of three hundred
    // points — sent as snapshot objects walked the graph one object at a
    // time on the UI thread, up to twenty-five milliseconds; as columns it
    // is a memcpy. The old graph is timed alongside for the record. The
    // send is timed on the SENDING side, where the copy happens; the echo
    // only proves the message arrived.
    final buildings = [for (var i = 0; i < 550; i++) building(i)];
    final roads = [for (var i = 0; i < 200; i++) road(i, points: 300)];
    final patches = [for (var i = 0; i < 60; i++) patch(i)];
    final ends = [for (var i = 0; i < 120; i++) end(i)];
    final roadEnds = <(double, int)?>[
      for (var i = 0; i < roads.length * 2; i++)
        i % 3 == 0 ? null : (d(8), 1 + rng.nextInt(4)),
    ];
    final transitEnds = [for (var i = 0; i < 8; i++) Vector3(d(), d(), r)];
    final packClock = Stopwatch()..start();
    final columns = CityTileColumns.fromSnapshots(
      buildings: buildings,
      roads: roads,
      patches: patches,
      ends: ends,
      roadEnds: roadEnds,
      transitEnds: transitEnds,
    );
    final packMs = packClock.elapsedMicroseconds / 1000;
    final graph = [buildings, roads, patches, ends, roadEnds, transitEnds];

    final inbox = ReceivePort();
    final replies = StreamIterator<Object?>(inbox);
    final isolate =
        await Isolate.spawn(_echoMain, inbox.sendPort, debugName: 'echo');
    expect(await replies.moveNext(), isTrue);
    final port = replies.current as SendPort;

    Future<double> sendMs(Object msg) async {
      final sw = Stopwatch()..start();
      port.send(msg);
      final ms = sw.elapsedMicroseconds / 1000;
      expect(await replies.moveNext(), isTrue);
      expect(replies.current, 'ok');
      return ms;
    }

    // A few of each, interleaved. The least is what the send costs; the
    // most is what it costs when the copy lands on a busy allocator —
    // the graph's hundreds of thousands of boxed doubles are all fresh
    // allocations on the sending side, the columns' blocks are not — and
    // the app pays the worst one in the frame it lands on.
    const runs = 8;
    final columnsMs = <double>[], graphMs = <double>[];
    for (var i = 0; i < runs; i++) {
      columnsMs.add(await sendMs(columns));
      graphMs.add(await sendMs(graph));
    }
    port.send('quit');
    await replies.cancel();
    inbox.close();
    isolate.kill();

    String stats(List<double> ms) {
      final least = ms.reduce(math.min), most = ms.reduce(math.max);
      final mean = ms.reduce((a, b) => a + b) / ms.length;
      return 'min ${least.toStringAsFixed(3)} / mean '
          '${mean.toStringAsFixed(3)} / max ${most.toStringAsFixed(3)} ms';
    }

    final mb = columns.typedBytes / (1024 * 1024);
    // ignore: avoid_print
    print('city tile send (550 buildings, 200 roads x 300 points): '
        'columns ${stats(columnsMs)} (${mb.toStringAsFixed(2)} MB typed, '
        'packed once in ${packMs.toStringAsFixed(2)} ms); '
        'object graph ${stats(graphMs)}');
    expect(columnsMs.reduce(math.min), lessThan(5.0),
        reason: 'a near tile must send in well under a frame slice');
    // The columns still hold the tile after being sent five times.
    expect(columns.buildingCount, 550);
    expect(columns.roadPoints.length, 200 * 300 * 3);
  });
}

/// The far side of the benchmark: takes each message and answers 'ok'.
void _echoMain(SendPort out) {
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  inbox.listen((Object? msg) {
    if (msg == 'quit') {
      inbox.close();
    } else {
      out.send('ok');
    }
  });
}
