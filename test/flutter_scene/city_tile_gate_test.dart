// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/architecture/building_generator.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/city/city_nodes.dart';
import 'package:flutter_test/flutter_test.dart';

/// The camera enters a near tile's build key only when a building in it
/// could resolve past a block — and a tile's bounding sphere alone says yes
/// far too often from above.
void main() {
  const near = CityTier.near;
  const full = BuildingDetail.full;

  test('the bounding sphere alone keeps the camera term at altitude', () {
    // Eye inside the tile's sphere: least distance reads 0.
    expect(
      CityNodes.tileCanDetail(near, 0, colonyTier: full,
          perBuildingLod: true, blockRangeM: 300),
      isTrue,
    );
  });

  test('the altitude bound removes it when the eye is above block range', () {
    // Body radius 1,737 km; buildings up to 40 m over the datum; the eye
    // 690 m up. No building can be within 300 m of the eye.
    expect(
      CityNodes.tileCanDetail(near, 0,
          colonyTier: full,
          perBuildingLod: true,
          blockRangeM: 300,
          focusRadiusM: 1737000 + 690,
          tileMaxRadiusM: 1737000 + 40),
      isFalse,
    );
  });

  test('a low eye keeps the camera term', () {
    expect(
      CityNodes.tileCanDetail(near, 0,
          colonyTier: full,
          perBuildingLod: true,
          blockRangeM: 300,
          focusRadiusM: 1737000 + 120,
          tileMaxRadiusM: 1737000 + 40),
      isTrue,
    );
  });

  test('a tile beyond block range never carries the camera', () {
    expect(
      CityNodes.tileCanDetail(near, 301,
          colonyTier: full,
          perBuildingLod: true,
          blockRangeM: 300,
          focusRadiusM: 1737000 + 50,
          tileMaxRadiusM: 1737000 + 40),
      isFalse,
    );
  });

  test('without per-building LOD the colony tier answers', () {
    expect(
      CityNodes.tileCanDetail(near, 0,
          colonyTier: BuildingDetail.block,
          perBuildingLod: false,
          focusRadiusM: 1737000 + 50,
          tileMaxRadiusM: 1737000 + 40),
      isFalse,
    );
    expect(
      CityNodes.tileCanDetail(near, 0,
          colonyTier: full,
          perBuildingLod: false,
          focusRadiusM: 1737000 + 5000,
          tileMaxRadiusM: 1737000 + 40),
      isTrue,
    );
  });
}
