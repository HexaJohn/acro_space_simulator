// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/combat/live/calibration.dart';
import 'package:acro_space_simulator/domain/combat/live/calibration_scenarios.dart';
import 'package:flutter_test/flutter_test.dart';

/// The calibration gate (combat.md §7I): live and abstract agree within ±10%
/// on the three reference scenarios (the same rows `bin/combat_calibrate.dart`
/// prints).
void main() {
  final rows = <CalibrationRow>[];
  tearDownAll(() {
    // ignore: avoid_print
    print('Calibration:\n  ${rows.join('\n  ')}');
  });

  for (final (name, build) in kCalibrationScenarios) {
    test(name, () {
      final r = calibrate(name, build);
      rows.add(r);
      expect(r.passes(0.10), isTrue, reason: '$r');
    });
  }
}
