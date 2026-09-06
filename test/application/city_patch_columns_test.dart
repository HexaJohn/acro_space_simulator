// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

/// The columns exist so that a frame's patches are a dozen heap objects
/// however many patches there are — the population the old-generation
/// marker walked was the six hundred thousand snapshot objects the frame
/// used to hold. These tests pin that shape, and that nothing a reader
/// could see has changed: rows come back field for field, the wire's maps
/// are the maps they were, and iteration hands out snapshots as before.
void main() {
  const n = 100000;
  const bodies = ['moon', 'mars'];
  final rng = math.Random(11);
  double d([double scale = 1000]) => (rng.nextDouble() * 2 - 1) * scale;

  CityPatchSnapshot patch(int i) => CityPatchSnapshot(
        colonyId: i % 3 == 0 ? 'c-b' : 'c-a',
        body: bodies[i % 2],
        px: d(1.7e6),
        py: d(1.7e6),
        pz: d(1.7e6),
        qw: d(1),
        qx: d(1),
        qy: d(1),
        qz: d(1),
        sizeM: 10 + rng.nextInt(300).toDouble(),
        depthM: i % 2 == 0 ? null : 10 + rng.nextInt(300).toDouble(),
        kind: i % 5,
      );

  test('a hundred thousand patches are a dozen typed lists, not objects', () {
    // Both ways: the object list the frame used to carry, and the columns.
    // The object list is a hundred thousand snapshots plus the list; the
    // columns are twelve typed lists and a string table of the four names
    // that repeat, whatever the count. The object path here is the SOURCE
    // of the columns, so both hold the same rows — but the columns retain
    // no snapshot at all: every one handed out is made on request.
    final objects = List<CityPatchSnapshot>.generate(n, patch);
    final sw = Stopwatch()..start();
    final b = CityPatchColumnsBuilder(capacity: n);
    for (final p in objects) {
      b.add(
        colonyId: p.colonyId,
        body: p.body,
        px: p.px,
        py: p.py,
        pz: p.pz,
        qw: p.qw,
        qx: p.qx,
        qy: p.qy,
        qz: p.qz,
        sizeM: p.sizeM,
        depthM: p.depthM,
        kind: p.kind,
      );
    }
    final columns = b.build();
    final buildMs = sw.elapsedMicroseconds / 1000;

    expect(columns.length, n);
    expect(columns, isNot(isA<List>()),
        reason: 'the columns are not a list of anything');
    // Every column is a typed list of exactly n, and the string table holds
    // each name once.
    for (final c in [columns.px, columns.py, columns.pz]) {
      expect(c, isA<Float64List>());
      expect(c.length, n);
    }
    for (final c in [
      columns.qw,
      columns.qx,
      columns.qy,
      columns.qz,
      columns.sizeM,
      columns.depthM,
    ]) {
      expect(c, isA<Float32List>());
      expect(c.length, n);
    }
    for (final c in [columns.kind, columns.colonyIndex, columns.bodyIndex]) {
      expect(c, isA<Int32List>());
      expect(c.length, n);
    }
    expect(columns.strings.toSet(), {'c-a', 'c-b', 'moon', 'mars'});
    // Three doubles, six floats, three ints a row: sixty bytes.
    expect(columns.typedBytes, n * (3 * 8 + 6 * 4 + 3 * 4));
    // Nothing is retained between two requests for the same row.
    expect(identical(columns.at(0), columns.at(0)), isFalse);
    expect(identical(columns.first, columns.first), isFalse);

    // Field for field: positions and kinds exact, the float columns to
    // float precision.
    for (final i in [0, 1, 2, n ~/ 2, n - 1]) {
      final a = objects[i], c = columns.at(i);
      expect(c.colonyId, a.colonyId);
      expect(c.body, a.body);
      expect([c.px, c.py, c.pz], [a.px, a.py, a.pz]);
      expect(c.qw, closeTo(a.qw, 1e-6));
      expect(c.qx, closeTo(a.qx, 1e-6));
      expect(c.qy, closeTo(a.qy, 1e-6));
      expect(c.qz, closeTo(a.qz, 1e-6));
      expect(c.sizeM, closeTo(a.sizeM, 1e-4));
      expect(c.depthM, closeTo(a.depthM, 1e-4));
      expect(c.kind, a.kind);
      expect(columns.colonyIdAt(i), a.colonyId);
      expect(columns.bodyAt(i), a.body);
    }
    // ignore: avoid_print
    print('city patch columns: $n rows built in '
        '${buildMs.toStringAsFixed(1)} ms, '
        '${(columns.typedBytes / (1024 * 1024)).toStringAsFixed(2)} MB typed');
  });

  test('the columns iterate as snapshots, and count without iterating', () {
    final columns = CityPatchColumns.of([for (var i = 0; i < 50; i++) patch(i)]);
    expect(columns.length, 50);
    expect(columns.isEmpty, isFalse);
    expect(columns.isNotEmpty, isTrue);
    expect(columns.where((p) => p.kind == 0).length, 10);
    expect(columns.map((p) => p.body).toSet(), {'moon', 'mars'});
    expect(columns.elementAt(7).kind, 7 % 5);
    var seen = 0;
    for (final p in columns) {
      expect(p.kind, seen % 5);
      seen++;
    }
    expect(seen, 50);
    expect(CityPatchColumns.empty, isEmpty);
    expect(CityPatchColumns.of(const []), same(CityPatchColumns.empty));
  });

  test('a builder grows past its capacity and trims to what it holds', () {
    // Capture reserves an upper bound; anything without one leans on the
    // doubling. Either way the columns come out at exactly the row count.
    final b = CityPatchColumnsBuilder(capacity: 4);
    for (var i = 0; i < 37; i++) {
      final p = patch(i);
      b.add(
        colonyId: p.colonyId,
        body: p.body,
        px: p.px,
        py: p.py,
        pz: p.pz,
        qw: p.qw,
        qx: p.qx,
        qy: p.qy,
        qz: p.qz,
        sizeM: p.sizeM,
        depthM: p.depthM,
        kind: p.kind,
      );
    }
    final c = b.build();
    expect(c.length, 37);
    expect(c.px.length, 37);
    expect(c.kind.length, 37);
    expect(c.kind[36], 36 % 5);

    // Reserving up front lands the rows in one allocation, and a reserve
    // that does not fit grows once to fit it.
    final r = CityPatchColumnsBuilder(capacity: 8)..reserve(100);
    expect(r.length, 0);
  });

  test('a gather is the rows asked for, with a string table of its own', () {
    final all = CityPatchColumns.of([for (var i = 0; i < 40; i++) patch(i)]);
    final picked = Int32List.fromList([3, 17, 5, 5, 39]);
    final sub = all.gather(picked);
    expect(sub.length, 5);
    for (var k = 0; k < picked.length; k++) {
      final i = picked[k];
      expect(sub.px[k], all.px[i]);
      expect(sub.qw[k], all.qw[i]);
      expect(sub.kind[k], all.kind[i]);
      expect(sub.colonyIdAt(k), all.colonyIdAt(i));
      expect(sub.bodyAt(k), all.bodyAt(i));
    }
    // Only the names those rows use — and every one of them.
    expect(sub.strings.toSet(),
        {for (final i in picked) all.colonyIdAt(i), for (final i in picked) all.bodyAt(i)});
    expect(all.gather(Int32List(0)), same(CityPatchColumns.empty));
    // Odd-row bodies are 'mars' only; the subset's table does not carry
    // 'moon' just because the source's does.
    final odd = all.gather(Int32List.fromList([1, 3, 5]));
    expect(odd.strings, isNot(contains('moon')));
  });

  test('the wire is the same maps, and decodes to equal columns', () {
    final columns =
        CityPatchColumns.of([for (var i = 0; i < 200; i++) patch(i)]);
    final maps = columns.toJsonList();
    expect(maps.length, 200);
    for (var i = 0; i < 200; i++) {
      expect(maps[i], columns.at(i).toJson());
    }
    final back = CityPatchColumns.fromJsonList(maps);
    expect(back.contentEquals(columns), isTrue);
    expect(back.toJsonList(), maps);
    // A map without 'd' (an older writer) reads the size as the depth, as
    // CityPatchSnapshot.fromJson always has.
    final short = Map<String, dynamic>.of(maps.first)..remove('d');
    final one = CityPatchColumns.fromJsonList([short]);
    expect(one.depthM[0], one.sizeM[0]);
    expect(CityPatchSnapshot.fromJson(short).depthM, one.sizeM[0]);
  });
}
