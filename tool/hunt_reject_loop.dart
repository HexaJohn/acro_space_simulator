// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Hammers the running `main_scene_dev` app with debug impactors until the
/// intermittent arrival-rejection loop latches, then prints the rejected key.
///
///   dart run tool/hunt_reject_loop.dart <vm-service-uri> [max-impacts]
///
/// The latch signature (from the first live repro): `rej` climbing across
/// consecutive samples while `missing+N` sits flat and `pend` idles — a
/// single mesh cycling submit -> arrive -> refused -> resubmit, with the
/// wants above it ladder-blocked. Timing-dependent: whether it latches
/// depends on what was in flight when the impact's invalidation landed, so
/// each impact is one roll of the dice.
library;

import 'dart:io';

import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  final ws = args[0]
      .replaceFirst('http://', 'ws://')
      .replaceFirst(RegExp(r'/?$'), '/ws');
  final maxImpacts = args.length > 1 ? int.parse(args[1]) : 12;
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
  await call('ext.acro.spawn', {'body': 'moon'});
  stdout.writeln('== landed; letting the site stream in');
  await Future<void>.delayed(const Duration(seconds: 20));

  int rejOf(String d) =>
      int.tryParse(RegExp(r'rej(\d+)').firstMatch(d)?.group(1) ?? '0') ?? 0;
  int missingOf(String d) =>
      int.tryParse(
          RegExp(r'missing\+(\d+)').firstMatch(d)?.group(1) ?? '0') ??
      0;

  for (var impact = 1; impact <= maxImpacts; impact++) {
    // Vary the energy a little: different crater sizes shift which chunks
    // and levels are in flight when the invalidation lands.
    final speed = 250 + (impact % 4) * 50;
    stdout.writeln('== impact #$impact (9 t @ $speed m/s)');
    await call('ext.acro.impact', {'massKg': '9000', 'speedMs': '$speed'});

    var lastRej = -1, climbs = 0, lastMissing = -1, flatMissing = 0;
    for (var t = 0; t < 20; t++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final j = await call('ext.acro.terrain');
      final d = j['debug'] as String? ?? '';
      final rej = rejOf(d), miss = missingOf(d);
      stdout.writeln('[#$impact ${t * 2}s] $d');
      climbs = (rej > lastRej && lastRej >= 0) ? climbs + 1 : 0;
      flatMissing = (miss == lastMissing && miss > 0) ? flatMissing + 1 : 0;
      lastRej = rej;
      lastMissing = miss;
      if (climbs >= 3 && flatMissing >= 3) {
        stdout.writeln('== LATCHED on impact #$impact');
        stdout.writeln('== reject: ${j['lastReject']}');
        // A few more samples to show it is truly stuck, not draining.
        for (var k = 0; k < 5; k++) {
          await Future<void>.delayed(const Duration(seconds: 2));
          final j2 = await call('ext.acro.terrain');
          stdout.writeln('[stuck +${k * 2}s] ${j2['debug']}');
          stdout.writeln('  reject: ${j2['lastReject']}');
        }
        await vm.dispose();
        exit(0);
      }
    }
    stdout.writeln('== impact #$impact drained clean');
  }
  stdout.writeln('== no latch after $maxImpacts impacts');
  await vm.dispose();
  exit(2);
}
