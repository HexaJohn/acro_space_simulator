// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A running factory floor (docs/plans/factory-floors.md §3, §8).
///
/// The one real [FactorySim]: a [FloorBlueprint]'s layout plus everything
/// it is doing — items riding belts, arms mid-swing, machines' buffers and
/// craft timers, workers carrying parts across the hall. The colony (phase
/// 3) and the measurement harness only call [step] and [takeLedger]; the
/// editor draws through the view getters and edits through the
/// [FactoryFloorEditor] methods.
///
/// **Tick.** [step] runs whole [kFactoryStepS] sub-steps and carries the
/// remainder, so a floor's result never depends on the caller's frame rate.
/// Each sub-step runs in the plan's order: receiving docks emit → move
/// requests are posted → the dispatcher assigns them → handlers walk, pick
/// and drop → arms swing → belts advance → machines craft → shipping docks
/// hand goods to the colony.
///
/// **Determinism.** No RNG, no clock, no hash order: placements are walked
/// in id order, tiles row-major, item maps in sorted-key order. [toJson]
/// saves every bit of runtime state (including the sub-step remainder), so
/// save → load → step equals an uninterrupted step bit for bit.
///
/// **Conservation.** Nothing is created or lost at the docks: a receiving
/// dock takes from the colony only when the tile in front of it has room,
/// and a shipping dock keeps an item the colony refuses (the dock backs up,
/// then the belt, then the line — real back-pressure). Partial grants are
/// carried as part-paid units on the dock, never rounded away. Nor is
/// anything lost to an EDIT: what a removed or re-recipe'd placement held
/// (a running craft's inputs included) is set down as a [FloorPile] beside
/// it, a load whose target vanished or was walled off is re-routed to the
/// nearest store with room or set down at the worker's feet, and a fired
/// worker sets his load down first. [itemsOnFloor] and [craftNet] let a
/// test prove it: held + shipped − received − craftNet is zero, always.
///
/// **Who feeds what.** Feeds are tracked per (machine, item), not per
/// machine. An arm or belt counts as feeding an input only if what can
/// actually reach it upstream includes that item: a receiving dock's item,
/// a machine's outputs (through a filter if the arm has one), what a belt
/// run carries (solved as a fixed point over docks, arms and belts), and
/// "anything" for an unfiltered chest. Likewise an arm clears only the
/// outputs its filter passes AND its drop tile accepts. So an assembler
/// with one belt-fed input still asks walkers for the other, and a
/// smelter whose only arm takes pig iron still offers its slag.
///
/// **People.** Stations need their crew and handlers are workers. The
/// colony's staffing share decides how many of the layout's jobs are filled
/// this sub-step; they are handed out by placement id, station crews first,
/// and a station short of its full crew does not run.
library;

import 'dart:collection';
import 'dart:typed_data';

import 'factory_catalog.dart';
import 'factory_colony_port.dart';
import 'factory_entities.dart';
import 'factory_floor_state.dart';
import 'factory_grid.dart';
import 'factory_handling.dart';
import 'factory_handling_dispatch.dart';
import 'factory_item.dart';
import 'factory_ledger.dart';
import 'factory_pathing.dart';
import 'factory_recipe.dart';
import 'factory_sim_api.dart';
import 'floor_blueprint.dart';

/// Belt speed in tiles per second: 3 m/s, a brisk industrial conveyor.
const double kBeltTilesPerS = 1.5;

/// Closest two items sit on one lane, in tiles: four per tile, so one lane
/// carries 6 items/s — far above any single dock, so belts are never the
/// template's bottleneck (a designer can still jam one).
const double kBeltGap = 0.25;

/// One arm swing, either way. A full pick-swing-drop-return cycle is two
/// swings: 2 items/s per arm.
const double kArmSwingS = 0.25;

/// Items a receiving dock emits per second when the tile in front has room.
/// One pallet a second: a truck bay with a dock leveller and a crew.
const double kReceivingItemsPerS = 1.0;

/// Items a shipping dock hands to the colony per second.
const double kShippingItemsPerS = 2.0;

/// Items a shipping dock holds while the colony refuses them.
const int kShippingBufferItems = 4;

/// Items a chest holds.
const int kChestCapacity = 32;

/// Items set down per staging tile (one pallet footprint, stacked two).
const int kStagingItemsPerTile = 2;

/// A machine buffers this many crafts' worth of each input and output.
const int kMachineBufferCrafts = 2;

/// Seconds a worker takes to pick up or set down a load at a stop.
const double kHandPickS = 1.0;
const double kHandDropS = 1.0;

/// Constant draw of an arm and of a belt tile, kW.
const double kArmKw = 0.4;
const double kBeltKw = 0.1;

/// Handler kinds this phase moves. Phase 4 adds vehicles; until then the
/// editor refuses to hire them and a blueprint's roster of them is kept but
/// not spawned.
const Set<HandlerKind> kSimulatedHandlerKinds = {HandlerKind.onFoot};

/// Slop for comparing accumulated sub-step sums (0.25 s steps are exact in
/// binary; machine speeds like 0.6 are not).
const double _eps = 1e-9;

/// Save format version.
const int _kFloorJsonVersion = 1;

/// Flow-field key reserved for the idle spot (placement ids are positive;
/// floor piles use [_pileId], below -1).
const int _kIdleKey = -1;

/// The pseudo-placement id of the floor pile on tile [t].
int _pileId(TilePos t) => -2 - t.key;

/// "Any item": what an unfiltered chest may hand an arm.
const String _kAnyItem = '*';

bool _isBelt(EntityKind k) => k == EntityKind.belt || k == EntityKind.crossing;

/// Solid entities a handler may still stand on.
bool _walkableSolid(EntityKind k) =>
    k == EntityKind.crossing || k == EntityKind.chargingBay;

class FactoryFloor implements FactorySim {
  FactoryFloor._(this._bp);

  /// A fresh floor running [bp] (copied; the blueprint stays untouched).
  /// Handlers of every simulated kind in the roster start at the idle spot.
  factory FactoryFloor.fromBlueprint(FloorBlueprint bp) {
    ensureFactoryCatalog();
    final f = FactoryFloor._(bp.copy());
    f._rebuild();
    for (final p in f._bp.placements) {
      f._initState(p);
    }
    final spot = f._idleTile;
    for (final kind in HandlerKind.values) {
      if (!kSimulatedHandlerKinds.contains(kind)) continue;
      final n = f._bp.roster[kind] ?? 0;
      for (var i = 0; i < n; i++) {
        f._handlers.add(FloorHandler(id: f._nextHandlerId++, kind: kind, at: spot));
      }
    }
    return f;
  }

  /// A floor exactly as [toJson] left it.
  factory FactoryFloor.fromJson(Map<String, Object?> j) {
    ensureFactoryCatalog();
    Map<String, Object?> m(Object? o) =>
        ((o as Map?) ?? const {}).cast<String, Object?>();
    final f = FactoryFloor._(FloorBlueprint.fromJson(m(j['bp'])))
      .._layoutRev = (j['rev'] as num?)?.toInt() ?? 0
      .._simSeconds = (j['t'] as num?)?.toDouble() ?? 0
      .._carry = (j['cr'] as num?)?.toDouble() ?? 0
      .._nextHandlerId = (j['nh'] as num?)?.toInt() ?? 1
      .._ledger = FactoryLedger.fromJson(m(j['led']));
    for (final h in (j['h'] as List? ?? const [])) {
      f._handlers.add(FloorHandler.fromJson(m(h)));
    }
    for (final r in (j['q'] as List? ?? const [])) {
      f._queue.add(MoveRequest.fromJson(r));
    }
    f._rebuild();
    for (final p in f._bp.placements) {
      f._initState(p);
    }
    m(j['m']).forEach(
        (k, v) => f._machines[int.parse(k)] = MachineState.fromJson(m(v)));
    m(j['b']).forEach((k, v) => f._belts[int.parse(k)] = BeltState.fromJson(v));
    m(j['a']).forEach((k, v) => f._arms[int.parse(k)] = ArmState.fromJson(m(v)));
    m(j['st']).forEach((k, v) => f._stores[int.parse(k)] = ItemBag.fromJson(v));
    m(j['rd']).forEach(
        (k, v) => f._recv[int.parse(k)] = ReceivingState.fromJson(v));
    m(j['sd']).forEach(
        (k, v) => f._ship[int.parse(k)] = ShippingState.fromJson(m(v)));
    for (final e in (j['pl'] as List? ?? const [])) {
      final pile = FloorPile.fromJson(e);
      f._piles[_pileId(pile.at)] = pile;
    }
    m(j['cx']).forEach((k, v) => f._craftNet[k] = (v as num).toInt());
    m(j['pp']).forEach((k, v) => f._prepaid[k] = (v as num).toDouble());
    m(j['ow']).forEach((k, v) => f._owed[k] = (v as num).toDouble());
    return f;
  }

  // ---- state ---------------------------------------------------------------

  final FloorBlueprint _bp;
  int _layoutRev = 0;
  double _simSeconds = 0;

  /// Sim seconds handed to [step] but not yet run (less than one sub-step).
  double _carry = 0;
  int _nextHandlerId = 1;

  final Map<int, MachineState> _machines = {};
  final Map<int, BeltState> _belts = {};
  final Map<int, ArmState> _arms = {};

  /// Chests and staging areas.
  final Map<int, ItemBag> _stores = {};
  final Map<int, ReceivingState> _recv = {};
  final Map<int, ShippingState> _ship = {};

  /// Goods set down on the floor, by [_pileId] (sorted: walked in order).
  final SplayTreeMap<int, FloorPile> _piles = SplayTreeMap();

  /// Items crafts made minus items they used up, by item id (sorted).
  final SplayTreeMap<String, int> _craftNet = SplayTreeMap();

  /// Commodity units already given to the colony (booked in
  /// `ledger.shipped`) for an item that is still on the floor: a removed
  /// shipping dock's part-paid front item. The next shipment of that
  /// commodity uses this credit up before asking the colony again, so the
  /// colony never gets the same units twice. Saved under 'pp'.
  final SplayTreeMap<String, double> _prepaid = SplayTreeMap();

  /// Commodity units already taken from the colony (booked in
  /// `ledger.received`) for an item not yet on the floor: a removed
  /// receiving dock's part-paid item. The next receipt of that commodity
  /// uses this credit up before taking from the colony again. Saved under
  /// 'ow'.
  final SplayTreeMap<String, double> _owed = SplayTreeMap();

  /// In id order.
  final List<FloorHandler> _handlers = [];
  final List<MoveRequest> _queue = [];
  FactoryLedger _ledger = FactoryLedger();

  // ---- derived from the layout (rebuilt on every edit, never saved) ---------

  Map<int, Placement> _byId = {};

  /// Tile key → the solid placement covering it.
  final Map<int, int> _solidAt = {};

  /// Tile key → the staging area marking it.
  final Map<int, int> _stagingAt = {};
  FloorPathing _paths = FloorPathing(const HallSize(0, 0), Uint8List(0));
  final Map<int, List<TilePos>> _goals = {};

  List<Placement> _machineList = const [];
  List<Placement> _armList = const [];
  List<Placement> _recvList = const [];
  List<Placement> _shipList = const [];
  List<Placement> _chestList = const [];
  List<Placement> _stagingList = const [];

  /// Belts and crossings, downstream first (so an item handed on is not
  /// advanced twice in one sub-step).
  List<Placement> _beltOrder = const [];

  /// Machines, chests and staging: where a handler may fetch from (a
  /// machine only the outputs no arm clears; see [_armCleared]).
  List<Placement> _providers = const [];

  /// (machine, input item) pairs an arm or belt feeds: no hand requests.
  Set<(int, String)> _autoFed = const {};

  /// (machine, output item) pairs an arm empties: not offered to handlers.
  Set<(int, String)> _armCleared = const {};

  /// Where idle handlers gather (and new hires start).
  TilePos _idleTile = const TilePos(0, 0);

  /// Items some hand-fed machine consumes: a hand-cleared output of one of
  /// these waits to be fetched rather than being pushed to a dock.
  Set<String> _handFedConsumes = const {};

  /// Staffed this sub-step, by machine id (transient).
  final Map<int, bool> _staffed = {};

  // ---- FactoryFloorView ----------------------------------------------------

  @override
  FloorBlueprint get blueprint => _bp;
  @override
  int get layoutRev => _layoutRev;
  @override
  double get simSeconds => _simSeconds;

  @override
  MachineStatus statusOf(int placementId) =>
      _machines[placementId]?.status ?? MachineStatus.idle;

  @override
  Map<String, int> contentsOf(int placementId) {
    final bag = ItemBag();
    final m = _machines[placementId];
    if (m != null) {
      for (final k in m.inBuf.keys) {
        bag.add(k, m.inBuf[k]);
      }
      for (final k in m.outBuf.keys) {
        bag.add(k, m.outBuf[k]);
      }
    }
    final s = _stores[placementId];
    if (s != null) {
      for (final k in s.keys) {
        bag.add(k, s[k]);
      }
    }
    final b = _belts[placementId];
    if (b != null) {
      for (final i in b.items) {
        bag.add(i.item, 1);
      }
    }
    final held = _arms[placementId]?.held;
    if (held != null) bag.add(held, 1);
    final sd = _ship[placementId];
    if (sd != null) {
      for (final i in sd.queue) {
        bag.add(i, 1);
      }
    }
    return bag.toMap();
  }

  /// Every item on the floor, by id: buffers (a running craft's inputs
  /// included), belts, arms, docks, stores, handlers' hands and piles.
  Map<String, int> get itemsOnFloor {
    final bag = ItemBag();
    void addBag(ItemBag b) {
      for (final k in b.keys) {
        bag.add(k, b[k]);
      }
    }

    for (final p in _machineList) {
      final m = _machines[p.id];
      if (m == null) continue;
      addBag(m.inBuf);
      addBag(m.outBuf);
      final r = _recipeOf(p);
      if (m.crafting && r != null) {
        for (final q in r.inputs) {
          bag.add(q.item, q.count);
        }
      }
    }
    for (final s in _stores.values) {
      addBag(s);
    }
    for (final b in _belts.values) {
      for (final i in b.items) {
        bag.add(i.item, 1);
      }
    }
    for (final a in _arms.values) {
      final held = a.held;
      if (held != null) bag.add(held, 1);
    }
    for (final s in _ship.values) {
      for (final i in s.queue) {
        bag.add(i, 1);
      }
    }
    for (final h in _handlers) {
      final c = h.carrying;
      if (c != null) bag.add(c, h.carryingCount);
    }
    for (final p in _piles.values) {
      addBag(p.items);
    }
    return bag.toMap();
  }

  /// Items crafts have made minus items they used up, since the floor was
  /// built (a running craft's inputs are still [itemsOnFloor], not here).
  Map<String, int> get craftNet => {..._craftNet};

  /// Commodity units booked in `ledger.shipped` for items still on the
  /// floor, by commodity: shipping docks' part-paid front items plus the
  /// prepaid credit removed docks left behind. Conservation reads
  /// held + shipped − [shippedAhead] − received + [receivedAhead] − craftNet.
  Map<String, double> get shippedAhead {
    final out = SplayTreeMap<String, double>.of(_prepaid);
    for (final p in _shipList) {
      final s = _ship[p.id];
      if (s == null || s.paid <= 0 || s.queue.isEmpty) continue;
      final c = FactoryItems.byId(s.queue.first)?.commodity;
      if (c != null) out[c] = (out[c] ?? 0) + s.paid;
    }
    out.removeWhere((_, v) => v <= 0);
    return out;
  }

  /// Commodity units booked in `ledger.received` for items not yet on the
  /// floor, by commodity: receiving docks' part-paid items plus the credit
  /// removed docks left behind (see [shippedAhead]).
  Map<String, double> get receivedAhead {
    final out = SplayTreeMap<String, double>.of(_owed);
    for (final p in _recvList) {
      final s = _recv[p.id];
      final item = p.item;
      if (s == null || s.paid <= 0 || item == null) continue;
      final c = FactoryItems.byId(item)?.commodity;
      if (c != null) out[c] = (out[c] ?? 0) + s.paid;
    }
    out.removeWhere((_, v) => v <= 0);
    return out;
  }

  /// Uses up to [need] units of [credit]'s [commodity], returning how many.
  static double _useCredit(
      SplayTreeMap<String, double> credit, String commodity, double need) {
    final have = credit[commodity] ?? 0;
    if (have <= 0 || need <= 0) return 0;
    final use = have < need ? have : need;
    final left = have - use;
    if (left > _eps) {
      credit[commodity] = left;
    } else {
      credit.remove(commodity);
    }
    return use;
  }

  /// Goods set down on the open floor, by tile (row-major order).
  Map<TilePos, Map<String, int>> get floorPiles {
    final ps = _piles.values.toList()
      ..sort((a, b) => a.at.key.compareTo(b.at.key));
    return {for (final p in ps) p.at: p.items.toMap()};
  }

  @override
  Iterable<BeltItemView> get beltItems sync* {
    for (final p in _beltOrderById) {
      final b = _belts[p.id];
      if (b == null) continue;
      for (final i in b.items) {
        yield BeltItemView(p.pos, i.item, i.p);
      }
    }
  }

  List<Placement> get _beltOrderById =>
      [..._beltOrder]..sort((a, b) => a.id.compareTo(b.id));

  @override
  Iterable<HandlerView> get handlers => [for (final h in _handlers) h.view];

  @override
  int get pendingRequests => _queue.length;

  @override
  FactoryLedger get ledger => _ledger;

  @override
  double get jobDemand => _bp.jobDemand;

  @override
  double get powerDemandKw {
    var kw = 0.0;
    for (final p in _machineList) {
      if (_machines[p.id]?.status != MachineStatus.working) continue;
      final r = _recipeOf(p);
      if (r != null) kw += r.powerKw * p.crew.powerMult;
    }
    kw += _armList.length * kArmKw + _beltOrder.length * kBeltKw;
    for (final h in _handlers) {
      if (h.active) kw += h.spec.powerKw;
    }
    return kw;
  }

  // ---- FactorySim ----------------------------------------------------------

  @override
  void step(double dt, FactoryColonyPort port) {
    if (!(dt > 0)) return;
    _carry += dt;
    final n = ((_carry + _eps) / kFactoryStepS).floor();
    if (n <= 0) return;
    _carry -= n * kFactoryStepS;
    if (_carry < 0) _carry = 0;
    for (var i = 0; i < n; i++) {
      _subStep(port);
    }
  }

  @override
  FactoryLedger takeLedger() {
    final l = _ledger;
    _ledger = FactoryLedger();
    return l;
  }

  @override
  Map<String, Object?> toJson() {
    Map<String, Object?> byId<T>(
            Map<int, T> m, Object? Function(T) enc) =>
        {
          for (final k in (m.keys.toList()..sort())) '$k': enc(m[k] as T),
        };
    return {
      'v': _kFloorJsonVersion,
      'bp': _bp.toJson(),
      'rev': _layoutRev,
      't': _simSeconds,
      'cr': _carry,
      'nh': _nextHandlerId,
      if (_machines.isNotEmpty) 'm': byId(_machines, (s) => s.toJson()),
      if (_belts.isNotEmpty) 'b': byId(_belts, (s) => s.toJson()),
      if (_arms.isNotEmpty) 'a': byId(_arms, (s) => s.toJson()),
      if (_stores.isNotEmpty) 'st': byId(_stores, (s) => s.toJson()),
      if (_recv.isNotEmpty) 'rd': byId(_recv, (s) => s.toJson()),
      if (_ship.isNotEmpty) 'sd': byId(_ship, (s) => s.toJson()),
      if (_handlers.isNotEmpty) 'h': [for (final h in _handlers) h.toJson()],
      if (_queue.isNotEmpty) 'q': [for (final r in _queue) r.toJson()],
      if (_piles.isNotEmpty) 'pl': [for (final p in _piles.values) p.toJson()],
      if (_craftNet.isNotEmpty) 'cx': {..._craftNet},
      if (_prepaid.isNotEmpty) 'pp': {..._prepaid},
      if (_owed.isNotEmpty) 'ow': {..._owed},
      'led': _ledger.toJson(),
    };
  }

  // ---- the sub-step --------------------------------------------------------

  void _subStep(FactoryColonyPort port) {
    const dt = kFactoryStepS;
    final power = _unit(port.powerShare);
    _allocateStaff(_unit(port.staffingShare), dt);
    _receive(port, dt);
    _postRequests();
    Dispatcher.assign(_queue, _handlers,
        distTo: _distTo, routable: _routable);
    _moveHandlers(dt);
    _swingArms(dt);
    _advanceBelts(dt);
    _craft(power, dt);
    _shipOut(port, dt);
    _ledger.energyKJ += powerDemandKw * power * dt;
    _ledger.seconds += dt;
    _simSeconds += dt;
  }

  static double _unit(double v) => v.isNaN ? 0 : (v < 0 ? 0 : (v > 1 ? 1 : v));

  void _allocateStaff(double share, double dt) {
    var avail = (_bp.jobDemand * share + _eps).floor();
    for (final p in _machineList) {
      final need = p.crew.workers;
      final ok = avail >= need;
      _staffed[p.id] = ok;
      if (!ok) continue;
      avail -= need;
      if (need > 0) _ledger.addWork(WorkRole.station, need * dt);
      if (p.crew.maintenance > 0) {
        _ledger.addWork(WorkRole.maintenance, p.crew.maintenance * dt);
      }
    }
    for (final h in _handlers) {
      final ops = h.spec.operators;
      h.active = avail >= ops;
      if (!h.active) continue;
      avail -= ops;
      if (ops > 0) _ledger.addWork(WorkRole.handler, ops * dt);
    }
  }

  // ---- docks ---------------------------------------------------------------

  void _receive(FactoryColonyPort port, double dt) {
    for (final p in _recvList) {
      final s = _recv[p.id]!;
      final itemId = p.item;
      final def = itemId == null ? null : FactoryItems.byId(itemId);
      if (def == null) continue;
      s.credit += kReceivingItemsPerS * dt;
      if (s.credit > 1) s.credit = 1;
      if (s.credit < 1 - _eps) continue;
      final front = _frontOf(p);
      // Never take from the colony what can't be set down.
      if (!_depositTile(front, def.id, commit: false)) continue;
      // Units a removed receiving dock already took count first.
      s.paid += _useCredit(_owed, def.commodity, def.commodityUnits - s.paid);
      final need = def.commodityUnits - s.paid;
      if (need > _eps) {
        var got = port.take(def.commodity, need);
        if (got.isNaN || got < 0) got = 0;
        if (got > need) got = need;
        if (got > 0) {
          s.paid += got;
          _ledger.addReceived(def.commodity, got);
        }
      }
      if (s.paid + _eps < def.commodityUnits) continue;
      _depositTile(front, def.id);
      s.paid = 0;
      s.credit -= 1;
    }
  }

  void _shipOut(FactoryColonyPort port, double dt) {
    for (final p in _shipList) {
      final s = _ship[p.id]!;
      s.credit += kShippingItemsPerS * dt;
      if (s.credit > 1) s.credit = 1;
      while (s.credit >= 1 - _eps && s.queue.isNotEmpty) {
        final def = FactoryItems.byId(s.queue.first);
        if (def == null) {
          // An item no catalog knows can't be counted as any commodity.
          s.queue.removeAt(0);
          s.paid = 0;
          continue;
        }
        // Units a removed shipping dock already gave count first.
        s.paid +=
            _useCredit(_prepaid, def.commodity, def.commodityUnits - s.paid);
        final need = def.commodityUnits - s.paid;
        var got = need > _eps ? port.give(def.commodity, need) : 0.0;
        if (got.isNaN || got < 0) got = 0;
        if (got > need) got = need;
        if (got > 0) {
          s.paid += got;
          _ledger.addShipped(def.commodity, got);
        }
        if (s.paid + _eps < def.commodityUnits) break; // refused: back up
        s.queue.removeAt(0);
        s.paid = 0;
        s.credit -= 1;
      }
    }
  }

  // ---- moving items between tiles and placements ---------------------------

  /// The tile just beyond [p]'s footprint along its facing.
  TilePos _frontOf(Placement p) {
    final f = p.footprint;
    return switch (p.dir) {
      Dir4.east => TilePos(f.x1, f.y0),
      Dir4.north => TilePos(f.x0, f.y1),
      Dir4.west => TilePos(f.x0 - 1, f.y0),
      Dir4.south => TilePos(f.x0, f.y0 - 1),
    };
  }

  /// The tile just behind [p] (an arm's pick tile).
  TilePos _behindOf(Placement p) {
    final f = p.footprint;
    return switch (p.dir) {
      Dir4.east => TilePos(f.x0 - 1, f.y0),
      Dir4.north => TilePos(f.x0, f.y0 - 1),
      Dir4.west => TilePos(f.x1, f.y0),
      Dir4.south => TilePos(f.x0, f.y1),
    };
  }

  Placement? _at(TilePos t) {
    if (!_bp.hall.contains(t)) return null;
    final id = _solidAt[t.key] ?? _stagingAt[t.key];
    return id == null ? null : _byId[id];
  }

  /// Sets [item] onto tile [t] (a belt's entry at [entry] progress, or into
  /// whatever placement covers it). With [commit] false, only asks.
  bool _depositTile(TilePos t, String item,
      {double entry = 0, bool commit = true}) {
    final p = _at(t);
    if (p == null) return false;
    if (_isBelt(p.kind)) {
      final b = _belts[p.id]!;
      final last = b.items.isEmpty ? null : b.items.last;
      if (last != null && last.p < kBeltGap) return false;
      if (!commit) return true;
      var e = entry;
      if (last != null && e > last.p - kBeltGap) e = last.p - kBeltGap;
      if (e < 0) e = 0;
      b.items.add(BeltItem(item, e));
      return true;
    }
    return _depositInto(p, item, commit: commit);
  }

  /// Puts one [item] into [p]'s buffer, if it takes that item and has room.
  bool _depositInto(Placement p, String item, {bool commit = true}) {
    switch (p.kind) {
      case EntityKind.machine:
        final r = _recipeOf(p);
        final q = r == null ? null : _qtyOf(r.inputs, item);
        if (q == null) return false;
        final m = _machines[p.id]!;
        if (m.inBuf[item] >= kMachineBufferCrafts * q.count) return false;
        if (commit) m.inBuf.add(item, 1);
        return true;
      case EntityKind.chest:
      case EntityKind.staging:
        final filter = p.item;
        if (filter != null && filter != item) return false;
        final bag = _stores[p.id]!;
        if (bag.total >= _storeCap(p)) return false;
        if (commit) bag.add(item, 1);
        return true;
      case EntityKind.shippingDock:
        final filter = p.item;
        if (filter != null && filter != item) return false;
        final s = _ship[p.id]!;
        if (s.queue.length >= kShippingBufferItems) return false;
        if (commit) s.queue.add(item);
        return true;
      default:
        return false;
    }
  }

  int _storeCap(Placement p) => p.kind == EntityKind.staging
      ? p.footprint.area * kStagingItemsPerTile
      : kChestCapacity;

  /// Takes one item [ok] accepts from tile [t]: the front-most on a belt,
  /// a machine's outputs in recipe order, a store's in id order.
  String? _takeFromTile(TilePos t, bool Function(String item) ok) {
    final p = _at(t);
    if (p == null) return null;
    if (_isBelt(p.kind)) {
      final b = _belts[p.id]!;
      for (var i = 0; i < b.items.length; i++) {
        final it = b.items[i].item;
        if (!ok(it)) continue;
        b.items.removeAt(i);
        return it;
      }
      return null;
    }
    for (final it in _offered(p)) {
      if (!ok(it)) continue;
      return _takeFrom(p, it, 1) == 1 ? it : null;
    }
    return null;
  }

  /// Items [p] can hand out, in pick order.
  List<String> _offered(Placement p) {
    switch (p.kind) {
      case EntityKind.machine:
        final r = _recipeOf(p);
        final m = _machines[p.id]!;
        if (r == null) return m.outBuf.keys;
        return [
          for (final q in r.outputs)
            if (m.outBuf[q.item] > 0) q.item,
        ];
      case EntityKind.chest:
      case EntityKind.staging:
        return _stores[p.id]!.keys;
      default:
        return const [];
    }
  }

  int _stored(Placement p, String item) => switch (p.kind) {
        EntityKind.machine => _machines[p.id]!.outBuf[item],
        EntityKind.chest || EntityKind.staging => _stores[p.id]![item],
        _ => 0,
      };

  /// Removes up to [n] of [item] from [p]'s output side; returns how many.
  int _takeFrom(Placement p, String item, int n) {
    final have = _stored(p, item);
    final k = have < n ? have : n;
    if (k <= 0) return 0;
    switch (p.kind) {
      case EntityKind.machine:
        _machines[p.id]!.outBuf.add(item, -k);
      case EntityKind.chest:
      case EntityKind.staging:
        _stores[p.id]!.add(item, -k);
      default:
        return 0;
    }
    return k;
  }

  // ---- arms ----------------------------------------------------------------

  void _swingArms(double dt) {
    for (final a in _armList) {
      final s = _arms[a.id]!;
      s.t -= dt;
      if (s.t > _eps) continue;
      s.t = 0;
      final front = _frontOf(a);
      final held = s.held;
      if (held != null) {
        if (_depositTile(front, held)) {
          s.held = null;
          s.t = kArmSwingS;
        }
        continue;
      }
      final filter = a.item;
      // An arm only picks what it can set down now (an inserter's rule), so
      // a filterless arm between a smelter and a press takes slag only.
      final got = _takeFromTile(
          _behindOf(a),
          (it) =>
              (filter == null || it == filter) &&
              _depositTile(front, it, commit: false));
      if (got != null) {
        s.held = got;
        s.t = kArmSwingS;
      }
    }
  }

  // ---- belts ---------------------------------------------------------------

  void _advanceBelts(double dt) {
    const move = kBeltTilesPerS * kFactoryStepS;
    assert(dt == kFactoryStepS);
    for (final p in _beltOrder) {
      final b = _belts[p.id]!;
      if (b.items.isEmpty) continue;
      final front = _frontOf(p);
      // The far edge of this tile is the near edge of a belt in front, so
      // the front item keeps its gap to that belt's last item too.
      final ahead = _at(front);
      final aheadBelt =
          ahead != null && _isBelt(ahead.kind) ? _belts[ahead.id] : null;
      var limit = double.infinity;
      if (aheadBelt != null && aheadBelt.items.isNotEmpty) {
        limit = 1 + aheadBelt.items.last.p - kBeltGap;
      }
      var i = 0;
      while (i < b.items.length) {
        final it = b.items[i];
        var np = it.p + move;
        if (np > limit) np = limit;
        if (i == 0 && np >= 1) {
          if (_depositTile(front, it.item, entry: np - 1)) {
            b.items.removeAt(0);
            // The next item is the front now, behind the one just handed on.
            limit = aheadBelt == null || aheadBelt.items.isEmpty
                ? double.infinity
                : 1 + aheadBelt.items.last.p - kBeltGap;
            continue;
          }
          np = 1;
        }
        if (np < it.p) np = it.p; // queued items never slide back
        it.p = np;
        limit = np - kBeltGap;
        i++;
      }
    }
  }

  // ---- machines ------------------------------------------------------------

  FactoryRecipe? _recipeOf(Placement p) {
    final id = p.recipe;
    return id == null ? null : FactoryRecipes.byId(id);
  }

  static ItemQty? _qtyOf(List<ItemQty> l, String item) {
    for (final q in l) {
      if (q.item == item) return q;
    }
    return null;
  }

  void _craft(double powerShare, double dt) {
    for (final p in _machineList) {
      final m = _machines[p.id]!;
      final r = _recipeOf(p);
      if (r == null) {
        m.status = MachineStatus.idle;
        continue;
      }
      if (_staffed[p.id] != true) {
        m.status = MachineStatus.unstaffed;
        continue;
      }
      final needsPower = r.powerKw > 0;
      if (needsPower && powerShare <= 0) {
        m.status = MachineStatus.unpowered;
        continue;
      }
      // A brownout slows a powered station in proportion (§3 Coupling).
      final speed = p.crew.speedMult * (needsPower ? powerShare : 1.0);
      if (m.crafting) {
        m.progress += dt * speed;
        if (m.progress + _eps < r.seconds) {
          m.status = MachineStatus.working;
          continue;
        }
        if (!_outputsFit(r, m)) {
          m.progress = r.seconds;
          m.status = MachineStatus.blocked;
          continue;
        }
        for (final q in r.outputs) {
          m.outBuf.add(q.item, q.count);
          _craftNet[q.item] = (_craftNet[q.item] ?? 0) + q.count;
        }
        for (final q in r.inputs) {
          _craftNet[q.item] = (_craftNet[q.item] ?? 0) - q.count;
        }
        m.crafting = false;
        // Carry the overshoot into the next craft, so a busy machine's rate
        // is exactly 1/seconds rather than rounded up to whole sub-steps.
        m.progress -= r.seconds;
        if (m.progress < 0) m.progress = 0;
      }
      if (_inputsReady(r, m)) {
        for (final q in r.inputs) {
          m.inBuf.add(q.item, -q.count);
        }
        m.crafting = true;
        m.status = MachineStatus.working;
      } else {
        m.progress = 0;
        m.status = MachineStatus.starved;
      }
    }
  }

  static bool _inputsReady(FactoryRecipe r, MachineState m) {
    for (final q in r.inputs) {
      if (m.inBuf[q.item] < q.count) return false;
    }
    return true;
  }

  static bool _outputsFit(FactoryRecipe r, MachineState m) {
    for (final q in r.outputs) {
      if (m.outBuf[q.item] + q.count > kMachineBufferCrafts * q.count) {
        return false;
      }
    }
    return true;
  }

  // ---- move requests -------------------------------------------------------

  /// A placement or (negative id) a floor pile still on the floor.
  bool _exists(int id) =>
      id < 0 ? _piles.containsKey(id) : _byId.containsKey(id);

  /// Doubled centre of a placement or pile (integers, no halves).
  (int, int) _centre2(int id) {
    if (id < 0) {
      final t = _piles[id]?.at ?? const TilePos(0, 0);
      return (2 * t.x + 1, 2 * t.y + 1);
    }
    final f = _byId[id]!.footprint;
    return (2 * f.x0 + f.w, 2 * f.y0 + f.h);
  }

  /// Doubled centre-to-centre Manhattan distance.
  int _centreDist(int a, int b) {
    final (ax, ay) = _centre2(a);
    final (bx, by) = _centre2(b);
    return (ax - bx).abs() + (ay - by).abs();
  }

  /// How many [item] placement or pile [id] can hand to a handler.
  int _storedAt(int id, String item) {
    if (id < 0) return _piles[id]?.items[item] ?? 0;
    final p = _byId[id];
    return p == null ? 0 : _stored(p, item);
  }

  /// Removes up to [n] of [item] from placement or pile [id].
  int _takeFromId(int id, String item, int n) {
    if (id >= 0) {
      final p = _byId[id];
      return p == null ? 0 : _takeFrom(p, item, n);
    }
    final pile = _piles[id];
    if (pile == null) return 0;
    final have = pile.items[item];
    final k = have < n ? have : n;
    if (k <= 0) return 0;
    pile.items.add(item, -k);
    if (pile.items.isEmpty) _piles.remove(id);
    return k;
  }

  /// Items already promised to each placement by the queue and by handlers
  /// on their way ([skip] excluded), all items together.
  Map<int, int> _inboundTotals({FloorHandler? skip}) {
    final out = <int, int>{};
    for (final r in _queue) {
      out[r.to] = (out[r.to] ?? 0) + r.count;
    }
    for (final h in _handlers) {
      final j = h.job;
      if (j == null || identical(h, skip)) continue;
      if (h.state == HandlerState.toPickup) {
        out[j.to] = (out[j.to] ?? 0) + j.count;
      } else if (h.state == HandlerState.carrying) {
        out[j.to] = (out[j.to] ?? 0) + h.carryingCount;
      }
    }
    return out;
  }

  /// Room for [item] at a store or shipping dock [p] (0 when its filter
  /// refuses it, or [p] stores nothing).
  int _roomFor(Placement p, String item, Map<int, int> inbound) {
    final filter = p.item;
    if (filter != null && filter != item) return 0;
    final int cap, held;
    switch (p.kind) {
      case EntityKind.shippingDock:
        cap = kShippingBufferItems;
        held = _ship[p.id]!.queue.length;
      case EntityKind.chest:
      case EntityKind.staging:
        cap = _storeCap(p);
        held = _stores[p.id]!.total;
      default:
        return 0;
    }
    return cap - held - (inbound[p.id] ?? 0);
  }

  /// Posts what hand-fed inputs need and what hand-cleared outputs (and
  /// piles) no one on the floor consumes. "Already on its way" is
  /// re-derived from the queue and the handlers' jobs every time, so
  /// nothing is posted twice.
  void _postRequests() {
    final inbound = <int, ItemBag>{};
    final outbound = <int, ItemBag>{};
    final inboundTotal = <int, int>{};
    void addIn(int to, String item, int n) {
      (inbound[to] ??= ItemBag()).add(item, n);
      inboundTotal[to] = (inboundTotal[to] ?? 0) + n;
    }

    void addOut(int from, String item, int n) =>
        (outbound[from] ??= ItemBag()).add(item, n);

    for (final r in _queue) {
      addIn(r.to, r.item, r.count);
      addOut(r.from, r.item, r.count);
    }
    for (final h in _handlers) {
      final j = h.job;
      if (j == null) continue;
      if (h.state == HandlerState.toPickup) {
        addIn(j.to, j.item, j.count);
        addOut(j.from, j.item, j.count);
      } else if (h.state == HandlerState.carrying) {
        addIn(j.to, j.item, h.carryingCount);
      }
    }
    int avail(int id, String item) =>
        _storedAt(id, item) - (outbound[id]?[item] ?? 0);

    void post(String item, int n, int from, int to) {
      _queue.add(MoveRequest(item: item, count: n, from: from, to: to));
      addIn(to, item, n);
      addOut(from, item, n);
    }

    final providers = [for (final p in _providers) p.id, ..._piles.keys];

    // Pull: hand-fed inputs fetch from the nearest provider.
    for (final m in _machineList) {
      final r = _recipeOf(m);
      if (r == null) continue;
      final ms = _machines[m.id]!;
      for (final q in r.inputs) {
        if (_autoFed.contains((m.id, q.item))) continue;
        var want = kMachineBufferCrafts * q.count -
            ms.inBuf[q.item] -
            (inbound[m.id]?[q.item] ?? 0);
        while (want > 0) {
          var best = 0, bestD = 0, bestA = 0;
          for (final id in providers) {
            if (id == m.id || _armCleared.contains((id, q.item))) continue;
            final a = avail(id, q.item);
            if (a <= 0) continue;
            final d = _centreDist(id, m.id);
            if (bestA == 0 || d < bestD) {
              best = id;
              bestD = d;
              bestA = a;
            }
          }
          if (bestA == 0) break;
          final n = want < bestA ? want : bestA;
          post(q.item, n, best, m.id);
          want -= n;
        }
      }
    }

    // Push: a hand-cleared output (or a pile) nothing here consumes goes to
    // the nearest shipping dock, else chest (piles: else staging) with room.
    void push(int src, String item, {required bool toStaging}) {
      var a = avail(src, item);
      while (a > 0) {
        Placement? best;
        var bestD = 0, bestRoom = 0;
        void consider(Placement p) {
          final room = _roomFor(p, item, inboundTotal);
          if (room <= 0) return;
          final d = _centreDist(p.id, src);
          if (best == null || d < bestD) {
            best = p;
            bestD = d;
            bestRoom = room;
          }
        }

        for (final p in _shipList) {
          consider(p);
        }
        if (best == null) {
          for (final p in _chestList) {
            consider(p);
          }
        }
        if (best == null && toStaging) {
          for (final p in _stagingList) {
            consider(p);
          }
        }
        final to = best;
        if (to == null) break;
        final n = a < bestRoom ? a : bestRoom;
        post(item, n, src, to.id);
        a -= n;
      }
    }

    for (final src in _machineList) {
      final r = _recipeOf(src);
      if (r == null) continue;
      for (final q in r.outputs) {
        if (_armCleared.contains((src.id, q.item))) continue;
        if (_handFedConsumes.contains(q.item)) continue;
        push(src.id, q.item, toStaging: false);
      }
    }
    for (final id in [..._piles.keys]) {
      final pile = _piles[id];
      if (pile == null) continue;
      for (final item in pile.items.keys) {
        if (_handFedConsumes.contains(item)) continue;
        push(id, item, toStaging: true);
      }
    }
  }

  // ---- handlers ------------------------------------------------------------

  /// Walkable tiles a handler stands on to work at [p]: beside its
  /// footprint, or anywhere on a staging area.
  List<TilePos> _goalsOf(Placement p) => _goals[p.id] ??= () {
        final f = p.footprint;
        final out = <TilePos>[];
        if (p.kind == EntityKind.staging) {
          for (final t in f.tiles) {
            if (_paths.isWalkable(t)) out.add(t);
          }
          return out;
        }
        for (var y = f.y0 - 1; y <= f.y1; y++) {
          for (var x = f.x0 - 1; x <= f.x1; x++) {
            final side = (y == f.y0 - 1 || y == f.y1) && x >= f.x0 && x < f.x1;
            final end = (x == f.x0 - 1 || x == f.x1) && y >= f.y0 && y < f.y1;
            if (!side && !end) continue;
            final t = TilePos(x, y);
            if (_paths.isWalkable(t)) out.add(t);
          }
        }
        return out;
      }();

  /// Where a handler stands to work at [id]: a placement's [_goalsOf], a
  /// pile's own tile, or the idle spot for [_kIdleKey].
  List<TilePos> _goalsFor(int id) {
    if (id == _kIdleKey) return [_idleTile];
    if (id < 0) {
      final pile = _piles[id];
      return pile == null ? const [] : [pile.at];
    }
    final p = _byId[id];
    return p == null ? const [] : _goalsOf(p);
  }

  Uint16List? _fieldTo(int id) {
    if (id != _kIdleKey && !_exists(id)) return null;
    return _paths.fieldTo(id, _goalsFor(id));
  }

  int _distTo(FloorHandler h, int id) {
    final f = _fieldTo(id);
    return f == null ? kUnreachable : _paths.distance(f, h.at);
  }

  bool _routable(int from, int to) {
    final f = _fieldTo(to);
    if (f == null || !_exists(from)) return false;
    for (final g in _goalsFor(from)) {
      if (_paths.distance(f, g) >= 0) return true;
    }
    return false;
  }

  void _moveHandlers(double dt) {
    for (final h in _handlers) {
      if (!h.active) {
        // An unstaffed hand stops where it is — on a tile, not between two.
        if (h.state == HandlerState.idle) h.settle();
        continue;
      }
      final job = h.job;
      if (job == null) {
        if (h.state != HandlerState.idle) h.goIdle();
        // Home to the idle spot (a half-taken step is finished on the way).
        _walk(h, _kIdleKey, dt);
        continue;
      }
      if (h.state == HandlerState.toPickup) {
        if (!_exists(job.from)) {
          h.goIdle();
          continue;
        }
        final w = _walk(h, job.from, dt);
        if (w < 0) {
          h.goIdle(); // cut off: the request is re-posted next sub-step
          continue;
        }
        if (w == 0) continue;
        h.timer += dt;
        if (h.timer + _eps < kHandPickS) continue;
        final cap = h.spec.capacity;
        final n =
            _takeFromId(job.from, job.item, job.count < cap ? job.count : cap);
        if (n == 0) {
          h.goIdle(); // someone else got there first
          continue;
        }
        h
          ..carrying = job.item
          ..carryingCount = n
          ..state = HandlerState.carrying
          ..timer = 0;
      } else if (h.state == HandlerState.carrying) {
        final dst = _byId[job.to];
        final item = h.carrying;
        if (item == null || h.carryingCount <= 0) {
          h.goIdle();
          continue;
        }
        if (dst == null) {
          _redirect(h); // its target was removed: take the load elsewhere
          continue;
        }
        final w = _walk(h, job.to, dt);
        if (w < 0) {
          _redirect(h); // walled off: elsewhere, or set it down here
          continue;
        }
        if (w == 0) continue;
        h.timer += dt;
        if (h.timer + _eps < kHandDropS) continue;
        while (h.carryingCount > 0 && _depositInto(dst, item)) {
          h.carryingCount--;
        }
        if (h.carryingCount == 0) h.goIdle();
      }
    }
  }

  /// Sends a loaded handler whose target is gone or out of reach to the
  /// nearest REACHABLE shipping dock, chest or staging area with room for
  /// its whole load (path distance, ties by id); with none, it sets the load
  /// down at its feet as a floor pile, which then posts its own requests.
  /// Never destroys the load.
  void _redirect(FloorHandler h) {
    final item = h.carrying;
    final n = h.carryingCount;
    if (item == null || n <= 0) {
      h.goIdle();
      return;
    }
    final inbound = _inboundTotals(skip: h);
    Placement? best;
    var bestD = 0;
    for (final p in [..._shipList, ..._chestList, ..._stagingList]
      ..sort((a, b) => a.id.compareTo(b.id))) {
      if (_roomFor(p, item, inbound) < n) continue;
      final d = _distTo(h, p.id);
      if (d < 0) continue;
      if (best == null || d < bestD) {
        best = p;
        bestD = d;
      }
    }
    final to = best;
    if (to != null) {
      final from = h.job?.from ?? to.id;
      h
        ..job = MoveRequest(item: item, count: n, from: from, to: to.id)
        ..state = HandlerState.carrying
        ..timer = 0;
      return;
    }
    h.settle();
    _addPile(h.at, item, n);
    h.goIdle();
  }

  /// Sets [n] of [item] down on tile [t] (merging with a pile there).
  void _addPile(TilePos t, String item, int n) {
    if (n <= 0) return;
    (_piles[_pileId(t)] ??= FloorPile(t)).items.add(item, n);
  }

  /// Sets everything in [bag] down as one pile on the walkable tile nearest
  /// [near] (or on [near] itself in a hall with no floor left).
  void _spill(TilePos near, ItemBag bag) {
    if (bag.isEmpty) return;
    final t = _nearestWalkable(near) ?? near;
    for (final k in bag.keys) {
      _addPile(t, k, bag[k]);
    }
  }

  /// The walkable tile nearest [c] in square rings, row-major within a ring.
  TilePos? _nearestWalkable(TilePos c) {
    final hall = _bp.hall;
    final maxR = hall.w > hall.h ? hall.w : hall.h;
    for (var r = 0; r <= maxR; r++) {
      for (var y = c.y - r; y <= c.y + r; y++) {
        for (var x = c.x - r; x <= c.x + r; x++) {
          if ((x - c.x).abs() != r && (y - c.y).abs() != r) continue;
          final t = TilePos(x, y);
          if (_paths.isWalkable(t)) return t;
        }
      }
    }
    return null;
  }

  /// Moves [h] toward [target] for [dt]: 1 = standing at it, 0 = on the
  /// way, -1 = no way there.
  int _walk(FloorHandler h, int target, double dt) {
    final field = _fieldTo(target);
    if (field == null) {
      h.settle();
      return -1;
    }
    var budget = h.spec.speedMps / kFactoryTileM * dt;
    var moved = 0.0;
    var result = 0;
    while (true) {
      var nx = h.next;
      if (nx == null) {
        final d = _paths.distance(field, h.at);
        if (d == 0) {
          result = 1;
          break;
        }
        nx = d < 0 ? null : _paths.nextStep(field, h.at);
        if (nx == null) {
          result = -1;
          break;
        }
        h.next = nx;
      }
      if (budget <= 0) break;
      final need = 1 - h.prog;
      if (budget + _eps >= need) {
        budget -= need;
        moved += need;
        h
          ..at = nx
          ..next = null
          ..prog = 0;
      } else {
        h.prog += budget;
        moved += budget;
        budget = 0;
        break;
      }
    }
    if (moved > 0 && h.carryingCount > 0) {
      _ledger.itemMetres += moved * kFactoryTileM * h.carryingCount;
    }
    if (moved > 0 && h.kind != HandlerKind.onFoot) {
      _ledger.addEquipment(h.kind, dt);
    }
    return result;
  }

  /// Where idle handlers gather: the first staging area's first walkable
  /// tile, else the first tile (from the hall origin) of the largest open
  /// region of floor.
  TilePos _idleSpot() {
    for (final p in [..._bp.placements]..sort((a, b) => a.id.compareTo(b.id))) {
      if (p.kind != EntityKind.staging) continue;
      final g = _goalsOf(p);
      if (g.isNotEmpty) return g.first;
    }
    return _paths.mainRegionStart() ?? const TilePos(0, 0);
  }

  // ---- layout bookkeeping --------------------------------------------------

  void _initState(Placement p) {
    switch (p.kind) {
      case EntityKind.machine:
        _machines.putIfAbsent(p.id, MachineState.new);
      case EntityKind.belt:
      case EntityKind.crossing:
        _belts.putIfAbsent(p.id, BeltState.new);
      case EntityKind.arm:
        _arms.putIfAbsent(p.id, ArmState.new);
      case EntityKind.chest:
      case EntityKind.staging:
        _stores.putIfAbsent(p.id, ItemBag.new);
      case EntityKind.receivingDock:
        _recv.putIfAbsent(p.id, ReceivingState.new);
      case EntityKind.shippingDock:
        _ship.putIfAbsent(p.id, ShippingState.new);
      default:
        break;
    }
  }

  /// Empties [p]'s runtime state and returns every item it held: buffers
  /// (a running craft's inputs handed back — the craft never finished),
  /// belt items, an arm's swing, a store, a shipping queue. Units a dock
  /// already took from or gave to the colony for a part-paid item stay
  /// booked in the ledger and become floor credit ([_prepaid] / [_owed])
  /// the next dock of that commodity uses up first.
  ItemBag _evict(Placement p) {
    final bag = ItemBag();
    void addBag(ItemBag b) {
      for (final k in b.keys) {
        bag.add(k, b[k]);
      }
    }

    final m = _machines[p.id];
    if (m != null) {
      addBag(m.inBuf);
      addBag(m.outBuf);
      final r = _recipeOf(p);
      if (m.crafting && r != null) {
        for (final q in r.inputs) {
          bag.add(q.item, q.count);
        }
      }
      _machines[p.id] = MachineState();
    }
    final b = _belts[p.id];
    if (b != null) {
      for (final i in b.items) {
        bag.add(i.item, 1);
      }
      b.items.clear();
    }
    final a = _arms[p.id];
    final held = a?.held;
    if (a != null && held != null) {
      bag.add(held, 1);
      a.held = null;
    }
    final st = _stores[p.id];
    if (st != null) {
      addBag(st);
      _stores[p.id] = ItemBag();
    }
    final sd = _ship[p.id];
    if (sd != null) {
      final c = sd.queue.isEmpty
          ? null
          : FactoryItems.byId(sd.queue.first)?.commodity;
      if (c != null && sd.paid > 0) _prepaid[c] = (_prepaid[c] ?? 0) + sd.paid;
      for (final i in sd.queue) {
        bag.add(i, 1);
      }
      sd.queue.clear();
      sd.paid = 0;
    }
    final rd = _recv[p.id];
    final ri = p.item;
    if (rd != null && ri != null && rd.paid > 0) {
      final c = FactoryItems.byId(ri)?.commodity;
      if (c != null) _owed[c] = (_owed[c] ?? 0) + rd.paid;
      rd.paid = 0;
    }
    return bag;
  }

  void _dropState(int id) {
    _machines.remove(id);
    _belts.remove(id);
    _arms.remove(id);
    _stores.remove(id);
    _recv.remove(id);
    _ship.remove(id);
  }

  /// What can arrive at an arm's or belt's pick side from [src]: a
  /// machine's outputs, a belt run's cargo ([carries]), a chest's filter or
  /// anything ([_kAnyItem]).
  Set<String> _deliverable(Placement? src, Map<int, Set<String>> carries) {
    if (src == null) return const {};
    switch (src.kind) {
      case EntityKind.machine:
        return {
          for (final q in _recipeOf(src)?.outputs ?? const <ItemQty>[]) q.item,
        };
      case EntityKind.belt:
      case EntityKind.crossing:
        return carries[src.id] ?? const {};
      case EntityKind.chest:
      case EntityKind.staging:
        final f = src.item;
        return f == null ? const {_kAnyItem} : {f};
      default:
        return const {};
    }
  }

  /// What arm [a] can set down, given what reaches its pick tile.
  Set<String> _armDelivers(Placement a, Map<int, Set<String>> carries) {
    final up = _deliverable(_at(_behindOf(a)), carries);
    final f = a.item;
    if (f == null) return up;
    return up.contains(f) || up.contains(_kAnyItem) ? {f} : const {};
  }

  /// Whether the tile in front of an arm could ever take [item].
  bool _accepts(Placement? to, String item) {
    if (to == null) return false;
    switch (to.kind) {
      case EntityKind.belt:
      case EntityKind.crossing:
        return true;
      case EntityKind.machine:
        final r = _recipeOf(to);
        return r != null && _qtyOf(r.inputs, item) != null;
      case EntityKind.chest:
      case EntityKind.staging:
      case EntityKind.shippingDock:
        final f = to.item;
        return f == null || f == item;
      default:
        return false;
    }
  }

  /// Re-derives every cache from the layout. Cheap (one pass over the
  /// placements and the hall, plus a small fixed point over the belts), and
  /// only run on load and on edits.
  void _rebuild() {
    final hall = _bp.hall;
    final sorted = [..._bp.placements]..sort((a, b) => a.id.compareTo(b.id));
    _byId = {for (final p in sorted) p.id: p};
    _solidAt.clear();
    _stagingAt.clear();
    _goals.clear();
    final walk = Uint8List(hall.w * hall.h)..fillRange(0, hall.w * hall.h, 1);
    for (final p in sorted) {
      final f = p.footprint;
      if (p.kind == EntityKind.staging) {
        for (final t in f.tiles) {
          if (hall.contains(t)) _stagingAt.putIfAbsent(t.key, () => p.id);
        }
      }
      if (kOverlayKinds.contains(p.kind)) continue;
      for (final t in f.tiles) {
        if (!hall.contains(t)) continue;
        _solidAt.putIfAbsent(t.key, () => p.id);
        if (!_walkableSolid(p.kind)) walk[t.y * hall.w + t.x] = 0;
      }
    }
    _paths = FloorPathing(hall, walk);
    _idleTile = _idleSpot();

    List<Placement> ofKind(bool Function(EntityKind) k) =>
        [for (final p in sorted) if (k(p.kind)) p];
    _machineList = ofKind((k) => k == EntityKind.machine);
    _armList = ofKind((k) => k == EntityKind.arm);
    _recvList = ofKind((k) => k == EntityKind.receivingDock);
    _shipList = ofKind((k) => k == EntityKind.shippingDock);
    _chestList = ofKind((k) => k == EntityKind.chest);
    _stagingList = ofKind((k) => k == EntityKind.staging);
    final belts = ofKind(_isBelt);

    // What each belt run can carry: docks, arms and upstream belts feed it.
    // Sets only grow over a finite universe, so the loop ends.
    final carries = {for (final b in belts) b.id: <String>{}};
    var changed = true;
    while (changed) {
      changed = false;
      void feed(TilePos t, Set<String> items) {
        final p = _at(t);
        if (p == null || !_isBelt(p.kind) || items.isEmpty) return;
        final c = carries[p.id]!;
        final before = c.length;
        c.addAll(items);
        if (c.length != before) changed = true;
      }

      for (final d in _recvList) {
        final it = d.item;
        if (it != null) feed(_frontOf(d), {it});
      }
      for (final a in _armList) {
        feed(_frontOf(a), _armDelivers(a, carries));
      }
      for (final b in belts) {
        feed(_frontOf(b), {...carries[b.id]!});
      }
    }

    final autoFed = <(int, String)>{}, armCleared = <(int, String)>{};
    void feeds(Placement? to, Set<String> items) {
      if (to == null || to.kind != EntityKind.machine) return;
      for (final q in _recipeOf(to)?.inputs ?? const <ItemQty>[]) {
        if (items.contains(q.item) || items.contains(_kAnyItem)) {
          autoFed.add((to.id, q.item));
        }
      }
    }

    for (final a in _armList) {
      final from = _at(_behindOf(a)), to = _at(_frontOf(a));
      if (from != null && from.kind == EntityKind.machine) {
        final filter = a.item;
        for (final q in _recipeOf(from)?.outputs ?? const <ItemQty>[]) {
          if (filter != null && filter != q.item) continue;
          if (_accepts(to, q.item)) armCleared.add((from.id, q.item));
        }
      }
      feeds(to, _armDelivers(a, carries));
    }
    for (final b in belts) {
      feeds(_at(_frontOf(b)), carries[b.id]!);
    }
    _autoFed = autoFed;
    _armCleared = armCleared;
    _handFedConsumes = {
      for (final m in _machineList)
        for (final q in _recipeOf(m)?.inputs ?? const <ItemQty>[])
          if (!autoFed.contains((m.id, q.item))) q.item,
    };
    _providers = [
      for (final p in sorted)
        if (p.kind == EntityKind.machine ||
            p.kind == EntityKind.chest ||
            p.kind == EntityKind.staging)
          p,
    ];

    // Downstream first: depth = belt hops to the end of the run.
    int depth(Placement b) {
      var cur = b;
      var n = 0;
      while (n <= belts.length) {
        final nx = _at(_frontOf(cur));
        if (nx == null || !_isBelt(nx.kind)) return n;
        cur = nx;
        n++;
      }
      return n; // a loop: last
    }

    final depths = {for (final b in belts) b.id: depth(b)};
    _beltOrder = [...belts]..sort((a, b) {
        final c = depths[a.id]!.compareTo(depths[b.id]!);
        return c != 0 ? c : a.id.compareTo(b.id);
      });

    // Handlers left standing where something now stands step off.
    for (final h in _handlers) {
      final nx = h.next;
      if (nx != null && !_paths.isWalkable(nx)) {
        h
          ..next = null
          ..prog = 0;
      }
      if (!_paths.isWalkable(h.at)) {
        h
          ..at = _idleTile
          ..next = null
          ..prog = 0;
      }
    }

    // A pile something now stands on slides to the nearest open tile.
    for (final id in [..._piles.keys]) {
      final pile = _piles[id]!;
      if (_paths.isWalkable(pile.at)) continue;
      final t = _nearestWalkable(pile.at);
      if (t == null) continue;
      _piles.remove(id);
      _spill(t, pile.items);
      _cancelJobsFor(id);
    }
  }

  void _layoutChanged() {
    _layoutRev++;
    _rebuild();
  }

  /// Cancels every queued request and every empty-handed trip that touches
  /// [id], and re-routes loads already on their way TO it. A load picked up
  /// from [id] is in a hand, not at [id]: it keeps going. Call after the
  /// layout caches are rebuilt (re-routing walks the new floor).
  void _cancelJobsFor(int id) {
    _queue.removeWhere((r) => r.from == id || r.to == id);
    for (final h in _handlers) {
      final j = h.job;
      if (j == null) continue;
      if (h.state == HandlerState.toPickup && (j.from == id || j.to == id)) {
        h.goIdle();
      } else if (h.state == HandlerState.carrying && j.to == id) {
        _redirect(h);
      }
    }
  }

  // ---- FactoryFloorEditor --------------------------------------------------

  /// Why [p] can't stand where it is (ignoring placement [ignoreId]), or
  /// null. The same rules as [FloorBlueprint.validate].
  EditResult? _check(Placement p, {int? ignoreId}) {
    if (p.kind == EntityKind.machine &&
        (p.recipe == null || FactoryRecipes.byId(p.recipe!) == null)) {
      return const EditResult.refused(EditRefusal.unknownRecipe);
    }
    if (kSpannedKinds.contains(p.kind)) {
      final s = p.span;
      if (s == null || s.$1 <= 0 || s.$2 <= 0) {
        return const EditResult.refused(EditRefusal.notAllowed);
      }
    }
    final f = p.footprint;
    if (!_bp.hall.rect.containsRect(f)) {
      return const EditResult.refused(EditRefusal.outOfHall);
    }
    if (kOverlayKinds.contains(p.kind)) return null;
    for (final q in _byId.values) {
      if (q.id == ignoreId || kOverlayKinds.contains(q.kind)) continue;
      if (q.footprint.overlaps(f)) {
        return EditResult.refused(EditRefusal.overlaps, q.id);
      }
    }
    return null;
  }

  void _replace(Placement p) {
    final i = _bp.placements.indexWhere((q) => q.id == p.id);
    _bp.placements[i] = p;
  }

  @override
  EditResult place(Placement p) {
    final q = p.copyWith(id: _bp.nextId);
    final bad = _check(q);
    if (bad != null) return bad;
    _bp.placements.add(q);
    _initState(q);
    _layoutChanged();
    return EditResult.ok(q.id);
  }

  @override
  EditResult remove(int placementId) {
    final p = _byId[placementId];
    if (p == null) {
      return const EditResult.refused(EditRefusal.noSuchPlacement);
    }
    // What it held is set down where it stood, never lost.
    final held = _evict(p);
    _bp.placements.removeWhere((q) => q.id == placementId);
    _dropState(placementId);
    _layoutChanged();
    _spill(p.pos, held);
    _cancelJobsFor(placementId);
    return EditResult.ok(placementId);
  }

  @override
  EditResult rotate(int placementId) {
    final p = _byId[placementId];
    if (p == null) return const EditResult.refused(EditRefusal.noSuchPlacement);
    final q = p.copyWith(dir: p.dir.turnCw);
    final bad = _check(q, ignoreId: p.id);
    if (bad != null) return bad;
    _replace(q);
    _layoutChanged();
    return EditResult.ok(p.id);
  }

  @override
  EditResult setRecipe(int placementId, String recipeId) {
    final p = _byId[placementId];
    if (p == null) return const EditResult.refused(EditRefusal.noSuchPlacement);
    if (p.kind != EntityKind.machine) {
      return const EditResult.refused(EditRefusal.wrongKind);
    }
    if (FactoryRecipes.byId(recipeId) == null) {
      return const EditResult.refused(EditRefusal.unknownRecipe);
    }
    final q = p.copyWith(recipe: recipeId);
    final bad = _check(q, ignoreId: p.id);
    if (bad != null) return bad;
    // A new recipe empties the station: its buffers (and a running craft's
    // inputs) were the old chain's goods and are set down beside it, and
    // loads en route for the old inputs go elsewhere.
    final held = _evict(p);
    _replace(q);
    _machines[p.id] = MachineState();
    _layoutChanged();
    _spill(p.pos, held);
    _cancelJobsFor(p.id);
    return EditResult.ok(p.id);
  }

  @override
  EditResult setMode(int placementId, MachineMode mode) {
    final p = _byId[placementId];
    if (p == null) return const EditResult.refused(EditRefusal.noSuchPlacement);
    if (p.kind != EntityKind.machine) {
      return const EditResult.refused(EditRefusal.wrongKind);
    }
    _replace(p.copyWith(mode: mode));
    _layoutChanged();
    return EditResult.ok(p.id);
  }

  @override
  EditResult hire(HandlerKind kind, int delta) {
    if (!kSimulatedHandlerKinds.contains(kind)) {
      return const EditResult.refused(EditRefusal.notAllowed);
    }
    final have = _bp.roster[kind] ?? 0;
    if (have + delta < 0) {
      return const EditResult.refused(EditRefusal.notAllowed);
    }
    if (delta == 0) return const EditResult.ok(null);
    if (delta > 0) {
      for (var i = 0; i < delta; i++) {
        _handlers.add(
            FloorHandler(id: _nextHandlerId++, kind: kind, at: _idleTile));
      }
    } else {
      // Let go of the newest empty-handed first; a loaded one, only when
      // there is no one else, sets the load down where he stands first.
      var drop = -delta;
      for (final emptyOnly in const [true, false]) {
        for (var i = _handlers.length - 1; i >= 0 && drop > 0; i--) {
          final h = _handlers[i];
          if (h.kind != kind) continue;
          final c = h.carrying;
          if (emptyOnly && c != null && h.carryingCount > 0) continue;
          if (c != null && h.carryingCount > 0) {
            h.settle();
            _addPile(h.at, c, h.carryingCount);
          }
          _handlers.removeAt(i);
          drop--;
        }
      }
    }
    if (have + delta == 0) {
      _bp.roster.remove(kind);
    } else {
      _bp.roster[kind] = have + delta;
    }
    _layoutChanged();
    return const EditResult.ok(null);
  }
}
