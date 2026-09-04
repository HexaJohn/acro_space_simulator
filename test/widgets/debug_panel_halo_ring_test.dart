// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The halo ring's kill switch, driven through the real debug panel.
//
// `HaloRingNodes.enabled` has always existed and its doc comment has always
// called it a "debug panel / dev ext" switch — but nothing referenced it, so
// there was no way to actually turn the ring off. This pins the row that makes
// the comment true, alongside the Gravity grid row it sits next to.

import 'package:acro_space_simulator/infrastructure/flutter/simulation_view.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/halo_ring_nodes.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/register_baked_dems.dart';

void main() {
  testWidgets('debug panel Halo ring row toggles the kill switch', (t) async {
    registerBakedDemsForTest();
    HaloRingNodes.enabled = true;
    addTearDown(() => HaloRingNodes.enabled = true);
    t.view.physicalSize = const Size(1200, 1800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    await t.pumpWidget(const MaterialApp(home: SimulationView()));
    await t.pump(const Duration(milliseconds: 400));

    await t.tap(find.byIcon(Icons.bug_report));
    await t.pump();

    final row = find.text('Halo ring');
    expect(row, findsOneWidget, reason: 'panel should show the row');
    await t.ensureVisible(row);
    await t.pump();

    await t.tap(row);
    await t.pump();
    expect(HaloRingNodes.enabled, isFalse, reason: 'one tap turns it off');

    await t.tap(row);
    await t.pump();
    expect(HaloRingNodes.enabled, isTrue, reason: 'and back on');
  });
}
