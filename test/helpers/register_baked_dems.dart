// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:io';

import 'package:acro_space_simulator/domain/terrain/dem_pyramid.dart';
import 'package:acro_space_simulator/domain/terrain/dem_registry.dart';

/// File-based DEM registration for tests (no asset bundle in plain VM tests).
///
/// Call from `setUpAll` in any test that builds a terrain field for a body
/// whose catalogue entry declares `demBodyId` — without it those fields THROW
/// by design (see [DemRegistry.require]). Registers every baked pyramid in
/// `assets/terrain/` by its basename (moon.acrodem -> 'moon'), so a body
/// gaining a DEM never needs this helper edited. Idempotent across test files
/// in one process.
void registerBakedDemsForTest() {
  final dir = Directory('assets/terrain');
  if (!dir.existsSync()) {
    throw StateError('assets/terrain missing — run tool/bake_dem.dart');
  }
  var found = 0;
  for (final f in dir.listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    if (!name.endsWith('.acrodem')) continue;
    found++;
    final id = name.substring(0, name.length - '.acrodem'.length);
    if (DemRegistry.contains(id)) continue;
    DemRegistry.register(id, DemPyramid.decode(f.readAsBytesSync()));
  }
  if (found == 0) {
    throw StateError(
        'no .acrodem pyramids in assets/terrain — run tool/bake_dem.dart');
  }
}
