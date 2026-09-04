// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Drives a running `main_city_studio_dev` app: presses GENERATE, waits the
/// build out, then samples the studio's perf numbers — the city-studio twin
/// of tool/sample_frame_stats.dart:
///
///   dart run tool/drive_city_studio.dart <vm-service-uri> [samples]
library;

import 'dart:io';

import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  final ws = args[0]
      .replaceFirst('http://', 'ws://')
      .replaceFirst(RegExp(r'/?$'), '/ws');
  final samples = args.length > 1 ? int.parse(args[1]) : 10;
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
  stdout.writeln('== studio live; generating');
  await call('ext.acro.citystudio', {'action': 'generate'});
  for (var i = 0; i < 120; i++) {
    await Future<void>.delayed(const Duration(seconds: 2));
    final s = await call('ext.acro.citystudio');
    if (s['busy'] != true) {
      stdout.writeln('== build done after ~${i * 2}s: ${s['stats']}');
      break;
    }
  }
  // Let streaming/uploads settle before judging steady state.
  await Future<void>.delayed(const Duration(seconds: 15));

  String f(dynamic v) => (v is num) ? v.toStringAsFixed(2) : '$v';
  for (var i = 0; i < samples; i++) {
    final s = await call('ext.acro.citystudio');
    stdout.writeln('[${i * 2}s] frame ${f(s['frameMs'])}ms  '
        'ui ${f(s['uiMs'])}ms  raster ${f(s['rasterMs'])}ms  '
        'terrain ${f(s['terrainMs'])}ms  city ${f(s['cityMs'])}ms  '
        'draws ${s['censusDraws']} (${s['censusInstances']} inst, '
        '${s['censusNodes']} nodes)'
        '${s['fault'] != null ? '  FAULT ${s['fault']}' : ''}');
    if (i == 0) {
      stdout.writeln('  terrain: ${s['terrainDebug']}');
      stdout.writeln('  profile: ${s['terrainProfile']}');
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  final home = Platform.environment['HOME']!;
  final shot =
      '$home/Library/Containers/com.example.acroSpaceSimulator/Data/city_studio_repro.png';
  final saved = await call('ext.acro.screenshot', {'path': shot});
  stdout.writeln('== screenshot: $saved');
  await vm.dispose();
}
