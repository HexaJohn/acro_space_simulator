// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Converts licensed source models (mesh_src/*.glb, gitignored) into
/// flutter_scene `.fsceneb` packages in assets/mesh/ — the only mesh format
/// the app bundles.
///
/// Run after dropping in or updating a .glb:
///
///     fvm dart run tool/import_mesh.dart
///
/// Both the .glb sources and the .fsceneb outputs are gitignored — the
/// models are licensed for commercial use but NOT redistribution, so they
/// live only on dev machines and inside built app bundles, never the repo.
/// Clones without them fall back to procedural part meshes (see
/// VesselNodes._failedAssets).
library;

import 'dart:io';

// Offline importer is not in flutter_scene's public API surface yet.
// ignore: implementation_imports
import 'package:flutter_scene/src/importer/offline_import.dart';

void main() {
  final srcDir = Directory('mesh_src');
  if (!srcDir.existsSync()) {
    stderr.writeln('mesh_src not found — run from the repo root.');
    exitCode = 2;
    return;
  }

  final sources = srcDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.glb'))
      .toList();
  if (sources.isEmpty) {
    stderr.writeln(
      'No .glb sources in mesh_src — nothing to import. '
      '(Licensed models are gitignored; copy them in locally first.)',
    );
    exitCode = 1;
    return;
  }

  for (final glb in sources) {
    final name = glb.uri.pathSegments.last;
    final out =
        'assets/mesh/${name.substring(0, name.length - '.glb'.length)}.fsceneb';
    stdout.writeln('${glb.path} -> $out');
    final sw = Stopwatch()..start();
    // KTX2 texture payloads: far smaller than raw rgba8 (apollo: 511 MB ->
    // KTX2), mipped, and one more step removed from the licensed source.
    importGltfToFsceneb(glb.path, out, compressTextures: true);
    final inMb = glb.lengthSync() / (1024 * 1024);
    final outMb = File(out).lengthSync() / (1024 * 1024);
    stdout.writeln(
      '  ${inMb.toStringAsFixed(1)} MB -> ${outMb.toStringAsFixed(1)} MB '
      'in ${sw.elapsedMilliseconds} ms',
    );
  }
}
