// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The surface of a running floor (docs/plans/factory-floors.md §6).
///
/// The editor draws through [FactoryFloorView] and edits through
/// [FactoryFloorEditor]; the colony and the measurement harness drive it
/// through [FactorySim.step]. Phase 1's `FactoryFloor` is the one real
/// implementation. Fixed sub-step [kFactoryStepS]: a caller hands `step`
/// any dt and the floor runs whole sub-steps, carrying the remainder, so a
/// floor's result never depends on the caller's frame rate.
library;

import 'factory_colony_port.dart';
import 'factory_entities.dart';
import 'factory_grid.dart';
import 'factory_handling.dart';
import 'factory_ledger.dart';
import 'floor_blueprint.dart';

/// Sim seconds per floor sub-step.
const double kFactoryStepS = 0.25;

/// What a machine is doing, for the bottleneck overlay.
enum MachineStatus {
  /// Crafting.
  working,

  /// Waiting on an input.
  starved,

  /// Output buffer full: nothing is clearing it.
  blocked,

  /// Not enough crew.
  unstaffed,

  /// Not enough power.
  unpowered,

  /// No recipe, or switched off.
  idle,
}

/// One item on a belt tile, for drawing. [progress] 0..1 along the belt.
class BeltItemView {
  const BeltItemView(this.tile, this.item, this.progress);
  final TilePos tile;
  final String item;
  final double progress;
}

enum HandlerState { idle, toPickup, carrying, charging }

/// One handler, for drawing. [x], [y] in TILES (fractional while moving).
class HandlerView {
  const HandlerView({
    required this.id,
    required this.kind,
    required this.x,
    required this.y,
    required this.state,
    this.carrying,
    this.carryingCount = 0,
  });
  final int id;
  final HandlerKind kind;
  final double x, y;
  final HandlerState state;
  final String? carrying;
  final int carryingCount;
}

/// Why an edit was refused (null result reason = accepted).
enum EditRefusal {
  outOfHall,
  overlaps,
  unknownRecipe,
  wrongKind,
  noSuchPlacement,
  notAllowed,
}

class EditResult {
  const EditResult.ok(this.placementId) : refusal = null, otherId = null;
  const EditResult.refused(this.refusal, [this.otherId]) : placementId = null;

  final int? placementId;
  final EditRefusal? refusal;

  /// The placement it collided with, for [EditRefusal.overlaps].
  final int? otherId;

  bool get ok => refusal == null;
}

/// Steady-state rates of a floor (§3 "Off-screen = measured steady state").
/// Per sim second, commodity units.
class MeasuredRates {
  const MeasuredRates({
    required this.inPerS,
    required this.outPerS,
    required this.powerKw,
    required this.jobs,
    required this.seconds,
  });

  static const MeasuredRates none = MeasuredRates(
      inPerS: {}, outPerS: {}, powerKw: 0, jobs: 0, seconds: 0);

  final Map<String, double> inPerS;
  final Map<String, double> outPerS;

  /// Mean draw over the window.
  final double powerKw;

  /// Job demand of the layout (staffing need, not just who was busy).
  final double jobs;

  /// Sim seconds measured. 0 = never measured.
  final double seconds;

  Map<String, Object?> toJson() => {
        'in': inPerS,
        'out': outPerS,
        'kw': powerKw,
        'jobs': jobs,
        's': seconds,
      };

  static MeasuredRates fromJson(Map<String, Object?> j) {
    Map<String, double> m(Object? o) => {
          for (final e
              in ((o as Map?) ?? const {}).cast<String, Object?>().entries)
            e.key: (e.value as num).toDouble(),
        };
    return MeasuredRates(
      inPerS: m(j['in']),
      outPerS: m(j['out']),
      powerKw: (j['kw'] as num?)?.toDouble() ?? 0,
      jobs: (j['jobs'] as num?)?.toDouble() ?? 0,
      seconds: (j['s'] as num?)?.toDouble() ?? 0,
    );
  }
}

abstract interface class FactoryFloorView {
  /// The layout as it stands (edits update it).
  FloorBlueprint get blueprint;

  /// Bumps on every accepted edit (cache key for drawing).
  int get layoutRev;

  /// Sim seconds run since load.
  double get simSeconds;

  MachineStatus statusOf(int placementId);

  /// Items held by a machine, chest or dock buffer, by item id.
  Map<String, int> contentsOf(int placementId);

  Iterable<BeltItemView> get beltItems;
  Iterable<HandlerView> get handlers;

  /// Move requests waiting for a free handler (long queue = hire more).
  int get pendingRequests;

  /// Counters since the last [FactorySim.takeLedger].
  FactoryLedger get ledger;

  /// Staffing need of the layout (stations + maintenance + operators).
  double get jobDemand;

  /// Draw right now.
  double get powerDemandKw;
}

abstract interface class FactoryFloorEditor {
  /// Adds [p] (its id is ignored; the floor assigns one).
  EditResult place(Placement p);
  EditResult remove(int placementId);
  EditResult rotate(int placementId);
  EditResult setRecipe(int placementId, String recipeId);
  EditResult setMode(int placementId, MachineMode mode);

  /// Hires ([delta] > 0) or lets go of handlers of [kind].
  EditResult hire(HandlerKind kind, int delta);
}

abstract interface class FactorySim
    implements FactoryFloorView, FactoryFloorEditor {
  /// Runs whole [kFactoryStepS] sub-steps covering [dt] against [port].
  void step(double dt, FactoryColonyPort port);

  /// Returns the counters since the last call and starts a fresh period.
  FactoryLedger takeLedger();

  /// Full runtime state (layout + buffers + belt items + handlers).
  Map<String, Object?> toJson();
}
