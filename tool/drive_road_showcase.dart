// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Drives a running `main_road_showcase_dev` app: prints what the showcase
/// built, shoots it from a ring of camera poses, then edits it — reverses a
/// one-way road, upgrades a street, switches a junction's lights — and
/// shoots again at once (the instant path) and after the tiles land.
///
/// `dart run tool/drive_road_showcase.dart VM_URI OUT_DIR [WAIT_S] [POSES_JSON]`
library;

import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: drive_road_showcase.dart <vm-uri> <outDir> [waitS]');
    exit(64);
  }
  final ws = args[0]
      .replaceFirst('http://', 'ws://')
      .replaceFirst(RegExp(r'/?$'), '/ws');
  final outDir = Directory(args[1])..createSync(recursive: true);
  final wait = args.length > 2 ? int.parse(args[2]) : 30;

  final vm = await vmServiceConnectUri(ws);
  final isolateId = (await vm.getVM()).isolates!.first.id!;

  Future<Map<String, dynamic>> call(String method,
      [Map<String, String> params = const {}]) async {
    final r =
        await vm.callServiceExtension(method, isolateId: isolateId, args: params);
    return (r.json ?? const {}).cast<String, dynamic>();
  }

  Future<void> shot(String name) async {
    final path = '${outDir.absolute.path}${Platform.pathSeparator}$name.png';
    final r = await call('ext.acro.screenshot', {'path': path});
    stdout.writeln('   shot ${r['saved'] ?? r}');
  }

  Future<void> pose(double az, double el, double range) =>
      call('ext.acro.camera', {
        'azimuthDeg': '$az',
        'elevationDeg': '$el',
        'rangeM': '$range',
      });

  stdout.writeln('== settling for ${wait}s');
  await Future<void>.delayed(Duration(seconds: wait));

  // A steps file instead of the default tour: a JSON list of
  // {"ext": "ext.acro.showcase", "params": {...}, "waitMs": 500,
  //  "shot": "name"} run in order, in-process, so a shot can follow an
  // edit by half a second.
  if (args.length > 4) {
    final steps = (jsonDecode(File(args[4]).readAsStringSync()) as List)
        .cast<Map<String, dynamic>>();
    for (final st in steps) {
      final ext = st['ext'] as String?;
      if (ext != null) {
        final r = await call(ext, {
          for (final e in ((st['params'] as Map?) ?? const {}).entries)
            '${e.key}': '${e.value}',
        });
        stdout.writeln('   $ext ${st['params']} -> '
            '${r['action'] ?? r['ok'] ?? r['saved'] ?? ''}');
      }
      final ms = (st['waitMs'] as num?)?.toInt() ?? 0;
      if (ms > 0) await Future<void>.delayed(Duration(milliseconds: ms));
      final name = st['shot'] as String?;
      if (name != null) await shot(name);
    }
    await vm.dispose();
    return;
  }

  final s = await call('ext.acro.showcase');
  stdout.writeln('== built');
  for (final b in (s['built'] as List? ?? const [])) {
    stdout.writeln('   $b');
  }
  stdout.writeln('== funds ${s['funds']}  upkeep/wk ${s['roadUpkeepPerWeek']}'
      '  traffic ${s['trafficRun']}');
  for (final r in (s['roads'] as List? ?? const [])) {
    stdout.writeln('   $r');
  }

  // A ring of poses round the crossroads: which azimuth frames the
  // showcase is found by looking.
  final poses = args.length > 3
      ? (jsonDecode(args[3]) as List).cast<List>()
      : [
          [0.0, 45.0, 1600.0],
          [90.0, 45.0, 1600.0],
          [180.0, 45.0, 1600.0],
          [270.0, 45.0, 1600.0],
          [315.0, 35.0, 1100.0],
          [225.0, 35.0, 1100.0],
        ];
  var k = 0;
  for (final p in poses) {
    await pose((p[0] as num).toDouble(), (p[1] as num).toDouble(),
        (p[2] as num).toDouble());
    await Future<void>.delayed(const Duration(seconds: 6));
    await shot('pose${k++}_az${p[0]}_el${p[1]}_r${p[2]}');
  }

  // Edits: each shot at once (the instant path) and after the tiles land.
  stdout.writeln('== edits');
  for (final edit in [
    // The showcase's one-way west, its cross street, and the four-lane ×
    // six-lane junction whose lights it switched off.
    {'reverse': '-100,200'},
    {'upgrade': '-300,0', 'type': 'four-lane-trees'},
    {'lights': '200,-200', 'on': '1'},
  ]) {
    final r = await call('ext.acro.showcase', edit);
    stdout.writeln('   ${r['action']}  rev ${r['roadsRevision']}');
  }
  await Future<void>.delayed(const Duration(milliseconds: 800));
  await shot('edit_instant');
  await Future<void>.delayed(const Duration(seconds: 20));
  await shot('edit_landed');
  await vm.dispose();
}
