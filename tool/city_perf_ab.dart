// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Drives a running `main_city_studio_dev` app through the perf A/B the
/// panel's own "unaccounted" note prescribes: generate the colony, park the
/// camera at a fixed pose, sample the frame numbers, then flip the ISOLATE
/// switches one at a time (shadows, atmosphere, perf panel) and sample again.
/// The deltas attribute the untimed part of the frame without a profiler.
///
///   dart run tool/city_perf_ab.dart <vm-service-uri> [--no-generate]
///       [--sprawl=20] [--distance=1320] [--elevation=0.55] [--samples=8]
///       [--shot=path.png]
library;

import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  final ws = args[0]
      .replaceFirst('http://', 'ws://')
      .replaceFirst(RegExp(r'/?$'), '/ws');
  String opt(String name, String fallback) {
    for (final a in args) {
      if (a.startsWith('--$name=')) return a.substring(name.length + 3);
    }
    return fallback;
  }

  final generate = !args.contains('--no-generate');
  final sprawl = opt('sprawl', '20');
  final distance = opt('distance', '1320');
  final elevation = opt('elevation', '0.55');
  final samples = int.parse(opt('samples', '8'));
  final shot = opt('shot', '');

  final vm = await vmServiceConnectUri(ws);
  final isolateId = (await vm.getVM()).isolates!.first.id!;
  Future<Map<String, dynamic>> call(String method,
      [Map<String, String> params = const {}]) async {
    final r = await vm.callServiceExtension(method,
        isolateId: isolateId, args: params);
    return (r.json ?? const {}).cast<String, dynamic>();
  }

  for (var i = 0;; i++) {
    final s = await call('ext.acro.citystudio');
    if (s['error'] == null) break;
    if (i > 60) {
      stderr.writeln('studio never came up');
      exit(1);
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  if (generate) {
    stdout.writeln('== generating sprawl=$sprawl');
    await call('ext.acro.citystudio', {'action': 'generate', 'sprawl': sprawl});
    for (var i = 0; i < 600; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final s = await call('ext.acro.citystudio');
      if (s['busy'] != true) {
        stdout.writeln('== built after ~${i * 2}s: ${s['stats']}');
        break;
      }
    }
  }
  // Settle: the generator returning is not the end of the build — the tiles
  // stream in for a while after, and a sample taken then measures the
  // streaming, not the frame. Wait for the city's own queue to read empty
  // three polls running.
  var drained = 0;
  for (var i = 0; i < 300 && drained < 3; i++) {
    await Future<void>.delayed(const Duration(seconds: 2));
    final s = await call('ext.acro.citystudio');
    final m = RegExp(r'(\d+) queued').firstMatch('${s['cityDebug']}');
    final queued = m == null ? 0 : int.parse(m.group(1)!);
    drained = queued == 0 && s['busy'] != true ? drained + 1 : 0;
  }
  stdout.writeln('== queue drained');
  await call('ext.acro.citystudio',
      {'distance': distance, 'elevation': elevation});
  await Future<void>.delayed(const Duration(seconds: 6));

  String f(dynamic v) => (v is num) ? v.toStringAsFixed(2) : '$v';
  Future<Map<String, double>> sample(String label, int n) async {
    final acc = <String, double>{};
    for (var i = 0; i < n; i++) {
      final s = await call('ext.acro.citystudio');
      for (final k in ['frameMs', 'uiMs', 'rasterMs', 'terrainMs', 'cityMs']) {
        acc[k] = (acc[k] ?? 0) + ((s[k] as num?)?.toDouble() ?? 0) / n;
      }
      acc['draws'] = ((s['censusDraws'] as num?)?.toDouble() ?? 0);
      acc['inst'] = ((s['censusInstances'] as num?)?.toDouble() ?? 0);
      if (s['fault'] != null) stdout.writeln('  FAULT ${s['fault']}');
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    stdout.writeln('[$label] frame ${f(acc['frameMs'])}  ui ${f(acc['uiMs'])}  '
        'raster ${f(acc['rasterMs'])}  terrain ${f(acc['terrainMs'])}  '
        'city ${f(acc['cityMs'])}  draws ${acc['draws']!.round()} '
        '(${acc['inst']!.round()} inst)');
    return acc;
  }

  final base = await sample('baseline', samples);
  final out = <String, Map<String, double>>{'baseline': base};
  Future<void> flip(String key, String param, String off, String on) async {
    await call('ext.acro.citystudio', {param: off});
    await Future<void>.delayed(const Duration(seconds: 4));
    out[key] = await sample('$key off', 5);
    await call('ext.acro.citystudio', {param: on});
    await Future<void>.delayed(const Duration(seconds: 3));
  }

  await flip('shadows', 'shadows', 'false', 'true');
  await flip('atmosphere', 'atmosphere', 'false', 'true');
  await flip('perfPanel', 'perf', 'false', 'true');
  final again = await sample('baseline again', 5);
  out['baselineAgain'] = again;

  stdout.writeln('== deltas vs baseline (ui ms):');
  for (final e in out.entries) {
    if (e.key == 'baseline') continue;
    stdout.writeln('  ${e.key}: ${f(base['uiMs']! - e.value['uiMs']!)} ms ui, '
        '${f(base['frameMs']! - e.value['frameMs']!)} ms frame');
  }
  if (shot.isNotEmpty) {
    final saved = await call('ext.acro.screenshot', {'path': shot});
    stdout.writeln('== screenshot: $saved');
  }
  stdout.writeln(jsonEncode(out));
  await vm.dispose();
}
