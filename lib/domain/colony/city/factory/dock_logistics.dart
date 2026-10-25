// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Docks that run on ORDERS and TRUCKS (docs/plans/factory-floors.md §10
/// items 4, 6 and 11).
///
/// Before this, a receiving dock pulled a pallet a second from the colony
/// for ever, and a shipping dock pushed out whatever reached it. The
/// playtest asked for the spaceport's pattern instead (`DeliverySchedule`
/// in city_sim.dart: a resource, an amount, an interval, one-time or
/// recurring), and for the outside to be finite. So a floor with a
/// [FloorLogistics] attached (`FactoryFloor.logistics`) works like this:
///
/// **Inbound.** The player places a [DockOrder]: a supplier, a good, a
/// number of pallets and a target receiving dock, either once or on an
/// [OrderSchedule] ("weekdays 06:00", or "every 30 min"). When it fires,
/// the supplier hands over what it has in whole natural packs
/// ([SupplyWorld.reserve]; a short supplier sends a short truck) and a
/// [FloorTruck] sets off, arriving after the supplier's lead time. One truck
/// at a time backs up to a dock (the rest wait outside, first come first
/// served); it stays until it is EMPTY, then leaves.
///
/// **Unloading** is real work. Without an upgrade, the floor posts move
/// requests from the dock to the dock — truck to loading area — that its
/// handlers serve like any other: a jack or forklift takes a whole pallet,
/// a worker on foot breaks it open at the tailgate and carries the loose
/// goods. A dock CONVEYOR ([DockBay.conveyor], paid capex) unloads by
/// itself, a pallet every [kConveyorUnloadS].
///
/// **Packaging** (item 6). You order GOODS, and trucks bring them in their
/// natural pack ([naturalPackOf]). The loading area breaks pallets down
/// into the loose form when the dock's item is the loose good: by hand,
/// [kHandBreakdownS] a pallet, or [kUnpackerBreakdownS] with an unpacker
/// ([DockBay.unpacker]). Outbound, a shipping dock's loading area simply
/// counts loose goods as the pallets they would fill ([slotsOf]): packing
/// for the truck is automatic, so a recipe never has to make crates just
/// to ship.
///
/// **Outbound.** Goods a shipping dock takes in go to its loading area
/// ([kLoadingAreaSlots] pallets of room; a full area backs the line up, as
/// before). A [PickupRule] calls a truck on a schedule or when N pallets
/// are ready; it arrives after [PickupRule.leadS], loads what fits, and the
/// load is SOLD: to contracts first, then the spot market
/// ([SupplyWorld.sell]), or to the colony's stock in a colony.
///
/// **Ledger and conservation.** The truck is outside the floor. A good
/// counts as received the moment it leaves an inbound truck (into a hand
/// or onto the conveyor) and as shipped the moment an outbound truck takes
/// it; between those it is in a loading area, which the floor counts as
/// held ([areaOf]). So the floor's "held + shipped − received − craftNet =
/// 0" holds through every truck, and pallet breakdown (one crate → ten
/// tubes) keeps commodity units exactly.
///
/// **Time.** Schedules read the floor's sim seconds through a small
/// [ScheduleClock] (a 24 h day starting Monday 06:00 by default), so a
/// calendar can replace it later without touching orders.
///
/// Pure Dart, deterministic: no RNG, no wall clock; orders, rules and
/// trucks in id order, bays and areas in sorted order; [toJson] saves
/// everything except the clock and the market price hook.
library;

import 'dart:collection';

import 'factory_colony_port.dart';
import 'factory_entities.dart';
import 'factory_floor_state.dart';
import 'factory_item.dart';
import 'supply_world.dart';

/// Pallets (or pallet-equivalents of loose goods) a 4 × 6 m loading area
/// holds: six floor tiles of 2 m, pallets stacked two high.
const int kLoadingAreaSlots = 12;

/// Seconds a dock conveyor takes to roll one pallet off a truck.
const double kConveyorUnloadS = 2.0;

/// Seconds the dock crew takes to break one pallet down by hand.
const double kHandBreakdownS = 4.0;

/// Seconds an unpacker takes per pallet.
const double kUnpackerBreakdownS = 0.5;

/// Items a receiving dock sets down per second from its loading area (the
/// old dock rate: a pallet jack's worth of throughput at the door).
const double kAreaEmitPerS = 1.0;

/// Items a shipping dock moves from its intake into its loading area per
/// second.
const double kAreaIntakePerS = 2.0;

/// Capex of the dock upgrades, in ore (the floor's capex unit). A
/// conveyor is the same price as the belt-fed dock leveller in
/// factory_capex.dart; an unpacker is a small station.
const double kDockConveyorCapexOre = 1.0;
const double kDockUnpackerCapexOre = 0.8;

/// Default lead time of a pickup truck, seconds.
const double kPickupLeadS = 60;

const double _eps = 1e-9;

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------

/// Maps floor sim seconds to a weekday and a time of day. Kept tiny so a
/// calendar (§10 item 5) can stand in for [SimWeekClock] later.
abstract interface class ScheduleClock {
  /// Seconds in one day.
  double get daySeconds;

  /// (weekday 0 = Monday … 6 = Sunday, seconds since that day's midnight)
  /// at floor time [t].
  (int, double) at(double t);

  /// The week (0, 1, …) floor time [t] falls in.
  int weekAt(double t);
}

/// A plain week on the floor's own clock: [daySeconds] a day, the floor's
/// t = 0 at [startOffsetS] into a Monday (06:00 by default: the first
/// shift).
class SimWeekClock implements ScheduleClock {
  const SimWeekClock({this.daySeconds = 86400, this.startOffsetS = 6 * 3600});

  @override
  final double daySeconds;
  final double startOffsetS;

  @override
  (int, double) at(double t) {
    final s = t + startOffsetS;
    final day = (s / daySeconds + _eps).floor();
    var sod = s - day * daySeconds;
    if (sod < 0) sod = 0;
    return (day % 7, sod);
  }

  @override
  int weekAt(double t) =>
      ((t + startOffsetS) / (7 * daySeconds) + _eps).floor();
}

/// When a recurring order or pickup fires: on [days] at [timeOfDayS], or
/// every [everyS] seconds (the fallback while there is no calendar).
class OrderSchedule {
  const OrderSchedule.weekly(this.days, this.timeOfDayS) : everyS = null;
  const OrderSchedule.every(double this.everyS)
      : days = const {},
        timeOfDayS = 0;

  /// Weekdays (0 = Monday) a weekly schedule fires on.
  final Set<int> days;
  final double timeOfDayS;

  /// Interval of an every-N schedule (null: weekly).
  final double? everyS;

  bool get isWeekly => everyS == null;

  /// The first firing strictly after [t] ([t] itself counts when
  /// [inclusive]: an every-N schedule fires the moment it is placed).
  double nextAfter(double t, ScheduleClock clock, {bool inclusive = false}) {
    final every = everyS;
    if (every != null) {
      if (!(every > 0)) return double.infinity;
      return inclusive ? t : t + every;
    }
    if (days.isEmpty) return double.infinity;
    final (wd, sod) = clock.at(t);
    final dayStart = t - sod;
    for (var d = 0; d <= 7; d++) {
      final cand = dayStart + d * clock.daySeconds + timeOfDayS;
      if (inclusive ? cand < t - _eps : cand <= t + _eps) continue;
      if (days.contains((wd + d) % 7)) return cand;
    }
    return double.infinity;
  }

  /// "Mon Wed Fri 06:00" or "every 30 min".
  String describe() {
    final every = everyS;
    if (every != null) {
      if (every >= 3600 && every % 3600 == 0) {
        return 'every ${(every / 3600).toStringAsFixed(0)} h';
      }
      return 'every ${(every / 60).toStringAsFixed(0)} min';
    }
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final d = (days.toList()..sort()).map((i) => names[i % 7]).join(' ');
    final h = (timeOfDayS ~/ 3600).toString().padLeft(2, '0');
    final m = ((timeOfDayS % 3600) ~/ 60).toString().padLeft(2, '0');
    return '$d $h:$m';
  }

  Object toJson() => everyS != null
      ? {'e': everyS}
      : {'d': (days.toList()..sort()), 't': timeOfDayS};

  static OrderSchedule fromJson(Object? o) {
    final j = (o as Map).cast<String, Object?>();
    final e = j['e'];
    if (e != null) return OrderSchedule.every((e as num).toDouble());
    return OrderSchedule.weekly(
        {for (final d in (j['d'] as List? ?? const [])) (d as num).toInt()},
        (j['t'] as num?)?.toDouble() ?? 0);
  }
}

// ---------------------------------------------------------------------------
// Orders, pickups, trucks
// ---------------------------------------------------------------------------

/// A purchase: [packs] natural packs of [good] from [supplier] to receiving
/// dock [dock], once (no [schedule]) or every time [schedule] fires.
class DockOrder {
  DockOrder({
    required this.id,
    required this.supplier,
    required this.good,
    required this.packs,
    required this.dock,
    this.schedule,
    required this.nextAt,
    this.active = true,
    this.fired = 0,
    this.lastShort = 0,
  });

  final int id;
  final String supplier;
  final String good;
  final int packs;
  final int dock;
  final OrderSchedule? schedule;

  /// Floor time of the next firing.
  double nextAt;

  /// False once a one-off has fired, or the order was cancelled.
  bool active;
  int fired;

  /// Packs the supplier could not supply at the last firing.
  int lastShort;

  bool get recurring => schedule != null;

  Map<String, Object?> toJson() => {
        'id': id,
        'sup': supplier,
        'g': good,
        'n': packs,
        'dock': dock,
        if (schedule != null) 'sch': schedule!.toJson(),
        'at': nextAt.isFinite ? nextAt : -1,
        if (!active) 'off': true,
        'f': fired,
        if (lastShort > 0) 'sh': lastShort,
      };

  static DockOrder fromJson(Map<String, Object?> j) {
    final at = (j['at'] as num).toDouble();
    return DockOrder(
      id: (j['id'] as num).toInt(),
      supplier: j['sup'] as String,
      good: j['g'] as String,
      packs: (j['n'] as num).toInt(),
      dock: (j['dock'] as num).toInt(),
      schedule: j['sch'] == null ? null : OrderSchedule.fromJson(j['sch']),
      nextAt: at < 0 ? double.infinity : at,
      active: j['off'] != true,
      fired: (j['f'] as num?)?.toInt() ?? 0,
      lastShort: (j['sh'] as num?)?.toInt() ?? 0,
    );
  }
}

/// When a shipping dock's goods are collected: on [schedule], or as soon
/// as [whenPallets] pallets are ready (whichever the rule names).
class PickupRule {
  PickupRule({
    required this.id,
    required this.dock,
    this.schedule,
    this.whenPallets,
    this.truckPallets = kDefaultTruckPallets,
    this.leadS = kPickupLeadS,
    this.nextAt = double.infinity,
    this.active = true,
  });

  final int id;
  final int dock;
  final OrderSchedule? schedule;
  final int? whenPallets;
  final int truckPallets;
  final double leadS;
  double nextAt;
  bool active;

  String describe() {
    final s = schedule;
    final n = whenPallets;
    if (s != null) return 'pickup ${s.describe()}';
    if (n != null) return 'pickup when $n pallet${n == 1 ? '' : 's'} ready';
    return 'pickup';
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'dock': dock,
        if (schedule != null) 'sch': schedule!.toJson(),
        'wp': ?whenPallets,
        'tp': truckPallets,
        'lt': leadS,
        'at': nextAt.isFinite ? nextAt : -1,
        if (!active) 'off': true,
      };

  static PickupRule fromJson(Map<String, Object?> j) {
    final at = (j['at'] as num?)?.toDouble() ?? -1;
    return PickupRule(
      id: (j['id'] as num).toInt(),
      dock: (j['dock'] as num).toInt(),
      schedule: j['sch'] == null ? null : OrderSchedule.fromJson(j['sch']),
      whenPallets: (j['wp'] as num?)?.toInt(),
      truckPallets: (j['tp'] as num?)?.toInt() ?? kDefaultTruckPallets,
      leadS: (j['lt'] as num?)?.toDouble() ?? kPickupLeadS,
      nextAt: at < 0 ? double.infinity : at,
      active: j['off'] != true,
    );
  }
}

enum TruckState { enRoute, waiting, docked }

/// A truck: inbound (a delivery for an order) or outbound (a pickup).
class FloorTruck {
  FloorTruck({
    required this.id,
    required this.dock,
    required this.inbound,
    required this.eta,
    this.supplier,
    this.order,
    this.rule,
    this.capacity = kDefaultTruckPallets,
    ItemBag? cargo,
    this.state = TruckState.enRoute,
  }) : cargo = cargo ?? ItemBag();

  final int id;
  final int dock;
  final bool inbound;
  final double eta;
  final String? supplier;
  final int? order;
  final int? rule;

  /// Pallet slots an outbound truck takes.
  final int capacity;

  /// Inbound: packs still aboard, plus loose goods from a pack a worker
  /// opened at the tailgate.
  final ItemBag cargo;
  TruckState state;

  Map<String, Object?> toJson() => {
        'id': id,
        'dock': dock,
        if (inbound) 'in': true,
        'eta': eta,
        'sup': ?supplier,
        'ord': ?order,
        'rule': ?rule,
        'cap': capacity,
        if (!cargo.isEmpty) 'c': cargo.toJson(),
        's': state.name,
      };

  static FloorTruck fromJson(Map<String, Object?> j) => FloorTruck(
        id: (j['id'] as num).toInt(),
        dock: (j['dock'] as num).toInt(),
        inbound: j['in'] == true,
        eta: (j['eta'] as num).toDouble(),
        supplier: j['sup'] as String?,
        order: (j['ord'] as num?)?.toInt(),
        rule: (j['rule'] as num?)?.toInt(),
        capacity: (j['cap'] as num?)?.toInt() ?? kDefaultTruckPallets,
        cargo: ItemBag.fromJson(j['c']),
        state: TruckState.values.byName(j['s'] as String? ?? 'enRoute'),
      );
}

/// A dock's own state: its loading area and its upgrades.
class DockBay {
  DockBay({this.conveyor = false, this.unpacker = false, ItemBag? area})
      : area = area ?? ItemBag();

  bool conveyor;
  bool unpacker;

  /// What stands in the loading area, packs and loose goods.
  final ItemBag area;

  /// Progress (s) on the pallet being broken down / rolled off.
  double breakT = 0;
  double unloadT = 0;

  /// Rate credit for setting goods down / taking them in (items).
  double credit = 0;

  Map<String, Object?> toJson() => {
        if (conveyor) 'cv': true,
        if (unpacker) 'up': true,
        if (!area.isEmpty) 'a': area.toJson(),
        'bt': breakT,
        'ut': unloadT,
        'cr': credit,
      };

  static DockBay fromJson(Map<String, Object?> j) => DockBay(
        conveyor: j['cv'] == true,
        unpacker: j['up'] == true,
        area: ItemBag.fromJson(j['a']),
      )
        ..breakT = (j['bt'] as num?)?.toDouble() ?? 0
        ..unloadT = (j['ut'] as num?)?.toDouble() ?? 0
        ..credit = (j['cr'] as num?)?.toDouble() ?? 0;
}

/// Pallet slots [n] of [item] take: a pack (or a good that travels loose,
/// like ore) one slot each; loose goods with a pack as the packs they
/// would fill, rounded up.
int slotsOf(String item, int n) {
  if (n <= 0) return 0;
  final good = goodOf(item);
  final pack = naturalPackOf(good);
  if (pack == null || item != good || pack.id == good) return n;
  final per = pack.commodityUnits.round();
  return per <= 1 ? n : (n + per - 1) ~/ per;
}

/// Slots everything in [bag] takes (loose goods of one kind pooled).
int slotsIn(ItemBag bag) {
  var s = 0;
  for (final k in bag.keys) {
    s += slotsOf(k, bag[k]);
  }
  return s;
}

/// A finished pickup or delivery, for the UI's recent list.
class TruckEvent {
  const TruckEvent(this.at, this.dock, this.text);
  final double at;
  final int dock;
  final String text;
}

/// The docks of one floor: [docks] by placement id, as the floor sees them
/// this sub-step ([Placement.kind] and [Placement.item] are what matter).
typedef DockSite = Map<int, Placement>;

class FloorLogistics {
  FloorLogistics({SupplyWorld? world, this.clock = const SimWeekClock()})
      : world = world ?? SupplyWorld.sandbox();

  final SupplyWorld world;

  /// Not saved: the host supplies it (a calendar later).
  ScheduleClock clock;

  final SplayTreeMap<int, DockOrder> orders = SplayTreeMap();
  final SplayTreeMap<int, PickupRule> pickups = SplayTreeMap();
  final SplayTreeMap<int, FloorTruck> trucks = SplayTreeMap();
  final SplayTreeMap<int, DockBay> bays = SplayTreeMap();
  int _nextId = 1;

  /// Floor time as of the last [tick].
  double now = 0;

  /// Capex the dock upgrades have cost, ore.
  double upgradeCapexOre = 0;

  /// Units received / shipped since the floor last drained them into its
  /// ledger ([drainReceived] / [drainShipped]), by commodity.
  final SplayTreeMap<String, double> _received = SplayTreeMap();
  final SplayTreeMap<String, double> _shipped = SplayTreeMap();

  /// Units a colony accepted part of an item for, booked shipped while the
  /// item is still in a loading area (see [shippedAhead]).
  final SplayTreeMap<String, double> _ahead = SplayTreeMap();

  /// Recent arrivals and pickups, newest last (at most 20; not saved).
  final List<TruckEvent> recent = [];

  /// Packs of trucks whose dock was removed, owed back to their supplier
  /// on the next tick (the port is not at hand when a dock is removed).
  final List<FloorTruck> _turnedAway = [];

  // ---- player actions ---------------------------------------------------

  /// Places an order; returns its id. A one-off ([schedule] null) or an
  /// every-N schedule fires on the next tick; a weekly one at its first
  /// slot.
  int placeOrder({
    required String supplier,
    required String good,
    required int packs,
    required int dock,
    OrderSchedule? schedule,
  }) {
    final id = _nextId++;
    final at = schedule == null
        ? now
        : schedule.nextAfter(now, clock, inclusive: true);
    orders[id] = DockOrder(
        id: id,
        supplier: supplier,
        good: good,
        packs: packs,
        dock: dock,
        schedule: schedule,
        nextAt: at);
    return id;
  }

  /// A truck-load of [good] from [supplier]: its truck size in packs.
  int truckLoad(String supplier) =>
      world.suppliers[supplier]?.truckPallets ?? kDefaultTruckPallets;

  void cancelOrder(int id) => orders[id]?.active = false;

  /// Adds a pickup rule for shipping dock [dock].
  int addPickup({
    required int dock,
    OrderSchedule? schedule,
    int? whenPallets,
    int truckPallets = kDefaultTruckPallets,
    double leadS = kPickupLeadS,
  }) {
    final id = _nextId++;
    pickups[id] = PickupRule(
        id: id,
        dock: dock,
        schedule: schedule,
        whenPallets: whenPallets,
        truckPallets: truckPallets,
        leadS: leadS,
        nextAt: schedule == null
            ? double.infinity
            : schedule.nextAfter(now, clock));
    return id;
  }

  void cancelPickup(int id) => pickups[id]?.active = false;

  /// Calls one pickup truck to [dock] now (it arrives after [leadS]).
  int callPickup(int dock, {double leadS = kPickupLeadS,
      int truckPallets = kDefaultTruckPallets}) {
    final id = _nextId++;
    trucks[id] = FloorTruck(
        id: id,
        dock: dock,
        inbound: false,
        eta: now + leadS,
        capacity: truckPallets);
    return id;
  }

  DockBay bay(int dock) => bays[dock] ??= DockBay();

  /// Buys (or sells back) a dock's conveyor; returns the capex change.
  double setConveyor(int dock, bool on) {
    final b = bay(dock);
    if (b.conveyor == on) return 0;
    b.conveyor = on;
    final d = on ? kDockConveyorCapexOre : -kDockConveyorCapexOre;
    upgradeCapexOre += d;
    return d;
  }

  double setUnpacker(int dock, bool on) {
    final b = bay(dock);
    if (b.unpacker == on) return 0;
    b.unpacker = on;
    final d = on ? kDockUnpackerCapexOre : -kDockUnpackerCapexOre;
    upgradeCapexOre += d;
    return d;
  }

  // ---- views --------------------------------------------------------------

  /// The truck backed up to [dock], if any.
  FloorTruck? dockedAt(int dock) {
    for (final t in trucks.values) {
      if (t.dock == dock && t.state == TruckState.docked) return t;
    }
    return null;
  }

  /// Trucks on their way to or waiting at [dock], soonest first.
  List<FloorTruck> incomingTo(int dock) => [
        for (final t in trucks.values)
          if (t.dock == dock && t.state != TruckState.docked) t,
      ]..sort((a, b) {
          final c = a.eta.compareTo(b.eta);
          return c != 0 ? c : a.id.compareTo(b.id);
        });

  Map<String, int> areaOf(int dock) => bays[dock]?.area.toMap() ?? const {};

  /// Every loading area's goods together (the floor counts them as held).
  ItemBag get areasTotal {
    final out = ItemBag();
    for (final b in bays.values) {
      for (final k in b.area.keys) {
        out.add(k, b.area[k]);
      }
    }
    return out;
  }

  /// Units already booked shipped for goods still in a loading area.
  Map<String, double> get shippedAhead => {..._ahead};

  /// Free pallet slots in [dock]'s loading area.
  int freeSlots(int dock) {
    final b = bays[dock];
    final used = b == null ? 0 : slotsIn(b.area);
    final f = kLoadingAreaSlots - used;
    return f > 0 ? f : 0;
  }

  /// How many more [item] fit in [dock]'s loading area.
  int roomFor(int dock, String item) {
    final b = bay(dock);
    final have = b.area[item];
    // The most n with slots(item, have + n) ≤ slots(item, have) + free.
    final free = freeSlots(dock);
    final cur = slotsOf(item, have);
    final good = goodOf(item);
    final pack = naturalPackOf(good);
    final per = (pack == null || item != good || pack.id == good)
        ? 1
        : pack.commodityUnits.round().clamp(1, 1 << 30);
    final maxItems = (cur + free) * per - have;
    return maxItems > 0 ? maxItems : 0;
  }

  // ---- floor hooks (called by FactoryFloor) ------------------------------

  /// How many [item] the truck docked at [dock] can hand over: whole packs,
  /// or (for a loose good) the loose units in its packs and opened goods.
  int truckCount(int dock, String item) {
    final t = dockedAt(dock);
    if (t == null || !t.inbound) return 0;
    final direct = t.cargo[item];
    final def = FactoryItems.byId(item);
    if (def == null) return direct;
    if (def.isCrate) return direct;
    final pack = naturalPackOf(item);
    if (pack == null || pack.id == item) return direct;
    return direct + t.cargo[pack.id] * pack.commodityUnits.round();
  }

  /// What the floor's handlers should unload from [dock]'s truck next: a
  /// whole pack if someone can lift it ([servable]), else its loose good
  /// (a worker opens the pallet at the tailgate), else the pack anyway as
  /// the waiting "hire a jack" signal. Null: nothing to unload (no truck,
  /// a conveyor does it, or the area is full).
  String? unloadItem(int dock, bool Function(String item) servable) {
    final b = bays[dock];
    if (b != null && b.conveyor) return null;
    final t = dockedAt(dock);
    if (t == null || !t.inbound || t.cargo.isEmpty) return null;
    for (final k in t.cargo.keys) {
      final def = FactoryItems.byId(k);
      if (def == null) continue;
      if (!def.isCrate) {
        if (roomFor(dock, k) > 0) return k;
        continue;
      }
      if (servable(k) && roomFor(dock, k) > 0) return k;
      final loose = def.commodity;
      if (FactoryItems.byId(loose) != null &&
          servable(loose) &&
          roomFor(dock, loose) > 0) {
        return loose;
      }
      if (roomFor(dock, k) > 0) return k;
    }
    return null;
  }

  /// Takes up to [n] of [item] off [dock]'s docked truck (opening a pack
  /// for a loose good); books them received. Returns how many.
  int takeFromTruck(int dock, String item, int n) {
    final t = dockedAt(dock);
    if (t == null || !t.inbound || n <= 0) return 0;
    final def = FactoryItems.byId(item);
    if (def == null) return 0;
    var got = 0;
    while (got < n) {
      if (t.cargo[item] > 0) {
        final k = t.cargo[item] < n - got ? t.cargo[item] : n - got;
        t.cargo.add(item, -k);
        got += k;
        continue;
      }
      if (def.isCrate) break;
      final pack = naturalPackOf(item);
      if (pack == null || pack.id == item || t.cargo[pack.id] <= 0) break;
      // Open one pack at the tailgate.
      t.cargo.add(pack.id, -1);
      t.cargo.add(item, pack.commodityUnits.round());
    }
    if (got > 0) _book(_received, def.commodity, got * def.commodityUnits);
    return got;
  }

  /// Sets one [item] into [dock]'s loading area if it has room.
  bool putInArea(int dock, String item, {bool commit = true}) {
    if (roomFor(dock, item) <= 0) return false;
    if (commit) bay(dock).area.add(item, 1);
    return true;
  }

  /// The item [dock]'s loading area can set down now for a dock whose item
  /// is [want] (exactly that form; pallets are broken down in [tick] when
  /// [want] is loose). Spends rate credit only on [take].
  String? emitReady(int dock, String want) {
    final b = bays[dock];
    if (b == null || b.credit < 1 - _eps) return null;
    return b.area[want] > 0 ? want : null;
  }

  void take(int dock, String item) {
    final b = bay(dock);
    b.area.add(item, -1);
    b.credit -= 1;
  }

  /// Spends one item of intake credit at shipping [dock] if its area has
  /// room for [item], moving it in. False: the area is full (back up).
  bool intake(int dock, String item) {
    final b = bay(dock);
    if (b.credit < 1 - _eps) return false;
    if (!putInArea(dock, item)) return false;
    b.credit -= 1;
    return true;
  }

  /// What the floor's ledger should book received since the last drain.
  Map<String, double> drainReceived() {
    final m = {..._received};
    _received.clear();
    return m;
  }

  Map<String, double> drainShipped() {
    final m = {..._shipped};
    _shipped.clear();
    return m;
  }

  /// [dock] was removed: its loading area is handed back (the floor sets
  /// it down as piles), its trucks turn away and its orders and pickups
  /// stop.
  ItemBag evictDock(int dock) {
    final b = bays.remove(dock);
    for (final id in [...trucks.keys]) {
      final t = trucks[id]!;
      if (t.dock != dock) continue;
      trucks.remove(id);
      if (t.inbound && !t.cargo.isEmpty) _turnedAway.add(t);
    }
    for (final o in orders.values) {
      if (o.dock == dock) o.active = false;
    }
    for (final r in pickups.values) {
      if (r.dock == dock) r.active = false;
    }
    return b?.area ?? ItemBag();
  }

  // ---- the tick -------------------------------------------------------------

  /// One floor sub-step of [dt] ending at floor time [t]: refill
  /// suppliers, fire due orders and pickups, move trucks, run conveyors
  /// and breakdown, top up rate credit. [docks] are the floor's docks by
  /// id; [port] is the floor's colony.
  void tick(double t, double dt, DockSite docks, FactoryColonyPort port) {
    now = t;
    world.refill(dt);
    for (final tr in _turnedAway) {
      final s = tr.supplier == null ? null : world.suppliers[tr.supplier!];
      if (s == null) continue;
      for (final k in tr.cargo.keys) {
        final def = FactoryItems.byId(k);
        if (def == null) continue;
        final per = packUnitsOf(def.commodity);
        final packs = (tr.cargo[k] * def.commodityUnits / per + _eps).floor();
        world.restock(s, def.commodity, packs, port);
      }
    }
    _turnedAway.clear();

    for (final o in orders.values) {
      if (!o.active || o.nextAt > t + _eps) continue;
      if (docks[o.dock]?.kind != EntityKind.receivingDock) {
        o.active = false;
        continue;
      }
      _fire(o, t, port);
      final s = o.schedule;
      if (s == null) {
        o.active = false;
      } else {
        o.nextAt = s.nextAfter(t, clock);
      }
    }

    for (final r in pickups.values) {
      if (!r.active) continue;
      if (docks[r.dock]?.kind != EntityKind.shippingDock) {
        r.active = false;
        continue;
      }
      final s = r.schedule;
      if (s != null) {
        if (r.nextAt <= t + _eps) {
          if (!_pickupPending(r.dock)) _callFor(r, t);
          r.nextAt = s.nextAfter(t, clock);
        }
        continue;
      }
      final n = r.whenPallets;
      if (n != null &&
          !_pickupPending(r.dock) &&
          slotsIn(bay(r.dock).area) >= n) {
        _callFor(r, t);
      }
    }

    // Arrivals: a truck at the door docks if its dock is free, else waits.
    final arrived = [
      for (final tr in trucks.values)
        if (tr.state != TruckState.docked && tr.eta <= t + _eps) tr,
    ]..sort((a, b) {
        final c = a.eta.compareTo(b.eta);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    for (final tr in arrived) {
      if (dockedAt(tr.dock) != null) {
        tr.state = TruckState.waiting;
        continue;
      }
      tr.state = TruckState.docked;
      if (!tr.inbound) _loadPickup(tr, t, port);
    }

    for (final id in docks.keys.toList()..sort()) {
      final p = docks[id]!;
      final b = bay(id);
      if (p.kind == EntityKind.receivingDock) {
        b.credit += kAreaEmitPerS * dt;
        if (b.credit > 1) b.credit = 1;
        _conveyorUnload(id, b, dt);
        _breakDown(b, p.item, dt);
      } else if (p.kind == EntityKind.shippingDock) {
        b.credit += kAreaIntakePerS * dt;
        if (b.credit > 1) b.credit = 1;
      }
    }

    // An empty inbound truck leaves; the next one waiting backs up.
    for (final id in [...trucks.keys]) {
      final tr = trucks[id]!;
      if (tr.state == TruckState.docked && tr.inbound && tr.cargo.isEmpty) {
        trucks.remove(id);
        _event(t, tr.dock, 'Truck unloaded and left');
      }
    }
  }

  void _event(double t, int dock, String text) {
    recent.add(TruckEvent(t, dock, text));
    if (recent.length > 20) recent.removeAt(0);
  }

  void _book(SplayTreeMap<String, double> m, String c, double u) {
    if (u <= 0) return;
    m[c] = (m[c] ?? 0) + u;
  }

  /// Sends order [o]'s goods: whole trucks of the supplier's size.
  void _fire(DockOrder o, double t, FactoryColonyPort port) {
    o.fired++;
    final s = world.suppliers[o.supplier];
    final pack = naturalPackOf(o.good);
    if (s == null || pack == null) {
      o.lastShort = o.packs;
      return;
    }
    final got = world.reserve(s, o.good, o.packs, port);
    o.lastShort = o.packs - got;
    var left = got;
    final size = s.truckPallets > 0 ? s.truckPallets : 1;
    while (left > 0) {
      final n = left < size ? left : size;
      final id = _nextId++;
      trucks[id] = FloorTruck(
          id: id,
          dock: o.dock,
          inbound: true,
          eta: t + s.leadTimeS,
          supplier: s.id,
          order: o.id,
          cargo: ItemBag()..add(pack.id, n));
      left -= n;
    }
  }

  bool _pickupPending(int dock) {
    for (final tr in trucks.values) {
      if (tr.dock == dock && !tr.inbound) return true;
    }
    return false;
  }

  void _callFor(PickupRule r, double t) {
    final id = _nextId++;
    trucks[id] = FloorTruck(
        id: id,
        dock: r.dock,
        inbound: false,
        eta: t + r.leadS,
        rule: r.id,
        capacity: r.truckPallets);
  }

  /// A pickup truck at the door: loads what fits, sells it, and leaves.
  void _loadPickup(FloorTruck tr, double t, FactoryColonyPort port) {
    final b = bay(tr.dock);
    var room = tr.capacity;
    final (wd, _) = clock.at(t);
    final week = clock.weekAt(t);
    var shipped = 0.0;
    for (final k in b.area.keys) {
      final def = FactoryItems.byId(k);
      if (def == null) continue;
      var n = b.area[k];
      // Whole pallets' worth only, until the truck is full.
      while (n > 0 && slotsOf(k, n) > room) {
        n--;
      }
      if (n <= 0) continue;
      final units = n * def.commodityUnits;
      // Credit a colony already holds for part of an item counts first.
      final ahead = _ahead[def.commodity] ?? 0;
      final need = units - ahead;
      double accepted;
      if (need <= _eps) {
        accepted = units;
        _ahead[def.commodity] = ahead - units;
      } else {
        _ahead.remove(def.commodity);
        final sale = world.sell(def.commodity, need, week, wd, port);
        final got = sale.contractUnits + sale.spotUnits;
        _book(_shipped, def.commodity, got);
        accepted = ahead + got;
      }
      // Items fully paid leave; a part-paid one stays, its units booked.
      final whole = (accepted / def.commodityUnits + _eps).floor();
      final gone = whole < n ? whole : n;
      final extra = accepted - gone * def.commodityUnits;
      if (extra > _eps) {
        _ahead[def.commodity] = (_ahead[def.commodity] ?? 0) + extra;
      }
      if ((_ahead[def.commodity] ?? 0) <= _eps) _ahead.remove(def.commodity);
      b.area.add(k, -gone);
      room -= slotsOf(k, gone);
      shipped += gone * def.commodityUnits;
      if (gone < n) break; // the buyer refused the rest
    }
    trucks.remove(tr.id);
    _event(t, tr.dock,
        'Pickup took ${shipped.toStringAsFixed(shipped % 1 == 0 ? 0 : 1)} units');
  }

  void _conveyorUnload(int dock, DockBay b, double dt) {
    if (!b.conveyor) return;
    final tr = dockedAt(dock);
    if (tr == null || !tr.inbound || tr.cargo.isEmpty) {
      b.unloadT = 0;
      return;
    }
    b.unloadT += dt;
    if (b.unloadT + _eps < kConveyorUnloadS) return;
    for (final k in tr.cargo.keys) {
      if (roomFor(dock, k) <= 0) continue;
      if (takeFromTruck(dock, k, 1) == 1) {
        b.area.add(k, 1);
        b.unloadT = 0;
      }
      return;
    }
    b.unloadT = kConveyorUnloadS; // area full: ready the moment it frees
  }

  /// Breaks one pallet of the dock's loose good down when the area has no
  /// loose ones left to set down.
  void _breakDown(DockBay b, String? want, double dt) {
    if (want == null) {
      b.breakT = 0;
      return;
    }
    final def = FactoryItems.byId(want);
    final pack = naturalPackOf(want);
    if (def == null || def.isCrate || pack == null || pack.id == want) {
      b.breakT = 0;
      return;
    }
    if (b.area[want] > 0 || b.area[pack.id] <= 0) {
      b.breakT = 0;
      return;
    }
    b.breakT += dt;
    final need = b.unpacker ? kUnpackerBreakdownS : kHandBreakdownS;
    if (b.breakT + _eps < need) return;
    b.breakT = 0;
    b.area.add(pack.id, -1);
    b.area.add(want, pack.commodityUnits.round());
  }

  // ---- persistence ---------------------------------------------------------

  Map<String, Object?> toJson() => {
        'w': world.toJson(),
        'n': _nextId,
        't': now,
        if (upgradeCapexOre != 0) 'cx': upgradeCapexOre,
        if (orders.isNotEmpty) 'o': [for (final o in orders.values) o.toJson()],
        if (pickups.isNotEmpty)
          'p': [for (final r in pickups.values) r.toJson()],
        if (trucks.isNotEmpty) 'tr': [for (final t in trucks.values) t.toJson()],
        if (bays.isNotEmpty)
          'b': {for (final e in bays.entries) '${e.key}': e.value.toJson()},
        if (_received.isNotEmpty) 'rx': {..._received},
        if (_shipped.isNotEmpty) 'sx': {..._shipped},
        if (_ahead.isNotEmpty) 'ah': {..._ahead},
        if (_turnedAway.isNotEmpty)
          'ta': [for (final t in _turnedAway) t.toJson()],
      };

  static FloorLogistics fromJson(Map<String, Object?> j,
      {ScheduleClock clock = const SimWeekClock()}) {
    Map<String, Object?> m(Object? o) =>
        ((o as Map?) ?? const {}).cast<String, Object?>();
    final lg = FloorLogistics(world: SupplyWorld.fromJson(m(j['w'])), clock: clock)
      .._nextId = (j['n'] as num?)?.toInt() ?? 1
      ..now = (j['t'] as num?)?.toDouble() ?? 0
      ..upgradeCapexOre = (j['cx'] as num?)?.toDouble() ?? 0;
    for (final o in (j['o'] as List? ?? const [])) {
      final d = DockOrder.fromJson(m(o));
      lg.orders[d.id] = d;
    }
    for (final o in (j['p'] as List? ?? const [])) {
      final r = PickupRule.fromJson(m(o));
      lg.pickups[r.id] = r;
    }
    for (final o in (j['tr'] as List? ?? const [])) {
      final t = FloorTruck.fromJson(m(o));
      lg.trucks[t.id] = t;
    }
    m(j['b']).forEach((k, v) => lg.bays[int.parse(k)] = DockBay.fromJson(m(v)));
    m(j['rx']).forEach((k, v) => lg._received[k] = (v as num).toDouble());
    m(j['sx']).forEach((k, v) => lg._shipped[k] = (v as num).toDouble());
    m(j['ah']).forEach((k, v) => lg._ahead[k] = (v as num).toDouble());
    for (final o in (j['ta'] as List? ?? const [])) {
      lg._turnedAway.add(FloorTruck.fromJson(m(o)));
    }
    return lg;
  }
}
