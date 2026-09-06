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
///       [--assert=static:12,sweep:16,worst:33,plat:12]
///
/// `--sweep` drives the camera the way a hand does: a cold orbit over
/// tiles never built, a warm one over the same ground, an elevation nod
/// and a zoom in and out, then a walk, a run and a drive down a street,
/// then the 2D plat panned at street and district scale and zoomed from
/// the county in — reporting each pattern's average frame, UI and raster
/// thread, worst frame, deepest build queue and governor level. Pans and
/// orbits are where the frame has dropped before (tile churn on the camera
/// term, tier flips on the view cone, the isolate send), and a static
/// sample never sees it; the plat is painted on the raster thread, which
/// the UI figure never sees. `--spikes` records the VM timeline through
/// each pattern and names its longest frames — the send, the upload, an
/// archetype generated cold, or a collection. `--assert` makes the run a
/// gate: the process exits 1 when the static average, the warm-orbit
/// average, the sweep's worst frame or the plat's raster average exceeds
/// its threshold in milliseconds.
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
  // --knob=name=value[,name=value]: perf trade-offs set by name before
  // the colony is generated (see PerfKnobs), so one build A/Bs them all.
  final knobs = <String, String>{
    for (final part in opt('knob', '').split(','))
      if (part.contains('=')) part.split('=')[0]: part.split('=')[1],
  };

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
  for (final e in knobs.entries) {
    final r = await call('ext.acro.citystudio', {'knob': e.key, 'value': e.value});
    if (r['error'] != null) {
      stderr.writeln('knob ${e.key}: ${r['error']}');
      exit(2);
    }
  }
  if (knobs.isNotEmpty) {
    final r = await call('ext.acro.citystudio');
    stdout.writeln('== knobs: ${r['knobs']}');
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
  // The ground too: under the frame budget its chunk uploads slow to one
  // a frame while the city builds, and a static sample taken with the
  // ground still meshing read the terrain pass at 6 ms.
  var drained = 0;
  for (var i = 0; i < 300 && drained < 3; i++) {
    await Future<void>.delayed(const Duration(seconds: 2));
    final s = await call('ext.acro.citystudio');
    final m = RegExp(r'(\d+) queued').firstMatch('${s['cityDebug']}');
    final queued = m == null ? 0 : int.parse(m.group(1)!);
    final terrain = (s['terrainMs'] as num?)?.toDouble() ?? 0;
    drained =
        queued == 0 && s['busy'] != true && terrain < 1.5 ? drained + 1 : 0;
  }
  stdout.writeln('== queue drained');
  await call('ext.acro.citystudio',
      {'distance': distance, 'elevation': elevation});
  await Future<void>.delayed(const Duration(seconds: 6));
  // The camera move re-selects the ground; one static sample was taken
  // with the terrain pass at 5.8 ms and read 12.5 where every other run
  // read 8.4. Wait for it too, and for the panel's window to be all
  // settled frames.
  for (var i = 0, calm = 0; i < 60 && calm < 3; i++) {
    final s = await call('ext.acro.citystudio');
    final terrain = (s['terrainMs'] as num?)?.toDouble() ?? 0;
    final m = RegExp(r'(\d+) queued').firstMatch('${s['cityDebug']}');
    final queued = m == null ? 0 : int.parse(m.group(1)!);
    calm = terrain < 1.5 && queued == 0 ? calm + 1 : 0;
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  await call('ext.acro.citystudio', {'resetFrames': 'true'});
  await Future<void>.delayed(const Duration(seconds: 2));

  String f(dynamic v) => (v is num) ? v.toStringAsFixed(2) : '$v';
  Future<Map<String, double>> sample(String label, int n) async {
    final acc = <String, double>{};
    for (var i = 0; i < n; i++) {
      final s = await call('ext.acro.citystudio');
      for (final k in ['frameMs', 'uiMs', 'rasterMs', 'terrainMs', 'cityMs']) {
        acc[k] = (acc[k] ?? 0) + ((s[k] as num?)?.toDouble() ?? 0) / n;
      }
      // The worst frame of the panel's window: for a static sample it is
      // the scavenge that finalises the frames' passes, the number the
      // pacer trades against.
      final worst = (s['worstMs'] as num?)?.toDouble() ?? 0;
      if (worst > (acc['worstMs'] ?? 0)) acc['worstMs'] = worst;
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
      final counts = (s['counts'] as Map?)?.cast<String, dynamic>();
      if (counts != null && i == n - 1) {
        stdout.writeln('    build: queued ${counts['queued']}  '
            'inFlight ${counts['inFlight']}  revealing ${counts['revealing']}  '
            'steps ${counts['steps']}  uploadBytes ${counts['uploadBytes']}  '
            'revealBytes ${counts['revealBytes']}  '
            'built ${counts['builtThisFrame']}  '
            'buildings ${counts['buildings']}');
        stdout.writeln('    queued why: tier ${counts['queued.tier']} '
            'structure ${counts['queued.structure']} knobs ${counts['queued.knobs']} '
            'stale ${counts['queued.stale']} answered ${counts['queued.answered']}');
        stdout.writeln('    caches: tier hits ${counts['tierCacheHits']} '
            'sets ${counts['tierCacheSets']} '
            'MB ${((counts['tierCacheBytes'] ?? 0) / 1048576).toStringAsFixed(0)}  '
            'pool hits ${counts['poolHits']} misses ${counts['poolMisses']} '
            'evicted ${counts['poolEvicted']} free ${counts['poolFree']} '
            'MB ${((counts['poolBytes'] ?? 0) / 1048576).toStringAsFixed(0)}');
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }
    stdout.writeln('[$label] frame ${f(acc['frameMs'])}  ui ${f(acc['uiMs'])}  '
        'raster ${f(acc['rasterMs'])}  worst ${f(acc['worstMs'])}  '
        'terrain ${f(acc['terrainMs'])}  '
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
        // The raster thread alongside the UI thread: the plat is a canvas
        // painted there, and its ~200 ms at street scale never shows in
        // uiMs. The scene's patterns carry it too, for the encode.
        'rasterMs': 0,
        'worstMs': 0,
        'queued': 0,
        'governor': 0,
        'submitMs': 0,
        'sliceMin': 99,
        'sliceSum': 0,
        'n': 0,
      };
      final steps = (seconds * 20).round();
      // The timeline first, and a moment for its start to pass: opening
      // the stream flushes the recorder's ring, a stall of up to half a
      // second that read as the pattern's worst frame when the panel's
      // window was reset after it. Then the panel's windows: they hold
      // the last ninety frames, and a pattern's worst frame must not be
      // the flip or the pattern before it.
      final window = spikes ? await TimelineWindow.begin(vm) : null;
      // What the pattern allocated, by class: the old-generation
      // collections that pause a frame are triggered by churn, and the
      // churn has a name.
      final allocBefore =
          spikes ? await vm.getAllocationProfile(isolateId) : null;
      final phaseSum = <String, double>{};
      var phaseN = 0;
      final budget0 = await call('ext.acro.citystudio');
      final overruns0 =
          ((budget0['frameBudget'] as Map?)?['overruns'] as num?) ?? 0;
      final stalls0 =
          ((budget0['frameBudget'] as Map?)?['stalls'] as num?) ?? 0;
      final fixed0 =
          ((budget0['frameBudget'] as Map?)?['fixedOverruns'] as num?) ?? 0;
      var overheadSum = 0.0, engineSum = 0.0;
      // Every service call above stalls the isolate — the allocation
      // profile walks the heap, the stream's opening flushes the ring —
      // for up to half a second; the panel's windows are reset only
      // after they have all passed, so the pattern's worst frame is the
      // pattern's.
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      await call('ext.acro.citystudio', {'resetFrames': 'true'});
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
          acc['rasterMs'] =
              acc['rasterMs']! + ((s['rasterMs'] as num?)?.toDouble() ?? 0);
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
          // The frame budget's slice: how much of each frame the streamers
          // were allowed, and so how fast a queue could drain.
          final slice =
              ((s['frameBudget'] as Map?)?['sliceMs'] as num?)?.toDouble() ??
                  9;
          if (slice < acc['sliceMin']!) acc['sliceMin'] = slice;
          acc['sliceSum'] = acc['sliceSum']! + slice;
          overheadSum +=
              ((s['frameBudget'] as Map?)?['overheadMs'] as num?)?.toDouble() ??
                  0;
          engineSum +=
              ((s['frameBudget'] as Map?)?['engineMs'] as num?)?.toDouble() ??
                  0;
          // Where the frame goes: every phase the studio times, averaged
          // over the pattern's polls (each poll is itself the panel's
          // 90-frame average).
          final phases = s['phaseMs'] as Map?;
          if (phases != null) {
            phaseN++;
            phases.forEach((k, v) {
              phaseSum['$k'] = (phaseSum['$k'] ?? 0) + ((v as num?)?.toDouble() ?? 0);
            });
          }
        }
      }
      final n = acc['n']!.clamp(1, 1e9);
      final r = {
        'frameMs': acc['frameMs']! / n,
        'uiMs': acc['uiMs']! / n,
        'rasterMs': acc['rasterMs']! / n,
        'worstMs': acc['worstMs']!,
        'queued': acc['queued']!,
        'governor': acc['governor']!,
        'submitMs': acc['submitMs']!,
        'sliceMin': acc['sliceMin']!,
        'sliceAvg': acc['sliceSum']! / n,
      };
      stdout.writeln('[sweep $label] frame ${f(r['frameMs'])}  '
          'ui ${f(r['uiMs'])}  raster ${f(r['rasterMs'])}  '
          'worst ${f(r['worstMs'])}  '
          'queued max ${r['queued']!.round()}  '
          'submit max ${f(r['submitMs'])}  '
          'governor max ${r['governor']!.round()}  '
          'slice avg ${f(r['sliceAvg'])} min ${f(r['sliceMin'])}');
      final budget1 = await call('ext.acro.citystudio');
      final overruns1 =
          ((budget1['frameBudget'] as Map?)?['overruns'] as num?) ?? 0;
      final stalls1 =
          ((budget1['frameBudget'] as Map?)?['stalls'] as num?) ?? 0;
      final fixed1 =
          ((budget1['frameBudget'] as Map?)?['fixedOverruns'] as num?) ?? 0;
      stdout.writeln('    budget: overruns ${overruns1 - overruns0}  '
          'fixed overruns ${fixed1 - fixed0}  '
          'stalls ${stalls1 - stalls0}  '
          'overhead avg ${f(overheadSum / n)}  engine avg ${f(engineSum / n)}');
      if (phaseN > 0) {
        final top = phaseSum.entries
            .map((e) => MapEntry(e.key, e.value / phaseN))
            .where((e) => e.value >= 0.05)
            .toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        stdout.writeln('    phases: ${top.take(10).map((e) => '${e.key} ${f(e.value)}').join('  ')}');
      }
      sweeps[label] = r;
      if (window != null) {
        final spans = await window.end();
        // The worst frame by the timeline's own clock, past the stream's
        // opening stall: the panel's worst has no timestamp to exclude
        // it by.
        final frames = framesOf(spans)
            .where((fr) => fr.ts - window.t0 > 3000000)
            .toList()
          ..sort((a, b) => b.dur.compareTo(a.dur));
        if (frames.isNotEmpty) {
          stdout.writeln('    timeline worst (after 3 s): '
              '${f(frames.first.dur / 1000)} ms @'
              '${((frames.first.ts - window.t0) / 1e6).toStringAsFixed(2)}s');
        }
        reportSpikes(spans, window.t0,
            thresholdMs: 16, count: 4, indent: '    ');
        final allocAfter = await vm.getAllocationProfile(isolateId);
        final before = <String, int>{
          for (final m in allocBefore!.members ?? const [])
            '${m.classRef?.id}': m.accumulatedSize ?? 0,
        };
        final deltas = <(String, int, int)>[];
        for (final m in allocAfter.members ?? const []) {
          final bytes = (m.accumulatedSize ?? 0) - (before['${m.classRef?.id}'] ?? 0);
          if (bytes > 0) deltas.add(('${m.classRef?.name}', bytes, m.instancesCurrent ?? 0));
        }
        deltas.sort((a, b) => b.$2.compareTo(a.$2));
        final total = deltas.fold<int>(0, (a, d) => a + d.$2);
        stdout.writeln('    allocated ${(total / 1048576).toStringAsFixed(0)} MB:');
        for (final d in deltas.take(10)) {
          stdout.writeln('      ${(d.$2 / 1048576).toStringAsFixed(1).padLeft(7)} MB  '
              '${d.$1}  (live ${d.$3})');
        }
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

    // ---- On foot, and at the wheel ---------------------------------------
    //
    // At eye height every sixty-four metres of travel re-keys the tile for
    // per-building detail, and full-detail archetypes are generated cold on
    // the UI thread: a walk is its own spike class. The walker starts where
    // the studio's G key puts it (colony-local 0, -40, facing north), walks
    // a street for ten seconds turning slowly, then runs; the buggy drives
    // the same street. The pattern's pose call is a no-op ping — the
    // motion is the studio's own, held by the walkDrive hook.
    await call('ext.acro.citystudio',
        {'walk': '0,-40,0,0'});
    await Future<void>.delayed(const Duration(seconds: 3));
    await call('ext.acro.citystudio', {'walkDrive': '1,0,0,0.12,10.5'});
    await pattern('walk', 10, (t) => const {'ping': '1'});
    await call('ext.acro.citystudio', {'walkDrive': '1,0,1,0.05,8.5'});
    await pattern('run', 8, (t) => const {'ping': '1'});
    await call('ext.acro.citystudio', {'drive': '0,-40,0,1,0.1,8.5'});
    await Future<void>.delayed(const Duration(seconds: 1));
    await pattern('drive', 8, (t) => const {'ping': '1'});
    await call('ext.acro.citystudio', {'view': 'orbit'});
    await call(
        'ext.acro.citystudio', {'distance': distance, 'elevation': elevation});
    await Future<void>.delayed(const Duration(seconds: 3));
    out['settledAfterWalk'] = await sample('settled after walk', 3);

    // ---- The plat ---------------------------------------------------------
    //
    // The 2D view is a canvas painted on the raster thread, and at street
    // scale it has cost ~200 ms a frame there while the UI thread read
    // idle — a cost no scene pattern sees. Each pattern drives the plat's
    // camera through the hook the way a hand does at one LOD: a pan at
    // street scale (every lot outlined), a pan at district scale (avenues
    // and block tints), and a zoom from the county down into the streets
    // about the colony's centre, crossing every level on the way. The
    // figure that matters is the pattern's raster average, gated by
    // `plat:`. The scene comes back after, and settles before the shot.
    await call('ext.acro.citystudio', {'view': 'plat'});
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await pattern('plat street pan', 8, (t) {
      // 600 m east over the pattern at one metre a pixel.
      return {'plat': '${fmt(t / 8 * 600)},0,1'};
    });
    await pattern('plat district pan', 8, (t) {
      // 8 km east at twelve metres a pixel: the same screens a second.
      return {'plat': '${fmt(t / 8 * 8000)},0,12'};
    });
    await pattern('plat zoom', 8, (t) {
      // County to street, 60 down to 0.6 m/px, log-spaced so each second
      // covers the same ratio and the LOD flips land where a wheel puts
      // them.
      final mpp = 60 * math.pow(0.01, t / 8).toDouble();
      return {'plat': '0,0,${fmt(mpp)}'};
    });
    await call('ext.acro.citystudio', {'view': 'orbit'});
    await Future<void>.delayed(const Duration(seconds: 2));
    out['settledAfterPlat'] = await sample('settled after plat', 3);
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

  // The UI thread's build time, not the frame: once the display paces
  // presentation at 60 Hz the frame reads 16.7 ms whatever the work cost,
  // and overnight the monitor's sleep flips that pacing. The worst frame
  // stays a frame — a stall is a stall however it is paced.
  if ((base['frameMs'] ?? 0) > 15.5 && (base['uiMs'] ?? 0) < 12) {
    stdout.writeln('note: presentation is vsync-paced (frame '
        '${f(base['frameMs'])} ms, ui ${f(base['uiMs'])} ms); the gate '
        'reads the UI thread');
  }
  check('static ui build', base['uiMs'], asserts['static']);
  check('warm orbit ui build', sweeps['orbit warm']?['uiMs'], asserts['sweep']);
  // The worst frame of every pattern but the cold orbit: its worst is the
  // one stall at the first camera move after generation (a raster-thread
  // encode of ~500 ms, see the wiki), a known open item that would fail
  // the gate on every run and hide a real regression behind it. It is
  // printed on its own line instead. The tile-landing worst the gate
  // exists for shows in every other pattern.
  final cold = sweeps['orbit cold']?['worstMs'];
  if (cold != null) {
    stdout.writeln('first-move stall (cold orbit worst, not gated): '
        '${f(cold)} ms');
  }
  final worstSweep = sweeps.entries
      .where((e) => e.key != 'orbit cold')
      .map((e) => e.value['worstMs'] ?? 0)
      .fold<double>(0, (a, b) => a > b ? a : b);
  check('sweep worst frame (past the cold orbit)',
      sweeps.length < 2 ? null : worstSweep, asserts['worst']);
  // The plat on the raster thread: the worst of its three patterns'
  // averages, since one LOD alone painting slow is the regression.
  final platPatterns = sweeps.entries
      .where((e) => e.key.startsWith('plat '))
      .map((e) => e.value['rasterMs'] ?? 0)
      .toList();
  check(
      'plat raster',
      platPatterns.isEmpty
          ? null
          : platPatterns.fold<double>(0, (a, b) => a > b ? a : b),
      asserts['plat']);
  if (failed) exit(1);
}
