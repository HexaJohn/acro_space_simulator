// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Samples the flight view's frame economics over the VM service:
///
///   dart run tool/sample_frame_stats.dart <vm-service-uri> [samples] [body]
///
/// Optionally lands the focused craft first (third arg, e.g. `moon`), then
/// prints frameMs / uiMs / rasterMs / presentMs from `ext.acro.status` every
/// 2 s — the before/after instrument for UI-thread frame-cost work.
library;

import 'dart:io';

import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  final ws = args[0]
      .replaceFirst('http://', 'ws://')
      .replaceFirst(RegExp(r'/?$'), '/ws');
  final samples = args.length > 1 ? int.parse(args[1]) : 10;
  final body = args.length > 2 ? args[2] : null;
  final vm = await vmServiceConnectUri(ws);
  final isolateId = (await vm.getVM()).isolates!.first.id!;

  Future<Map<String, dynamic>> call(String method,
      [Map<String, String> params = const {}]) async {
    final r = await vm.callServiceExtension(method,
        isolateId: isolateId, args: params);
    return (r.json ?? const {}).cast<String, dynamic>();
  }

  for (var i = 0;; i++) {
    final s = await call('ext.acro.status');
    if (s['error'] == null) break;
    if (i > 60) {
      stderr.writeln('view never came up');
      exit(1);
    }
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  if (body != null) {
    await call('ext.acro.spawn', {'body': body});
    stdout.writeln('== landed on $body; settling');
    await Future<void>.delayed(const Duration(seconds: 15));
  }

  String f(dynamic v) => (v is num) ? v.toStringAsFixed(2) : '$v';
  for (var i = 0; i < samples; i++) {
    final s = await call('ext.acro.status');
    stdout.writeln('[${i * 2}s] frame ${f(s['frameMs'])}ms  '
        'ui ${f(s['uiMs'])}ms  raster ${f(s['rasterMs'])}ms  '
        'present ${f(s['presentMs'])}ms  backend ${s['backend']}');
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  await vm.dispose();
}
