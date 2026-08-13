// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The debug panel's SPAWN section, driven the way a user drives it: open the
// panel, tap a preset, and read the result back off the flight status row.
import 'package:acro_space_simulator/infrastructure/flutter/simulation_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> openDebugPanel(WidgetTester t) async {
    // A tall surface: the FAB stack has to be fully laid out to reach the bug
    // button, and the panel itself is long.
    t.view.physicalSize = const Size(1400, 2000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(const MaterialApp(home: SimulationView()));
    await t.pump(const Duration(milliseconds: 16));
    await t.tap(find.byIcon(Icons.bug_report));
    await t.pump();
  }

  /// 'ALT 123.4km · 567 m/s · STAGE 1/1' -> 123.4
  double altitudeKm(WidgetTester t) {
    final line = t
        .widgetList<Text>(find.textContaining('ALT '))
        .map((w) => w.data!)
        .first;
    return double.parse(RegExp(r'ALT ([-\d.]+)km').firstMatch(line)!.group(1)!);
  }

  testWidgets('the panel lists every spawn preset', (t) async {
    await openDebugPanel(t);
    expect(find.text('SPAWN'), findsOneWidget);
    expect(find.text('Earth surface'), findsOneWidget);
    expect(find.text('Earth ocean'), findsOneWidget);
    expect(find.text('Low Earth orbit'), findsOneWidget);
    expect(find.text('Landed — Moon'), findsOneWidget);
    expect(find.text('Low lunar orbit'), findsOneWidget);
    expect(find.text('Inside Saturn rings'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('an orbit preset puts the craft at that altitude', (t) async {
    await openDebugPanel(t);
    await t.tap(find.text('Low Earth orbit'));
    await t.pump();
    expect(altitudeKm(t), closeTo(400, 0.1));
    expect(t.takeException(), isNull);
  });

  testWidgets('a surface preset lands the craft (FOUND colony offered)',
      (t) async {
    await openDebugPanel(t);
    expect(find.text('FOUND'), findsNothing); // starts in lunar orbit
    await t.tap(find.text('Earth surface'));
    await t.pump();
    expect(find.text('FOUND'), findsOneWidget);
    // On the ground: within Earth's ±4.5 km of relief, not out in space.
    expect(altitudeKm(t).abs(), lessThan(5));
    expect(t.takeException(), isNull);
  });

  testWidgets('the ring preset flies out to Saturn', (t) async {
    await openDebugPanel(t);
    await t.tap(find.text('Inside Saturn rings'));
    await t.pump();
    // 1.55 Saturn radii => ~32,000 km above the cloud tops.
    expect(altitudeKm(t), closeTo(0.55 * 58232, 10));
    expect(t.takeException(), isNull);
  });
}
