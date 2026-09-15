// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'bench_support.dart';

/// Agent traffic compiled ahead of time and run (tool/aot_traffic_smoke.dart):
/// the JIT this suite runs in never compiles the traffic code the way the
/// profile and release builds do, and a native crash there — the readout's
/// first pass reading through null, 25–35 s into the City Builder — passed
/// every other test. A bench, since it compiles a whole executable.
void main() {
  test('bench: agent traffic survives an AOT build', () async {
    final root = Platform.environment['FLUTTER_ROOT'];
    expect(root, isNotNull, reason: 'run under flutter test');
    final dart = '$root/bin/cache/dart-sdk/bin/dart'
        '${Platform.isWindows ? '.exe' : ''}';
    final out = Directory.systemTemp.createTempSync('aot_traffic_smoke');
    try {
      final exe = '${out.path}/aot_traffic_smoke'
          '${Platform.isWindows ? '.exe' : ''}';
      final build = await Process.run(
          dart, ['compile', 'exe', 'tool/aot_traffic_smoke.dart', '-o', exe]);
      expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');
      final run = await Process.run(exe, ['4000']);
      report('${run.stdout}'.trim());
      expect(run.exitCode, 0,
          reason: 'a native crash in AOT code:\n${run.stdout}\n${run.stderr}');
    } finally {
      out.deleteSync(recursive: true);
    }
  }, skip: benchSkip, timeout: benchTimeout);
}
