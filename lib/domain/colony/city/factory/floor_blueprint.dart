// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A floor design with no site attached (docs/plans/factory-floors.md §3
/// "Design before building").
///
/// A blueprint is a hall size, a layout and a handler roster. The player can
/// draw one from the build menu before the plant exists, save a live floor as
/// one, or start from a template (every template is a built-in blueprint).
/// Placing the plant stamps the chosen blueprint onto the site's building
/// envelope; [fitsEnvelope] is what the placement preview asks first.
library;

import '../site_access/site_envelope.dart';
import 'factory_entities.dart';
import 'factory_grid.dart';
import 'factory_handling.dart';
import 'factory_recipe.dart';

/// Why a layout is not buildable as drawn.
enum BlueprintIssueKind { outOfHall, overlap, unknownRecipe, missingSpan }

class BlueprintIssue {
  const BlueprintIssue(this.kind, this.placementId, [this.otherId]);
  final BlueprintIssueKind kind;
  final int placementId;
  final int? otherId;

  @override
  String toString() => 'BlueprintIssue(${kind.name} #$placementId'
      '${otherId == null ? '' : ' vs #$otherId'})';
}

/// Kinds that may share tiles with others: floor markings, not objects.
/// Belts may run through an aisle (that is what a [EntityKind.crossing] is
/// for) and a crane bay spans over machines.
const Set<EntityKind> kOverlayKinds = {
  EntityKind.aisle,
  EntityKind.craneBay,
  EntityKind.staging,
};

class FloorBlueprint {
  FloorBlueprint({
    required this.name,
    required this.hall,
    List<Placement>? placements,
    Map<HandlerKind, int>? roster,
    this.plantType,
  })  : placements = placements ?? [],
        roster = roster ?? {};

  String name;

  /// The `CityBuildingSpec.type` it was drawn for (null = any plant).
  final String? plantType;

  HallSize hall;
  final List<Placement> placements;

  /// Handlers hired, by kind.
  final Map<HandlerKind, int> roster;

  int get nextId =>
      placements.fold(0, (m, p) => p.id > m ? p.id : m) + 1;

  Placement? byId(int id) {
    for (final p in placements) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Every reason this layout can't be built, in placement order. Empty =
  /// buildable. Overlap is reported once per pair, against the earlier one.
  List<BlueprintIssue> validate() {
    final issues = <BlueprintIssue>[];
    final solid = <Placement>[];
    for (final p in placements) {
      if (p.kind == EntityKind.machine &&
          (p.recipe == null || FactoryRecipes.byId(p.recipe!) == null)) {
        issues.add(BlueprintIssue(BlueprintIssueKind.unknownRecipe, p.id));
      }
      if (kSpannedKinds.contains(p.kind) && p.span == null) {
        issues.add(BlueprintIssue(BlueprintIssueKind.missingSpan, p.id));
      }
      final f = p.footprint;
      if (!hall.rect.containsRect(f)) {
        issues.add(BlueprintIssue(BlueprintIssueKind.outOfHall, p.id));
      }
      if (kOverlayKinds.contains(p.kind)) continue;
      for (final q in solid) {
        if (q.footprint.overlaps(f)) {
          issues.add(BlueprintIssue(BlueprintIssueKind.overlap, p.id, q.id));
          break;
        }
      }
      solid.add(p);
    }
    return issues;
  }

  /// Whether the hall fits inside [env] (site-frame metres).
  bool fitsEnvelope(SiteEnvelope env) =>
      !env.isEmpty && hall.widthM <= env.width && hall.depthM <= env.depth;

  /// Total job demand at full staffing: station crews, maintenance shares
  /// and handler operators. The sim refines this (idle stations still count;
  /// a plant is staffed for its layout, not its luck).
  double get jobDemand {
    var jobs = 0.0;
    for (final p in placements) {
      if (p.kind != EntityKind.machine) continue;
      jobs += p.crew.workers + p.crew.maintenance;
    }
    roster.forEach((k, n) => jobs += kHandlerSpecs[k]!.operators * n);
    return jobs;
  }

  FloorBlueprint copy({String? name}) => FloorBlueprint(
        name: name ?? this.name,
        hall: hall,
        placements: [...placements],
        roster: {...roster},
        plantType: plantType,
      );

  Map<String, Object?> toJson() => {
        'name': name,
        'plant': ?plantType,
        'hall': hall.toJson(),
        'pl': [for (final p in placements) p.toJson()],
        if (roster.isNotEmpty)
          'crew': {
            for (final k in HandlerKind.values)
              if ((roster[k] ?? 0) > 0) k.name: roster[k],
          },
      };

  static FloorBlueprint fromJson(Map<String, Object?> j) => FloorBlueprint(
        name: j['name'] as String? ?? 'Floor',
        plantType: j['plant'] as String?,
        hall: HallSize.fromJson(j['hall']),
        placements: [
          for (final p in (j['pl'] as List? ?? const []))
            Placement.fromJson((p as Map).cast<String, Object?>()),
        ],
        roster: {
          for (final e
              in ((j['crew'] as Map?) ?? const {}).cast<String, Object?>()
                  .entries)
            HandlerKind.values.byName(e.key): (e.value as num).toInt(),
        },
      );
}
