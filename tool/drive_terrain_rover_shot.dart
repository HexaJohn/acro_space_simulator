// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Drives a running `main_terrain_studio_dev` app: opens the site, stands the
/// walker facing north and picks the ground either side of the screen to
/// prove which way is east on screen (screen-right must be east — the
/// chirality check), then puts the buggy down parked, flat out and in a hard
/// turn, printing the 'rover' status beside each shot — including the ground
/// under it read from the drawn mesh AND the analytic field, whose gap is
/// what "the collision does not match the ground" measures.
///
///   dart run tool/drive_terrain_rover_shot.dart `<vm-service-uri>` `[out-dir]`
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
    final s = await call('ext.acro.terrainstudio');
    stdout.writeln('== $name: $saved');
    stdout.writeln('   rover: ${s['rover']}');
    stdout.writeln('   frame ${s['frameMs']} ms  terrain ${s['terrainMs']} ms  '
        'draws ${s['censusDraws']}  ${s['terrainDebug']}');
  }

  for (var i = 0;; i++) {
    final s = await call('ext.acro.terrainstudio');
    if (s['error'] == null) break;
    if (i > 90) {
      stderr.writeln('studio never came up');
      exit(1);
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  stdout.writeln('== studio live; opening the site');
  await call('ext.acro.terrainstudio', {'action': 'open'});
  for (var i = 0; i < 60; i++) {
    await Future<void>.delayed(const Duration(seconds: 1));
    final s = await call('ext.acro.terrainstudio');
    if (s['site'] == true) break;
  }
  // Let the streamer bring the ground in before anything stands on it.
  await Future<void>.delayed(const Duration(seconds: 20));
  await call('ext.acro.terrainstudio', {'perf': 'false', 'controls': 'false'});

  // Chirality: on foot facing north, the ground picked on the screen's right
  // must be EAST of the ground picked on its left.
  await call('ext.acro.terrainstudio', {'walk': '0,0,0,0'});
  await Future<void>.delayed(const Duration(seconds: 3));
  await shot('terrain_walk_north');
  final left = (await call('ext.acro.terrainstudio', {'pick': '0.15,0.6'}))['hit'];
  final right = (await call('ext.acro.terrainstudio', {'pick': '0.85,0.6'}))['hit'];
  stdout.writeln('== pick left  $left');
  stdout.writeln('== pick right $right');
  if (left is Map && right is Map) {
    final le = (left['e'] as num).toDouble();
    final re = (right['e'] as num).toDouble();
    stdout.writeln(re > le
        ? '== CHIRALITY OK: screen-right is east (facing north)'
        : '== CHIRALITY MIRRORED: screen-right is west (facing north)');
  } else {
    stdout.writeln('== chirality check: a pick missed the ground');
  }

  // Parked just south of the anchor, facing into it.
  await call('ext.acro.terrainstudio', {'drive': '0,-30,0'});
  await Future<void>.delayed(const Duration(seconds: 4));
  await shot('terrain_rover_parked');

  // Flat out north for eight seconds; shoot mid-run.
  await call('ext.acro.terrainstudio', {'drive': '0,-60,0,1,0,8'});
  await Future<void>.delayed(const Duration(seconds: 6));
  await shot('terrain_rover_driving');

  // A hard right under power.
  await call('ext.acro.terrainstudio', {'drive': '0,-60,0,1,0.9,8'});
  await Future<void>.delayed(const Duration(seconds: 6));
  await shot('terrain_rover_turning');
  await vm.dispose();
}
