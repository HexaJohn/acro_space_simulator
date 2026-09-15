// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_envelope.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_frame.dart';
import 'package:acro_space_simulator/domain/colony/city/spatial_index.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shared §6.1 helpers every R2 generator uses
/// (docs/plans/site-access.md §6.1 as built).
void main() {
  // A 24 × 32 m lot fronting y = 0, the frame's x east and y north.
  final frame = SiteFrame.of(
    const [Vec2(0, 0), Vec2(24, 0), Vec2(24, 32), Vec2(0, 32)],
    (const Vec2(24, 0), const Vec2(0, 0)),
    SegmentIndex(),
  )!;

  test('the frame is the lot', () {
    expect(frame.widthM, 24);
    expect(frame.toLocal(const Vec2(0, 32)).n, closeTo(32, 1e-9));
    expect(depthOver(frame.profile, 0, 23.9), closeTo(32, 1e-9));
  });

  test('largestFreeRect: the whole profile, then clear of a drive', () {
    final all = largestFreeRect(frame.profile, frame.widthM)!;
    expect(all.x0, closeTo(0, 1e-9));
    expect(all.x1, closeTo(24, 1e-9));
    expect(all.y0, closeTo(kDepthProfileMarginM, 1e-9));
    expect(all.y1, closeTo(32 - kDepthProfileMarginM, 1e-9));
    // A drive at x 1.5..7.5 from the kerb to y 12, cleared by 1 m: the strip
    // beside it (15.5 × 31.4) beats the band behind it (24 × 18.7).
    final free = largestFreeRect(frame.profile, frame.widthM,
        blocked: const [SiteRect(1.5, -3, 7.5, 12)], clearanceM: 1)!;
    expect(free.x0, closeTo(8.5, 1e-9));
    expect(free.x1, closeTo(24, 1e-9));
    expect(free.y0, closeTo(0.3, 1e-9));
    expect(free.y1, closeTo(31.7, 1e-9));
    // Inside side setbacks.
    final set = largestFreeRect(frame.profile, frame.widthM,
        xMin: kSideSetbackM, xMax: frame.widthM - kSideSetbackM)!;
    expect(set.x0, closeTo(1.5, 1e-9));
    expect(set.x1, closeTo(22.5, 1e-9));
  });

  test('fitFootprint centres across, front-aligned; refuses under 8 m or '
      'A_min', () {
    const free = SiteRect(1.5, 4, 22.5, 29);
    final fit = fitFootprint(free, 10, 12)!;
    expect(fit.x0, 7);
    expect(fit.x1, 17);
    expect(fit.y0, 4);
    expect(fit.y1, 16);
    expect(fitFootprint(free, 7.9, 12), isNull);
    expect(fitFootprint(free, 10, 12, minArea: 121), isNull);
    // Overfilled: the free rectangle.
    final whole = fitFootprint(free, 100, 100)!;
    expect(whole.width, 21);
    expect(whole.depth, 25);
  });

  test('door and lamps', () {
    expect(envelopeDoor(const SiteEnvelope(2, 5, 12, 20)), (7.0, 5.0));
    expect(lampsAlong(0, 60, 16.7), [(12.5, 16.7), (37.5, 16.7)]);
    expect(lampsAlong(0, 10, 0), isEmpty);
  });
}
