// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'plant_generator.dart';
import 'prop_model.dart';
import 'rock_generator.dart';
import 'tree_generator.dart';

/// Every prop the scatter system can grow, as one flat list.
///
/// Placement will want to say "give me a temperate lowland mix" without caring
/// which of three generators answers, so the kind is the unit of selection and
/// the generator behind it is an implementation detail.
enum PropKind {
  broadleafTree,
  coniferTree,
  palmTree,
  deadSnag,
  grassTuft,
  fern,
  shrub,
  reeds,
  boulder,
  rockShard,
  rockSlab,
  rockCluster,
}

/// Which generator family a kind belongs to — drives grouping in UI and, later,
/// per-family scatter density rules.
enum PropFamily { tree, plant, rock }

extension PropKindInfo on PropKind {
  PropFamily get family => switch (this) {
        PropKind.broadleafTree ||
        PropKind.coniferTree ||
        PropKind.palmTree ||
        PropKind.deadSnag =>
          PropFamily.tree,
        PropKind.grassTuft ||
        PropKind.fern ||
        PropKind.shrub ||
        PropKind.reeds =>
          PropFamily.plant,
        PropKind.boulder ||
        PropKind.rockShard ||
        PropKind.rockSlab ||
        PropKind.rockCluster =>
          PropFamily.rock,
      };

  /// Human label for the preview UI and debug output.
  String get label => switch (this) {
        PropKind.broadleafTree => 'Broadleaf tree',
        PropKind.coniferTree => 'Conifer',
        PropKind.palmTree => 'Palm',
        PropKind.deadSnag => 'Dead snag',
        PropKind.grassTuft => 'Grass tuft',
        PropKind.fern => 'Fern',
        PropKind.shrub => 'Shrub',
        PropKind.reeds => 'Reeds',
        PropKind.boulder => 'Boulder',
        PropKind.rockShard => 'Rock shard',
        PropKind.rockSlab => 'Rock slab',
        PropKind.rockCluster => 'Rock cluster',
      };

  /// The size this kind defaults to (m) — height for trees and plants, nominal
  /// radius for rocks.
  double get defaultSizeM => switch (this) {
        PropKind.broadleafTree => 12.0,
        PropKind.coniferTree => 18.0,
        PropKind.palmTree => 9.0,
        PropKind.deadSnag => 8.0,
        PropKind.grassTuft => 0.38,
        PropKind.fern => 0.62,
        PropKind.shrub => 0.95,
        PropKind.reeds => 1.45,
        PropKind.boulder => 1.1,
        PropKind.rockShard => 0.75,
        PropKind.rockSlab => 1.4,
        PropKind.rockCluster => 0.95,
      };

  /// A sensible spacing (m) for laying this kind out on a preview grid, so a
  /// conifer and a grass tuft both fill the frame sensibly.
  double get previewSpacingM => switch (family) {
        PropFamily.tree => defaultSizeM * 0.85,
        PropFamily.plant => defaultSizeM * 1.6,
        PropFamily.rock => defaultSizeM * 2.6,
      };
}

/// Grow every LOD plus the imposter for [kind].
///
/// [seed] selects the individual; [sizeM] overrides the kind's default size
/// (height for trees/plants, radius for rocks).
PropLodSet buildProp(PropKind kind, {int seed = 1, double? sizeM}) =>
    switch (kind) {
      PropKind.broadleafTree => buildTreeLodSet(
          TreeParams.of(TreeSpecies.broadleaf, seed: seed, heightM: sizeM)),
      PropKind.coniferTree => buildTreeLodSet(
          TreeParams.of(TreeSpecies.conifer, seed: seed, heightM: sizeM)),
      PropKind.palmTree => buildTreeLodSet(
          TreeParams.of(TreeSpecies.palm, seed: seed, heightM: sizeM)),
      PropKind.deadSnag => buildTreeLodSet(
          TreeParams.of(TreeSpecies.deadSnag, seed: seed, heightM: sizeM)),
      PropKind.grassTuft => buildPlantLodSet(
          PlantParams.of(PlantSpecies.grassTuft, seed: seed, heightM: sizeM)),
      PropKind.fern => buildPlantLodSet(
          PlantParams.of(PlantSpecies.fern, seed: seed, heightM: sizeM)),
      PropKind.shrub => buildPlantLodSet(
          PlantParams.of(PlantSpecies.shrub, seed: seed, heightM: sizeM)),
      PropKind.reeds => buildPlantLodSet(
          PlantParams.of(PlantSpecies.reeds, seed: seed, heightM: sizeM)),
      PropKind.boulder => buildRockLodSet(
          RockParams.of(RockSpecies.boulder, seed: seed, radiusM: sizeM)),
      PropKind.rockShard => buildRockLodSet(
          RockParams.of(RockSpecies.shard, seed: seed, radiusM: sizeM)),
      PropKind.rockSlab => buildRockLodSet(
          RockParams.of(RockSpecies.slab, seed: seed, radiusM: sizeM)),
      PropKind.rockCluster => buildRockLodSet(
          RockParams.of(RockSpecies.cluster, seed: seed, radiusM: sizeM)),
    };
