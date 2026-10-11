// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What a forward base can build (docs/plans/combat.md §7C, §7D; the
/// reference's §10A.4): prefab modules carried in the landers.
///
/// A combat-owned catalog. It is never part of the colony catalog
/// (`kUtilCatalog`): a module is a row on the operation that changes the
/// battle's terms, never a colony building the target's rebels would own, a
/// generator could stake, or a governor could buy.
library;

/// A module. Append-only: saved by name.
enum ModuleKind { supplyPad, turret, barracksPod, stores, fieldHospital, generator, workshop }

/// Which ring a module stands in.
enum SocketKind { module, turret }

/// The core's tier. Append-only: saved by name.
enum BaseTier { firebase, station, fortress }

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
    this.steel = 0,
    this.gate,
    this.max = 99,
  });

  final ModuleKind kind;
  final String label;
  final SocketKind socket;

  /// Materiel (ore) it costs, whole units; and steel.
  final int materiel;
  final int steel;

  /// Seconds of operation time to build.
  final int buildS;

  /// Support staff it needs to run.
  final int crew;

  /// Power it draws running, kW (negative: it makes power).
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
    max: 2,
  ),
  ModuleSpec(
    kind: ModuleKind.stores,
    label: 'Stores',
    socket: SocketKind.module,
    materiel: 20,
    buildS: 20,
    crew: 0,
    powerKw: 0,
    hp: 2,
  ),
  ModuleSpec(
    kind: ModuleKind.fieldHospital,
    label: 'Field hospital',
    socket: SocketKind.module,
    materiel: 40,
    buildS: 40,
    crew: 2,
    powerKw: 4,
    hp: 2,
    gate: 'hospital',
    max: 1,
  ),
  ModuleSpec(
    kind: ModuleKind.generator,
    label: 'Generator',
    socket: SocketKind.module,
    materiel: 40,
    buildS: 30,
    crew: 1,
    powerKw: -30,
    hp: 1.5,
  ),
  ModuleSpec(
    kind: ModuleKind.workshop,
    label: 'Munitions workshop',
    socket: SocketKind.module,
    materiel: 60,
    steel: 10,
    buildS: 50,
    crew: 3,
    powerKw: 12,
    hp: 2,
    gate: 'gunfactory',
    max: 1,
  ),
];

ModuleSpec moduleSpec(ModuleKind k) {
  for (final s in kBaseModules) {
    if (s.kind == k) return s;
  }
  throw ArgumentError('no module $k');
}

/// A tier's sockets, lines and price.
class TierSpec {
  const TierSpec(this.tier, this.label, this.moduleSockets, this.turretSockets, this.lines,
      {this.materiel = 0, this.steel = 0, this.buildS = 0, this.fortification = 0, this.gate});
  final BaseTier tier;
  final String label;
  final int moduleSockets;
  final int turretSockets;
  final int lines;
  final int materiel;
  final int steel;
  final int buildS;

  /// Extra attacker fortification at the LZ.
  final double fortification;
  final String? gate;
}

const List<TierSpec> kTiers = [
  TierSpec(BaseTier.firebase, 'Firebase', 3, 2, 1),
  TierSpec(BaseTier.station, 'Station', 5, 4, 2, materiel: 100, buildS: 50),
  TierSpec(BaseTier.fortress, 'Fortress', 7, 4, 3,
      materiel: 160, steel: 20, buildS: 60, fortification: 0.3, gate: 'base'),
];

TierSpec tierSpec(BaseTier t) => kTiers[t.index];

/// An outpost (§7D): its sockets, line, price and fortification.
const int kOutpostModuleSockets = 2;
const int kOutpostTurretSockets = 1;
const int kOutpostMateriel = 120;
const int kOutpostBuildS = 40;
const double kOutpostFortification = 0.3;
const int kMaxOutposts = 3;

/// The spare core kit's price, and how long it takes to deploy.
const int kSpareCoreMateriel = 100;
const int kSpareCoreDeployS = 60;

/// Kept for 1b-i's tests and readers: the Firebase tier's sockets.
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

/// Stock caps: unpacked Materiel and each stock, plus this per Stores.
const int kCapC = 40000;
const int kStoresCapC = 30000;

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

/// The field hospital: every this many seconds the wounded recover into the
/// LZ reserve, at this much medicine a patient-day.
const int kHospitalCycleS = 60;
const double kMedicinePerPatientDay = 0.2;

/// The generator's fuel, centi-units a second (0.1/s).
const int kGeneratorFuelC = 10;

/// The workshop works in batches: every [kWorkshopBatchS] it turns steel and
/// electronics into ammo and guns (a tenth of its day).
const int kWorkshopBatchS = 12;
const int kWorkshopSteelC = 150;
const int kWorkshopElectronicsC = 30;
const int kWorkshopAmmoC = 300;
const int kWorkshopGunsC = 90;

/// The barracks pod forms a squad of recovered wounded this often, from this
/// many waiting.
const int kPodCycleS = 30;
const int kPodMinimum = 4;

/// The stock the base keeps, in a fixed order (for saving and capture).
const List<String> kBaseStock = [
  'ammo',
  'guns',
  'rations',
  'fuel',
  'medicine',
  'steel',
  'electronics',
];

/// A doctrine's build list (§7D). Append-only: saved by name.
enum Doctrine { balanced, hold, push, manual }

String doctrineLabel(Doctrine d) => switch (d) {
      Doctrine.balanced => 'Balanced',
      Doctrine.hold => 'Hold',
      Doctrine.push => 'Push',
      Doctrine.manual => 'Manual',
    };

/// One item of a doctrine's list: a module, a tier upgrade, or an outpost.
enum DoctrineStep {
  pad,
  pod,
  turret,
  stores,
  hospital,
  generator,
  workshop,
  station,
  fortress,
  outpost,
}

const Map<Doctrine, List<DoctrineStep>> kDoctrines = {
  Doctrine.balanced: [
    DoctrineStep.pad,
    DoctrineStep.pod,
    DoctrineStep.station,
    DoctrineStep.stores,
    DoctrineStep.hospital,
    DoctrineStep.turret,
    DoctrineStep.workshop,
    DoctrineStep.outpost,
    DoctrineStep.fortress,
    DoctrineStep.turret,
    DoctrineStep.turret,
    DoctrineStep.pad,
  ],
  Doctrine.hold: [
    DoctrineStep.turret,
    DoctrineStep.turret,
    DoctrineStep.hospital,
    DoctrineStep.station,
    DoctrineStep.turret,
    DoctrineStep.stores,
    DoctrineStep.pad,
    DoctrineStep.pod,
    DoctrineStep.fortress,
    DoctrineStep.turret,
  ],
  Doctrine.push: [
    DoctrineStep.pad,
    DoctrineStep.pod,
    DoctrineStep.station,
    DoctrineStep.pod,
    DoctrineStep.stores,
    DoctrineStep.hospital,
    DoctrineStep.outpost,
    DoctrineStep.turret,
    DoctrineStep.fortress,
  ],
  Doctrine.manual: [],
};

ModuleKind? moduleOfStep(DoctrineStep s) => switch (s) {
      DoctrineStep.pad => ModuleKind.supplyPad,
      DoctrineStep.pod => ModuleKind.barracksPod,
      DoctrineStep.turret => ModuleKind.turret,
      DoctrineStep.stores => ModuleKind.stores,
      DoctrineStep.hospital => ModuleKind.fieldHospital,
      DoctrineStep.generator => ModuleKind.generator,
      DoctrineStep.workshop => ModuleKind.workshop,
      DoctrineStep.station || DoctrineStep.fortress || DoctrineStep.outpost => null,
    };
