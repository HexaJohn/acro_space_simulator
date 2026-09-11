// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What the renderer is told about the vehicles, once per agent sub-step
/// (docs/plans/agent-traffic.md §13.1–13.3).
///
/// A vehicle is published as where it is in simulation terms — its element
/// (a lane or a connector), how far along it, how fast — never as a
/// body-fixed position. The renderer maps that through geometry sliced from
/// the very ribbons it draws, so a car sits on the paint with no ground
/// query in the domain, and it interpolates in `s` against its own agent
/// clock ([AgentFrame.timeUs]).
///
/// Three column sets, written in turn: sub-step k writes set k mod 3 and
/// hands out a new, tiny [AgentFrame] over it. A set is written again only
/// two publishes later, so a frame the renderer still holds is never
/// changed under it — the one allocation per sub-step is the wrapper.
///
/// Rows are SLOTS: row i is the vehicle in slot i, so a vehicle keeps its
/// row as long as it lives, and an empty slot's row reads handle −1 and
/// element −1 (not drawn).
library;

import 'dart:typed_data';

import 'vehicle_table.dart';

/// Bits of [AgentFrame.flags].
///
/// [kFrameBraking]: brake lights. [kFrameStopping]: it is standing at, or
/// pulling up to, a point it may not pass — a line it was refused at, the
/// end of the edge it is held on, its dwell — so the renderer must not roll
/// it on into its next element. [kFrameEmergency] and [kFrameDoors] are the
/// service fleets' and the buses' (slices 5 and 9).
const int kFrameBraking = 1;
const int kFrameStopping = 2;
const int kFrameEmergency = 4;
const int kFrameDoors = 8;

/// A deceleration past this shows brake lights, m/s²: harder than a car
/// coasting, softer than the comfortable braking of any kind.
const double kBrakeLightMps2 = 0.6;

/// One published sample of every vehicle. Its lists are never written again
/// once it is handed out.
class AgentFrame {
  AgentFrame._({
    required this.count,
    required this.timeUs,
    required this.worldEpochS,
    required this.graphRev,
    required this.handle,
    required this.elem,
    required this.next,
    required this.s,
    required this.v,
    required this.a,
    required this.lat,
    required this.kind,
    required this.variant,
    required this.flags,
  });

  /// No vehicles: what a colony without agents, or before its first
  /// sub-step, publishes.
  static final AgentFrame empty = AgentFrame._(
    count: 0,
    timeUs: 0,
    worldEpochS: 0,
    graphRev: 0,
    handle: Int32List(0),
    elem: Int32List(0),
    next: Int32List(0),
    s: Float32List(0),
    v: Float32List(0),
    a: Float32List(0),
    lat: Float32List(0),
    kind: Uint8List(0),
    variant: Uint8List(0),
    flags: Uint8List(0),
  );

  /// Rows in use: `0 <= row < count`, some of them empty slots.
  final int count;

  /// The agent clock at this sample, microseconds: a whole number held in a
  /// double.
  final double timeUs;

  /// The world epoch the tick that ran this sub-step carried, as the host
  /// stamped it (`CityAgents.worldEpochS`).
  final double worldEpochS;

  /// The lane graph's revision: element ids mean something only against
  /// the geometry of the same revision.
  final int graphRev;

  /// The vehicle's handle, or −1 for an empty slot.
  final Int32List handle;

  /// Its element — a lane below the graph's lane count, a connector at or
  /// above it — or −1: not drawn.
  final Int32List elem;

  /// The next element of its route, or −1 on its last.
  final Int32List next;

  /// Metres along its element, speed (m/s), acceleration (m/s²), and the
  /// extra sideways offset (m, right of travel; 0 in slice 1).
  final Float32List s, v, a, lat;

  /// `AgentKind` index; the opaque byte the renderer picks a model by
  /// (D42); the [kFrameBraking]… bits.
  final Uint8List kind, variant, flags;
}

/// One set of columns, sized to the vehicle table.
class _Columns {
  _Columns(int n)
      : handle = Int32List(n),
        elem = Int32List(n),
        next = Int32List(n),
        s = Float32List(n),
        v = Float32List(n),
        a = Float32List(n),
        lat = Float32List(n),
        kind = Uint8List(n),
        variant = Uint8List(n),
        flags = Uint8List(n);

  final Int32List handle, elem, next;
  final Float32List s, v, a, lat;
  final Uint8List kind, variant, flags;

  int get capacity => handle.length;
}

/// Publishes [AgentFrame]s from a [VehicleTable], three column sets in turn.
class AgentFrameBuilder {
  final List<_Columns?> _sets = List<_Columns?>.filled(3, null);
  int _next = 0;

  /// Frames published so far.
  int published = 0;

  /// The last frame published.
  AgentFrame latest = AgentFrame.empty;

  static final int _driving = VehicleState.driving.index;

  /// Writes the next column set from [table] and returns the frame over it,
  /// stamped with agent time [timeUs]. Allocates only the frame itself —
  /// and, when the table has grown, the column set it is written to.
  AgentFrame publish(VehicleTable table,
      {required int timeUs, double worldEpochS = 0, int graphRev = 0}) {
    final k = _next;
    var set = _sets[k];
    if (set == null || set.capacity < table.capacity) {
      set = _sets[k] = _Columns(table.capacity);
    }
    final hw = table.highWater;
    for (var sl = 0; sl < hw; sl++) {
      if (!table.isSlotLive(sl)) {
        set.handle[sl] = -1;
        set.elem[sl] = -1;
        set.next[sl] = -1;
        set.s[sl] = 0;
        set.v[sl] = 0;
        set.a[sl] = 0;
        set.lat[sl] = 0;
        set.kind[sl] = 0;
        set.variant[sl] = 0;
        set.flags[sl] = 0;
        continue;
      }
      final acc = table.a[sl];
      var bits = acc < -kBrakeLightMps2 ? kFrameBraking : 0;
      if (table.state[sl] != _driving || table.flags[sl] & kRefused != 0) {
        bits |= kFrameStopping;
      }
      set.handle[sl] = table.handleOf(sl);
      set.elem[sl] = table.elem[sl];
      set.next[sl] = table.nextElemOf(sl);
      set.s[sl] = table.s[sl];
      set.v[sl] = table.v[sl];
      set.a[sl] = acc;
      set.lat[sl] = 0;
      set.kind[sl] = table.kind[sl];
      set.variant[sl] = table.variant[sl];
      set.flags[sl] = bits;
    }
    _next = (k + 1) % 3;
    published++;
    return latest = AgentFrame._(
      count: hw,
      timeUs: timeUs.toDouble(),
      worldEpochS: worldEpochS,
      graphRev: graphRev,
      handle: set.handle,
      elem: set.elem,
      next: set.next,
      s: set.s,
      v: set.v,
      a: set.a,
      lat: set.lat,
      kind: set.kind,
      variant: set.variant,
      flags: set.flags,
    );
  }
}
