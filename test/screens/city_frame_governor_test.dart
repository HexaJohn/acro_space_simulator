// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/infrastructure/flutter/screens/city_studio_screen.dart';
import 'package:flutter_test/flutter_test.dart';

/// The frame governor is a state machine fed p95 readings and a clock, and
/// nothing else — so the whole shed/restore sequence, and the hysteresis
/// that keeps it from flapping, can be walked through here without a frame.
void main() {
  const hot = 20.0; // over shedAboveMs
  const cool = 5.0; // under restoreBelowMs
  const band = 11.0; // between the two: hold

  /// Feed [p95] every [stepS] from [fromS] to [toS] inclusive, and return
  /// the levels seen after each feed.
  List<int> run(CityFrameGovernor g, double p95, double fromS, double toS,
      {double stepS = 0.25}) {
    final seen = <int>[];
    for (var t = fromS; t <= toS + 1e-9; t += stepS) {
      g.feed(p95, t);
      seen.add(g.level);
    }
    return seen;
  }

  test('one long reading sheds nothing; a second of them sheds one step', () {
    final g = CityFrameGovernor();
    expect(g.feed(hot, 0.0), isFalse);
    expect(g.level, 0);
    expect(g.feed(hot, 0.9), isFalse);
    expect(g.level, 0, reason: 'not yet a full second over the line');
    expect(g.feed(hot, 1.0), isTrue);
    expect(g.level, 1);
  });

  test('sheds one step per second over the line, in order, then holds', () {
    final g = CityFrameGovernor();
    run(g, hot, 0.0, 6.0);
    expect(g.level, CityFrameGovernor.maxLevel);
    // The sequence: each level held for a second before the next.
    final g2 = CityFrameGovernor();
    final levels = run(g2, hot, 0.0, 4.0, stepS: 1.0);
    expect(levels, [0, 1, 2, 3, 4]);
    // The steps map onto the knobs in the stated order.
    final g3 = CityFrameGovernor();
    expect(g3.shadowRangeScale, 1.0);
    g3.feed(hot, 0);
    g3.feed(hot, 1);
    expect(g3.level, 1);
    expect(g3.shadowRangeScale, 0.6);
    expect(g3.trafficScale, 1.0);
    g3.feed(hot, 2);
    expect(g3.trafficScale, 0.5);
    expect(g3.floraTreeScale, 1.0);
    g3.feed(hot, 3);
    expect(g3.floraTreeScale, 0.5);
    expect(g3.shadowsOff, isFalse);
    g3.feed(hot, 4);
    expect(g3.shadowsOff, isTrue);
    expect(g3.label, contains('shadows off'));
  });

  test('restores one step at a time, after two seconds under the floor', () {
    final g = CityFrameGovernor();
    run(g, hot, 0.0, 2.0, stepS: 1.0);
    expect(g.level, 2);
    // Cool from t=3: nothing until t=5, then one step per two seconds.
    expect(g.feed(cool, 3.0), isFalse);
    expect(g.feed(cool, 4.9), isFalse);
    expect(g.level, 2, reason: 'a restore needs two full seconds');
    expect(g.feed(cool, 5.0), isTrue);
    expect(g.level, 1);
    expect(g.feed(cool, 6.0), isFalse);
    expect(g.feed(cool, 7.0), isTrue);
    expect(g.level, 0);
    expect(g.feed(cool, 20.0), isFalse, reason: 'nothing below clear');
    expect(g.label, 'clear');
  });

  test('the band between the thresholds holds the level and resets the clocks',
      () {
    final g = CityFrameGovernor();
    run(g, hot, 0.0, 1.0, stepS: 1.0);
    expect(g.level, 1);
    // Half a second of cool, then a busy-but-fine reading, then cool again:
    // the restore clock must start over at the second cool reading, not
    // carry the half second across the band.
    g.feed(cool, 1.5);
    g.feed(band, 2.0);
    expect(g.level, 1);
    g.feed(cool, 2.5);
    g.feed(cool, 4.4);
    expect(g.level, 1, reason: 'only 1.9 s since the clock restarted');
    g.feed(cool, 4.5);
    expect(g.level, 0);
    // And the same for the shed clock: 0.9 s hot, a band reading, then hot
    // again — no shed until a fresh second.
    g.feed(hot, 5.0);
    g.feed(hot, 5.9);
    g.feed(band, 6.0);
    g.feed(hot, 6.5);
    g.feed(hot, 7.4);
    expect(g.level, 0);
    g.feed(hot, 7.5);
    expect(g.level, 1);
  });

  test('a shed does not undo itself on the frames that earned it', () {
    // After a shed the p95 window still holds the slow frames for a while;
    // the governor must not take a second step until a second has passed
    // SINCE the first, whatever the window says.
    final g = CityFrameGovernor();
    g.feed(hot, 0.0);
    g.feed(hot, 1.0);
    expect(g.level, 1);
    g.feed(hot, 1.5);
    expect(g.level, 1);
    g.feed(hot, 1.99);
    expect(g.level, 1);
    g.feed(hot, 2.0);
    expect(g.level, 2);
  });

  test('switched off, the level reads clear and nothing is shed', () {
    final g = CityFrameGovernor();
    run(g, hot, 0.0, 3.0, stepS: 1.0);
    expect(g.level, 3);
    g.enabled = false;
    expect(g.level, 0);
    expect(g.shadowsOff, isFalse);
    expect(g.trafficScale, 1.0);
    // Fed while off: still nothing, and switching back on starts over.
    run(g, hot, 4.0, 10.0);
    expect(g.level, 0);
    g.enabled = true;
    expect(g.level, 0);
    expect(g.feed(hot, 11.0), isFalse);
    expect(g.feed(hot, 12.0), isTrue);
    expect(g.level, 1);
  });

  test('a forced level pins the knobs and outranks the frame', () {
    final g = CityFrameGovernor();
    g.forcedLevel = 4;
    expect(g.level, 4);
    expect(g.shadowsOff, isTrue);
    run(g, cool, 0.0, 10.0);
    expect(g.level, 4, reason: 'cool frames do not release a pin');
    g.forcedLevel = 99;
    expect(g.level, CityFrameGovernor.maxLevel, reason: 'clamped');
    g.forcedLevel = null;
    expect(g.level, 0, reason: 'released, and nothing earned meanwhile');
  });

  test('the label names the steps in force', () {
    final g = CityFrameGovernor();
    expect(g.label, 'clear');
    g.forcedLevel = 2;
    expect(g.label, 'shadow range ×0.6, traffic ×0.5');
    expect(CityFrameGovernor.steps.length, CityFrameGovernor.maxLevel);
  });
}
