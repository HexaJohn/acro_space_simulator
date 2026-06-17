// Generates docs/REFERENCE.md — the in-depth wiki of every building, part, and
// celestial body, read DIRECTLY from the live catalogs so it can never drift
// from the code. Runs as a test (the building catalog pulls in Flutter, which
// needs the Flutter test VM):
//
//   flutter test test/tools/gen_reference_test.dart
//
// The part + body catalogs are pure domain; the building catalog lives in
// infrastructure, hence the Flutter dependency.
import 'dart:io';

import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/city_model.dart';
import 'package:flutter_test/flutter_test.dart';

String _f(double v, [int dp = 0]) =>
    v == v.roundToDouble() && dp == 0 ? v.toInt().toString() : v.toStringAsFixed(dp);

String _map(Map<String, double> m) => m.isEmpty
    ? '—'
    : m.entries.map((e) => '${e.key} ${_f(e.value, 2)}/s').join(', ');

void main() => test('generate docs/REFERENCE.md', () {
  final b = StringBuffer();
  b.writeln('# Reference — Buildings, Parts & Bodies\n');
  b.writeln('> Auto-generated from the live catalogs by '
      '`test/tools/gen_reference_test.dart` '
      '(`flutter test test/tools/gen_reference_test.dart`). '
      'Do not edit by hand — regenerate.\n');
  b.writeln('Source of truth:');
  b.writeln('- Buildings → `lib/infrastructure/flutter/screens/city_model.dart` '
      '(`kUtilCatalog`, [`CitySpec`](../doc/api/index.html))');
  b.writeln('- Parts → `lib/domain/parts/part_catalog.dart` '
      '([`PartCatalog`](../doc/api/index.html), `PartDef`)');
  b.writeln('- Bodies → `lib/domain/universe/real_solar_system.dart` '
      '(`RealSolarSystem`, `CelestialBody`)\n');

  // ---- Buildings ----
  b.writeln('## Buildings\n');
  b.writeln('${kUtilCatalog.length} placeable structures, grouped by tab.\n');
  final byGroup = <String, List<CitySpec>>{};
  for (final s in kUtilCatalog) {
    (byGroup[s.group] ??= []).add(s);
  }
  for (final group in byGroup.keys) {
    b.writeln('### ${group[0].toUpperCase()}${group.substring(1)}\n');
    b.writeln('| Building | Size | Cost | Jobs | Power | Inputs | Outputs | '
        'Pollution | Unlock pop |');
    b.writeln('|---|---|---|---|---|---|---|---|---|');
    for (final s in byGroup[group]!) {
      final power = s.powerOutput > 0
          ? '+${_f(s.powerOutput)}'
          : (s.powerDraw > 0 ? '−${_f(s.powerDraw)}' : '—');
      b.writeln('| **${s.label}** | ${s.footW}×${s.footH} | ${_f(s.buildCost)} '
          '| ${s.jobs} | $power | ${_map(s.inputs)} | ${_map(s.outputs)} | '
          '${_f(s.pollution, 1)} | ${s.unlockPop} |');
    }
    b.writeln('');
  }

  // ---- Parts ----
  b.writeln('## Parts\n');
  final catalog = PartCatalog.standard();
  final parts = catalog.all.toList();
  b.writeln('${parts.length} craft parts.\n');
  final byCat = <PartCategory, List<PartDef>>{};
  for (final p in parts) {
    (byCat[p.category] ??= []).add(p);
  }
  for (final cat in byCat.keys) {
    b.writeln('### ${cat.name}\n');
    b.writeln('| Part | Dry mass | Thrust (vac) | Isp | Crew | Fuel | Notes |');
    b.writeln('|---|---|---|---|---|---|---|');
    for (final p in byCat[cat]!) {
      final eng = p.rocketEngine;
      final jet = p.jetEngine;
      final thrust = eng != null
          ? '${_f(eng.maxThrustVacuum / 1000)} kN'
          : (jet != null ? '${_f(jet.maxStaticThrust / 1000)} kN jet' : '—');
      final isp = eng != null ? '${_f(eng.ispVacuum)} s' : '—';
      final fuel = p.resources.isEmpty
          ? '—'
          : _f(p.resources.fold<double>(0, (a, r) => a + r.capacity));
      final notes = <String>[
        if (p.wing != null) 'wing ${_f(p.wing!.area)} m²',
        if (p.ablator > 0) 'heat shield',
        if (p.intakeArea > 0) 'intake',
      ].join(', ');
      b.writeln('| **${p.name}** | ${_f(p.dryMass)} kg | $thrust | $isp | '
          '${p.crewCapacity} | $fuel | ${notes.isEmpty ? "—" : notes} |');
    }
    b.writeln('');
  }

  // ---- Bodies ----
  b.writeln('## Celestial bodies\n');
  final system = RealSolarSystem.build();
  final bodies = system.all.toList();
  b.writeln('${bodies.length} bodies (Sun + planets + dwarf planets + moons).\n');
  b.writeln('| Body | Type | Radius | Surface g | Rotation | Atmosphere | '
      'Parent |');
  b.writeln('|---|---|---|---|---|---|---|');
  for (final body in bodies) {
    final g = body.mu / (body.radius * body.radius);
    final type = body.isStar
        ? 'star'
        : (body.isGasGiant ? 'gas giant' : (body.parent != null ? 'moon' : 'planet'));
    final rotH = (body.siderealRotationPeriod.abs() / 3600);
    final atmo = body.atmosphere != null
        ? '${_f(body.atmosphere!.atmosphereHeight / 1000)} km'
        : 'none';
    final parent = body.parent?.value ?? '—';
    b.writeln('| **${body.name}** | $type | ${_f(body.radius / 1000)} km | '
        '${_f(g, 2)} m/s² | ${_f(rotH, 1)} h | $atmo | $parent |');
  }
  b.writeln('');

  final out = File('docs/REFERENCE.md');
  out.parent.createSync(recursive: true);
  out.writeAsStringSync(b.toString());
  stdout.writeln('Wrote ${out.path} '
      '(${kUtilCatalog.length} buildings, ${parts.length} parts, '
      '${bodies.length} bodies).');
});
