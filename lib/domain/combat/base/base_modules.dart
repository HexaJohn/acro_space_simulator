// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What a forward base can build (docs/plans/combat.md §7C; the reference's
/// §10A.4): prefab modules carried in the landers.
///
/// A combat-owned catalog. It is never part of the colony catalog
/// (`kUtilCatalog`): a module is a row on the operation that changes the
/// battle's terms, never a colony building the target's rebels would own, a
/// generator could stake, or a governor could buy.
library;

/// A module. Append-only: saved by name.
enum ModuleKind { supplyPad, turret, barracksPod }

/// Which ring a module stands in.
enum SocketKind { module, turret }

class ModuleSpec {
  const ModuleSpec({
    required this.kind,
    required this.label,
    required this.socket,
    required this.materiel,
    required this.buildS,
    required this.crew,
    required this.powerKw,
    required this.hp,
    this.gate,
    this.max = 99,
  });

  final ModuleKind kind;
  final String label;
  final SocketKind socket;

  /// Materiel (ore) it costs, whole units.
  final int materiel;

  /// Seconds of operation time to build.
  final int buildS;

  /// Support staff it needs to run.
  final int crew;

  /// Power it draws running, kW.
  final double powerKw;

  /// Hit points in member-equivalents.
  final double hp;

  /// The building a source colony must have for it (a colony building type),
  /// or null for none.
  final String? gate;

  /// Most of it one base may have.
  final int max;
}

const List<ModuleSpec> kBaseModules = [
  ModuleSpec(
    kind: ModuleKind.supplyPad,
    label: 'Supply pad',
    socket: SocketKind.module,
    materiel: 30,
    buildS: 25,
    crew: 1,
    powerKw: 2,
    hp: 2,
    gate: 'spaceport',
    max: 2,
  ),
  ModuleSpec(
    kind: ModuleKind.turret,
    label: 'Turret',
    socket: SocketKind.turret,
    materiel: 60,
    buildS: 30,
    crew: 2,
    powerKw: 6,
    hp: 2,
    gate: 'gunfactory',
  ),
  ModuleSpec(
    kind: ModuleKind.barracksPod,
    label: 'Barracks pod',
    socket: SocketKind.module,
    materiel: 50,
    buildS: 40,
    crew: 2,
    powerKw: 6,
    hp: 2,
    gate: 'barracks',
    max: 1,
  ),
];

ModuleSpec moduleSpec(ModuleKind k) {
  for (final s in kBaseModules) {
    if (s.kind == k) return s;
  }
  throw ArgumentError('no module $k');
}

/// The Firebase tier (the core, on landing): its sockets and build lines.
const int kFirebaseModuleSockets = 3;
const int kFirebaseTurretSockets = 2;
const int kFirebaseLines = 1;

/// The core's own terms.
const double kCorePowerKw = 20;
const int kCoreUnpackC = 50; // 0.5 Materiel/s, in centi-units
const int kPadUnpackC = 100; // +1.0 Materiel/s per supply pad
const double kCoreFortification = 0.3;
const double kTurretFortification = 0.25;
const int kDeployS = 30;

/// The supply-run interval, days, before pads shorten it.
const double kRunIntervalDays = 3;

/// Materiel a supply run brings, whole units.
const int kRunMateriel = 100;

/// Turret ammo a second while its objective is fought over, and idle.
const double kTurretAmmoEngaged = 0.5;
const double kTurretAmmoIdle = 0.05;

/// What one person eats and fires a day (the barracks' per-job rates).
const double kRationsPerDay = 2;
const double kAmmoPerDay = 1.2;

/// Resupply: a formation at the LZ, or one link from it, regains a day of
/// kit every this many seconds, up to [kResupplyToDays].
const int kResupplyDayS = 30;
const double kResupplyToDays = 3;

/// The stock the base keeps, in a fixed order (for saving and capture).
const List<String> kBaseStock = ['ammo', 'guns', 'rations'];
