// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:io';

import 'package:flutter_scene/fscene.dart' as fsb;
import 'package:flutter_test/flutter_test.dart';

/// Diagnostic: what is inside the craft bakes — texture/geometry payload
/// counts, formats, and byte sizes. Run when load-time cost needs attributing
/// to specific resources (`ResourceRealizer.preload` walks every one of
/// these). Skips on clones without the licensed assets.
void main() {
  for (final path in ['assets/mesh/apollo.fsceneb', 'assets/mesh/lander.fsceneb']) {
    test('$path payload stats', () async {
      final file = File(path);
      if (!file.existsSync()) {
        markTestSkipped('licensed bake not present in this clone');
        return;
      }
      final doc = fsb.readFsceneb(await file.readAsBytes());
      // ignore: avoid_print
      print('=== $path: ${doc.nodes.length} nodes, '
          '${doc.resources.length} resources, ${doc.payloads.length} payloads');
      final byKind = <String, int>{};
      final bytesByKind = <String, int>{};
      for (final p in doc.payloads.values) {
        final kind = '${p.encoding.name}/${p.format ?? '-'}'
            '${p.width != null ? ' ${p.width}x${p.height}' : ''}';
        byKind[kind] = (byKind[kind] ?? 0) + 1;
        bytesByKind[kind] = (bytesByKind[kind] ?? 0) + (p.bytes?.length ?? 0);
      }
      for (final e in byKind.entries) {
        // ignore: avoid_print
        print('  ${e.key}: ${e.value} payloads, '
            '${(bytesByKind[e.key]! / (1024 * 1024)).toStringAsFixed(1)} MB');
      }
    });
  }
}
