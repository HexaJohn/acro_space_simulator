// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Drives a running `main_city_game_dev` app: prints the colony's live numbers
/// and captures a screenshot, so a city-builder run can be judged from the
/// console instead of by eye.
///
///   dart run tool/drive_city_game.dart <vm-service-uri> [out.png] [waitSeconds]
///       [walk] [--script=steps.json]
///
/// `--script` runs a list of extension calls after the settle and before
/// the screenshot — `[{"ext": "ext.acro.roadtool", "params": {"tool":
/// "road", "click": "0.5,0.45"}, "waitMs": 500}, ...]` — printing each
/// reply, so a road-tool session (lay a chain, raise it, upgrade it) can be
/// replayed and judged from the console and the shot.
library;

import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> argv) async {
  const scriptFlag = '--script=';
  final scriptPath = argv
      .where((a) => a.startsWith(scriptFlag))
      .map((a) => a.substring(scriptFlag.length))
      .firstOrNull;
  final args = [
    for (final a in argv)
      if (!a.startsWith('--')) a
  ];
  if (args.isEmpty) {
    stderr.writeln('usage: drive_city_game.dart <vm-service-uri> '
        '[out.png] [waitSeconds] [walk] [--script=<steps.json>]');
    exit(64);
  }
  final ws = args[0]
      .replaceFirst('http://', 'ws://')
      .replaceFirst(RegExp(r'/?$'), '/ws');
  final out = args.length > 1 ? args[1] : 'city_game_shot.png';
  final wait = args.length > 2 ? int.parse(args[2]) : 20;
  // Read up front: a typo in the path should fail before the settle, not
  // after twenty seconds of it.
  final List<Object?> steps = scriptPath == null
      ? const []
      : jsonDecode(File(scriptPath).readAsStringSync()) as List<Object?>;

  final vm = await vmServiceConnectUri(ws);
  final isolateId = (await vm.getVM()).isolates!.first.id!;

  Future<Map<String, dynamic>> call(String method,
      [Map<String, String> params = const {}]) async {
    final r =
        await vm.callServiceExtension(method, isolateId: isolateId, args: params);
    return (r.json ?? const {}).cast<String, dynamic>();
  }

  // The first frames are terrain streaming and shader warm-up; a shot taken
  // then is a picture of a loading screen.
  stdout.writeln('== settling for ${wait}s');
  await Future<void>.delayed(Duration(seconds: wait));

  // `walk` as a fourth argument steps out onto the streets first, so the
  // report shows the walker's camera and whether the mouse was captured.
  if (args.length > 3 && args[3] == 'walk') {
    await call('ext.acro.citygame', {'walk': 'on'});
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  for (final (i, step) in steps.indexed) {
    final m = (step as Map).cast<String, Object?>();
    final ext = m['ext'] as String;
    final params = {
      for (final e in ((m['params'] as Map?) ?? const {}).entries)
        '${e.key}': '${e.value}',
    };
    final reply = await call(ext, params);
    stdout.writeln('== step $i $ext $params');
    stdout.writeln('   ${jsonEncode(reply)}');
    final waitMs = (m['waitMs'] as num?)?.toInt() ?? 0;
    if (waitMs > 0) await Future<void>.delayed(Duration(milliseconds: waitMs));
  }

  final s = await call('ext.acro.citygame');
  stdout.writeln('== colony');
  for (final e in s.entries) {
    stdout.writeln('   ${e.key}: ${e.value}');
  }

  final shot = await call('ext.acro.screenshot', {'path': out});
  stdout.writeln('== ${shot['saved'] ?? shot}');
  await vm.dispose();
}
