import 'dart:math' as math;

import 'package:acro_space_simulator/domain/planetary/season_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const tilt = 0.41; // ~23.4 deg, Earth-like
  const model = SeasonModel(axialTilt: tilt);

  double deg(double d) => d * math.pi / 180.0;

  test('subsolar latitude swings between +tilt and -tilt across the year', () {
    var minLat = double.infinity;
    var maxLat = double.negativeInfinity;
    for (var i = 0; i <= 360; i++) {
      final lat = model.subsolarLatitude(i / 360.0);
      minLat = math.min(minLat, lat);
      maxLat = math.max(maxLat, lat);
    }
    expect(maxLat, closeTo(tilt, 1e-3));
    expect(minLat, closeTo(-tilt, 1e-3));
  });

  test('summer and winter solstices hit the extremes', () {
    // Convention: phase 0.5 -> northern summer (+tilt), phase 0 -> -tilt.
    expect(model.subsolarLatitude(0.5), closeTo(tilt, 1e-9));
    expect(model.subsolarLatitude(0.0), closeTo(-tilt, 1e-9));
  });

  test('equinoxes give subsolar latitude ~0', () {
    expect(model.subsolarLatitude(0.25), closeTo(0.0, 1e-9));
    expect(model.subsolarLatitude(0.75), closeTo(0.0, 1e-9));
  });

  test('a zero-tilt planet has no seasons (subsolar latitude always 0)', () {
    const flat = SeasonModel(axialTilt: 0);
    expect(flat.hasNoSeasons, isTrue);
    for (var i = 0; i <= 100; i++) {
      expect(flat.subsolarLatitude(i / 100.0), closeTo(0.0, 1e-12));
    }
  });

  test('insolation factor is in [0,1] and peaks when sun is overhead', () {
    // Northern summer solstice: sun overhead at +tilt.
    final atSubsolar = model.insolationFactor(tilt, 0.5);
    expect(atSubsolar, closeTo(1.0, 1e-9));

    for (var i = 0; i <= 50; i++) {
      final f = model.insolationFactor(deg(40), i / 50.0);
      expect(f, inInclusiveRange(0.0, 1.0));
    }
  });

  test('insolation: summer hemisphere is warmer than winter hemisphere', () {
    // Northern summer (phase 0.5): +40 deg gets more sun than -40 deg.
    final north = model.insolationFactor(deg(40), 0.5);
    final south = model.insolationFactor(deg(-40), 0.5);
    expect(north, greaterThan(south));
  });

  test('zero-tilt planet has constant insolation through the year', () {
    const flat = SeasonModel(axialTilt: 0);
    final a = flat.insolationFactor(deg(30), 0.0);
    final b = flat.insolationFactor(deg(30), 0.5);
    expect(a, closeTo(b, 1e-12));
  });
}
