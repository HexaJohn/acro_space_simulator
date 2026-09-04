// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Drives a running `main_scene_dev` app through the stuck-crater repro over
/// the VM service, using the dev extensions the harness already registers:
///
///   dart run tool/drive_crater_repro.dart <vm-service-uri> [seconds]
///
/// Lands the focused craft on the Moon (`ext.acro.spawn`), waits for the site
/// to stream in, drops the debug impactor beside it (`ext.acro.impact`), then
/// polls `ext.acro.terrain` and prints the debugLine every 2 s — the
/// rej/dropGen/dropEdit/editsChg counters in it name whichever silent-drop
/// path is eating the crater's meshes. Finishes with an `ext.acro.screenshot`
/// (sandboxed: the path must sit under the app container's Data dir).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run tool/drive_crater_repro.dart '
        '<vm-service-uri> [watch-seconds]');
    exit(64);
  }
  final watchS = args.length > 1 ? int.parse(args[1]) : 90;
  final ws = args[0]
      .replaceFirst('http://', 'ws://')
      .replaceFirst(RegExp(r'/?$'), '/ws');
  final vm = await vmServiceConnectUri(ws);
  final isolateId = (await vm.getVM()).isolates!.first.id!;

  Future<Map<String, dynamic>> call(String method,
      [Map<String, String> params = const {}]) async {
    final r = await vm.callServiceExtension(method,
        isolateId: isolateId, args: params);
    return (r.json ?? const {}).cast<String, dynamic>();
  }

  // Wait for the live view (SimViewControl registers on first build).
  for (var i = 0;; i++) {
    final s = await call('ext.acro.status');
    if (s['error'] == null) break;
    if (i > 60) {
      stderr.writeln('view never came up: $s');
      exit(1);
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  stdout.writeln('== view live; landing on the moon');
  await call('ext.acro.spawn', {'body': 'moon'});

  Future<void> sample(String tag) async {
    final t = await call('ext.acro.terrain');
    stdout.writeln('[$tag] ${t['debug']}');
    final rej = t['lastReject'];
    if (rej is String && rej.isNotEmpty) stdout.writeln('  reject: $rej');
  }

  // Let the landing site stream in before the impact, so "stuck" afterwards
  // is attributable to the crater and not the initial fill.
  for (var i = 0; i < 15; i++) {
    await Future<void>.delayed(const Duration(seconds: 2));
    await sample('pre  ${i * 2}s');
  }

  stdout.writeln('== dropping impactor (9 t @ 300 m/s)');
  await call('ext.acro.impact', {'massKg': '9000', 'speedMs': '300'});

  for (var i = 0; i * 2 < watchS; i++) {
    await Future<void>.delayed(const Duration(seconds: 2));
    await sample('post ${i * 2}s');
  }

  final home = Platform.environment['HOME']!;
  final shot =
      '$home/Library/Containers/com.example.acroSpaceSimulator/Data/crater_repro.png';
  final saved = await call('ext.acro.screenshot', {'path': shot});
  stdout.writeln('== screenshot: ${jsonEncode(saved)}');
  await vm.dispose();
}
