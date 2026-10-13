// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Jobs, not routes: how freight gets a handler
/// (docs/plans/factory-floors.md §3 "Material handling").
///
/// Machines, chests and docks never own a worker. They post [MoveRequest]s
/// ("3 tubes from press #9 to packer #40"), and the [Dispatcher] hands each
/// one to the nearest free handler that can LIFT it — a worker on foot never
/// gets a pallet, however close. A request bigger than one trip is split:
/// the handler takes what it can carry and the rest stays queued, so the
/// queue's length is the honest "hire more / buy a forklift" signal. Small
/// requests for the same goods between the same two places are merged into
/// one trip up to the handler's capacity.
///
/// Reservations are not stored anywhere: the floor re-derives "already on
/// its way" from the queue and the handlers' current jobs each sub-step, so
/// a save holds no bookkeeping that could drift from what is really moving.
///
/// [FloorHandler] is a handler's RUNTIME state. Every kind is shaped the
/// same (a spec, a tile, a job); phase 4 added the movement rules (see
/// `factory_vehicles.dart`) and a battery, not a new class.
///
/// **Who gets a job** (phase 4): of the free handlers that can LIFT the
/// load and can REACH both ends of the trip on their own layer, the one
/// with the shortest path to the pickup; equally near, the CHEAPEST kind
/// ([kHandlerCostRank]: walker < jack < forklift < AGV < crane), then the
/// lowest id. So a walker carries a box a forklift could also take, and a
/// crane is never spent on what a pair of hands can move from the same
/// spot.
library;

import 'factory_grid.dart';
import 'factory_handling.dart';
import 'factory_item.dart';
import 'factory_sim_api.dart';
import 'factory_vehicles.dart';

/// Move [count] of [item] from placement [from] to placement [to].
class MoveRequest {
  MoveRequest({
    required this.item,
    required this.count,
    required this.from,
    required this.to,
  });

  final String item;

  /// Items still to move (a split request shrinks as handlers take trips).
  int count;
  final int from, to;

  List<Object?> toJson() => [item, count, from, to];
  static MoveRequest fromJson(Object? j) {
    final l = j as List;
    return MoveRequest(
      item: l[0] as String,
      count: (l[1] as num).toInt(),
      from: (l[2] as num).toInt(),
      to: (l[3] as num).toInt(),
    );
  }
}

/// One handler on the floor.
class FloorHandler {
  FloorHandler({required this.id, required this.kind, required this.at})
      : battery = kBatteryRuntimeS[kind] ?? 0;

  final int id;
  final HandlerKind kind;

  /// The tile it stands on (or is leaving, while [next] is set).
  TilePos at;

  /// The tile it is stepping onto, [prog] (0..1) of the way.
  TilePos? next;
  double prog = 0;

  HandlerState state = HandlerState.idle;

  /// Its trip, while [state] is toPickup or carrying.
  MoveRequest? job;

  /// What it holds now.
  String? carrying;
  int carryingCount = 0;

  /// Seconds spent picking up or setting down at the current stop.
  double timer = 0;

  /// Seconds of work left in the battery ([isBatteryKind] only; full when
  /// hired). A vehicle always finishes the trip it is on, so this never
  /// strands a load mid-hall: it is floored at zero, and a flat vehicle
  /// takes no new job until it has charged.
  double battery;

  /// Staffed this sub-step (transient: re-derived from the colony's
  /// staffing share every sub-step, never saved).
  bool active = true;

  HandlerSpec get spec => kHandlerSpecs[kind]!;

  bool get isBattery => isBatteryKind(kind);

  /// Idle, staffed and (for a battery vehicle) not flat.
  bool get isFree =>
      active &&
      state == HandlerState.idle &&
      (!isBattery || battery > 0);

  /// Drops the trip (and whatever it holds: the floor sets a load down
  /// before calling this) and settles onto a whole tile.
  void goIdle() {
    settle();
    state = HandlerState.idle;
    job = null;
    carrying = null;
    carryingCount = 0;
    timer = 0;
  }

  /// Finishes or abandons a half-taken step so the handler stands on one
  /// tile: past halfway it arrives, before it turns back. A handler that is
  /// not walking is never drawn parked between two tiles.
  void settle() {
    final n = next;
    if (n == null) return;
    if (prog >= 0.5) at = n;
    next = null;
    prog = 0;
  }

  HandlerView get view {
    final n = next;
    final x = n == null ? at.x.toDouble() : at.x + (n.x - at.x) * prog;
    final y = n == null ? at.y.toDouble() : at.y + (n.y - at.y) * prog;
    return HandlerView(
      id: id,
      kind: kind,
      x: x,
      y: y,
      state: state,
      carrying: carrying,
      carryingCount: carryingCount,
      battery: isBattery ? battery / kBatteryRuntimeS[kind]! : null,
    );
  }

  Map<String, Object?> toJson() => {
        'id': id,
        'k': kind.name,
        'at': at.toJson(),
        if (next != null) 'nx': next!.toJson(),
        'pr': prog,
        's': state.name,
        if (job != null) 'job': job!.toJson(),
        if (carrying != null) 'c': carrying,
        if (carryingCount != 0) 'cn': carryingCount,
        't': timer,
        if (isBattery) 'bt': battery,
      };

  static FloorHandler fromJson(Map<String, Object?> j) {
    final h = FloorHandler(
      id: (j['id'] as num).toInt(),
      kind: HandlerKind.values.byName(j['k'] as String),
      at: TilePos.fromJson(j['at']),
    );
    h.next = j['nx'] == null ? null : TilePos.fromJson(j['nx']);
    h.prog = (j['pr'] as num?)?.toDouble() ?? 0;
    h.state = HandlerState.values.byName(j['s'] as String? ?? 'idle');
    h.job = j['job'] == null ? null : MoveRequest.fromJson(j['job']);
    h.carrying = j['c'] as String?;
    h.carryingCount = (j['cn'] as num?)?.toInt() ?? 0;
    h.timer = (j['t'] as num?)?.toDouble() ?? 0;
    h.battery = (j['bt'] as num?)?.toDouble() ?? h.battery;
    return h;
  }
}

/// Matches queued requests to free handlers.
class Dispatcher {
  Dispatcher._();

  /// Walks [queue] in posting order; each request goes to the free,
  /// capable handler with the shortest path to its source ([distTo] < 0 =
  /// can't get there); equally near, the cheapest kind ([kHandlerCostRank]),
  /// then the lowest id ([handlers] must be in id order). A handler whose
  /// [routable] says it could not then carry the goods to the target (a
  /// forklift with no aisle there, a crane whose bay doesn't cover it) is
  /// passed over; with nobody left the request stays queued. Unknown items
  /// are never assigned.
  ///
  /// [routable] can cost a flow field, so it is asked only once some free
  /// handler could lift the load at all: a queue of pallets with only
  /// walkers on the floor builds no fields.
  static void assign(
    List<MoveRequest> queue,
    List<FloorHandler> handlers, {
    required int Function(FloorHandler h, int placementId) distTo,
    required bool Function(FloorHandler h, int from, int to) routable,
  }) {
    var i = 0;
    while (i < queue.length) {
      final req = queue[i];
      final def = FactoryItems.byId(req.item);
      FloorHandler? best;
      var bestD = 0, bestRank = 0;
      var canLift = false;
      if (def != null) {
        for (final h in handlers) {
          if (h.isFree && h.spec.canLift(def.loadClass)) {
            canLift = true;
            break;
          }
        }
      }
      if (def != null && canLift) {
        for (final h in handlers) {
          if (!h.isFree || !h.spec.canLift(def.loadClass)) continue;
          final d = distTo(h, req.from);
          if (d < 0) continue;
          final rank = kHandlerCostRank[h.kind] ?? 0;
          if (best != null && (d > bestD || (d == bestD && rank >= bestRank))) {
            continue;
          }
          if (!routable(h, req.from, req.to)) continue;
          best = h;
          bestD = d;
          bestRank = rank;
        }
      }
      if (best == null) {
        i++;
        continue;
      }
      final cap = best.spec.capacity;
      var take = req.count < cap ? req.count : cap;
      req.count -= take;
      // Fill the trip: later requests for the same item, source and target
      // ride along (a forklift takes both pallets a packer has made).
      for (var k = i + 1; k < queue.length && take < cap;) {
        final o = queue[k];
        if (o.item == req.item && o.from == req.from && o.to == req.to) {
          final t = o.count < cap - take ? o.count : cap - take;
          take += t;
          o.count -= t;
          if (o.count <= 0) {
            queue.removeAt(k);
            continue;
          }
        }
        k++;
      }
      best
        ..state = HandlerState.toPickup
        ..timer = 0
        ..job = MoveRequest(item: req.item, count: take, from: req.from, to: req.to);
      if (req.count <= 0) {
        queue.removeAt(i);
      }
      // A split request stays at i: the next free handler may take the rest.
    }
  }
}
