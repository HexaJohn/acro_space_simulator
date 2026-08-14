// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:acro_space_simulator/adapters/presenters/top_down_snapshot.dart';
import 'package:acro_space_simulator/infrastructure/flutter/debug_layers.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/scene_hud_overlay.dart';

/// The 3D-backend HUD overlay must draw the SOI debug rings ([DebugLayers.showSoi])
/// — it's the only painter running in scene mode, so if it skips them the debug
/// option silently does nothing there (the original bug).
void main() {
  const size = Size(600, 400);
  const soiPx = 120.0;

  Future<ui.Image> render(WidgetTester t, DebugLayers layers) async {
    final snapshot = TopDownSnapshot(
      bodies: [
        const BodyView('Earth', 0, 0, 6.371e6, false, soiRadiusPx: soiPx),
      ],
      vessels: const [],
      hud: const HudView([]),
    );
    final painter = SceneHudOverlayPainter(
      snapshot,
      const OrthoCamera(CameraOrbit.top, 1e6),
      layers: layers,
    );
    final key = GlobalKey();
    await t.pumpWidget(MaterialApp(
      home: RepaintBoundary(
        key: key,
        child: Container(
          color: Colors.black,
          child: CustomPaint(size: size, painter: painter),
        ),
      ),
    ));
    await t.pump();
    late ui.Image image;
    await t.runAsync(() async {
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      image = await boundary.toImage(pixelRatio: 1.0);
    });
    return image;
  }

  // Max green-channel value in a small window on the ring's rightmost point
  // (angle 0 — the first dash, always drawn).
  Future<int> ringGreen(WidgetTester t, ui.Image image, Size painted) async {
    final data = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!;
    final w = image.width;
    final cx = (painted.width / 2).round(), cy = (painted.height / 2).round();
    var maxG = 0;
    for (var dx = -2; dx <= 2; dx++) {
      final x = cx + soiPx.round() + dx;
      final g = data.getUint8((cy * w + x) * 4 + 1);
      if (g > maxG) maxG = g;
    }
    return maxG;
  }

  testWidgets('scene HUD overlay draws the SOI ring when showSoi is on',
      (t) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    final on = await render(t, const DebugLayers(showSoi: true));
    late int gOn;
    await t.runAsync(() async => gOn = await ringGreen(t, on, size));
    expect(gOn, greaterThan(20),
        reason: 'showSoi on -> a dashed ring pixel at the SOI radius');

    final off = await render(t, const DebugLayers());
    late int gOff;
    await t.runAsync(() async => gOff = await ringGreen(t, off, size));
    expect(gOff, 0, reason: 'showSoi off -> no ring');
  });
}
