// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Who moves freight, and how stations are crewed
/// (docs/plans/factory-floors.md §3 "Material handling").
///
/// Real plants are rarely lights-out: people unload trucks, run pallet jacks
/// and forklifts, and drive cranes. A [HandlerKind] is one such mover; its
/// [HandlerSpec] says what it can lift and what space it needs. Phase 1 runs
/// [HandlerKind.onFoot] only; phase 4 brings the rest, so the enum is shaped
/// for them now and saves never need a migration.
library;

import 'factory_item.dart';

enum HandlerKind { onFoot, palletJack, forklift, crane, agv }

class HandlerSpec {
  const HandlerSpec({
    required this.kind,
    required this.label,
    required this.maxLoad,
    required this.capacity,
    required this.speedMps,
    required this.operators,
    required this.aisleTiles,
    required this.powerKw,
    required this.needsCraneBay,
  });

  final HandlerKind kind;
  final String label;

  /// Heaviest [LoadClass] it can move.
  final LoadClass maxLoad;

  /// Items per trip.
  final int capacity;

  /// Travel speed when loaded.
  final double speedMps;

  /// Workers it takes (0 for an AGV): counts toward the floor's job demand.
  final int operators;

  /// Clear aisle width it needs, in tiles (1 for walkers and jacks).
  final int aisleTiles;

  /// Draw while working (charging, for battery vehicles).
  final double powerKw;

  /// Cranes run only inside a crane bay and ignore floor traffic.
  final bool needsCraneBay;

  bool canLift(LoadClass c) => c.index <= maxLoad.index;
}

/// Handler numbers. Provisional; phase 4 tunes them.
const Map<HandlerKind, HandlerSpec> kHandlerSpecs = {
  HandlerKind.onFoot: HandlerSpec(
      kind: HandlerKind.onFoot, label: 'Worker', maxLoad: LoadClass.hand,
      capacity: 1, speedMps: 1.2, operators: 1, aisleTiles: 1, powerKw: 0,
      needsCraneBay: false),
  HandlerKind.palletJack: HandlerSpec(
      kind: HandlerKind.palletJack, label: 'Pallet Jack',
      maxLoad: LoadClass.pallet, capacity: 1, speedMps: 1.0, operators: 1,
      aisleTiles: 1, powerKw: 0.5, needsCraneBay: false),
  HandlerKind.forklift: HandlerSpec(
      kind: HandlerKind.forklift, label: 'Forklift',
      maxLoad: LoadClass.pallet, capacity: 2, speedMps: 3.0, operators: 1,
      aisleTiles: 2, powerKw: 6, needsCraneBay: false),
  HandlerKind.crane: HandlerSpec(
      kind: HandlerKind.crane, label: 'Overhead Crane',
      maxLoad: LoadClass.heavy, capacity: 1, speedMps: 1.5, operators: 1,
      aisleTiles: 0, powerKw: 25, needsCraneBay: true),
  HandlerKind.agv: HandlerSpec(
      kind: HandlerKind.agv, label: 'AGV', maxLoad: LoadClass.pallet,
      capacity: 1, speedMps: 1.5, operators: 0, aisleTiles: 2, powerKw: 4,
      needsCraneBay: false),
};

/// How a machine is crewed. Provisional numbers; phase 4 tunes them.
enum MachineMode {
  /// Hands on everything: slow, no extra power.
  manual(workers: 2, speedMult: 0.6, powerMult: 1.0, maintenance: 0),

  /// One operator minding automation.
  assisted(workers: 1, speedMult: 1.0, powerMult: 1.4, maintenance: 0),

  /// Lights-out: no operator, high draw, and a share of a technician.
  automated(workers: 0, speedMult: 1.3, powerMult: 2.2, maintenance: 0.25);

  const MachineMode({
    required this.workers,
    required this.speedMult,
    required this.powerMult,
    required this.maintenance,
  });

  final int workers;
  final double speedMult;
  final double powerMult;

  /// Technician share this station needs (fractional jobs).
  final double maintenance;
}
