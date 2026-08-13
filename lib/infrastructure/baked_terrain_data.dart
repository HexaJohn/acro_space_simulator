// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:flutter/services.dart' show rootBundle;

import '../domain/terrain/dem_pyramid.dart';
import '../domain/terrain/dem_registry.dart';
import '../domain/universe/real_solar_system.dart';

/// Decode and register every baked DEM the catalogue declares. MUST complete
/// before the first terrain field is built — collision consults the registry
/// synchronously from the deterministic tick, so this is an awaited boot step,
/// not a fire-and-forget like the albedo textures.
///
/// Catalogue-driven on purpose: adding a surveyed body means baking its
/// `.acrodem` and setting `demBodyId` in the catalogue — no second list here
/// to forget. A declared-but-missing asset throws (via `DemPyramid.decode` or
/// the bundle itself): a mis-loaded DEM silently moves the ground, which is
/// far worse than failing to boot.
Future<void> loadBakedTerrainData() async {
  for (final body in RealSolarSystem.build().all) {
    final id = body.terrain?.demBodyId;
    if (id == null || DemRegistry.contains(id)) continue;
    final data = await rootBundle.load('assets/terrain/$id.acrodem');
    DemRegistry.register(
      id,
      DemPyramid.decode(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)),
    );
  }
}
