// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/app_theme.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_catalog_pane.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_editor_controller.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_staging_pane.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_stats_pane.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_tree_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Each inspector pane, alone, at every column width the screen can hand it,
/// with a craft ON it.
///
/// The screen's own layout tests pump the whole editor and therefore only ever
/// exercise the width its breakpoints choose — so a pane that overflows at 276
/// logical pixels is invisible to them until someone changes a constant. These
/// pump the panes directly at the narrow end, and with parts placed: an empty
/// design paints an eight-word placeholder and cannot overflow anything, which
/// is exactly how a readout row that only exists once there is something to read
/// stayed unnoticed.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PartCatalog catalog;
  late CraftEditorController editor;

  PartDef part(String id) => catalog.byId(id) ?? fail('no part "$id"');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    catalog = PartCatalog.standard();
    editor = CraftEditorController(catalog: catalog, craftName: 'Eagle');
  });
  tearDown(() => editor.dispose());

  /// A pod, a descent stage under it and four RCS quads round the ring — enough
  /// that every section of every pane has real content, including the per-stage
  /// budget rows and the symmetry-collapsed tree rows.
  void buildEagle() {
    editor.hold(part('eagle-command-pod'));
    expect(editor.placeRoot(), isTrue, reason: editor.blocked ?? '');
    final rootId = editor.design.rootId!;
    editor.hold(part('eagle-fuel-tank'));
    expect(
        editor.attachAt(editor.pairings.firstWhere(
            (p) => p.target.nodeName == 'stage-bottom')),
        isTrue,
        reason: editor.blocked ?? '');
    editor.hold(part('eagle-thruster'));
    expect(
        editor.attachAt(editor.pairings
            .firstWhere((p) => p.target.nodeName == 'engine-mount')),
        isTrue,
        reason: editor.blocked ?? '');
    editor.hold(part('eagle-rcs-block'));
    editor.setSymmetryCount(4);
    expect(
        editor.attachAt(editor.pairings.firstWhere((p) =>
            p.target.ownerInstanceId == rootId &&
            p.target.nodeName == 'quad-1')),
        isTrue,
        reason: editor.blocked ?? '');
    editor.clearHeld();
    expect(editor.autoStage(), isTrue);
    expect(editor.design.partCount, 7);
  }

  Future<void> pump(WidgetTester t, Widget pane, double width) async {
    // The surface IS the column, and it is tall on purpose: a scrolling pane
    // only builds what fits, so at a phone height the STAGING block sits below
    // the fold and a row that overflows there stays green forever.
    t.view.physicalSize = Size(width, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(backgroundColor: AppTheme.bg, body: pane),
    ));
    await t.pump();
  }

  // The band the screen can actually produce: 240 is the catalog column's floor
  // and 276 is what a 300 px inspector leaves its ListView children after the
  // pane's own 12 px padding — the width the STAGING header overflowed at.
  const widths = [240.0, 276.0, 300.0, 352.0, 380.0];

  group('the inspector panes fit the narrowest column the screen can give them',
      () {
    for (final w in widths) {
      testWidgets('the stats pane at ${w.toInt()} px', (t) async {
        buildEagle();
        await pump(t, CraftStatsPane(controller: editor), w);
        expect(t.takeException(), isNull);
      });

      testWidgets('the staging pane at ${w.toInt()} px', (t) async {
        buildEagle();
        await pump(t, CraftStagingPane(controller: editor), w);
        expect(t.takeException(), isNull);
      });

      testWidgets('the tree pane at ${w.toInt()} px', (t) async {
        buildEagle();
        await pump(t, CraftTreePane(controller: editor), w);
        expect(t.takeException(), isNull);
      });

      testWidgets('the catalog pane at ${w.toInt()} px', (t) async {
        await pump(t, CraftCatalogPane(controller: editor), w);
        expect(t.takeException(), isNull);
      });
    }
  });

  testWidgets('the stats pane still says what the numbers are when it is narrow',
      (t) async {
    // An ellipsis is only an acceptable answer if the value survives; the
    // headline the STAGING row carries is the total, so it must still be
    // readable at the narrow end rather than clipped to "total".
    buildEagle();
    await pump(t, CraftStatsPane(controller: editor), 276);
    expect(t.takeException(), isNull);
    expect(find.text('STAGING'), findsOneWidget);
    final total = CraftStatsPane.budgets(editor.design)
        .fold(0.0, (s, b) => s + b.deltaV);
    expect(find.text('total Δv ${total.toStringAsFixed(0)} m/s'), findsOneWidget);
  });
}
