// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The calibration gate (docs/plans/combat.md §7I): live and abstract fights
/// of the three reference scenarios, compared.
///
///   fvm dart run bin/combat_calibrate.dart            # report
///   fvm dart run bin/combat_calibrate.dart --gate     # and fail past ±10%
///   fvm dart run bin/combat_calibrate.dart --seeds=16
library;

import 'dart:io';

import 'package:acro_space_simulator/domain/combat/live/calibration_scenarios.dart';

void main(List<String> args) {
  final gate = args.contains('--gate');
  final seedsArg = args.where((a) => a.startsWith('--seeds=')).firstOrNull;
  final seeds = int.tryParse(seedsArg?.substring('--seeds='.length) ?? '') ?? 8;
  final rows = calibrateAll(seeds: seeds);
  var ok = true;
  for (final r in rows) {
    final pass = r.passes(0.10);
    ok = ok && pass;
    stdout.writeln('${pass ? 'PASS' : 'FAIL'}  $r');
  }
  if (gate && !ok) {
    stderr.writeln('Calibration gate failed: live and abstract disagree by more than 10%.');
    exit(1);
  }
}
