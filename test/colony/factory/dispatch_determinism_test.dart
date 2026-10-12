// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/domain/colony/city/factory/factory_colony_port.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_floor.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_grid.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_handling_dispatch.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_sim_api.dart';
import 'package:acro_space_simulator/domain/colony/city/factory/factory_templates.dart';
import 'package:flutter_test/flutter_test.dart';

/// Floors are measured headless and re-run after load (§3 "Off-screen"),
/// so the same layout must always produce the same floor: two identical
/// floors stepped identically must print identical JSON, whatever chunks
/// the caller hands [FactoryFloor.step]. The dispatcher's tie-break (lowest
/// id) and its lift rule are pinned directly because they are where an
/// accidental hash-order or "close enough" handler would creep in.
void main() {
  test('identical floors stepped identically stay identical', () {
    final a = FactoryFloor.fromBlueprint(factoryTemplateFor('steelmill')!);
    final b = FactoryFloor.fromBlueprint(factoryTemplateFor('steelmill')!);
    final pa = InfiniteColonyPort(), pb = InfiniteColonyPort();
    for (var t = 0; t < 6; t++) {
      a.step(50, pa);
      b.step(50, pb);
      expect(jsonEncode(a.toJson()), jsonEncode(b.toJson()),
          reason: 'diverged by ${(t + 1) * 50} s');
    }
    expect(a.handlers.any((h) => h.state != HandlerState.idle), isTrue,
        reason: 'the comparison covered handlers mid-trip');
  });

  test('the caller\'s step size never changes the result', () {
    final a = FactoryFloor.fromBlueprint(factoryTemplateFor('steelmill')!);
    final b = FactoryFloor.fromBlueprint(factoryTemplateFor('steelmill')!);
    final pa = InfiniteColonyPort(), pb = InfiniteColonyPort();
    for (var i = 0; i < 1200; i++) {
      a.step(0.25, pa); // 300 s in sub-steps
    }
    for (var i = 0; i < 40; i++) {
      b.step(7.5, pb); // 300 s in big frames
    }
    expect(jsonEncode(a.toJson()), jsonEncode(b.toJson()));
  });

  test('dispatch: nearest capable handler, ties to the lowest id', () {
    FloorHandler h(int id) =>
        FloorHandler(id: id, kind: HandlerKind.onFoot, at: const TilePos(0, 0));
    final hs = [h(1), h(2), h(3)];
    final dist = {1: 5, 2: 3, 3: 3};
    final q = [
      MoveRequest(item: 'tubes', count: 2, from: 10, to: 20),
      MoveRequest(item: 'ore', count: 1, from: 10, to: 20),
    ];
    Dispatcher.assign(q, hs,
        distTo: (h, _) => dist[h.id]!, routable: (_, _) => true);
    expect(hs[1].job?.count, 1, reason: '#2 and #3 tie at 3 tiles: #2 wins');
    expect(hs[2].job?.count, 1, reason: 'the split remainder goes to #3');
    expect(hs[0].job, isNull,
        reason: 'ore is a pallet load: the worker on foot is never sent');
    expect(q.single.item, 'ore', reason: 'it waits for a jack or forklift');
  });
}
