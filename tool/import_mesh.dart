// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Converts licensed source models (`mesh_src/**.glb`, gitignored) into
/// flutter_scene `.fsceneb` packages in `assets/mesh/` — the only mesh format
/// the app bundles.
///
/// The search is recursive, so sources may be filed into subdirectories by
/// vendor or craft (`mesh_src/LEM Parts/eagle_legs.glb`). Output is FLAT:
/// every bake lands directly in `assets/mesh/`, because `PartDef.modelAsset`
/// keys off a single-segment asset name and pubspec bundles `assets/mesh/`
/// as one directory. Flattening can make two differently-filed sources claim
/// the same output, so a collision is a hard error — see [_checkCollisions].
///
/// Run after dropping in or updating a .glb:
///
///     fvm dart run tool/import_mesh.dart          # bake every source
///     fvm dart run tool/import_mesh.dart eagle    # bake matching sources only
///
/// Any arguments are substring filters against the source path (case
/// insensitive, `/`-normalised); a source is baked if it matches ANY of them.
/// A full bake of the current set takes minutes and hundreds of megabytes of
/// texture transcoding, so the filter exists to re-bake one model after a
/// tweak without paying for the rest.
///
/// Both the .glb sources and the .fsceneb outputs are gitignored — the
/// models are licensed for commercial use but NOT redistribution, so they
/// live only on dev machines, inside built app bundles, and in the private
/// HexaJohn/acro-space-assets repo. Clones without them fall back to
/// procedural part meshes (see VesselNodes._failedAssets).
library;

import 'dart:io';

// Offline importer is not in flutter_scene's public API surface yet.
// ignore: implementation_imports
import 'package:flutter_scene/src/importer/offline_import.dart';

/// Anything outside this set becomes `_` in an output name.
///
/// Asset paths travel through pubspec manifests, the Flutter asset bundle and
/// (for bridged clients) the FlatBuffers wire, so the safe alphabet is the
/// conservative intersection: lowercase ASCII, digits, `_` and `-`. Spaces in
/// particular must go — `mesh_src/LEM Parts/` is a real source directory.
final RegExp _unsafeInName = RegExp(r'[^a-z0-9_-]');

const String _glbExt = '.glb';
const String _outDir = 'assets/mesh';

/// The flat, sanitised output basename (no extension) for [glb].
String _outputStem(File glb) {
  // File.uri normalises Windows separators and percent-decodes, so the last
  // segment is the plain basename regardless of host path style.
  final base = glb.uri.pathSegments.last;
  final stem = base.substring(0, base.length - _glbExt.length);
  return stem.toLowerCase().replaceAll(_unsafeInName, '_');
}

/// Source path in a stable, comparable form: forward slashes, lowercase.
String _matchPath(File glb) => glb.path.replaceAll(r'\', '/').toLowerCase();

/// Aborts if two sources would bake over each other in [_outDir].
///
/// Always run against the FULL source set, never the filtered subset: a
/// filtered re-bake that quietly clobbers an unrelated model is exactly the
/// invisible failure this guard exists to prevent.
///
/// Returns true when the set is safe to bake.
bool _checkCollisions(List<File> allSources) {
  final byStem = <String, List<String>>{};
  for (final glb in allSources) {
    byStem.putIfAbsent(_outputStem(glb), () => <String>[]).add(glb.path);
  }
  final clashes = byStem.entries.where((e) => e.value.length > 1).toList();
  if (clashes.isEmpty) return true;

  stderr.writeln(
    'Output name collision — refusing to bake, one source would silently '
    'overwrite another:',
  );
  for (final clash in clashes) {
    stderr.writeln('  $_outDir/${clash.key}.fsceneb is claimed by:');
    for (final src in clash.value) {
      stderr.writeln('    $src');
    }
  }
  stderr.writeln(
    'Rename one of the sources (output names are lowercased and any character '
    'outside [a-z0-9_-] becomes "_", so "RCS Block.glb" and "rcs_block.glb" '
    'collide).',
  );
  return false;
}

void main(List<String> args) {
  final srcDir = Directory('mesh_src');
  if (!srcDir.existsSync()) {
    stderr.writeln('mesh_src not found — run from the repo root.');
    exitCode = 2;
    return;
  }

  final allSources =
      srcDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith(_glbExt))
          .toList()
        // Deterministic order so the stdout log is diffable run to run.
        ..sort((a, b) => _matchPath(a).compareTo(_matchPath(b)));
  if (allSources.isEmpty) {
    stderr.writeln(
      'No .glb sources in mesh_src — nothing to import. '
      '(Licensed models are gitignored; copy them in locally first.)',
    );
    exitCode = 1;
    return;
  }

  if (!_checkCollisions(allSources)) {
    exitCode = 3;
    return;
  }

  final filters = args
      .map((a) => a.replaceAll(r'\', '/').toLowerCase())
      .toList();
  final sources = filters.isEmpty
      ? allSources
      : allSources.where((f) {
          final path = _matchPath(f);
          return filters.any(path.contains);
        }).toList();
  if (sources.isEmpty) {
    stderr.writeln(
      'No source matched ${args.map((a) => '"$a"').join(', ')} — '
      '${allSources.length} .glb found under mesh_src:',
    );
    for (final glb in allSources) {
      stderr.writeln('  ${glb.path}');
    }
    exitCode = 1;
    return;
  }
  if (filters.isNotEmpty) {
    stdout.writeln(
      'Filtered to ${sources.length} of ${allSources.length} sources.',
    );
  }

  Directory(_outDir).createSync(recursive: true);
  for (final glb in sources) {
    final out = '$_outDir/${_outputStem(glb)}.fsceneb';
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
