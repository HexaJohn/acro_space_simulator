// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The scalability slider, driven through the real OptionsScreen.
//
// The point of the feature is that dragging it changes what the render passes
// do, so the assertions are on GraphicsQuality — the statics cloud_nodes,
// atmosphere_nodes and environment_baker actually read — rather than on the
// widget's own state.

import 'package:acro_space_simulator/infrastructure/flutter/screens/options_screen.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/graphics_quality.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GraphicsQuality.reset();
  });
  tearDown(GraphicsQuality.reset);

  Future<void> pump(WidgetTester t) async {
    await t.pumpWidget(const MaterialApp(home: OptionsScreen()));
    await t.pumpAndSettle();
  }

  /// The master slider is the first one on the screen — the quality block is
  /// rendered above every other section.
  Finder masterSlider() => find.byType(Slider).first;

  testWidgets('dragging the master preset moves what the shaders read',
      (t) async {
    await pump(t);
    expect(GraphicsQuality.master, QualityLevel.high);

    // Drag left: 3 divisions across the track, so a full-width drag left lands
    // on Low regardless of the exact track geometry.
    await t.drag(masterSlider(), const Offset(-500, 0));
    await t.pumpAndSettle();

    expect(GraphicsQuality.master, QualityLevel.low);
    expect(GraphicsQuality.clouds.viewSampleCap,
        CloudQuality.low.viewSampleCap);
    expect(GraphicsQuality.lighting.atmoViewSamples,
        LightingQuality.low.atmoViewSamples);
    expect(GraphicsQuality.lighting.envBakeWidth, 96);
  });

  testWidgets('the preset persists', (t) async {
    await pump(t);
    await t.drag(masterSlider(), const Offset(-500, 0));
    await t.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    expect(prefs.getString(GraphicsQuality.masterKey), QualityLevel.low.name);

    // And comes back on the next launch, through the same decode main() uses.
    GraphicsQuality.reset();
    GraphicsQuality.applyPrefs({
      GraphicsQuality.masterKey: prefs.getString(GraphicsQuality.masterKey),
      GraphicsQuality.cloudKey: prefs.getString(GraphicsQuality.cloudKey),
      GraphicsQuality.lightingKey:
          prefs.getString(GraphicsQuality.lightingKey),
    });
    expect(GraphicsQuality.master, QualityLevel.low);
  });

  testWidgets('per-feature overrides are behind a disclosure and work',
      (t) async {
    await pump(t);
    // Closed by default when nothing is overridden. (The screen has other,
    // unrelated sliders below, so this asks for the rows by name rather than
    // counting Slider widgets.)
    expect(find.text('Cloud quality'), findsNothing);
    expect(find.text('Lighting quality'), findsNothing);

    await t.tap(find.text('Per-feature overrides'));
    await t.pumpAndSettle();
    expect(find.text('Cloud quality'), findsOneWidget);
    expect(find.text('Lighting quality'), findsOneWidget);

    // Turn clouds down without touching lighting.
    final cloudSlider = find.byType(Slider).at(1);
    await t.drag(cloudSlider, const Offset(-500, 0));
    await t.pumpAndSettle();

    expect(GraphicsQuality.cloudLevel, QualityLevel.low);
    expect(GraphicsQuality.lightingLevel, QualityLevel.high,
        reason: 'lighting must still follow the master');
    expect(find.text('CUSTOM'), findsOneWidget);
  });

  testWidgets('"Follow preset" clears the overrides', (t) async {
    GraphicsQuality.cloudOverride = QualityLevel.low;
    await pump(t);
    // Opens itself when the stored settings are already custom.
    expect(find.text('Cloud quality'), findsOneWidget);

    await t.tap(find.text('Follow preset'));
    await t.pumpAndSettle();

    expect(GraphicsQuality.cloudOverride, isNull);
    expect(GraphicsQuality.cloudLevel, GraphicsQuality.master);
    expect(find.text('CUSTOM'), findsNothing);
  });

  testWidgets('moving the master after an override actually lowers quality',
      (t) async {
    // The trap the master exists to avoid: a stale Ultra override surviving a
    // drag to Low, so the user turns everything down and nothing gets faster.
    GraphicsQuality.cloudOverride = QualityLevel.ultra;
    await pump(t);

    await t.drag(masterSlider(), const Offset(-500, 0));
    await t.pumpAndSettle();

    expect(GraphicsQuality.master, QualityLevel.low);
    expect(GraphicsQuality.cloudLevel, QualityLevel.low);
    expect(GraphicsQuality.clouds.worstCaseSamples,
        CloudQuality.low.worstCaseSamples);
  });

  testWidgets('the screen names the cost the preset is actually buying',
      (t) async {
    await pump(t);
    await t.tap(find.text('Per-feature overrides'));
    await t.pumpAndSettle();
    // High is the baseline, so it carries no ratio.
    expect(find.textContaining('40 view x 5 light samples'), findsOneWidget);
    expect(find.textContaining('256x128'), findsOneWidget);

    await t.drag(find.byType(Slider).at(1), const Offset(-500, 0));
    await t.pumpAndSettle();
    expect(find.textContaining('cheaper than High'), findsOneWidget);
    // Low is the simplified technique, and the screen says so. (The master
    // help also mentions "no raymarch", so match the cost line's fuller
    // phrasing.)
    expect(find.textContaining('Textured shell — no raymarch'), findsOneWidget);
  });
}
