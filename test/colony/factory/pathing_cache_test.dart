// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:typed_data';

import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling_dispatch.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_pathing.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:flutter_test/flutter_test.dart';

/// Flow fields are the handlers' whole pathing budget (§3: "cached flow
/// fields per busy target"), so their memory must be bounded: 2-byte
/// distances, an LRU cap, and no field built for a request nobody on the
/// floor could carry anyway.
void main() {
  FloorPathing open(int w, int h, {int maxFields = kMaxCachedFields}) =>
      FloorPathing(HallSize(w, h), Uint8List(w * h)..fillRange(0, w * h, 1),
          maxFields: maxFields);

  test('fields are 2 bytes a tile and report unreachable as -1', () {
    final walk = Uint8List(5 * 3)..fillRange(0, 15, 1);
    for (var y = 0; y < 3; y++) {
      walk[y * 5 + 2] = 0; // a wall down column 2
    }
    final p = FloorPathing(const HallSize(5, 3), walk);
    final f = p.fieldTo(1, const [TilePos(0, 0)]);
    expect(f, isA<Uint16List>());
    expect(p.distance(f, const TilePos(1, 2)), 3);
    expect(p.distance(f, const TilePos(4, 0)), kUnreachable);
    expect(p.distance(f, const TilePos(9, 9)), kUnreachable);
    expect(p.nextStep(f, const TilePos(4, 0)), isNull);
  });

  test('the cache is bounded and evicts the least recently used', () {
    final p = open(8, 8, maxFields: 4);
    for (var k = 0; k < 4; k++) {
      p.fieldTo(k, [TilePos(k, 0)]);
    }
    p.fieldTo(0, const [TilePos(0, 0)]); // 0 is now the most recent
    p.fieldTo(10, const [TilePos(5, 5)]);
    expect(p.cachedFields, 4);
    expect(p.isCached(0), isTrue);
    expect(p.isCached(1), isFalse, reason: 'the least recently used goes');
    expect(p.isCached(10), isTrue);
    for (var k = 20; k < 40; k++) {
      p.fieldTo(k, [TilePos(k % 8, 3)]);
    }
    expect(p.cachedFields, 4);
    final again = p.fieldTo(1, const [TilePos(1, 0)]);
    expect(p.distance(again, const TilePos(1, 7)), 7,
        reason: 'an evicted field rebuilds identically');
  });

  test('routable is never asked when no free handler can lift the load', () {
    final hs = [
      FloorHandler(id: 1, kind: HandlerKind.onFoot, at: const TilePos(0, 0)),
    ];
    var asked = 0;
    final q = [MoveRequest(item: 'ore', count: 1, from: 10, to: 20)];
    Dispatcher.assign(q, hs, distTo: (_, _) => 1, routable: (_, _) {
      asked++;
      return true;
    });
    expect(asked, 0, reason: 'ore is a pallet load and only a walker is free');
    expect(q, hasLength(1));

    hs.single.state = HandlerState.carrying;
    q.add(MoveRequest(item: 'tubes', count: 1, from: 10, to: 20));
    Dispatcher.assign(q, hs, distTo: (_, _) => 1, routable: (_, _) {
      asked++;
      return true;
    });
    expect(asked, 0, reason: 'nobody is free at all');

    hs.single.state = HandlerState.idle;
    Dispatcher.assign(q, hs, distTo: (_, _) => 1, routable: (_, _) {
      asked++;
      return true;
    });
    expect(asked, 1);
    expect(hs.single.job?.item, 'tubes');
  });
}
