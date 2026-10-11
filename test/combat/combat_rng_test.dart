// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:io';

import 'package:acro_space_simulator/domain/colony/city/traffic/traffic_rng.dart' as traffic;
import 'package:acro_space_simulator/domain/combat/combat_rng.dart';
import 'package:acro_space_simulator/domain/combat/defender_sizing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('rolls are pure functions of what they are about', () {
    expect(combatRoll32(7, 1, 2), combatRoll32(7, 1, 2));
    expect(combatRoll32(7, 1, 2), isNot(combatRoll32(7, 1, 3)));
    expect(combatRoll32(7, 1, 2), isNot(combatRoll32(8, 1, 2)));
  });

  test('signed rolls fill [-1, 1) with mean near 0', () {
    var sum = 0.0, lo = 1.0, hi = -1.0;
    for (var i = 0; i < 20000; i++) {
      final u = combatSigned(42, i, 0);
      sum += u;
      if (u < lo) lo = u;
      if (u > hi) hi = u;
    }
    expect(sum / 20000, closeTo(0, 0.02));
    expect(lo, greaterThanOrEqualTo(-1));
    expect(hi, lessThan(1));
    expect(lo, lessThan(-0.99));
    expect(hi, greaterThan(0.99));
  });

  test('the objective key is the traffic FNV-1a, bit for bit', () {
    for (final s in ['port', 'lz', 'seat-7', 'Ünïcode', '']) {
      expect(combatKey(s), traffic.fnv1a32(s));
    }
  });

  test('defender sizing: the worked scale from the plan', () {
    // A starter town under its governor: ~64 settlers, mood 0.2, severity 0.5.
    final r = colonyResolve(severity: 0.5, mood: 0.2, wish: 0, hunger: 0);
    expect(r, closeTo(0.51, 1e-9));
    final militia = militiaRaised(population: 64, resolve: r);
    expect(militia, 9);
    expect(militiaArmed(militia: militia, gunsInStock: 0), 2);
    // A colony that wants to come home fights badly; a starving one folds.
    expect(colonyResolve(severity: 0.5, mood: 0.2, wish: 1, hunger: 0), 0.05);
    expect(colonyResolve(severity: 0, mood: 0, wish: 0, hunger: 1), 0.05);
    expect(portHolders(spaceportJobs: 40, population: 64, resolve: r), 21);
  });

  test('combat sources never reach for the platform\'s chance, clock or hash',
      () {
    final banned = [
      RegExp(r'\bRandom\b'),
      RegExp(r'\bDateTime\b'),
      RegExp(r'\bStopwatch\b'),
      RegExp(r'\.hashCode\b'),
      RegExp(r'Object\.hash'),
      RegExp(r"import\s+'[^']*traffic/"),
      RegExp(r'\.entries\b'),
      RegExp(r'\.keys\b'),
    ];
    final dir = Directory('lib/domain/combat');
    final offenders = <String>[];
    for (final f in dir.listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart')) continue;
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final code = lines[i].split('//').first;
        for (final b in banned) {
          if (b.hasMatch(code)) offenders.add('${f.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    expect(offenders, isEmpty);
  });
}
