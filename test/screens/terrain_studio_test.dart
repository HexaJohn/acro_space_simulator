// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/infrastructure/flutter/screens/terrain_studio_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The terrain studio's way onto the ground: walking and driving are both
/// offered, and both wait for a site to be opened — there is no ground to
/// stand a walker or a buggy on before then.
void main() {
  testWidgets('walk and drive are offered, and need a site first', (t) async {
    await t.pumpWidget(const MaterialApp(home: TerrainStudioScreen()));
    await t.pump();

    for (final icon in [Icons.directions_walk, Icons.directions_car]) {
      final button = find.byIcon(icon);
      expect(button, findsOneWidget, reason: 'no way onto the ground: $icon');
      final w = t.widget<IconButton>(
          find.ancestor(of: button, matching: find.byType(IconButton)).first);
      expect(w.onPressed, isNull,
          reason: 'an unopened site has nothing to stand on: $icon');
    }
    expect(t.takeException(), isNull);
  });

  testWidgets('the dev hooks are registered while the studio lives',
      (t) async {
    await t.pumpWidget(const MaterialApp(home: TerrainStudioScreen()));
    await t.pump();
    expect(TerrainStudioDevHooks.status, isNotNull);
    expect(TerrainStudioDevHooks.drive, isNotNull);
    final s = TerrainStudioDevHooks.status!();
    expect(s['site'], isFalse);
    expect(s['rover'], isNull);

    await t.pumpWidget(const SizedBox());
    expect(TerrainStudioDevHooks.status, isNull,
        reason: 'a disposed studio must not leave hooks pointing at it');
  });
}
