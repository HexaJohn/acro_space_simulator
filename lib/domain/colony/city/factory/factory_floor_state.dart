// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The runtime state a floor keeps per placement
/// (docs/plans/factory-floors.md §3 "Core model").
///
/// A [Placement] is design; these are what it is DOING: a machine's buffers
/// and craft timer, the items riding a belt, what an arm holds mid-swing, a
/// dock's part-paid item. They are keyed by placement id in `FactoryFloor`,
/// so a layout can be measured, drawn and stamped without any of it.
///
/// Every class saves ALL of its state, item maps with sorted keys, so a
/// floor saved mid-run and loaded steps bit-for-bit like one that never
/// stopped — and two floors that ran identically print identical JSON.
library;

import 'factory_grid.dart';
import 'factory_sim_api.dart';

/// Item counts with a stable JSON form (sorted keys) and no zero entries.
class ItemBag {
  final Map<String, int> _m = {};

  int operator [](String item) => _m[item] ?? 0;

  int get total => _m.values.fold(0, (a, b) => a + b);
  bool get isEmpty => _m.isEmpty;

  void add(String item, int n) {
    final v = (_m[item] ?? 0) + n;
    if (v <= 0) {
      _m.remove(item);
    } else {
      _m[item] = v;
    }
  }

  /// Item ids held, sorted (the only order anything may pick in).
  List<String> get keys => _m.keys.toList()..sort();

  Map<String, int> toMap() => {for (final k in keys) k: _m[k]!};

  Map<String, Object?> toJson() => toMap();

  static ItemBag fromJson(Object? j) {
    final b = ItemBag();
    ((j as Map?) ?? const {}).forEach(
        (k, v) => b.add(k as String, (v as num).toInt()));
    return b;
  }
}

class MachineState {
  ItemBag inBuf = ItemBag();
  ItemBag outBuf = ItemBag();

  /// Work done on the current craft, recipe seconds at speed 1.
  double progress = 0;

  /// Inputs are consumed when a craft starts; true until it completes.
  bool crafting = false;

  MachineStatus status = MachineStatus.idle;

  /// Seconds of unmaintained running (phase 4): grows while a station that
  /// needs a technician works without one, drains while it has one; at
  /// `kWearToBreakS` the station breaks down.
  double wear = 0;

  /// Broken down: crafts nothing (a running craft just pauses) until
  /// [repair] reaches `kRepairS`.
  bool broken = false;

  /// Technician seconds spent on the current repair.
  double repair = 0;

  Map<String, Object?> toJson() => {
        if (!inBuf.isEmpty) 'in': inBuf.toJson(),
        if (!outBuf.isEmpty) 'out': outBuf.toJson(),
        'p': progress,
        if (crafting) 'c': true,
        's': status.name,
        if (wear != 0) 'w': wear,
        if (broken) 'br': true,
        if (repair != 0) 'rp': repair,
      };

  static MachineState fromJson(Map<String, Object?> j) => MachineState()
    ..inBuf = ItemBag.fromJson(j['in'])
    ..outBuf = ItemBag.fromJson(j['out'])
    ..progress = (j['p'] as num?)?.toDouble() ?? 0
    ..crafting = j['c'] == true
    ..status = MachineStatus.values.byName(j['s'] as String? ?? 'idle')
    ..wear = (j['w'] as num?)?.toDouble() ?? 0
    ..broken = j['br'] == true
    ..repair = (j['rp'] as num?)?.toDouble() ?? 0;
}

/// One item on a belt tile, [p] 0..1 along it (1 = at the far edge).
class BeltItem {
  BeltItem(this.item, this.p);
  final String item;
  double p;
}

class BeltState {
  /// Front first (highest [BeltItem.p]).
  final List<BeltItem> items = [];

  List<Object?> toJson() => [
        for (final i in items) [i.item, i.p],
      ];

  static BeltState fromJson(Object? j) {
    final b = BeltState();
    for (final e in (j as List? ?? const [])) {
      final l = e as List;
      b.items.add(BeltItem(l[0] as String, (l[1] as num).toDouble()));
    }
    return b;
  }
}

class ArmState {
  String? held;

  /// Seconds until the current swing ends.
  double t = 0;

  Map<String, Object?> toJson() => {'h': ?held, 't': t};

  static ArmState fromJson(Map<String, Object?> j) => ArmState()
    ..held = j['h'] as String?
    ..t = (j['t'] as num?)?.toDouble() ?? 0;
}

class ReceivingState {
  /// Emit allowance in items (capped at one, so a stalled dock never bursts).
  double credit = 0;

  /// Commodity units already taken from the colony toward the next item.
  double paid = 0;

  List<Object?> toJson() => [credit, paid];

  static ReceivingState fromJson(Object? j) {
    final l = j as List;
    return ReceivingState()
      ..credit = (l[0] as num).toDouble()
      ..paid = (l[1] as num).toDouble();
  }
}

class ShippingState {
  /// Items waiting to go, oldest first.
  final List<String> queue = [];

  /// Commodity units of the front item the colony has already accepted.
  double paid = 0;

  /// Ship allowance in items (capped at one).
  double credit = 0;

  Map<String, Object?> toJson() => {
        if (queue.isNotEmpty) 'q': [...queue],
        'p': paid,
        'c': credit,
      };

  static ShippingState fromJson(Map<String, Object?> j) {
    final s = ShippingState()
      ..paid = (j['p'] as num?)?.toDouble() ?? 0
      ..credit = (j['c'] as num?)?.toDouble() ?? 0;
    for (final i in (j['q'] as List? ?? const [])) {
      s.queue.add(i as String);
    }
    return s;
  }
}

/// Goods set down on the open floor: a load whose trip had nowhere left to
/// go, or what a removed or re-recipe'd placement held. A pile never
/// destroys anything; it posts move requests like a chest until it is
/// cleared, and it does not block walking.
class FloorPile {
  FloorPile(this.at);

  final TilePos at;
  final ItemBag items = ItemBag();

  List<Object?> toJson() => [at.x, at.y, items.toJson()];

  static FloorPile fromJson(Object? j) {
    final l = j as List;
    final p = FloorPile(
        TilePos((l[0] as num).toInt(), (l[1] as num).toInt()));
    final bag = ItemBag.fromJson(l[2]);
    for (final k in bag.keys) {
      p.items.add(k, bag[k]);
    }
    return p;
  }
}
