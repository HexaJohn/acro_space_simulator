// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/infrastructure/flutter/screens/city_plat_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The plat view's camera: colony metres to screen and back, zoom about a
/// point, and the scale ladder that decides what gets drawn.
void main() {
  const size = Size(800, 600);

  test('screen and colony metres round-trip, north up', () {
    final cam = CityPlatCamera(centreE: 100, centreN: -50, metresPerPx: 2);
    final centre = cam.toLocal(const Offset(400, 300), size);
    expect(centre.e, 100);
    expect(centre.n, -50);
    // Ten pixels right is 20 m east; ten pixels up is 20 m NORTH.
    final p = cam.toLocal(const Offset(410, 290), size);
    expect(p.e, closeTo(120, 1e-9));
    expect(p.n, closeTo(-30, 1e-9));
    final back = cam.toScreen(p.e, p.n, size);
    expect(back.dx, closeTo(410, 1e-9));
    expect(back.dy, closeTo(290, 1e-9));
  });

  test('zooming about a point keeps that point under the cursor', () {
    final cam = CityPlatCamera(centreE: 0, centreN: 0, metresPerPx: 4);
    const at = Offset(600, 100);
    final before = cam.toLocal(at, size);
    cam.zoomAbout(0.5, at, size);
    expect(cam.metresPerPx, 2);
    final after = cam.toLocal(at, size);
    expect(after.e, closeTo(before.e, 1e-9));
    expect(after.n, closeTo(before.n, 1e-9));
    expect(cam.centreE, isNot(0), reason: 'the centre moved to hold the point');
  });

  test('zoom is clamped at both ends', () {
    final cam = CityPlatCamera(metresPerPx: 1);
    cam.zoomAbout(1e-6, const Offset(400, 300), size);
    expect(cam.metresPerPx, 0.05);
    cam.zoomAbout(1e9, const Offset(400, 300), size);
    expect(cam.metresPerPx, 500);
  });

  test('fit asks for a re-placement on the next layout', () {
    final cam = CityPlatCamera(centreE: 5, centreN: 5, metresPerPx: 3);
    cam.fit(9000);
    expect(cam.metresPerPx, 0);
    expect(cam.fitM, 9000);
    expect(cam.centreE, 0);
    expect(cam.centreN, 0);
  });

  test('the scale ladder: county, district, street', () {
    // A lot is worth drawing once it is a few pixels across (30 m lot,
    // under ~7 m/px); a street once it is about a pixel wide.
    expect(PlatLod.forScale(100), PlatLod.county);
    expect(PlatLod.forScale(25), PlatLod.county);
    expect(PlatLod.forScale(20), PlatLod.district);
    expect(PlatLod.forScale(8), PlatLod.district);
    expect(PlatLod.forScale(6), PlatLod.street);
    expect(PlatLod.forScale(0.5), PlatLod.street);
  });
}
