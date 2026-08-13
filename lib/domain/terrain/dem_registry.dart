// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dem_pyramid.dart';

/// Process-wide registry of decoded DEM pyramids, keyed by body id.
///
/// The seam between async asset loading and the synchronous deterministic
/// tick: infrastructure decodes `assets/terrain/<body>.acrodem` ONCE at boot
/// and registers it here; `TerrainConfig.fieldFor` then consults the registry
/// synchronously — collision samples terrain from inside the tick and cannot
/// await a bundle load.
///
/// Registration is REQUIRED for a body whose `TerrainConfig` declares
/// [TerrainConfig.demBodyId]: a missing pyramid throws instead of silently
/// falling back to procedural relief. A peer that quietly walked procedural
/// ground while the server walked DEM ground would be a determinism desync
/// with the ground itself — far worse than failing to start.
class DemRegistry {
  DemRegistry._();

  static final Map<String, DemPyramid> _byBody = {};

  static void register(String bodyId, DemPyramid dem) => _byBody[bodyId] = dem;

  static bool contains(String bodyId) => _byBody.containsKey(bodyId);

  static DemPyramid require(String bodyId) {
    final dem = _byBody[bodyId];
    if (dem == null) {
      throw StateError(
          'DEM for "$bodyId" is not registered — decode assets/terrain/'
          '$bodyId.acrodem and DemRegistry.register() it before building '
          'the body\'s terrain field');
    }
    return dem;
  }

  /// Tests only — a leftover registration would let one test's ground leak
  /// into the next.
  static void clear() => _byBody.clear();
}
