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
/// queue's length is the honest "hire more / buy a forklift" signal.
///
/// Reservations are not stored anywhere: the floor re-derives "already on
/// its way" from the queue and the handlers' current jobs each sub-step, so
/// a save holds no bookkeeping that could drift from what is really moving.
///
/// [FloorHandler] is a handler's RUNTIME state. Phase 1 runs
/// [HandlerKind.onFoot]; every other kind is shaped the same (a spec, a
/// tile, a job), so phase 4 adds movement rules, not a new class.
library;

import 'factory_grid.dart';
import 'factory_handling.dart';
import 'factory_item.dart';
import 'factory_sim_api.dart';

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
  FloorHandler({required this.id, required this.kind, required this.at});

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

  /// Staffed this sub-step (transient: re-derived from the colony's
  /// staffing share every sub-step, never saved).
  bool active = true;

  HandlerSpec get spec => kHandlerSpecs[kind]!;

  bool get isFree => active && state == HandlerState.idle;

  /// Drops the trip and stands where it is.
  void goIdle() {
    state = HandlerState.idle;
    job = null;
    carrying = null;
    carryingCount = 0;
    timer = 0;
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
    return h;
  }
}

/// Matches queued requests to free handlers.
class Dispatcher {
  Dispatcher._();

  /// Walks [queue] in posting order; each request goes to the free,
  /// capable handler with the shortest path to its source ([distTo] < 0 =
  /// can't get there), ties by id ([handlers] must be in id order). A
  /// request whose [routable] says the goods could not then reach the
  /// target is left queued. Unknown items are never assigned.
  static void assign(
    List<MoveRequest> queue,
    List<FloorHandler> handlers, {
    required int Function(FloorHandler h, int placementId) distTo,
    required bool Function(int from, int to) routable,
  }) {
    var i = 0;
    while (i < queue.length) {
      final req = queue[i];
      final def = FactoryItems.byId(req.item);
      FloorHandler? best;
      var bestD = 0;
      if (def != null && routable(req.from, req.to)) {
        for (final h in handlers) {
          if (!h.isFree || !h.spec.canLift(def.loadClass)) continue;
          final d = distTo(h, req.from);
          if (d < 0) continue;
          if (best == null || d < bestD) {
            best = h;
            bestD = d;
          }
        }
      }
      if (best == null) {
        i++;
        continue;
      }
      final take = req.count < best.spec.capacity ? req.count : best.spec.capacity;
      best
        ..state = HandlerState.toPickup
        ..timer = 0
        ..job = MoveRequest(item: req.item, count: take, from: req.from, to: req.to);
      req.count -= take;
      if (req.count <= 0) {
        queue.removeAt(i);
      }
      // A split request stays at i: the next free handler may take the rest.
    }
  }
}
