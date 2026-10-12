// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A stand-in [FactorySim] so the floor editor can be built, run and
/// play-tested before the real floor exists (docs/plans/factory-floors.md
/// §6, wave 1 track B).
///
/// The real `FactoryFloor` (track A) is being written in parallel; the
/// editor talks only to the [FactorySim] interface, so wave 2 swaps this out
/// with no editor change. Until then this sim has to *behave* well enough to
/// exercise every drawing path: items crawl along belts and pile into
/// machines, machines craft, starve and block, and handlers walk between the
/// receiving and shipping docks carrying freight. It makes no claim to the
/// real floor's rules or rates — it is a toy with honest edges (it refuses
/// out-of-hall and overlapping placements the same way the real one will).
///
/// Deterministic like the real thing: placements are walked in id order and
/// nothing reads a clock or an RNG, so a widget test can step it and assert.
library;

import 'dart:math' as math;

import '../../../../domain/colony/city/factory/factory_colony_port.dart';
import '../../../../domain/colony/city/factory/factory_entities.dart';
import '../../../../domain/colony/city/factory/factory_grid.dart';
import '../../../../domain/colony/city/factory/factory_handling.dart';
import '../../../../domain/colony/city/factory/factory_item.dart';
import '../../../../domain/colony/city/factory/factory_ledger.dart';
import '../../../../domain/colony/city/factory/factory_recipe.dart';
import '../../../../domain/colony/city/factory/factory_sim_api.dart';
import '../../../../domain/colony/city/factory/floor_blueprint.dart';
import 'floor_layout_index.dart';

/// Tiles per second an item rides a belt (a slow conveyor, ~0.9 m/s).
const double kDemoBeltTilesPerS = 0.45;

/// Smallest gap between two items on one belt tile run, in tiles.
const double kDemoBeltGap = 0.5;

/// Seconds between items fed onto a belt run that starts at a dock.
const double kDemoFeedEveryS = 2.0;

/// Output items a machine holds before it reports blocked.
const int kDemoOutputCap = 6;

/// Seconds a handler spends picking up or setting down a load.
const double kDemoHandleS = 1.0;

/// Demo recipes, registered only by the dev entry ([ensureDemoRecipes]) so
/// that a real recipe table is never polluted by the toy. Ids are prefixed
/// `demo:` so they can never collide with a real saved id.
const List<FactoryRecipe> kDemoRecipes = [
  FactoryRecipe(id: 'demo:smelt', label: 'Smelt Ore',
      station: StationKind.smelter, inputs: [ItemQty('ore', 2)],
      outputs: [ItemQty('pigIron', 1), ItemQty('slag', 1)], seconds: 4,
      powerKw: 120),
  FactoryRecipe(id: 'demo:refine', label: 'Refine Steel',
      station: StationKind.furnace, inputs: [ItemQty('pigIron', 1)],
      outputs: [ItemQty('steelBillet', 1)], seconds: 5, powerKw: 90),
  FactoryRecipe(id: 'demo:roll', label: 'Roll Steel',
      station: StationKind.mill, inputs: [ItemQty('steelBillet', 1)],
      outputs: [ItemQty('steel', 4)], seconds: 3, powerKw: 60),
  FactoryRecipe(id: 'demo:tube', label: 'Draw Tubes',
      station: StationKind.press, inputs: [ItemQty('steel', 1)],
      outputs: [ItemQty('tubes', 1)], seconds: 2, powerKw: 25),
  FactoryRecipe(id: 'demo:packSteel', label: 'Pack Steel',
      station: StationKind.packer, inputs: [ItemQty('steel', 10)],
      outputs: [ItemQty('crate:steel', 1)], seconds: 3, powerKw: 8),
  FactoryRecipe(id: 'demo:packTubes', label: 'Pack Tubes',
      station: StationKind.packer, inputs: [ItemQty('tubes', 10)],
      outputs: [ItemQty('crate:tubes', 1)], seconds: 3, powerKw: 8),
  FactoryRecipe(id: 'demo:assemble', label: 'Assemble Frame',
      station: StationKind.assembler, inputs: [ItemQty('steel', 2)],
      outputs: [ItemQty('tubes', 1)], seconds: 4, powerKw: 15),
  FactoryRecipe(id: 'demo:leach', label: 'Leach Slag',
      station: StationKind.chem, inputs: [ItemQty('slag', 2)],
      outputs: [ItemQty('ore', 1)], seconds: 6, powerKw: 40),
  FactoryRecipe(id: 'demo:unpack', label: 'Unpack Steel',
      station: StationKind.unpacker, inputs: [ItemQty('crate:steel', 1)],
      outputs: [ItemQty('steel', 10)], seconds: 3, powerKw: 5),
];

/// Registers [kDemoRecipes] (idempotent).
void ensureDemoRecipes() {
  for (final r in kDemoRecipes) {
    FactoryRecipes.register(r);
  }
}

class _BeltItem {
  _BeltItem(this.item, this.progress);
  final String item;
  double progress;
}

class _Machine {
  final Map<String, int> input = {};
  final Map<String, int> output = {};
  double timer = 0;
  MachineStatus status = MachineStatus.idle;
}

class _Handler {
  _Handler(this.id, this.kind, this.x, this.y);
  final int id;
  final HandlerKind kind;
  double x, y;
  HandlerState state = HandlerState.idle;
  String? carrying;
  int count = 0;
  int? target; // placement id
  double wait = 0;
  int trip = 0;
}

class DemoFactorySim implements FactorySim {
  DemoFactorySim(this._bp) {
    _reindex();
    _syncHandlers();
  }

  /// A demo hall that touches every kind of entity the editor draws: docks
  /// on the south (receiving) and north (shipping) walls, belts into a
  /// smelter line, a crane bay over the heavy mill, aisles, staging, racks,
  /// a charging bay, a crossing, an arm and chests, and a mixed crew.
  factory DemoFactorySim.demo() {
    ensureDemoRecipes();
    final bp = FloorBlueprint(
        name: 'Demo Steel Works', hall: const HallSize(80, 50),
        plantType: 'steelmill');
    final sim = DemoFactorySim(bp);
    void put(Placement p) => sim.place(p);
    // Floor markings first so solids draw over them.
    put(const Placement(id: 0, kind: EntityKind.staging, pos: TilePos(2, 1),
        span: (16, 4)));
    put(const Placement(id: 0, kind: EntityKind.aisle, pos: TilePos(0, 22),
        span: (80, 2)));
    put(const Placement(id: 0, kind: EntityKind.aisle, pos: TilePos(38, 0),
        span: (2, 50)));
    put(const Placement(id: 0, kind: EntityKind.craneBay, pos: TilePos(44, 8),
        span: (24, 10)));
    put(const Placement(id: 0, kind: EntityKind.staging,
        pos: TilePos(56, 44), span: (16, 4)));
    // Receiving docks on the south wall, belts north into two smelters.
    for (final x in const [4, 12]) {
      put(Placement(id: 0, kind: EntityKind.receivingDock, pos: TilePos(x, 0),
          item: 'ore'));
      for (var y = 1; y < 8; y++) {
        put(Placement(id: 0, kind: EntityKind.belt, pos: TilePos(x, y),
            dir: Dir4.north));
      }
      put(Placement(id: 0, kind: EntityKind.machine, pos: TilePos(x - 1, 8),
          recipe: 'demo:smelt', dir: Dir4.north));
      // Each smelter's output climbs one tile onto the shared run east.
      put(Placement(id: 0, kind: EntityKind.belt, pos: TilePos(x + 1, 12),
          dir: Dir4.north));
    }
    for (var x = 5; x < 22; x++) {
      put(Placement(id: 0, kind: EntityKind.belt, pos: TilePos(x, 13)));
    }
    put(const Placement(id: 0, kind: EntityKind.machine, pos: TilePos(22, 12),
        recipe: 'demo:refine'));
    // The billet run crosses the north-south aisle on two crossings.
    for (var x = 26; x < 46; x++) {
      put(Placement(id: 0,
          kind: x == 38 || x == 39 ? EntityKind.crossing : EntityKind.belt,
          pos: TilePos(x, 13)));
    }
    put(const Placement(id: 0, kind: EntityKind.machine, pos: TilePos(46, 12),
        recipe: 'demo:roll', mode: MachineMode.automated));
    for (var x = 51; x < 58; x++) {
      put(Placement(id: 0, kind: EntityKind.belt, pos: TilePos(x, 13)));
    }
    put(const Placement(id: 0, kind: EntityKind.machine, pos: TilePos(58, 12),
        recipe: 'demo:tube', mode: MachineMode.manual));
    for (var y = 15; y < 30; y++) {
      put(Placement(id: 0, kind: EntityKind.belt, pos: TilePos(59, y),
          dir: Dir4.north));
    }
    put(const Placement(id: 0, kind: EntityKind.machine, pos: TilePos(58, 30),
        recipe: 'demo:packTubes', dir: Dir4.north));
    put(const Placement(id: 0, kind: EntityKind.machine, pos: TilePos(64, 30),
        recipe: 'demo:packSteel'));
    put(const Placement(id: 0, kind: EntityKind.machine, pos: TilePos(20, 30),
        recipe: 'demo:assemble'));
    put(const Placement(id: 0, kind: EntityKind.machine, pos: TilePos(28, 30),
        recipe: 'demo:leach'));
    put(const Placement(id: 0, kind: EntityKind.chest, pos: TilePos(18, 31)));
    put(const Placement(id: 0, kind: EntityKind.arm, pos: TilePos(19, 31)));
    put(const Placement(id: 0, kind: EntityKind.chest, pos: TilePos(18, 32),
        item: 'slag'));
    for (var i = 0; i < 4; i++) {
      put(Placement(id: 0, kind: EntityKind.rack,
          pos: TilePos(2 + i * 3, 40)));
    }
    put(const Placement(id: 0, kind: EntityKind.chargingBay,
        pos: TilePos(34, 44)));
    for (final x in const [58, 64, 70]) {
      put(Placement(id: 0, kind: EntityKind.shippingDock,
          pos: TilePos(x, 49)));
    }
    sim
      ..hire(HandlerKind.onFoot, 5)
      ..hire(HandlerKind.palletJack, 1)
      ..hire(HandlerKind.forklift, 2)
      ..hire(HandlerKind.crane, 1);
    return sim;
  }

  final FloorBlueprint _bp;
  int _rev = 0;
  double _sim = 0;
  double _carry = 0;
  FactoryLedger _ledger = FactoryLedger();
  late FloorLayoutIndex _ix;

  final Map<int, List<_BeltItem>> _belts = {};
  final Map<int, _Machine> _machines = {};
  final Map<int, Map<String, int>> _stores = {};
  final Map<int, double> _feed = {};
  final List<_Handler> _handlers = [];
  int _nextHandlerId = 1;
  double _powerKw = 0;

  void _reindex() {
    _ix = FloorLayoutIndex(_bp, _rev);
    final live = {for (final p in _bp.placements) p.id};
    _belts.removeWhere((k, _) => !live.contains(k));
    _machines.removeWhere((k, _) => !live.contains(k));
    _stores.removeWhere((k, _) => !live.contains(k));
    for (final p in _bp.placements) {
      switch (p.kind) {
        case EntityKind.belt:
          _belts.putIfAbsent(p.id, () => []);
        case EntityKind.machine:
          _machines.putIfAbsent(p.id, () => _Machine());
        case EntityKind.chest:
        case EntityKind.receivingDock:
        case EntityKind.shippingDock:
        case EntityKind.rack:
          _stores.putIfAbsent(p.id, () => {});
        default:
      }
    }
  }

  void _syncHandlers() {
    final docks = [
      for (final p in _bp.placements)
        if (p.kind == EntityKind.receivingDock) p,
    ];
    final home = docks.isEmpty ? const TilePos(1, 1) : docks.first.pos;
    for (final kind in HandlerKind.values) {
      final want = _bp.roster[kind] ?? 0;
      final have = [for (final h in _handlers) if (h.kind == kind) h];
      for (var i = have.length; i < want; i++) {
        _handlers.add(_Handler(_nextHandlerId++, kind,
            home.x + 0.5 + i % 4, home.y + 1.5 + i ~/ 4));
      }
      for (var i = have.length - 1; i >= want; i--) {
        _handlers.remove(have[i]);
      }
    }
  }

  EditResult _edited(int id) {
    _rev++;
    _reindex();
    return EditResult.ok(id);
  }

  // ---- View ----------------------------------------------------------

  @override
  FloorBlueprint get blueprint => _bp;
  @override
  int get layoutRev => _rev;
  @override
  double get simSeconds => _sim;

  @override
  MachineStatus statusOf(int placementId) =>
      _machines[placementId]?.status ?? MachineStatus.idle;

  @override
  Map<String, int> contentsOf(int placementId) {
    final m = _machines[placementId];
    if (m != null) {
      final out = <String, int>{...m.input};
      m.output.forEach((k, v) => out[k] = (out[k] ?? 0) + v);
      return out;
    }
    final s = _stores[placementId];
    if (s != null) return {...s};
    final b = _belts[placementId];
    if (b != null) {
      final out = <String, int>{};
      for (final i in b) {
        out[i.item] = (out[i.item] ?? 0) + 1;
      }
      return out;
    }
    return const {};
  }

  @override
  Iterable<BeltItemView> get beltItems sync* {
    for (final p in _bp.placements) {
      if (p.kind != EntityKind.belt) continue;
      final list = _belts[p.id];
      if (list == null) continue;
      for (final i in list) {
        yield BeltItemView(p.pos, i.item, i.progress);
      }
    }
  }

  @override
  Iterable<HandlerView> get handlers => [
        for (final h in _handlers)
          HandlerView(id: h.id, kind: h.kind, x: h.x, y: h.y, state: h.state,
              carrying: h.carrying, carryingCount: h.count),
      ];

  @override
  int get pendingRequests {
    var n = 0;
    for (final m in _machines.values) {
      if (m.status == MachineStatus.blocked) n++;
    }
    for (final h in _handlers) {
      if (h.state == HandlerState.idle) n--;
    }
    return math.max(0, n);
  }

  @override
  FactoryLedger get ledger => _ledger;

  @override
  double get jobDemand => _bp.jobDemand;

  @override
  double get powerDemandKw => _powerKw;

  // ---- Editor --------------------------------------------------------

  @override
  EditResult place(Placement p) {
    final verdict = _ix.check(p);
    if (!verdict.ok) {
      return EditResult.refused(verdict.refusal, verdict.otherId);
    }
    final id = _bp.nextId;
    _bp.placements.add(p.copyWith(id: id));
    return _edited(id);
  }

  @override
  EditResult remove(int placementId) {
    final i = _bp.placements.indexWhere((p) => p.id == placementId);
    if (i < 0) return const EditResult.refused(EditRefusal.noSuchPlacement);
    _bp.placements.removeAt(i);
    return _edited(placementId);
  }

  @override
  EditResult rotate(int placementId) {
    final i = _bp.placements.indexWhere((p) => p.id == placementId);
    if (i < 0) return const EditResult.refused(EditRefusal.noSuchPlacement);
    final old = _bp.placements[i];
    if (kSpannedKinds.contains(old.kind)) {
      return const EditResult.refused(EditRefusal.wrongKind);
    }
    final turned = old.copyWith(dir: old.dir.turnCw);
    _bp.placements.removeAt(i);
    final verdict = FloorLayoutIndex(_bp, _rev).check(turned);
    if (!verdict.ok) {
      _bp.placements.insert(i, old);
      return EditResult.refused(verdict.refusal, verdict.otherId);
    }
    _bp.placements.insert(i, turned);
    return _edited(placementId);
  }

  @override
  EditResult setRecipe(int placementId, String recipeId) {
    final i = _bp.placements.indexWhere((p) => p.id == placementId);
    if (i < 0) return const EditResult.refused(EditRefusal.noSuchPlacement);
    final old = _bp.placements[i];
    if (old.kind != EntityKind.machine) {
      return const EditResult.refused(EditRefusal.wrongKind);
    }
    final r = FactoryRecipes.byId(recipeId);
    if (r == null) return const EditResult.refused(EditRefusal.unknownRecipe);
    final cur = old.recipe == null ? null : FactoryRecipes.byId(old.recipe!);
    if (cur != null && cur.station != r.station) {
      return const EditResult.refused(EditRefusal.wrongKind);
    }
    _bp.placements[i] = old.copyWith(recipe: recipeId);
    _machines[placementId] = _Machine();
    return _edited(placementId);
  }

  @override
  EditResult setMode(int placementId, MachineMode mode) {
    final i = _bp.placements.indexWhere((p) => p.id == placementId);
    if (i < 0) return const EditResult.refused(EditRefusal.noSuchPlacement);
    final old = _bp.placements[i];
    if (old.kind != EntityKind.machine) {
      return const EditResult.refused(EditRefusal.wrongKind);
    }
    _bp.placements[i] = old.copyWith(mode: mode);
    return _edited(placementId);
  }

  @override
  EditResult hire(HandlerKind kind, int delta) {
    final n = (_bp.roster[kind] ?? 0) + delta;
    if (n < 0) return const EditResult.refused(EditRefusal.notAllowed);
    if (n == 0) {
      _bp.roster.remove(kind);
    } else {
      _bp.roster[kind] = n;
    }
    _syncHandlers();
    _rev++;
    return const EditResult.ok(null);
  }

  // ---- Sim -----------------------------------------------------------

  @override
  void step(double dt, FactoryColonyPort port) {
    _carry += dt;
    while (_carry >= kFactoryStepS) {
      _carry -= kFactoryStepS;
      _sub(kFactoryStepS, port);
    }
  }

  @override
  FactoryLedger takeLedger() {
    final l = _ledger;
    _ledger = FactoryLedger();
    return l;
  }

  @override
  Map<String, Object?> toJson() => {
        'bp': _bp.toJson(),
        't': _sim,
      };

  void _sub(double dt, FactoryColonyPort port) {
    _sim += dt;
    _ledger.seconds += dt;
    final speed = port.powerShare.clamp(0.0, 1.0) *
        port.staffingShare.clamp(0.0, 1.0);
    _feedBelts(dt, port);
    _advanceBelts(dt * speed);
    _craft(dt * speed, port);
    _moveHandlers(dt * speed, port);
    _ledger.energyKJ += _powerKw * dt;
  }

  /// A belt whose upstream tile is a receiving dock is a run head: the dock
  /// feeds it its item on a fixed cadence (the real floor's handlers and
  /// arms do this; the toy shortcuts it).
  void _feedBelts(double dt, FactoryColonyPort port) {
    for (final p in _bp.placements) {
      if (p.kind != EntityKind.belt) continue;
      final up = _ix.solidAt(p.pos.step(p.dir.opposite));
      if (up == null) continue;
      if (up.kind != EntityKind.receivingDock &&
          up.kind != EntityKind.machine) {
        continue;
      }
      final t = (_feed[p.id] ?? 0) + dt;
      if (t < kDemoFeedEveryS) {
        _feed[p.id] = t;
        continue;
      }
      final list = _belts[p.id]!;
      if (list.isNotEmpty && list.last.progress < kDemoBeltGap) {
        _feed[p.id] = t;
        continue;
      }
      String? item;
      if (up.kind == EntityKind.receivingDock) {
        final want = up.item ?? 'ore';
        final def = FactoryItems.byId(want);
        final units = def?.commodityUnits ?? 1;
        final got = port.take(def?.commodity ?? want, units);
        if (got >= units) {
          item = want;
          _ledger.addReceived(def?.commodity ?? want, got);
        }
      } else {
        final m = _machines[up.id];
        if (m != null) {
          for (final k in m.output.keys.toList()..sort()) {
            final n = m.output[k] ?? 0;
            if (n > 0) {
              item = k;
              m.output[k] = n - 1;
              break;
            }
          }
        }
      }
      _feed[p.id] = 0;
      if (item != null) list.add(_BeltItem(item, 0));
    }
  }

  void _advanceBelts(double dt) {
    final move = kDemoBeltTilesPerS * dt;
    // Downstream first, so a freed slot is seen in the same sub-step.
    for (var i = _bp.placements.length - 1; i >= 0; i--) {
      final p = _bp.placements[i];
      if (p.kind != EntityKind.belt) continue;
      final list = _belts[p.id]!;
      var limit = 1.0;
      for (var j = 0; j < list.length; j++) {
        final it = list[j];
        it.progress = math.min(it.progress + move, limit);
        limit = it.progress - kDemoBeltGap;
      }
      if (list.isEmpty || list.first.progress < 1.0) continue;
      // A crossing is a walkable bridge over the run: items pass under it
      // to the next tile beyond (up to a few in a row).
      var at = p.pos.step(p.dir);
      var next = _ix.solidAt(at);
      for (var hop = 0;
          hop < 4 && next != null && next.kind == EntityKind.crossing;
          hop++) {
        at = at.step(p.dir);
        next = _ix.solidAt(at);
      }
      if (next == null) continue;
      final head = list.first;
      if (next.kind == EntityKind.belt) {
        final nl = _belts[next.id]!;
        if (nl.isNotEmpty && nl.last.progress < kDemoBeltGap) continue;
        list.removeAt(0);
        nl.add(_BeltItem(head.item, 0));
      } else if (next.kind == EntityKind.machine) {
        final m = _machines[next.id]!;
        final held = m.input.values.fold(0, (a, b) => a + b);
        if (held >= kDemoOutputCap * 2) continue;
        list.removeAt(0);
        m.input[head.item] = (m.input[head.item] ?? 0) + 1;
      } else if (next.kind == EntityKind.chest ||
          next.kind == EntityKind.shippingDock) {
        list.removeAt(0);
        final s = _stores[next.id]!;
        s[head.item] = (s[head.item] ?? 0) + 1;
      } else if (next.kind == EntityKind.arm) {
        // An arm hands the item on to the tile it faces.
        final drop = _ix.solidAt(next.pos.step(next.dir));
        if (drop != null && drop.kind == EntityKind.belt) {
          final nl = _belts[drop.id]!;
          if (nl.isNotEmpty && nl.last.progress < kDemoBeltGap) continue;
          list.removeAt(0);
          nl.add(_BeltItem(head.item, 0));
        }
      }
    }
  }

  void _craft(double dt, FactoryColonyPort port) {
    var kw = 0.0;
    for (final p in _bp.placements) {
      if (p.kind != EntityKind.machine) continue;
      final m = _machines[p.id]!;
      final rid = p.recipe;
      final r = rid == null ? null : FactoryRecipes.byId(rid);
      if (r == null) {
        m.status = MachineStatus.idle;
        continue;
      }
      if (port.staffingShare < 1 && p.crew.workers > 0) {
        m.status = MachineStatus.unstaffed;
        continue;
      }
      if (port.powerShare <= 0) {
        m.status = MachineStatus.unpowered;
        continue;
      }
      final out = m.output.values.fold(0, (a, b) => a + b);
      if (out >= kDemoOutputCap) {
        m.status = MachineStatus.blocked;
        continue;
      }
      // The toy accepts ANY input item: it only needs as many items as the
      // recipe's inputs total, so every demo line keeps moving.
      final need = r.inputs.fold(0, (a, q) => a + q.count);
      final have = m.input.values.fold(0, (a, b) => a + b);
      if (m.timer <= 0 && have < need) {
        m.status = MachineStatus.starved;
        continue;
      }
      if (m.timer <= 0) {
        var left = need;
        for (final k in m.input.keys.toList()..sort()) {
          final n = m.input[k] ?? 0;
          final use = math.min(n, left);
          m.input[k] = n - use;
          left -= use;
          if (left == 0) break;
        }
        m.input.removeWhere((_, v) => v == 0);
      }
      m.status = MachineStatus.working;
      kw += r.powerKw * p.crew.powerMult;
      _ledger.addWork(WorkRole.station, p.crew.workers * dt);
      m.timer += dt * p.crew.speedMult;
      if (m.timer >= r.seconds) {
        m.timer = 0;
        for (final q in r.outputs) {
          m.output[q.item] = (m.output[q.item] ?? 0) + 1;
        }
      }
    }
    for (final h in _handlers) {
      if (h.state != HandlerState.idle) {
        kw += kHandlerSpecs[h.kind]!.powerKw;
      }
    }
    _powerKw = kw;
  }

  /// Handlers shuttle: a receiving dock (pick up its item) → the nearest
  /// machine by placement order on alternate trips, or a shipping dock (set
  /// down; it ships). Straight lines through the hall — the real floor
  /// paths on the grid, the toy only has to look busy.
  void _moveHandlers(double dt, FactoryColonyPort port) {
    final receiving = <Placement>[];
    final shipping = <Placement>[];
    for (final p in _bp.placements) {
      if (p.kind == EntityKind.receivingDock) receiving.add(p);
      if (p.kind == EntityKind.shippingDock) shipping.add(p);
    }
    for (final h in _handlers) {
      final spec = kHandlerSpecs[h.kind]!;
      if (receiving.isEmpty || shipping.isEmpty) {
        h.state = HandlerState.idle;
        continue;
      }
      if (h.wait > 0) {
        h.wait -= dt;
        continue;
      }
      if (h.state == HandlerState.idle) {
        h.target = receiving[(h.id + h.trip) % receiving.length].id;
        h.state = HandlerState.toPickup;
      }
      final tgt = h.target == null ? null : _ix.byId(h.target!);
      if (tgt == null) {
        h.state = HandlerState.idle;
        continue;
      }
      final f = tgt.footprint;
      final tx = f.x0 + f.w / 2;
      final ty = h.state == HandlerState.toPickup ? f.y1 + 0.5 : f.y0 - 0.5;
      final dx = tx - h.x, dy = ty - h.y;
      final d = math.sqrt(dx * dx + dy * dy);
      final stepTiles = spec.speedMps / kFactoryTileM * dt;
      if (d > stepTiles) {
        h.x += dx / d * stepTiles;
        h.y += dy / d * stepTiles;
        _ledger.addWork(WorkRole.handler, spec.operators * dt);
        _ledger.addEquipment(h.kind, dt);
        if (h.carrying != null) {
          _ledger.itemMetres += h.count * stepTiles * kFactoryTileM;
        }
        continue;
      }
      h.x = tx;
      h.y = ty;
      h.wait = kDemoHandleS;
      if (h.state == HandlerState.toPickup) {
        final want = tgt.item ?? 'ore';
        final def = FactoryItems.byId(want);
        final units = (def?.commodityUnits ?? 1) * spec.capacity;
        final got = port.take(def?.commodity ?? want, units);
        _ledger.addReceived(def?.commodity ?? want, got);
        h.carrying = want;
        h.count = spec.capacity;
        h.target = shipping[(h.id + h.trip) % shipping.length].id;
        h.state = HandlerState.carrying;
      } else {
        final item = h.carrying ?? 'ore';
        final def = FactoryItems.byId(item);
        final units = (def?.commodityUnits ?? 1) * h.count;
        final put = port.give(def?.commodity ?? item, units);
        _ledger.addShipped(def?.commodity ?? item, put);
        final s = _stores[tgt.id];
        if (s != null) s[item] = (s[item] ?? 0) + h.count;
        h.carrying = null;
        h.count = 0;
        h.trip++;
        h.state = HandlerState.idle;
      }
    }
  }
}
