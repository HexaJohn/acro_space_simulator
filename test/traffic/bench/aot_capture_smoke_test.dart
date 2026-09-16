// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'bench_support.dart';

/// The City Builder's FRAME compiled ahead of time and run
/// (tool/aot_capture_smoke.dart): a town grown, ticked through the frame
/// hold, and captured into a `WorldSnapshot` every frame.
///
/// Beside aot_smoke_test.dart rather than folded into it because it is a
/// different question. That one asks whether the agents' TICK survives an
/// AOT build; this one asks whether the CAPTURE does — the site poses and
/// the parked-car columns T4a put on the wire, which the traffic-only smoke
/// never builds, with the site frame, the drapes and the ground moving
/// under them as a town grows. A bench, since it compiles an executable and
/// then runs the better part of an hour of colony time in it — past the
/// forty minutes the live crash took.
void main() {
  test('bench: the city capture survives an AOT build', () async {
    final root = Platform.environment['FLUTTER_ROOT'];
    expect(root, isNotNull, reason: 'run under flutter test');
    final dart = '$root/bin/cache/dart-sdk/bin/dart'
        '${Platform.isWindows ? '.exe' : ''}';
    final out = Directory.systemTemp.createTempSync('aot_capture_smoke');
    try {
      final exe = '${out.path}/aot_capture_smoke'
          '${Platform.isWindows ? '.exe' : ''}';
      final build = await Process.run(
          dart, ['compile', 'exe', 'tool/aot_capture_smoke.dart', '-o', exe]);
      expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');
      // The harness reads assets/terrain itself: the capture asks the ground
      // for every drape and pad, and a body with a baked DEM throws without
      // its pyramid. `flutter test` runs from the repo root, so the default
      // relative path finds them.
      final run = await Process.run(exe, ['6000']);
      report('${run.stdout}'.trim());
      expect(run.exitCode, 0,
          reason: 'a native crash in AOT code:\n${run.stdout}\n${run.stderr}');
    } finally {
      out.deleteSync(recursive: true);
    }
    // Ten minutes, not the benches' five: this one compiles an executable
    // AND runs three quarters of an hour of colony time in it, and the
    // suite runs its files in parallel on every core, so the clean minute
    // it takes alone is not the minute it takes here.
  }, skip: benchSkip, timeout: const Timeout(Duration(minutes: 10)));
}
