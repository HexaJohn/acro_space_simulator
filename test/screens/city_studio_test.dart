// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/infrastructure/flutter/screens/city_studio_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The studio's control panel, laid out end to end.
///
/// A [ListTile] paints its background and ink onto the nearest [Material]
/// ancestor, so putting a coloured box between the two makes Flutter assert —
/// on EVERY frame, which buries the console. It is an easy mistake to make
/// (a `Container(color:)` is the obvious way to tint a panel) and this project
/// has now made it twice: once in the in-world editor's readout drawer and
/// once here.
///
/// The plain smoke test does not catch it, because the offending tile sits far
/// enough down a scrolling list that it never gets built. This one scrolls to
/// the bottom, which is what forces the tile to lay out.
void main() {
  testWidgets('the control panel lays out without assertions', (t) async {
    await t.pumpWidget(const MaterialApp(home: CityStudioScreen()));
    await t.pump();

    final list = find.byType(ListView);
    expect(list, findsWidgets);

    // Drag the controls to the end, building every tile on the way, and note
    // which switches were seen. Counting them at the BOTTOM would not work:
    // a ListView unbuilds what has scrolled off, so the tiles higher up are
    // gone by the time the last one arrives.
    final seen = <String>{};
    for (var i = 0; i < 40; i++) {
      await t.drag(list.last, const Offset(0, -260));
      await t.pump();
      expect(t.takeException(), isNull,
          reason: 'a widget in the control panel asserted while laying out — '
              'a ListTile inside a coloured box is the usual cause');
      for (final e in t.widgetList<SwitchListTile>(find.byType(SwitchListTile))) {
        final title = e.title;
        if (title is Text && title.data != null) seen.add(title.data!);
      }
    }

    // The switches are the tiles in question; all must be reachable.
    expect(
        seen,
        containsAll(<String>[
          'Road traffic',
          'Street furniture',
          'LOD visualiser',
          'Per-building LOD',
          'Alleys',
          'On-street parking',
          'Fences, signs, car parks',
          'Scale reference',
          'Terrain',
          'City (all of it)',
        ]));
  });

  testWidgets('it opens on its own scene, not the flight universe', (t) async {
    await t.pumpWidget(const MaterialApp(home: CityStudioScreen()));
    await t.pump();
    // Controls are there from the start; the preview says what to do next.
    expect(find.text('WORLD'), findsOneWidget);
    expect(find.text('LAYOUT'), findsOneWidget);
    expect(find.textContaining('GENERATE'), findsNothing,
        reason: 'the button sits below the fold until the list is scrolled');
    expect(t.takeException(), isNull);
  });

  testWidgets('walking the streets is offered, and needs a colony first',
      (t) async {
    await t.pumpWidget(const MaterialApp(home: CityStudioScreen()));
    await t.pump();

    final walk = find.byIcon(Icons.directions_walk);
    expect(walk, findsOneWidget, reason: 'no way onto the pavement');
    // Disabled until there is something to walk around in: on foot the eye is
    // placed off the colony's OWN ground, and there is no ground to sample
    // before a colony has been generated.
    final button = t.widget<IconButton>(
        find.ancestor(of: walk, matching: find.byType(IconButton)).first);
    expect(button.onPressed, isNull,
        reason: 'walking an ungenerated colony has nothing to stand on');
    expect(t.takeException(), isNull);
  });
}

// NOT TESTED HERE: what the walker SEES. Placing the eye needs the terrain
// field the colony was cut into, which needs a generated colony, which needs a
// GPU — so the height sampling, the mouse-look basis and the WASD stepping are
// all verified by walking it. What a widget test can hold is that the way in
// exists and is gated on there being ground to stand on.

// NOT TESTED HERE: that the scene-resource future is created once rather than
// per build. It is the bug that left the preview spinning forever — a
// FutureBuilder compares futures by identity, and this screen rebuilds off a
// ticker — but it cannot be observed in a widget test: `Scene`'s static
// resources and the terrain shader never resolve without a GPU, so the gate
// sits in its waiting state either way and a test written against it passes on
// the broken code too. Guarded by review instead: build the future in a field,
// never in `build`.
