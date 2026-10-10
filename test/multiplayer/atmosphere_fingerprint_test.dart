// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/planetary/atmospheric_composition.dart';
import 'package:acro_space_simulator/infrastructure/bridge/sim_host.dart';
import 'package:flutter_test/flutter_test.dart';

/// A body's gas inventory decides the air every craft in its sky flies
/// through, so it is world state the determinism fingerprint has to cover
/// (docs/plans/terraforming.md §5.6).
void main() {
  test('the authoritative host ships every body\'s inventory', () {
    final host = SimHost.sample();
    host.step();
    final snap = host.sim.snapshot();
    expect(snap.atmospheres.map((a) => a.body),
        containsAll(['earth', 'mars', 'venus', 'titan']));
    // Body-id order, whatever order the system lists them in.
    final ids = snap.atmospheres.map((a) => a.body).toList();
    expect(ids, [...ids]..sort());
  });

  test('two hosts agree; one whose air diverged does not', () {
    final a = SimHost.sample();
    final b = SimHost.sample();
    a.step();
    b.step();
    expect(a.sim.snapshot().fingerprint, b.sim.snapshot().fingerprint);

    b.sim.advance.atmosphere.forBody('mars')!.add(AtmosphereGas.oxygen, 1e12);
    expect(a.sim.snapshot().fingerprint,
        isNot(b.sim.snapshot().fingerprint),
        reason: 'a client whose Mars is thicker flies a different reentry');
  });

  test('the inventory survives the snapshot\'s JSON round-trip', () {
    final host = SimHost.sample();
    host.sim.advance.atmosphere.forBody('mars')!
        .add(AtmosphereGas.oxygen, 3e17);
    final snap = host.sim.snapshot();
    final back = WorldSnapshot.fromJson(
        jsonDecode(jsonEncode(snap.toJson())) as Map<String, dynamic>);
    expect(back.fingerprint, snap.fingerprint);
    expect(back.atmospheres.length, snap.atmospheres.length);
  });
}
