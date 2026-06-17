// Captures the GAME SCREENS (not just the orbit painter) to PNGs for the
// release / docs gallery. Pumps each full screen widget, lets its ticker settle
// a few frames, then snapshots the render tree via a RepaintBoundary.
//
//   flutter test test/screenshots/capture_screens_test.dart
//
// Not a behavioural test — it writes release/screenshots/screen_*.png.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:acro_space_simulator/infrastructure/flutter/screens/city_builder_screen.dart';
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
}
