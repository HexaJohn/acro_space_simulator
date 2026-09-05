// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Drives a running `main_city_studio_dev` app through the perf A/B the
/// panel's own "unaccounted" note prescribes: generate the colony, park the
/// camera at a fixed pose, sample the frame numbers, then flip the ISOLATE
/// switches one at a time (shadows, atmosphere, perf panel) and sample again.
/// The deltas attribute the untimed part of the frame without a profiler.
///
///   dart run tool/city_perf_ab.dart <vm-service-uri> [--no-generate]
///       [--sprawl=20] [--distance=1320] [--elevation=0.55] [--samples=8]
///       [--shot=path.png] [--sweep] [--spikes] [--no-flips]
///       [--assert=static:12,sweep:16,worst:33]
///
/// `--sweep` drives the camera the way a hand does: a cold orbit over
/// tiles never built, a warm one over the same ground, an elevation nod
/// and a zoom in and out, reporting each pattern's average frame, worst
/// frame, deepest build queue and governor level. Pans and orbits are
/// where the frame has dropped before (tile churn on the camera term,
/// tier flips on the view cone, the isolate send), and a static sample
/// never sees it. `--spikes` records the VM timeline through each pattern
/// and names its longest frames — the send, the upload, an archetype
/// generated cold, or a collection. `--assert` makes the run a gate: the process exits 1
/// when the static average, the warm-orbit average or the sweep's worst
/// frame exceeds its threshold in milliseconds.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:vm_service/vm_service_io.dart';

import 'timeline_spans.dart';

Future<void> main(List<String> args) async {
  final ws = args[0]
      .replaceFirst('http://', 'ws://')
      .replaceFirst(RegExp(r'/?$'), '/ws');
  String opt(String name, String fallback) {
    for (final a in args) {
      if (a.startsWith('--$name=')) return a.substring(name.length + 3);
    }
    return fallback;
  }

  final generate = !args.contains('--no-generate');
  final sweep = args.contains('--sweep');
  final spikes = args.contains('--spikes');
  final flips = !args.contains('--no-flips');
  final asserts = <String, double>{};
  for (final part in opt('assert', '').split(',')) {
    final kv = part.split(':');
    if (kv.length == 2) asserts[kv[0]] = double.parse(kv[1]);
  }
  final sprawl = opt('sprawl', '20');
  final distance = opt('distance', '1320');
  final elevation = opt('elevation', '0.55');
  final samples = int.parse(opt('samples', '8'));
  final shot = opt('shot', '');

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
  if (generate) {
    stdout.writeln('== generating sprawl=$sprawl');
    await call('ext.acro.citystudio', {'action': 'generate', 'sprawl': sprawl});
    for (var i = 0; i < 600; i++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      final s = await call('ext.acro.citystudio');
      if (s['busy'] != true) {
        stdout.writeln('== built after ~${i * 2}s: ${s['stats']}');
        break;
      }
    }
  }
  // Settle: the generator returning is not the end of the build — the tiles
  // stream in for a while after, and a sample taken then measures the
  // streaming, not the frame. Wait for the city's own queue to read empty
  // three polls running.
  var drained = 0;
  for (var i = 0; i < 300 && drained < 3; i++) {
    await Future<void>.delayed(const Duration(seconds: 2));
    final s = await call('ext.acro.citystudio');
    final m = RegExp(r'(\d+) queued').firstMatch('${s['cityDebug']}');
    final queued = m == null ? 0 : int.parse(m.group(1)!);
    drained = queued == 0 && s['busy'] != true ? drained + 1 : 0;
  }
  stdout.writeln('== queue drained');
  await call('ext.acro.citystudio',
      {'distance': distance, 'elevation': elevation});
  await Future<void>.delayed(const Duration(seconds: 6));

  String f(dynamic v) => (v is num) ? v.toStringAsFixed(2) : '$v';
  Future<Map<String, double>> sample(String label, int n) async {
    final acc = <String, double>{};
    for (var i = 0; i < n; i++) {
      final s = await call('ext.acro.citystudio');
      for (final k in ['frameMs', 'uiMs', 'rasterMs', 'terrainMs', 'cityMs']) {
        acc[k] = (acc[k] ?? 0) + ((s[k] as num?)?.toDouble() ?? 0) / n;
      }
      acc['draws'] = ((s['censusDraws'] as num?)?.toDouble() ?? 0);
      acc['inst'] = ((s['censusInstances'] as num?)?.toDouble() ?? 0);
      final eng = (s['engine'] as Map?)?.cast<String, dynamic>();
      if (eng != null) {
        for (final k in [
          'colourDraws', 'shadowDraws', 'packedInstances', 'instancesEmplaced',
          'materialBinds',
          'prePassMs', 'bvhMs', 'shadowMs', 'colourMs', 'bvhRebuilds',
        ]) {
          acc['e.$k'] =
              (acc['e.$k'] ?? 0) + ((eng[k] as num?)?.toDouble() ?? 0) / n;
        }
      }
      if (s['fault'] != null) stdout.writeln('  FAULT ${s['fault']}');
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    stdout.writeln('[$label] frame ${f(acc['frameMs'])}  ui ${f(acc['uiMs'])}  '
        'raster ${f(acc['rasterMs'])}  terrain ${f(acc['terrainMs'])}  '
        'city ${f(acc['cityMs'])}  draws ${acc['draws']!.round()} '
        '(${acc['inst']!.round()} inst)');
    if (acc.containsKey('e.colourDraws')) {
      stdout.writeln('    engine: encoded colour '
          '${acc['e.colourDraws']!.round()} '
          'shadow ${acc['e.shadowDraws']!.round()}  '
          'binds ${acc['e.materialBinds']!.round()}  '
          'packed ${acc['e.packedInstances']!.round()}'
          '/${(acc['e.instancesEmplaced'] ?? 0).round()}  '
          'ms pre ${f(acc['e.prePassMs'])} bvh ${f(acc['e.bvhMs'])} '
          'shadow ${f(acc['e.shadowMs'])} colour ${f(acc['e.colourMs'])}  '
          'rebuilds/frame ${f(acc['e.bvhRebuilds'])}');
    }
    return acc;
  }

  final base = await sample('baseline', samples);
  final out = <String, Map<String, double>>{'baseline': base};
  Future<void> flip(String key, String param, String off, String on) async {
    await call('ext.acro.citystudio', {param: off});
    await Future<void>.delayed(const Duration(seconds: 4));
    out[key] = await sample('$key off', 5);
    await call('ext.acro.citystudio', {param: on});
    await Future<void>.delayed(const Duration(seconds: 3));
  }

  if (flips) {
    await flip('shadows', 'shadows', 'false', 'true');
    await flip('atmosphere', 'atmosphere', 'false', 'true');
    await flip('perfPanel', 'perf', 'false', 'true');
    final again = await sample('baseline again', 5);
    out['baselineAgain'] = again;

    stdout.writeln('== deltas vs baseline (ui ms):');
    for (final e in out.entries) {
      if (e.key == 'baseline') continue;
      stdout.writeln(
          '  ${e.key}: ${f(base['uiMs']! - e.value['uiMs']!)} ms ui, '
          '${f(base['frameMs']! - e.value['frameMs']!)} ms frame');
    }
  }

  // ---- The moving camera --------------------------------------------------
  //
  // Each pattern steps the pose at 20 Hz for its duration and reads the
  // status every quarter second: the panel's 90-frame average, the worst
  // frame in that window, the build queue and the governor's level. The
  // worst frame is what a hand feels.
  final sweeps = <String, Map<String, double>>{};
  if (sweep) {
    final az0 = double.parse(opt('azimuth', '0'));
    final d0 = double.parse(distance);
    Future<Map<String, double>> pattern(String label, double seconds,
        Map<String, String> Function(double t) pose) async {
      final acc = <String, double>{
        'frameMs': 0,
        'uiMs': 0,
        'worstMs': 0,
        'queued': 0,
        'governor': 0,
        'submitMs': 0,
        'n': 0,
      };
      final steps = (seconds * 20).round();
      // The panel's windows hold the last ninety frames; a pattern's worst
      // frame must not be the flip or the pattern before it.
      await call('ext.acro.citystudio', {'resetFrames': 'true'});
      final t0 = spikes ? await beginTimeline(vm) : 0;
      for (var i = 0; i < steps; i++) {
        final t = i / 20.0;
        await call('ext.acro.citystudio', pose(t));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        if (i % 5 == 4) {
          final s = await call('ext.acro.citystudio');
          acc['n'] = acc['n']! + 1;
          acc['frameMs'] =
              acc['frameMs']! + ((s['frameMs'] as num?)?.toDouble() ?? 0);
          acc['uiMs'] = acc['uiMs']! + ((s['uiMs'] as num?)?.toDouble() ?? 0);
          final worst = (s['worstMs'] as num?)?.toDouble() ?? 0;
          if (worst > acc['worstMs']!) acc['worstMs'] = worst;
          final m = RegExp(r'(\d+) queued').firstMatch('${s['cityDebug']}');
          final queued = m == null ? 0.0 : double.parse(m.group(1)!);
          if (queued > acc['queued']!) acc['queued'] = queued;
          final gov =
              ((s['governor'] as Map?)?['level'] as num?)?.toDouble() ?? 0;
          if (gov > acc['governor']!) acc['governor'] = gov;
          final sub =
              ((s['phaseMs'] as Map?)?['city.submit'] as num?)?.toDouble() ??
                  0;
          if (sub > acc['submitMs']!) acc['submitMs'] = sub;
        }
      }
      final n = acc['n']!.clamp(1, 1e9);
      final r = {
        'frameMs': acc['frameMs']! / n,
        'uiMs': acc['uiMs']! / n,
        'worstMs': acc['worstMs']!,
        'queued': acc['queued']!,
        'governor': acc['governor']!,
        'submitMs': acc['submitMs']!,
      };
      stdout.writeln('[sweep $label] frame ${f(r['frameMs'])}  '
          'ui ${f(r['uiMs'])}  worst ${f(r['worstMs'])}  '
          'queued max ${r['queued']!.round()}  '
          'submit max ${f(r['submitMs'])}  '
          'governor max ${r['governor']!.round()}');
      sweeps[label] = r;
      if (spikes) {
        reportSpikes(await endTimeline(vm, t0), t0,
            thresholdMs: 16, count: 4, indent: '    ');
      }
      return r;
    }

    String fmt(double v) => v.toStringAsFixed(4);
    // A full turn at the sampling pose: the first over ground the hidden
    // policy left unbuilt, the second over what the first built.
    await pattern(
        'orbit cold', 12, (t) => {'azimuth': fmt(az0 + t / 12 * 6.2832)});
    await pattern(
        'orbit warm', 12, (t) => {'azimuth': fmt(az0 + t / 12 * 6.2832)});
    await pattern('nod', 6, (t) => {
          'elevation':
              fmt(0.3 + 0.9 * (0.5 - 0.5 * math.cos(t / 6 * 6.2832))),
        });
    await call('ext.acro.citystudio', {'elevation': elevation});
    await pattern('zoom', 8, (t) {
      // In to a third, out to three times, back: log-spaced, so each
      // second covers the same ratio.
      final k = math.pow(3.0, math.sin(t / 8 * 6.2832)).toDouble();
      return {'distance': fmt(d0 * k)};
    });
    await call(
        'ext.acro.citystudio', {'distance': distance, 'elevation': elevation});
    await Future<void>.delayed(const Duration(seconds: 3));
    out['settled'] = await sample('settled after sweep', 4);
  }
  if (shot.isNotEmpty) {
    final saved = await call('ext.acro.screenshot', {'path': shot});
    stdout.writeln('== screenshot: $saved');
  }
  stdout.writeln(jsonEncode({...out, 'sweeps': sweeps}));
  await vm.dispose();

  // The gate: each threshold names the figure it bounds.
  var failed = false;
  void check(String name, double? value, double? limit) {
    if (limit == null || value == null) return;
    final ok = value <= limit;
    stdout.writeln(
        '${ok ? 'PASS' : 'FAIL'} $name ${f(value)} ms <= ${f(limit)} ms');
    if (!ok) failed = true;
  }

  check('static frame', base['frameMs'], asserts['static']);
  check('warm orbit frame', sweeps['orbit warm']?['frameMs'], asserts['sweep']);
  final worstSweep = sweeps.values
      .map((r) => r['worstMs'] ?? 0)
      .fold<double>(0, (a, b) => a > b ? a : b);
  check('sweep worst frame', sweeps.isEmpty ? null : worstSweep,
      asserts['worst']);
  if (failed) exit(1);
}
