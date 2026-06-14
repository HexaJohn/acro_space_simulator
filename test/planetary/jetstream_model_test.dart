import 'dart:math' as math;

import 'package:acro_space_simulator/domain/planetary/jetstream_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const model = JetstreamModel(bandCount: 3, peakSpeed: 30);

  double deg(double d) => d * math.pi / 180.0;

  test('wind alternates direction across latitude bands', () {
    // Sample band centres from equator to pole; consecutive bands flip sign.
    final centres = <double>[];
    for (var b = 0; b < model.bandCount; b++) {
      // Centre of band b sits at (b + 0.5)/bandCount of the way to the pole.
      final lat = (b + 0.5) / model.bandCount * (math.pi / 2);
      centres.add(model.zonalWindAt(lat));
    }
    for (var i = 1; i < centres.length; i++) {
      expect(centres[i].sign, isNot(centres[i - 1].sign),
          reason: 'band $i should oppose band ${i - 1}');
    }
  });

  test('equator and poles are handled (finite, within bounds)', () {
    final eq = model.zonalWindAt(0);
    final pole = model.zonalWindAt(deg(90));
    expect(eq.isFinite, isTrue);
    expect(pole.isFinite, isTrue);
    // Equator is a band centre (equatorial trades) -> full-strength wind.
    expect(eq.abs(), closeTo(model.peakSpeed, 1e-9));
    // Pole stays within bounds regardless of band count.
    expect(pole.abs(), lessThanOrEqualTo(model.peakSpeed + 1e-9));
  });

  test('hemispheres mirror: same |latitude| gives same wind', () {
    final north = model.zonalWindAt(deg(35));
    final south = model.zonalWindAt(deg(-35));
    expect(north, closeTo(south, 1e-12));
  });

  test('stronger peakSpeed -> proportionally stronger winds', () {
    const weak = JetstreamModel(bandCount: 3, peakSpeed: 10);
    const strong = JetstreamModel(bandCount: 3, peakSpeed: 30);
    final lat = deg(35);
    final w = weak.zonalWindAt(lat);
    final s = strong.zonalWindAt(lat);
    expect(w.abs(), greaterThan(0)); // not at a node
    expect(s, closeTo(w * 3.0, 1e-9)); // 3x peak -> 3x wind everywhere
  });

  test('wind magnitude never exceeds peakSpeed', () {
    for (var d = -90; d <= 90; d += 1) {
      expect(model.zonalWindAt(deg(d.toDouble())).abs(),
          lessThanOrEqualTo(model.peakSpeed + 1e-9));
    }
  });

  test('more bands -> more sign changes over the hemisphere', () {
    int signChanges(JetstreamModel m) {
      var changes = 0;
      var prev = m.zonalWindAt(deg(0.5)).sign;
      for (var d = 1; d <= 90; d++) {
        final s = m.zonalWindAt(deg(d.toDouble())).sign;
        if (s != 0 && s != prev) {
          changes++;
          prev = s;
        }
      }
      return changes;
    }

    expect(signChanges(const JetstreamModel(bandCount: 5, peakSpeed: 20)),
        greaterThan(signChanges(const JetstreamModel(bandCount: 2, peakSpeed: 20))));
  });
}
