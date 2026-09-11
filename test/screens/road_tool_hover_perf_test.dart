// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/city_config.dart';
import 'package:acro_space_simulator/domain/colony/city/city_starter_kit.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_edit_overlay.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/road_tool_scene.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/road_overlay_state.dart';
import 'package:flutter_test/flutter_test.dart';

/// The road tool's hover runs on every mouse move (thirty times a second
/// at most): snap the cursor against the town's roads, shape the stretch,
/// price it over the ground, lay the ghost. Once the ground is warm it has
/// to fit in a sliver of a frame — the budget is ~2 ms in a release build;
/// a debug test run is several times slower, so the bound here is loose and
/// the figure is printed.
void main() {
  tearDown(RoadOverlayState.instance.clear);

  test('a warm hover — snap, shape, quote, ghost — fits in a frame', () {
    final city = CityStarterKit.found(
      bodies: RealSolarSystem.build().all.where((b) => !b.isStar).toList(),
      config: const CityConfig(bodyId: 'earth', latitude: 12, longitude: 20),
      id: 'perf',
    )..funds = 1e6;
    expect(city.layout.roads, isNotEmpty);
    // A sloping ground, so the survey has work to do.
    final scene = RoadToolScene()
      ..bindCustom(
        bodyId: 'earth',
        toBodyFixed: (p, h) => Vector3(p.e, p.n, 6.371e6 + h),
        height: (p) => 0.04 * p.e - 0.02 * p.n,
      );
    // Every snapping option on, as a player has it.
    final c = CityEditController()..set(CityEditTool.roadSpline);
    c.clickAt(city, const Vec2(60, 60), ground: scene.exactHeightAt);
    c.stepElevation(1);

    void hover(int i) {
      final p = Vec2(60 + (i % 60) * 7.0, 320 + (i ~/ 60) * 9.0);
      c.previewTo(city, p, ground: scene.heightAt, scale: 2.5);
      scene.showRoadTool(city, c, pxM: 2.5);
    }

    for (var i = 0; i < 40; i++) {
      hover(i);
    }
    const n = 300;
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      hover(i);
    }
    final ms = sw.elapsedMicroseconds / n / 1000;
    // ignore: avoid_print
    print('road tool hover: ${ms.toStringAsFixed(3)} ms per move '
        '(${RoadOverlayState.instance.ghostBF.length} ghost points)');
    expect(RoadOverlayState.instance.ghostBF, isNotEmpty);
    expect(ms, lessThan(8.0));
  });
}
