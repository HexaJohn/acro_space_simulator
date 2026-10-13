// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What a floor costs to build (docs/plans/factory-floors.md §3 "build cost
/// scales with hall area", "Space is the cost", phase 4).
///
/// Priced in ORE, the colony's build currency today
/// (`CityBuildingSpec.buildCost` is ore). Phase 5 converts ore to credits
/// for a private firm's payback test; until then this is what placing a
/// plant with this floor takes from stock.
///
/// **Calibration.** The Steel Mill TEMPLATE costs what a Steel Mill always
/// cost — the spec's default `buildCost` of 40 ore — within 10% (pinned by
/// a test), so stamping the template changes nothing for a colony. Every
/// figure below is relative to that: a smelter is a few percent of a mill,
/// a forklift about the same as a smelter, a belt tile nearly free.
///
/// **What it rewards.** Hall area is a real cost, so a compact layout pays;
/// automation costs more to build than a manned station (it saves jobs
/// instead); vehicles and their aisles, bays and chargers cost, so a
/// designer weighs a crane against two forklifts against more belts. A
/// receiving dock that drops straight onto a belt is a DOCK CONVEYOR, the
/// plan's expensive automated unloading, and is charged as one.
library;

import 'factory_entities.dart';
import 'factory_grid.dart';
import 'factory_handling.dart';
import 'factory_recipe.dart';
import 'floor_blueprint.dart';

/// Ore per square metre of hall: the shed, its slab and roof. A 66 × 56 m
/// mill shed is about a quarter of a Steel Mill's cost.
const double kCapexHallOrePerM2 = 0.0025;

/// Ore per door: a dock leveller and its bay, receiving or shipping.
const double kCapexDockOre = 0.3;

/// Ore per receiving dock that unloads straight onto a belt (on top of the
/// door): the automated dock conveyor upgrade (§3 "Docks are manual by
/// default").
const double kCapexDockConveyorOre = 1.0;

/// Ore per tile of painted aisle: almost nothing — its cost is the floor
/// it takes.
const double kCapexAisleTileOre = 0.005;

/// Ore per station, by kind, before the crew mode's multiplier. Hot,
/// heavy plant (smelting, rolling) costs most; a packer least.
const Map<StationKind, double> kCapexStationOre = {
  StationKind.smelter: 1.5,
  StationKind.furnace: 1.5,
  StationKind.press: 1.0,
  StationKind.mill: 2.0,
  StationKind.assembler: 1.0,
  StationKind.chem: 1.5,
  StationKind.packer: 0.5,
  StationKind.unpacker: 0.5,
};

/// Station cost multiplier by crew mode: an operator's station carries some
/// controls, a lights-out one sensors, drives and electronics (§3
/// "Automated … costs electronics to build").
const Map<MachineMode, double> kCapexModeMult = {
  MachineMode.manual: 1.0,
  MachineMode.assisted: 1.15,
  MachineMode.automated: 1.6,
};

/// Ore per belt tile, per crossing (a belt with a walkway over it) and per
/// arm.
const double kCapexBeltTileOre = 0.04;
const double kCapexCrossingOre = 0.06;
const double kCapexArmOre = 0.15;

/// Ore per chest, per rack (steel racking a forklift stacks) and per
/// staging-area tile (marked, kerbed floor).
const double kCapexChestOre = 0.1;
const double kCapexRackOre = 0.4;
const double kCapexStagingTileOre = 0.01;

/// Ore per handler bought, by kind. People cost nothing to build (they cost
/// jobs); a crane's price is its trolley and hoist, the runway is per tile.
const Map<HandlerKind, double> kCapexHandlerOre = {
  HandlerKind.onFoot: 0,
  HandlerKind.palletJack: 0.2,
  HandlerKind.forklift: 0.8,
  HandlerKind.crane: 1.0,
  HandlerKind.agv: 2.0,
};

/// Ore per crane-bay tile (runway beams and rails) and per charging bay.
const double kCapexCraneBayTileOre = 0.02;
const double kCapexChargingBayOre = 0.4;

/// A floor's build cost in ore, by what it buys.
class FloorCapex {
  const FloorCapex({
    required this.hall,
    required this.machines,
    required this.conveyors,
    required this.storage,
    required this.vehicles,
  });

  /// The shed (area), its doors and its aisle markings.
  final double hall;

  /// Stations, by kind and crew mode.
  final double machines;

  /// Belts, crossings, arms and dock conveyors.
  final double conveyors;

  /// Chests, racks and staging areas.
  final double storage;

  /// Handlers bought, crane runways and charging bays.
  final double vehicles;

  double get total => hall + machines + conveyors + storage + vehicles;

  @override
  String toString() =>
      'FloorCapex(hall ${hall.toStringAsFixed(2)}, '
      'machines ${machines.toStringAsFixed(2)}, '
      'conveyors ${conveyors.toStringAsFixed(2)}, '
      'storage ${storage.toStringAsFixed(2)}, '
      'vehicles ${vehicles.toStringAsFixed(2)}, '
      'total ${total.toStringAsFixed(2)})';
}

/// The build cost of [bp], in ore. Placements are walked in list order and
/// the roster by kind, so the sum is the same on every run.
FloorCapex capexOf(FloorBlueprint bp) {
  var hall = bp.hall.areaM2 * kCapexHallOrePerM2;
  var machines = 0.0, conveyors = 0.0, storage = 0.0, vehicles = 0.0;

  // Tiles a belt or crossing covers, for spotting dock conveyors.
  final beltTiles = <int>{
    for (final p in bp.placements)
      if (p.kind == EntityKind.belt || p.kind == EntityKind.crossing) p.pos.key,
  };

  for (final p in bp.placements) {
    final area = p.footprint.area;
    switch (p.kind) {
      case EntityKind.machine:
        final r = p.recipe == null ? null : FactoryRecipes.byId(p.recipe!);
        final st = r?.station;
        if (st != null) {
          machines +=
              (kCapexStationOre[st] ?? 0) * (kCapexModeMult[p.crew] ?? 1);
        }
      case EntityKind.belt:
        conveyors += kCapexBeltTileOre;
      case EntityKind.crossing:
        conveyors += kCapexCrossingOre;
      case EntityKind.arm:
        conveyors += kCapexArmOre;
      case EntityKind.receivingDock:
        hall += kCapexDockOre;
        if (beltTiles.contains(_frontKey(p))) {
          conveyors += kCapexDockConveyorOre;
        }
      case EntityKind.shippingDock:
        hall += kCapexDockOre;
      case EntityKind.aisle:
        hall += area * kCapexAisleTileOre;
      case EntityKind.chest:
        storage += kCapexChestOre;
      case EntityKind.rack:
        storage += kCapexRackOre;
      case EntityKind.staging:
        storage += area * kCapexStagingTileOre;
      case EntityKind.craneBay:
        vehicles += area * kCapexCraneBayTileOre;
      case EntityKind.chargingBay:
        vehicles += kCapexChargingBayOre;
    }
  }
  for (final k in HandlerKind.values) {
    vehicles += (bp.roster[k] ?? 0) * (kCapexHandlerOre[k] ?? 0);
  }
  return FloorCapex(
    hall: hall,
    machines: machines,
    conveyors: conveyors,
    storage: storage,
    vehicles: vehicles,
  );
}

/// Key of the tile just beyond a dock's footprint along its facing (where
/// it sets freight down), or -1 off the hall's low edges.
int _frontKey(Placement p) {
  final f = p.footprint;
  final t = switch (p.dir) {
    Dir4.east => TilePos(f.x1, f.y0),
    Dir4.north => TilePos(f.x0, f.y1),
    Dir4.west => TilePos(f.x0 - 1, f.y0),
    Dir4.south => TilePos(f.x0, f.y0 - 1),
  };
  return t.x < 0 || t.y < 0 ? -1 : t.key;
}
