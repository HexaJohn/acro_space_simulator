// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter_scene/fscene.dart' as fsb;
import 'package:flutter_test/flutter_test.dart';

/// VesselNodes parses craft bakes with `compute(readFsceneb, ...)` so the
/// ~130 MB of container decode stays off the UI isolate (a synchronous
/// `loadFscenebAsset` call froze flight entry for seconds). That only works
/// if [fsb.SceneDocument] survives the isolate send — it must stay pure data
/// (no closures, ports, or GPU handles). This exercises the real bakes when
/// present; clones without the licensed assets skip.
void main() {
  for (final path in ['assets/mesh/apollo.fsceneb', 'assets/mesh/lander.fsceneb']) {
    test('$path parses in a background isolate', () async {
      final file = File(path);
      if (!file.existsSync()) {
        markTestSkipped('licensed bake not present in this clone');
        return;
      }
      final bytes = await file.readAsBytes();
      final sw = Stopwatch()..start();
      final doc = await compute(fsb.readFsceneb, bytes, debugLabel: 'parse $path');
      sw.stop();
      // ignore: avoid_print
      print('$path: parsed ${bytes.length ~/ (1024 * 1024)} MB off-thread '
          'in ${sw.elapsedMilliseconds} ms');
      expect(doc.nodes, isNotEmpty);
      expect(doc.roots, isNotEmpty);
      // Payload bytes must cross the isolate boundary attached — realize
      // reads vertex/index buffers and textures from them.
      expect(doc.payloads.values.any((p) => p.bytes != null), isTrue);
    });
  }
}
