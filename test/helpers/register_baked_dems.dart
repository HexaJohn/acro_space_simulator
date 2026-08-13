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
/// by design (see [DemRegistry.require]). Idempotent across test files in one
/// process.
void registerBakedDemsForTest() {
  if (DemRegistry.contains('moon')) return;
  final f = File('assets/terrain/moon.acrodem');
  if (!f.existsSync()) {
    throw StateError(
        'assets/terrain/moon.acrodem missing — run tool/bake_dem.dart');
  }
  DemRegistry.register('moon', DemPyramid.decode(f.readAsBytesSync()));
}
