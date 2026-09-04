// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Samples the UI isolate's CPU profile over the VM service and prints the
/// hottest functions (exclusive ticks), so a "ui build is N ms" reading can
/// be attributed to real code without attaching DevTools:
///
///   dart run tool/profile_ui_thread.dart <vm-service-uri> [seconds]
library;

import 'dart:io';

import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  final ws = args[0]
      .replaceFirst('http://', 'ws://')
      .replaceFirst(RegExp(r'/?$'), '/ws');
  final seconds = args.length > 1 ? int.parse(args[1]) : 4;
  final vm = await vmServiceConnectUri(ws);
  final isolateId = (await vm.getVM()).isolates!.first.id!;

  // The desktop embedder ships with the VM profiler off; flip it on live.
  try {
    final r = await vm.setFlag('profiler', 'true');
    stdout.writeln('== profiler flag: ${r.type}');
  } catch (e) {
    stdout.writeln('== setFlag failed: $e');
  }

  // getCpuSamples' window is in the VM's own monotonic clock, not wall time.
  final t0 = (await vm.getVMTimelineMicros()).timestamp!;
  stdout.writeln('== sampling ${seconds}s...');
  await Future<void>.delayed(Duration(seconds: seconds));
  final CpuSamples s = await vm.getCpuSamples(
      isolateId, t0, seconds * 1000000);

  final funcs = s.functions ?? const [];
  final exclusive = <int, int>{};
  for (final sample in s.samples ?? const <CpuSample>[]) {
    final stack = sample.stack;
    if (stack == null || stack.isEmpty) continue;
    exclusive.update(stack.first, (n) => n + 1, ifAbsent: () => 1);
  }
  final total = (s.samples ?? const []).length;
  stdout.writeln('== $total samples @ ${s.samplePeriod}us');

  // Inclusive attribution under named roots: a sample counts toward a root
  // when any frame of its stack is a function whose name contains the
  // pattern. Splits the frame budget at the subsystem level before the
  // exclusive leaf view below fine-tunes inside one.
  String nameOf(int idx) {
    final f = idx < funcs.length ? funcs[idx].function : null;
    if (f is FuncRef) {
      final owner = f.owner;
      return '${owner is ClassRef ? '${owner.name}.' : ''}${f.name}';
    }
    if (f is NativeFunction) return 'native:${f.name}';
    return '$f';
  }

  const roots = [
    'AdvanceSimulationTick.execute',
    'SceneSync.update',
    'TerrainNodes.update',
    'LineNodes.update',
    'ScatterNodes.update',
    'TopDownSnapshotPresenter.present',
    'SceneView.', // flutter_scene draw encoding
    'StatefulElement.build',
    'RendererBinding.drawFrame',
    'orbitPathRelativeToParent',
    '_solveKepler',
    'MarkingVisitor', // GC
  ];
  final inclusive = <String, int>{for (final r in roots) r: 0};
  for (final sample in s.samples ?? const <CpuSample>[]) {
    final seen = <String>{};
    for (final idx in sample.stack ?? const <int>[]) {
      final n = nameOf(idx);
      for (final r in roots) {
        if (n.contains(r)) seen.add(r);
      }
    }
    for (final r in seen) {
      inclusive[r] = inclusive[r]! + 1;
    }
  }
  stdout.writeln('-- inclusive --');
  for (final r in roots) {
    final n = inclusive[r]!;
    stdout.writeln(
        '${(n * 100 / total).toStringAsFixed(1).padLeft(5)}%  $r');
  }
  stdout.writeln('-- exclusive leaves --');
  final rows = exclusive.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  for (final e in rows.take(30)) {
    final f = e.key < funcs.length ? funcs[e.key] : null;
    final fr = f?.function;
    final name = fr is FuncRef
        ? '${(fr.owner is ClassRef) ? '${(fr.owner as ClassRef).name}.' : ''}'
            '${fr.name}'
        : (fr is NativeFunction ? 'native:${fr.name}' : '$fr');
    final pct = (e.value * 100 / total).toStringAsFixed(1);
    stdout.writeln('${pct.padLeft(5)}%  ${e.value.toString().padLeft(5)}  '
        '$name');
  }
  await vm.dispose();
}
