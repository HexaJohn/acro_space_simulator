// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling_dispatch.dart';
import 'package:flutter_test/flutter_test.dart';

/// With a mixed fleet the dispatcher must not waste the expensive kit
/// (§3 "Material handling"): of the handlers that can lift a load and are
/// equally near it, the CHEAPEST kind goes — walker before jack before
/// forklift before AGV before crane — and only then the lowest id. Nearer
/// still beats cheaper, and a handler that can't reach the target is
/// passed over for one that can.
void main() {
  FloorHandler h(int id, HandlerKind k) =>
      FloorHandler(id: id, kind: k, at: const TilePos(0, 0));

  /// Every kind, all 3 tiles from the pickup; ids chosen so the cheapest
  /// kind never has the lowest id.
  List<FloorHandler> fleet() => [
    h(1, HandlerKind.crane),
    h(2, HandlerKind.agv),
    h(3, HandlerKind.forklift),
    h(4, HandlerKind.palletJack),
    h(5, HandlerKind.onFoot),
  ];

  HandlerKind? winner(
    String item, {
    Map<int, int> dist = const {},
    bool Function(FloorHandler h)? reaches,
  }) {
    final hs = fleet();
    Dispatcher.assign(
      [MoveRequest(item: item, count: 1, from: 10, to: 20)],
      hs,
      distTo: (h, _) => dist[h.id] ?? 3,
      routable: (h, _, _) => reaches?.call(h) ?? true,
    );
    for (final x in hs) {
      if (x.job != null) return x.kind;
    }
    return null;
  }

  test('equally near: the cheapest kind that can lift it', () {
    expect(winner('tubes'), HandlerKind.onFoot, reason: 'a hand load');
    expect(winner('ore'), HandlerKind.palletJack, reason: 'a pallet');
    expect(winner('steelBillet'), HandlerKind.crane, reason: 'heavy');
  });

  test('nearer beats cheaper; unreachable is passed over', () {
    expect(
      winner('tubes', dist: {3: 1}),
      HandlerKind.forklift,
      reason: 'the forklift is two tiles closer',
    );
    expect(
      winner('ore', reaches: (h) => h.kind != HandlerKind.palletJack),
      HandlerKind.forklift,
      reason: 'the jack cannot get the pallet to the target',
    );
    expect(
      winner('steelBillet', reaches: (_) => false),
      isNull,
      reason: 'nobody can make the trip: it waits',
    );
  });

  test('a trip is filled up to capacity from matching requests', () {
    final f = h(1, HandlerKind.forklift);
    final q = [
      MoveRequest(item: 'crate:steel', count: 1, from: 10, to: 20),
      MoveRequest(item: 'crate:steel', count: 1, from: 11, to: 20),
      MoveRequest(item: 'crate:steel', count: 1, from: 10, to: 20),
    ];
    Dispatcher.assign(q, [f], distTo: (_, _) => 1, routable: (_, _, _) => true);
    expect(f.job?.count, 2, reason: 'both crates from #10 in one trip');
    expect(q.single.from, 11, reason: 'the other source still waits');
  });
}
