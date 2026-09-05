// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Drives a running `main_city_studio_dev` app into the dune buggy and
/// screenshots it: generate a small colony, park the buggy on the approach
/// road and shoot; then hold the throttle and shoot again with the dust up;
/// then a hard turn. Prints the studio's 'rover' status beside each shot so
/// the numbers (speed, wheels down, compression, dust) can be read against
/// the picture.
///
///   dart run tool/drive_rover_shot.dart `<vm-service-uri>` `[out-dir]`
library;

import 'dart:io';

import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  final ws = args[0]
      .replaceFirst('http://', 'ws://')
      .replaceFirst(RegExp(r'/?$'), '/ws');
  final outDir = args.length > 1 ? args[1] : '.';
  final vm = await vmServiceConnectUri(ws);
  final isolateId = (await vm.getVM()).isolates!.first.id!;

  Future<Map<String, dynamic>> call(String method,
      [Map<String, String> params = const {}]) async {
    final r = await vm.callServiceExtension(method,
        isolateId: isolateId, args: params);
    return (r.json ?? const {}).cast<String, dynamic>();
  }

  Future<void> shot(String name) async {
    final path = '$outDir/$name.png';
    final saved = await call('ext.acro.screenshot', {'path': path});
    final s = await call('ext.acro.citystudio');
    stdout.writeln('== $name: $saved');
    stdout.writeln('   rover: ${s['rover']}');
    stdout.writeln('   frame ${s['frameMs']} ms  ui ${s['uiMs']} ms  '
        'raster ${s['rasterMs']} ms  terrain ${s['terrainMs']} ms  '
        'city ${s['cityMs']} ms  draws ${s['censusDraws']}'
        '${s['fault'] != null ? '  FAULT ${s['fault']}' : ''}');
  }

  for (var i = 0;; i++) {
    final s = await call('ext.acro.citystudio');
    if (s['error'] == null) break;
    if (i > 90) {
      stderr.writeln('studio never came up');
      exit(1);
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  stdout.writeln('== studio live; generating a small colony');
  await call('ext.acro.citystudio',
      {'action': 'generate', 'blocks': '3', 'sprawl': '0'});
  // The build goes busy a moment after the call; wait for it to START and
  // then to finish, and let the drape and streaming settle after that.
  await Future<void>.delayed(const Duration(seconds: 3));
  for (var i = 0; i < 150; i++) {
    await Future<void>.delayed(const Duration(seconds: 2));
    final s = await call('ext.acro.citystudio');
    if (s['busy'] != true) {
      stdout.writeln('== build done after ~${3 + i * 2}s');
      break;
    }
  }
  await Future<void>.delayed(const Duration(seconds: 15));
  await call('ext.acro.citystudio', {'perf': 'false', 'controls': 'false'});

  // Parked on the approach, facing into town.
  await call('ext.acro.citystudio', {'drive': '0,-160,0'});
  await Future<void>.delayed(const Duration(seconds: 3));
  await shot('rover_parked');

  // Flat out toward town for six seconds; shoot mid-run.
  await call('ext.acro.citystudio', {'drive': '0,-220,0,1,0,6'});
  await Future<void>.delayed(const Duration(seconds: 4));
  await shot('rover_driving');

  // A hard right under power: lean, steer, and the rear wheels' dust.
  await call('ext.acro.citystudio', {'drive': '0,-220,0,1,0.9,6'});
  await Future<void>.delayed(const Duration(seconds: 4));
  await shot('rover_turning');

  // Coast to a stop and shoot the resting pose from a longer lens.
  await Future<void>.delayed(const Duration(seconds: 5));
  await shot('rover_stopped');
  await vm.dispose();
}
