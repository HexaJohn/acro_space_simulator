// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The road menu: what a player can build, what it costs to build and to
/// keep, and when it opens.
///
/// A [RoadClass] is a CROSS-SECTION — lanes, width, grade limit — and the
/// generator lays classes. A player picks a [RoadType]: a class plus the
/// variant attributes a city builder's road menu offers as separate roads
/// (decorative grass or trees, sound barriers), with a price and an upkeep.
/// A type is never persisted: a road's class, decoration and walls are, and
/// [RoadType.of] recovers its type from them, so a generated road and an
/// old save both resolve to an entry with no migration.
///
/// Prices are Cities: Skylines' own base-game table, per 8 m cell: the
/// construction cost in §/cell and the upkeep in §/week/cell, with the
/// elevated and tunnel multipliers its highway rows imply (0.96 at grade,
/// 2.08 one tier up, 5.12 underground).
library;

import 'dart:math' as math;

import 'parcel.dart';

/// Where a type sits in the menu. The order is the menu's.
enum RoadGroup {
  small('Small Roads'),
  medium('Medium Roads'),
  large('Large Roads'),
  highway('Highways'),
  special('Special');

  const RoadGroup(this.label);
  final String label;
}

/// One entry on the road menu.
class RoadType {
  const RoadType({
    required this.id,
    required this.label,
    required this.group,
    required this.roadClass,
    this.decoration = RoadDecoration.none,
    this.soundWalls = false,
    required this.costPerCell,
    required this.upkeepPerCellWeek,
    required this.speedKmh,
    this.unlockPop = 0,
    required this.noise,
  });

  /// Stable id for UI state and tests. Never persisted on a road.
  final String id;
  final String label;
  final RoadGroup group;
  final RoadClass roadClass;
  final RoadDecoration decoration;
  final bool soundWalls;

  /// Construction, § per [RoadCosts.cellM] of centreline, at grade.
  final double costPerCell;

  /// Upkeep, § per week per [RoadCosts.cellM], at grade.
  final double upkeepPerCellWeek;

  /// Speed limit. Drives route times and the traffic pass.
  final double speedKmh;

  /// Population that opens it. Always ON a milestone population (see
  /// `CityProgression.all`) — milestones are bands over unlocks, never a
  /// second gate, and a road opening between two rungs would be one.
  final int unlockPop;

  /// Traffic noise it throws at the lots beside it, 0..1, before
  /// decoration and walls (see [noiseEmission]).
  final double noise;

  bool get oneWay => roadClass.oneWay;

  /// Whether lots front it — roadside zoning. Highways and ramps: never.
  bool get zonable => roadClass.platsLots;

  bool get canTunnel => roadClass.canTunnel;
  bool get canElevate => roadClass.canElevate;

  /// Kerbside parking. Undecorated roads with a pavement park cars along
  /// the kerb; decoration takes the kerb for grass or trees — except on a
  /// four-lane road, which keeps its parking whatever it is dressed in.
  bool get hasParking =>
      roadClass.hasPavement &&
      (decoration == RoadDecoration.none || roadClass == RoadClass.avenue);

  /// Noise it actually throws, after decoration and sound barriers.
  double get noiseEmission =>
      noise * decoration.noiseFactor * (soundWalls ? 0.35 : 1.0);

  /// The same road with a different dressing, if the menu has one.
  RoadType? withDecoration(RoadDecoration d) => kRoadCatalog
      .where((t) =>
          t.roadClass == roadClass &&
          t.decoration == d &&
          t.soundWalls == soundWalls)
      .firstOrNull;

  /// The menu entry a built road is: exact match on class, decoration and
  /// walls; else the class's plain entry; else a synthesized special entry
  /// so every class — generated or loaded — has a price.
  static RoadType of(RoadSpline road) => forClass(road.roadClass,
      decoration: road.decoration, soundWalls: road.soundWalls);

  static RoadType forClass(
    RoadClass cls, {
    RoadDecoration decoration = RoadDecoration.none,
    bool soundWalls = false,
  }) {
    RoadType? plain;
    for (final t in kRoadCatalog) {
      if (t.roadClass != cls) continue;
      if (t.decoration == decoration && t.soundWalls == soundWalls) return t;
      if (t.decoration == RoadDecoration.none && !t.soundWalls) plain ??= t;
    }
    if (plain != null) return plain;
    return RoadType(
      id: 'class:${cls.name}',
      label: cls.label,
      group: RoadGroup.special,
      roadClass: cls,
      costPerCell: 40,
      upkeepPerCellWeek: 0.32,
      speedKmh: 40,
      noise: 0.2,
    );
  }

  static RoadType? byId(String id) =>
      kRoadCatalog.where((t) => t.id == id).firstOrNull;

  @override
  String toString() => 'RoadType($id)';
}

/// What roads cost. Pure arithmetic over a type and how much of a road is
/// at grade, on a structure, or underground.
class RoadCosts {
  const RoadCosts._();

  /// The cell the prices are quoted per: Cities: Skylines' 8 m.
  static const double cellM = 8;

  /// Construction on a structure (piers), on a tall bridge, and in a
  /// tunnel, as multiples of the at-grade price.
  static const double structureBuildMult = 2.0;
  static const double bridgeBuildMult = 2.5;
  static const double tunnelBuildMult = 4.0;

  /// Upkeep multiples, from the highway's rows: 2.08 / 0.96 elevated,
  /// 5.12 / 0.96 in a tunnel.
  static const double structureUpkeepMult = 2.08 / 0.96;
  static const double tunnelUpkeepMult = 5.12 / 0.96;

  /// § to build [lengthM] of [t], [structureM] of it on piers ([bridgeM]
  /// of that tall enough to be a bridge) and [tunnelM] of it underground.
  static double construction(
    RoadType t, {
    required double lengthM,
    double structureM = 0,
    double bridgeM = 0,
    double tunnelM = 0,
  }) {
    final (ground, low, high, under) =
        _split(lengthM, structureM, bridgeM, tunnelM);
    final cells = (ground +
            low * structureBuildMult +
            high * bridgeBuildMult +
            under * tunnelBuildMult) /
        cellM;
    return cells * t.costPerCell;
  }

  /// § per week to keep the same road.
  static double upkeepPerWeek(
    RoadType t, {
    required double lengthM,
    double structureM = 0,
    double tunnelM = 0,
  }) {
    final (ground, low, high, under) = _split(lengthM, structureM, 0, tunnelM);
    final cells = (ground +
            (low + high) * structureUpkeepMult +
            under * tunnelUpkeepMult) /
        cellM;
    return cells * t.upkeepPerCellWeek;
  }

  /// § to turn [from] into [to] in place: the difference in construction,
  /// never negative — a downgrade is free, not a refund.
  static double upgrade(
    RoadType from,
    RoadType to, {
    required double lengthM,
    double structureM = 0,
    double bridgeM = 0,
    double tunnelM = 0,
  }) {
    double c(RoadType t) => construction(t,
        lengthM: lengthM,
        structureM: structureM,
        bridgeM: bridgeM,
        tunnelM: tunnelM);
    return math.max(0, c(to) - c(from));
  }

  /// (at grade, low structure, bridge, tunnel) metres, each clamped so the
  /// four add up to [lengthM].
  static (double, double, double, double) _split(
      double lengthM, double structureM, double bridgeM, double tunnelM) {
    final len = math.max(0.0, lengthM);
    final under = tunnelM.clamp(0.0, len);
    final onPiers = structureM.clamp(0.0, len - under);
    final high = bridgeM.clamp(0.0, onPiers);
    final low = onPiers - high;
    final ground = len - under - onPiers;
    return (ground, low, high, under);
  }
}

// ---- The menu --------------------------------------------------------------

/// Busy Town / Boom Town in Cities: Skylines, on this game's ladder: the
/// highways open at Township (200), the decorated roads and the walled
/// highway at Small Town (300). Every figure lands on a milestone.
const int _boomTown = 200;
const int _busyTown = 300;

const List<RoadType> kRoadCatalog = [
  // Small roads.
  RoadType(
      id: 'gravel',
      label: 'Gravel Road',
      group: RoadGroup.small,
      roadClass: RoadClass.path,
      costPerCell: 20,
      upkeepPerCellWeek: 0.19,
      speedKmh: 30,
      noise: 0.05),
  RoadType(
      id: 'two-lane',
      label: 'Two-Lane Road',
      group: RoadGroup.small,
      roadClass: RoadClass.street,
      costPerCell: 40,
      upkeepPerCellWeek: 0.32,
      speedKmh: 40,
      noise: 0.15),
  RoadType(
      id: 'two-lane-grass',
      label: 'Two-Lane Road with Decorative Grass',
      group: RoadGroup.small,
      roadClass: RoadClass.street,
      decoration: RoadDecoration.grass,
      costPerCell: 50,
      upkeepPerCellWeek: 0.40,
      speedKmh: 40,
      unlockPop: _busyTown,
      noise: 0.15),
  RoadType(
      id: 'two-lane-trees',
      label: 'Two-Lane Road with Decorative Trees',
      group: RoadGroup.small,
      roadClass: RoadClass.street,
      decoration: RoadDecoration.trees,
      costPerCell: 60,
      upkeepPerCellWeek: 0.48,
      speedKmh: 40,
      unlockPop: _busyTown,
      noise: 0.15),
  RoadType(
      id: 'one-way',
      label: 'Two-Lane One-Way Road',
      group: RoadGroup.small,
      roadClass: RoadClass.streetOneWay,
      costPerCell: 40,
      upkeepPerCellWeek: 0.32,
      speedKmh: 40,
      noise: 0.15),
  RoadType(
      id: 'one-way-grass',
      label: 'Two-Lane One-Way Road with Decorative Grass',
      group: RoadGroup.small,
      roadClass: RoadClass.streetOneWay,
      decoration: RoadDecoration.grass,
      costPerCell: 50,
      upkeepPerCellWeek: 0.40,
      speedKmh: 40,
      unlockPop: _busyTown,
      noise: 0.15),
  RoadType(
      id: 'one-way-trees',
      label: 'Two-Lane One-Way Road with Decorative Trees',
      group: RoadGroup.small,
      roadClass: RoadClass.streetOneWay,
      decoration: RoadDecoration.trees,
      costPerCell: 60,
      upkeepPerCellWeek: 0.48,
      speedKmh: 40,
      unlockPop: _busyTown,
      noise: 0.15),
  // Medium.
  RoadType(
      id: 'four-lane',
      label: 'Four-Lane Road',
      group: RoadGroup.medium,
      roadClass: RoadClass.avenue,
      costPerCell: 60,
      upkeepPerCellWeek: 0.80,
      speedKmh: 50,
      noise: 0.3),
  RoadType(
      id: 'four-lane-grass',
      label: 'Four-Lane Road with Decorative Grass',
      group: RoadGroup.medium,
      roadClass: RoadClass.avenue,
      decoration: RoadDecoration.grass,
      costPerCell: 70,
      upkeepPerCellWeek: 0.96,
      speedKmh: 50,
      unlockPop: _busyTown,
      noise: 0.3),
  RoadType(
      id: 'four-lane-trees',
      label: 'Four-Lane Road with Decorative Trees',
      group: RoadGroup.medium,
      roadClass: RoadClass.avenue,
      decoration: RoadDecoration.trees,
      costPerCell: 80,
      upkeepPerCellWeek: 1.12,
      speedKmh: 50,
      unlockPop: _busyTown,
      noise: 0.3),
  // Large.
  RoadType(
      id: 'six-lane',
      label: 'Six-Lane Road',
      group: RoadGroup.large,
      roadClass: RoadClass.boulevard,
      costPerCell: 80,
      upkeepPerCellWeek: 0.96,
      speedKmh: 60,
      noise: 0.45),
  RoadType(
      id: 'six-lane-grass',
      label: 'Six-Lane Road with Decorative Grass',
      group: RoadGroup.large,
      roadClass: RoadClass.boulevard,
      decoration: RoadDecoration.grass,
      costPerCell: 90,
      upkeepPerCellWeek: 1.12,
      speedKmh: 60,
      unlockPop: _busyTown,
      noise: 0.45),
  RoadType(
      id: 'six-lane-trees',
      label: 'Six-Lane Road with Decorative Trees',
      group: RoadGroup.large,
      roadClass: RoadClass.boulevard,
      decoration: RoadDecoration.trees,
      costPerCell: 100,
      upkeepPerCellWeek: 1.28,
      speedKmh: 60,
      unlockPop: _busyTown,
      noise: 0.45),
  // Highways.
  RoadType(
      id: 'ramp',
      label: 'Highway Ramp',
      group: RoadGroup.highway,
      roadClass: RoadClass.ramp,
      costPerCell: 30,
      upkeepPerCellWeek: 0.32,
      speedKmh: 80,
      unlockPop: _boomTown,
      noise: 0.5),
  RoadType(
      id: 'highway',
      label: 'Highway',
      group: RoadGroup.highway,
      roadClass: RoadClass.motorway,
      costPerCell: 70,
      upkeepPerCellWeek: 0.96,
      speedKmh: 100,
      unlockPop: _boomTown,
      noise: 0.8),
  RoadType(
      id: 'highway-walls',
      label: 'Highway with Sound Barriers',
      group: RoadGroup.highway,
      roadClass: RoadClass.motorway,
      soundWalls: true,
      costPerCell: 90,
      upkeepPerCellWeek: 1.28,
      speedKmh: 100,
      unlockPop: _busyTown,
      noise: 0.8),
  // Special: the generator's tiers, offered to the player as they were
  // before the menu existed, gated on the ladder.
  RoadType(
      id: 'alley',
      label: 'Alley',
      group: RoadGroup.special,
      roadClass: RoadClass.alley,
      costPerCell: 30,
      upkeepPerCellWeek: 0.24,
      speedKmh: 20,
      noise: 0.08),
  RoadType(
      id: 'trunk',
      label: 'Trunk Road',
      group: RoadGroup.special,
      roadClass: RoadClass.trunk,
      costPerCell: 70,
      upkeepPerCellWeek: 0.96,
      speedKmh: 80,
      unlockPop: _boomTown,
      noise: 0.6),
  RoadType(
      id: 'urban-highway',
      label: 'Urban Highway',
      group: RoadGroup.special,
      roadClass: RoadClass.highway,
      costPerCell: 110,
      upkeepPerCellWeek: 1.44,
      speedKmh: 70,
      unlockPop: 400,
      noise: 0.7),
  RoadType(
      id: 'urban-highway-walls',
      label: 'Urban Highway with Sound Barriers',
      group: RoadGroup.special,
      roadClass: RoadClass.highway,
      soundWalls: true,
      costPerCell: 130,
      upkeepPerCellWeek: 1.76,
      speedKmh: 70,
      unlockPop: 400,
      noise: 0.7),
  RoadType(
      id: 'expressway4',
      label: '4-Lane Expressway',
      group: RoadGroup.special,
      roadClass: RoadClass.expressway4,
      costPerCell: 90,
      upkeepPerCellWeek: 1.12,
      speedKmh: 100,
      unlockPop: 400,
      noise: 0.85),
  RoadType(
      id: 'expressway6',
      label: '6-Lane Expressway',
      group: RoadGroup.special,
      roadClass: RoadClass.expressway6,
      costPerCell: 110,
      upkeepPerCellWeek: 1.44,
      speedKmh: 100,
      unlockPop: 400,
      noise: 0.9),
  RoadType(
      id: 'expressway8',
      label: '8-Lane Expressway',
      group: RoadGroup.special,
      roadClass: RoadClass.expressway8,
      costPerCell: 130,
      upkeepPerCellWeek: 1.76,
      speedKmh: 100,
      unlockPop: 400,
      noise: 0.95),
  RoadType(
      id: 'elevated-highway',
      label: 'Elevated Highway',
      group: RoadGroup.special,
      roadClass: RoadClass.elevated,
      costPerCell: 160,
      upkeepPerCellWeek: 2.08,
      speedKmh: 90,
      unlockPop: 400,
      noise: 0.8),
  RoadType(
      id: 'railway',
      label: 'Railway',
      group: RoadGroup.special,
      roadClass: RoadClass.rail,
      costPerCell: 60,
      upkeepPerCellWeek: 0.48,
      speedKmh: 120,
      unlockPop: _busyTown,
      noise: 0.6),
  RoadType(
      id: 'elevated-rail',
      label: 'Elevated Rail',
      group: RoadGroup.special,
      roadClass: RoadClass.transit,
      costPerCell: 120,
      upkeepPerCellWeek: 1.2,
      speedKmh: 80,
      unlockPop: 600,
      noise: 0.5),
];
