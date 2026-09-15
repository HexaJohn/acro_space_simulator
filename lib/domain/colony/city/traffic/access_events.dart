// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The access events: a vehicle entering a site from the road, and leaving
/// it again (docs/plans/t4a-implementation.md §1.5; site-access.md §7.1,
/// §7.4, agent-traffic.md §5.5).
///
/// Site entry and exit are the only exception to "a vehicle changes lane
/// only through a connector": every road↔site element change is legal only
/// with an event logged here, whose `(edge, T)` is that join's (within
/// 1.5 m; a home back-out's EXIT within 11 m) and whose lane is the
/// arrival's lane (ENTER) or one `canJoin` would take it into (EXIT). The
/// property test reads this log after every sub-step.
///
/// One sub-step's events, in the order they happened: [AccessEventLog.beginStep]
/// empties the log at the top of the sub-step, and the running totals
/// ([AccessEventLog.enters], [AccessEventLog.exits]) never go back. Typed
/// columns sized to the vehicle table: nothing allocates while it runs.
library;

import 'dart:typed_data';

import 'traffic_rng.dart';

/// What happened at the kerb. Append-only: the column holds the index.
enum AccessEventKind {
  /// Granted at the gate: off the road onto the throat in-lane (§7.4 step 5).
  enter,

  /// Out of a throat into the road lane `canJoin` granted (departure
  /// step 5).
  exit,

  /// A home back-out's rear crossing the kerb line into its target lane,
  /// where it is a REVERSING vehicle (§7.4 Home back-out).
  backOutExit,
}

/// One sub-step's access events. See the library comment.
class AccessEventLog {
  AccessEventLog({int capacity = 1024})
      : handle = Int32List(capacity),
        edge = Int32List(capacity),
        lane = Int32List(capacity),
        row = Int32List(capacity),
        join = Int32List(capacity),
        t = Float32List(capacity),
        kind = Uint8List(capacity);

  /// Events this sub-step; ENTERs and EXITs (back-outs included) since the
  /// log was made.
  int count = 0, enters = 0, exits = 0;

  /// Events the columns had no room for since the log was made. Every
  /// vehicle crosses a kerb line at most once a sub-step (a throat is at
  /// least 7 m, V5), so a log [ensure]d to the vehicle table never drops
  /// one: the property test pins this at 0.
  int dropped = 0;

  /// Per event: the vehicle's handle; the road edge, and the travel arc on
  /// it (m) where it crossed; the road lane it left or joined; the site row
  /// and the plan-local join.
  Int32List handle, edge, lane, row, join;
  Float32List t;

  /// [AccessEventKind] index.
  Uint8List kind;

  int get capacity => handle.length;

  /// Room for one event per vehicle of a table of [vehicleCapacity] slots.
  /// Grows only when the table has, keeping this sub-step's events.
  void ensure(int vehicleCapacity) {
    final old = handle.length;
    if (vehicleCapacity <= old) return;
    Int32List i32(Int32List a) =>
        Int32List(vehicleCapacity)..setRange(0, count, a);
    handle = i32(handle);
    edge = i32(edge);
    lane = i32(lane);
    row = i32(row);
    join = i32(join);
    t = Float32List(vehicleCapacity)..setRange(0, count, t);
    kind = Uint8List(vehicleCapacity)..setRange(0, count, kind);
  }

  /// Empties the log for a new sub-step. The totals stay.
  void beginStep() => count = 0;

  /// Logs [k] by vehicle [handle] at travel arc [t] of road [edge], road
  /// lane [lane], site row [row] and plan-local join [join].
  void log(AccessEventKind k, int handle, int edge, double t, int lane,
      int row, int join) {
    if (k == AccessEventKind.enter) {
      enters++;
    } else {
      exits++;
    }
    final i = count;
    if (i >= this.handle.length) {
      dropped++;
      return;
    }
    this.handle[i] = handle;
    this.edge[i] = edge;
    this.t[i] = t;
    this.lane[i] = lane;
    this.row[i] = row;
    this.join[i] = join;
    kind[i] = k.index;
    count = i + 1;
  }

  /// Every column by name into [into], for the allocation test (§15.2,
  /// A13): none is replaced unless the vehicle table grows.
  void collectBuffers(Map<String, Object> into, String name) {
    into['$name.handle'] = handle;
    into['$name.edge'] = edge;
    into['$name.lane'] = lane;
    into['$name.row'] = row;
    into['$name.join'] = join;
    into['$name.t'] = t;
    into['$name.kind'] = kind;
  }

  /// [hash] with the totals and this sub-step's events folded in, in the
  /// order they happened; the arc to the millimetre.
  int digest(int hash) {
    var h = fnv1aU32(hash, enters);
    h = fnv1aU32(h, exits);
    h = fnv1aU32(h, dropped);
    h = fnv1aU32(h, count);
    for (var i = 0; i < count; i++) {
      h = fnv1aU32(h, handle[i]);
      h = fnv1aU32(h, kind[i]);
      h = fnv1aU32(h, edge[i]);
      h = fnv1aU32(h, (t[i] * 1000).round());
      h = fnv1aU32(h, lane[i]);
      h = fnv1aU32(h, row[i]);
      h = fnv1aU32(h, join[i]);
    }
    return h;
  }
}
