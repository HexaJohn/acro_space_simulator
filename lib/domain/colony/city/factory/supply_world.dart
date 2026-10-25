// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The world outside a factory's doors (docs/plans/factory-floors.md §10
/// item 11): who sells it goods and who buys what it makes.
///
/// The playtest's complaint was that the outside was unlimited: a dock
/// pulled a pallet a second for ever, for free, so the floor had no reason
/// to plan. Now a floor that runs on ORDERS (dock_logistics.dart) buys from
/// [Supplier]s — a small cast, each with finite [SupplyLine.stock] that
/// refills at a rate, a price, a lead time and a truck size — and sells to
/// [CustomerContract]s (so much a week, inside a delivery window, at a
/// pay rate) and, for anything else, a spot market that pays less.
///
/// **Sandbox and tutorial.** [SupplyWorld.sandbox] is the documented cast
/// below. Prices come from the colony market when one is wired
/// ([SupplyWorld.marketPrice], e.g. the dynamic markets' local prices);
/// without one they are Earth prices ([earthPrice]) marked up by the
/// supplier's [Supplier.markup] — the freight and margin a sandbox has no
/// other way to price.
///
/// **Unlimited supply.** [SupplyWorld.unlimited] restores the old instant
/// feed (default OFF). Turning it on sets [SupplyWorld.usedUnlimited] for
/// good, so a goal tracker can mark a run that leaned on it.
///
/// **In a colony** ([SupplyWorld.colony]) the one supplier and the one
/// customer are the colony's own stock, reached through the
/// [FactoryColonyPort] the floor already trades with — so `CitySim` needs
/// no change, and imports reach the floor whenever they reach the stock.
///
/// Pure Dart and deterministic: no clock, no RNG; suppliers and lines in
/// id order; [toJson] saves every bit of state (the price hook excepted:
/// the host re-attaches it).
library;

import 'dart:collection';

import '../economy/earth_market.dart';
import 'factory_colony_port.dart';
import 'factory_item.dart';

/// Seconds in an hour (refill rates are per hour).
const double kHourS = 3600;

/// Slots a delivery truck carries when a supplier names none.
const int kDefaultTruckPallets = 12;

/// The spot market pays this share of a good's price (a buyer with no
/// contract takes a discount for the trouble).
const double kSpotShare = 0.8;

/// The natural pack a good travels in: the registered pack whose commodity
/// is [good] (`crate:tubes` for tubes), the item itself when it has none
/// (ore, missiles), or null for an unknown id. Lowest id wins when a good
/// has several packs, so the choice is stable.
FactoryItem? naturalPackOf(String good) {
  final loose = FactoryItems.byId(good);
  if (loose == null) return null;
  FactoryItem? best;
  for (final id in (FactoryItems.table.keys.toList()..sort())) {
    final it = FactoryItems.table[id]!;
    if (it.commodity == good && it.isCrate && it.id != good) {
      best ??= it;
    }
  }
  return best ?? loose;
}

/// The loose good an item is (a pack's commodity), or the item itself.
String goodOf(String item) => FactoryItems.byId(item)?.commodity ?? item;

/// Units of [good] in one of its natural packs (1 for a good with none).
double packUnitsOf(String good) => naturalPackOf(good)?.commodityUnits ?? 1;

/// One good a supplier stocks.
class SupplyLine {
  SupplyLine({
    required this.good,
    required this.stock,
    required this.cap,
    required this.refillPerHour,
    this.price,
  });

  /// The loose good id (`tubes`, never `crate:tubes`).
  final String good;

  /// Units on hand now.
  double stock;

  /// The most it holds (refill stops here).
  final double cap;

  /// Units restocked per sim hour.
  final double refillPerHour;

  /// Fixed price per unit; null = the world's market or sandbox price.
  final double? price;

  Map<String, Object?> toJson() => {
        'g': good,
        's': stock,
        'c': cap,
        'r': refillPerHour,
        'p': ?price,
      };

  static SupplyLine fromJson(Map<String, Object?> j) => SupplyLine(
        good: j['g'] as String,
        stock: (j['s'] as num).toDouble(),
        cap: (j['c'] as num).toDouble(),
        refillPerHour: (j['r'] as num).toDouble(),
        price: (j['p'] as num?)?.toDouble(),
      );
}

class Supplier {
  Supplier({
    required this.id,
    required this.name,
    required this.leadTimeS,
    this.truckPallets = kDefaultTruckPallets,
    this.markup = 1.25,
    this.colonyStock = false,
    Iterable<SupplyLine> lines = const [],
  }) : lines = SplayTreeMap.of({for (final l in lines) l.good: l});

  final String id;
  final String name;

  /// Sim seconds from order to the truck at the door.
  final double leadTimeS;

  /// Pallets (natural packs) one truck carries.
  final int truckPallets;

  /// Sandbox price = Earth price × this (freight and margin).
  final double markup;

  /// True: stock is the colony's, through the floor's port (no lines).
  final bool colonyStock;

  /// By good id.
  final SplayTreeMap<String, SupplyLine> lines;

  Map<String, Object?> toJson() => {
        'id': id,
        'n': name,
        'lt': leadTimeS,
        'tp': truckPallets,
        'mk': markup,
        if (colonyStock) 'cs': true,
        'l': [for (final l in lines.values) l.toJson()],
      };

  static Supplier fromJson(Map<String, Object?> j) => Supplier(
        id: j['id'] as String,
        name: j['n'] as String,
        leadTimeS: (j['lt'] as num).toDouble(),
        truckPallets: (j['tp'] as num?)?.toInt() ?? kDefaultTruckPallets,
        markup: (j['mk'] as num?)?.toDouble() ?? 1.25,
        colonyStock: j['cs'] == true,
        lines: [
          for (final l in (j['l'] as List? ?? const []))
            SupplyLine.fromJson((l as Map).cast<String, Object?>()),
        ],
      );
}

/// A standing buyer: [unitsPerWeek] of [good], counted only when picked up
/// on one of [windowDays] (0 = Monday … 6 = Sunday), paid [payPerUnit].
class CustomerContract {
  CustomerContract({
    required this.id,
    required this.customer,
    required this.good,
    required this.unitsPerWeek,
    required this.payPerUnit,
    Set<int>? windowDays,
    this.week = 0,
    this.deliveredThisWeek = 0,
    this.weeksMet = 0,
    this.weeksMissed = 0,
  }) : windowDays = SplayTreeSet.of(windowDays ?? const {0, 1, 2, 3, 4});

  final String id;
  final String customer;
  final String good;
  final double unitsPerWeek;
  final double payPerUnit;
  final SplayTreeSet<int> windowDays;

  /// The week [deliveredThisWeek] counts (floor-clock weeks since start).
  int week;
  double deliveredThisWeek;
  int weeksMet;
  int weeksMissed;

  double get remaining {
    final r = unitsPerWeek - deliveredThisWeek;
    return r > 0 ? r : 0;
  }

  /// Closes every week before [now]: a week that reached its quantity is
  /// met, any other missed.
  void rollTo(int now) {
    while (week < now) {
      if (deliveredThisWeek + 1e-9 >= unitsPerWeek) {
        weeksMet++;
      } else {
        weeksMissed++;
      }
      deliveredThisWeek = 0;
      week++;
    }
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'c': customer,
        'g': good,
        'u': unitsPerWeek,
        'p': payPerUnit,
        'd': [...windowDays],
        'w': week,
        'dt': deliveredThisWeek,
        'wm': weeksMet,
        'wx': weeksMissed,
      };

  static CustomerContract fromJson(Map<String, Object?> j) => CustomerContract(
        id: j['id'] as String,
        customer: j['c'] as String,
        good: j['g'] as String,
        unitsPerWeek: (j['u'] as num).toDouble(),
        payPerUnit: (j['p'] as num).toDouble(),
        windowDays: {
          for (final d in (j['d'] as List? ?? const [])) (d as num).toInt(),
        },
        week: (j['w'] as num?)?.toInt() ?? 0,
        deliveredThisWeek: (j['dt'] as num?)?.toDouble() ?? 0,
        weeksMet: (j['wm'] as num?)?.toInt() ?? 0,
        weeksMissed: (j['wx'] as num?)?.toInt() ?? 0,
      );
}

/// What a sale paid, for the books and the UI.
class SaleResult {
  const SaleResult(this.contractUnits, this.spotUnits, this.paid);
  final double contractUnits;
  final double spotUnits;
  final double paid;
}

class SupplyWorld {
  SupplyWorld({
    Iterable<Supplier> suppliers = const [],
    Iterable<CustomerContract> contracts = const [],
    this.unlimited = false,
    this.usedUnlimited = false,
    this.spent = 0,
    this.earned = 0,
    this.colony = false,
  })  : suppliers = SplayTreeMap.of({for (final s in suppliers) s.id: s}),
        contracts =
            SplayTreeMap.of({for (final c in contracts) c.id: c}) {
    if (unlimited) usedUnlimited = true;
  }

  /// The colony world: its stock is the only supplier and the only
  /// customer, through the floor's port. Lead time is a short haul across
  /// the settlement.
  factory SupplyWorld.colony() => SupplyWorld(colony: true, suppliers: [
        Supplier(
            id: kColonyStoresId,
            name: 'Colony stores',
            leadTimeS: 60,
            markup: 1,
            colonyStock: true),
      ]);

  /// The sandbox and tutorial cast (documented defaults, §10 item 11).
  ///
  /// | supplier            | goods                         | lead  | truck |
  /// |---------------------|-------------------------------|-------|-------|
  /// | Regolith Mining Co. | ore                           | 90 s  | 12    |
  /// | Ares Steelworks     | steel, tubes                  | 60 s  | 10    |
  /// | Circuit Foundry     | electronics                   | 45 s  | 8     |
  /// | Valley Co-op        | food, water, medicine         | 60 s  | 12    |
  /// | Propellant Depot    | fuel, oxidizer, oxygen        | 120 s | 8     |
  /// | General Freight     | every other good, dear, slow  | 240 s | 6     |
  ///
  /// Stock is a few truckloads with a slow refill (a truckload or two an
  /// hour), so ordering more than a line can sustain shows up as short
  /// trucks. Lead times are minutes, not days: the sandbox clock is the
  /// floor's real time, and a tutorial can't wait a day for tubes.
  /// Customers: the Colony Depot takes rocket parts (200 a week, weekdays)
  /// at 1.3 × price; everything else sells on the spot market.
  factory SupplyWorld.sandbox({bool unlimited = false}) {
    SupplyLine line(String good, double trucks, double perHour,
        {int truck = kDefaultTruckPallets}) {
      final per = packUnitsOf(good) * truck;
      return SupplyLine(
          good: good,
          stock: per * trucks,
          cap: per * trucks,
          refillPerHour: per * perHour);
    }

    final named = <String>{};
    Supplier sup(String id, String name, double lead, int truck,
        List<String> goods,
        {double markup = 1.25, double trucks = 4, double perHour = 1.5}) {
      named.addAll(goods);
      return Supplier(
          id: id,
          name: name,
          leadTimeS: lead,
          truckPallets: truck,
          markup: markup,
          lines: [
            for (final g in goods)
              line(g, trucks, perHour, truck: truck),
          ]);
    }

    final cast = [
      sup('regolith', 'Regolith Mining Co.', 90, 12, ['ore'],
          markup: 1.1, trucks: 6, perHour: 3),
      sup('ares', 'Ares Steelworks', 60, 10, ['steel', 'tubes']),
      sup('circuit', 'Circuit Foundry', 45, 8, ['electronics']),
      sup('valley', 'Valley Co-op', 60, 12, ['food', 'water', 'medicine']),
      sup('propellant', 'Propellant Depot', 120, 8,
          ['fuel', 'oxidizer', 'oxygen']),
    ];
    // Every other good a floor might name (intermediates included), dear
    // and slow, so no dock is ever impossible to supply.
    final rest = [
      for (final id in (FactoryItems.table.keys.toList()..sort()))
        if (goodOf(id) == id && !named.contains(id)) id,
    ];
    cast.add(sup('freight', 'General Freight', 240, 6, rest,
        markup: 2, trucks: 2, perHour: 0.5));
    return SupplyWorld(
      suppliers: cast,
      unlimited: unlimited,
      contracts: [
        CustomerContract(
            id: 'depot-rocketParts',
            customer: 'Colony Depot',
            good: 'rocketParts',
            unitsPerWeek: 200,
            payPerUnit: earthPrice('rocketParts') * 1.3),
      ],
    );
  }

  static const String kColonyStoresId = 'colony';

  /// By id.
  final SplayTreeMap<String, Supplier> suppliers;

  /// By id.
  final SplayTreeMap<String, CustomerContract> contracts;

  /// True: the colony stock is the market (no money changes hands).
  final bool colony;

  /// The old instant, unlimited feed (docks pull continuously).
  bool unlimited;

  /// Sticky: this run has used [unlimited] at some point.
  bool usedUnlimited;

  /// Credits paid to suppliers and received from customers.
  double spent;
  double earned;

  /// The colony market's price for a good, when one is wired (not saved).
  double? Function(String good)? marketPrice;

  void setUnlimited(bool on) {
    unlimited = on;
    if (on) usedUnlimited = true;
  }

  /// Price of one unit of [good] at [s].
  double priceAt(Supplier s, String good) {
    final fixed = s.lines[good]?.price;
    if (fixed != null) return fixed;
    final m = marketPrice?.call(good);
    if (m != null && m.isFinite && m >= 0) return m;
    return earthPrice(good) * s.markup;
  }

  /// What the spot market pays per unit of [good].
  double spotPrice(String good) {
    final m = marketPrice?.call(good);
    final base = (m != null && m.isFinite && m >= 0) ? m : earthPrice(good);
    return base * kSpotShare;
  }

  /// Units of [good] [s] can sell now (the colony's through [port]: not
  /// known without taking, so reported as unbounded).
  double stockOf(Supplier s, String good) =>
      s.colonyStock ? double.infinity : (s.lines[good]?.stock ?? 0);

  /// Takes up to [packs] whole natural packs of [good] from [s]: returns
  /// the packs granted. Pays for them ([spent]). A colony supplier takes
  /// from the colony through [port], handing back a part pack it can't use.
  int reserve(Supplier s, String good, int packs, FactoryColonyPort port) {
    if (packs <= 0) return 0;
    final per = packUnitsOf(good);
    if (s.colonyStock) {
      final want = packs * per;
      var got = port.take(good, want);
      if (got.isNaN || got < 0) got = 0;
      if (got > want) got = want;
      final whole = (got / per + 1e-9).floor();
      final extra = got - whole * per;
      if (extra > 1e-9) port.give(good, extra);
      return whole;
    }
    final l = s.lines[good];
    if (l == null) return 0;
    final avail = (l.stock / per + 1e-9).floor();
    final n = packs < avail ? packs : avail;
    if (n <= 0) return 0;
    l.stock -= n * per;
    if (l.stock < 1e-9) l.stock = 0;
    spent += n * per * priceAt(s, good);
    return n;
  }

  /// Puts [packs] of [good] back (a truck turned away), refunding them.
  void restock(Supplier s, String good, int packs, FactoryColonyPort port) {
    if (packs <= 0) return;
    final per = packUnitsOf(good);
    if (s.colonyStock) {
      port.give(good, packs * per);
      return;
    }
    final l = s.lines[good];
    if (l == null) return;
    l.stock += packs * per;
    spent -= packs * per * priceAt(s, good);
  }

  /// Refills every line by [dtS] seconds' worth, up to its cap.
  void refill(double dtS) {
    for (final s in suppliers.values) {
      for (final l in s.lines.values) {
        if (l.stock >= l.cap) continue;
        l.stock += l.refillPerHour * dtS / kHourS;
        if (l.stock > l.cap) l.stock = l.cap;
      }
    }
  }

  /// Sells [units] of [good] picked up on [weekday] of floor week [week]:
  /// open contracts for the good first (in id order, within their window),
  /// the rest on the spot market. In a colony the colony takes it all
  /// through [port] and returns what it accepted as contract units (the
  /// caller keeps any refusal on the floor).
  SaleResult sell(String good, double units, int week, int weekday,
      FactoryColonyPort port) {
    if (!(units > 0)) return const SaleResult(0, 0, 0);
    if (colony) {
      var got = port.give(good, units);
      if (got.isNaN || got < 0) got = 0;
      if (got > units) got = units;
      return SaleResult(got, 0, 0);
    }
    var left = units;
    var contract = 0.0, paid = 0.0;
    for (final c in contracts.values) {
      c.rollTo(week);
      if (c.good != good || !c.windowDays.contains(weekday)) continue;
      final n = left < c.remaining ? left : c.remaining;
      if (n <= 0) continue;
      c.deliveredThisWeek += n;
      contract += n;
      paid += n * c.payPerUnit;
      left -= n;
    }
    final spot = left;
    paid += spot * spotPrice(good);
    earned += paid;
    return SaleResult(contract, spot, paid);
  }

  Map<String, Object?> toJson() => {
        if (colony) 'col': true,
        if (unlimited) 'u': true,
        if (usedUnlimited) 'uu': true,
        'sp': spent,
        'ea': earned,
        's': [for (final s in suppliers.values) s.toJson()],
        if (contracts.isNotEmpty)
          'k': [for (final c in contracts.values) c.toJson()],
      };

  static SupplyWorld fromJson(Map<String, Object?> j) => SupplyWorld(
        colony: j['col'] == true,
        unlimited: j['u'] == true,
        usedUnlimited: j['uu'] == true,
        spent: (j['sp'] as num?)?.toDouble() ?? 0,
        earned: (j['ea'] as num?)?.toDouble() ?? 0,
        suppliers: [
          for (final s in (j['s'] as List? ?? const []))
            Supplier.fromJson((s as Map).cast<String, Object?>()),
        ],
        contracts: [
          for (final c in (j['k'] as List? ?? const []))
            CustomerContract.fromJson((c as Map).cast<String, Object?>()),
        ],
      );
}
