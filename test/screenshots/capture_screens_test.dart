// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Captures the GAME SCREENS (not just the orbit painter) to PNGs for the
// release / docs gallery. Pumps each full screen widget, lets its ticker settle
// a few frames, then snapshots the render tree via a RepaintBoundary.
//
//   flutter test test/screenshots/capture_screens_test.dart
//
// Not a behavioural test — it writes release/screenshots/screen_*.png.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:acro_space_simulator/domain/craft/craft_design.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_builder_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_editor_controller.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_editor_viewport.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft_assembly_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/main_menu_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _shoot(
  WidgetTester t,
  Widget screen,
  String path, {
  Size size = const Size(1280, 800),
}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);

  final key = GlobalKey();
  await t.pumpWidget(RepaintBoundary(
    key: key,
    child: MaterialApp(home: screen),
  ));
  // Let animated screens (tickers) draw a few frames.
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }

  await t.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.0);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

void main() {
  testWidgets('capture: main menu', (t) async {
    await _shoot(t, const MainMenuScreen(), 'release/screenshots/screen_menu.png');
  });
  testWidgets('capture: city builder', (t) async {
    await _shoot(
        t, const CityBuilderScreen(), 'release/screenshots/screen_city.png');
  });
  testWidgets('capture: craft assembly (VAB)', (t) async {
    await _shoot(t, const CraftAssemblyScreen(),
        'release/screenshots/screen_vab.png');
  });
  // The VAB is the only screen that changes SHAPE rather than reflowing, so the
  // gallery needs both: side-by-side panes at desk width, and the 3D view
  // stacked over a tabbed sheet on a phone.
  testWidgets('capture: craft assembly (VAB), narrow', (t) async {
    await _shoot(t, const CraftAssemblyScreen(),
        'release/screenshots/screen_vab_narrow.png',
        size: const Size(420, 840));
  });
  // ...and one shot of the editor with something ON it. An empty VAB is an
  // honest picture of the screen and a useless picture of the feature: the
  // attach markers, the symmetry ring, the balance readout and the selection
  // outline only exist once a craft does.
  testWidgets('capture: craft editor with the Eagle assembled', (t) async {
    const size = Size(1280, 800);
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final controller = CraftEditorController(
        catalog: PartCatalog.standard(), design: _eagle());
    addTearDown(controller.dispose);
    final viewportKey = GlobalKey<CraftEditorViewportState>();
    final key = GlobalKey();

    await t.pumpWidget(RepaintBoundary(
      key: key,
      child: MaterialApp(
        // This one is a picture of the VIEW, not of the app chrome, so the
        // debug ribbon across the corner is noise the gallery does not want.
        debugShowCheckedModeBanner: false,
        home: CraftEditorViewport(
          key: viewportKey,
          controller: controller,
          // Headless there is no asset bundle worth warming, and the bakes
          // would only be parses this capture then had to wait on.
          prewarmModels: false,
        ),
      ),
    ));
    await t.pump();
    // The camera only auto-frames when the design CHANGES; this one arrived
    // already built, so the gallery has to ask.
    viewportKey.currentState!.frameCraft();
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }

    await t.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 1.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final file = File('release/screenshots/screen_vab_editor.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes!.buffer.asUint8List());
    });
  });
}

/// The flown Apollo Lunar Module, built straight through the domain.
///
/// The gallery wants the craft the part catalog was authored for, and building
/// it here rather than by tapping keeps the picture independent of the input
/// map: a change to picking can make this shot uglier, never absent.
CraftDesign _eagle() {
  final catalog = PartCatalog.standard();
  final design = CraftDesign(name: 'Eagle');
  design.addPart(
      def: catalog.byId('eagle-command-pod')!,
      instanceId: 'ascent',
      position: Vector3.zero);
  design.attachPart(
    def: catalog.byId('eagle-fuel-tank')!,
    instanceId: 'descent',
    toInstanceId: 'ascent',
    parentNode: 'stage-bottom',
    childNode: 'deck-top',
  );
  design.attachPart(
    def: catalog.byId('eagle-thruster')!,
    instanceId: 'dps',
    toInstanceId: 'descent',
    parentNode: 'engine-mount',
    childNode: 'mount',
  );
  for (var i = 1; i <= 4; i++) {
    design.attachPart(
      def: catalog.byId('eagle-legs')!,
      instanceId: 'leg-$i',
      toInstanceId: 'descent',
      parentNode: 'leg-$i',
      childNode: 'outrigger',
    );
    design.attachPart(
      def: catalog.byId('eagle-rcs-block')!,
      instanceId: 'quad-$i',
      toInstanceId: 'ascent',
      parentNode: 'quad-$i',
      childNode: 'mount',
    );
  }
  return design;
}
