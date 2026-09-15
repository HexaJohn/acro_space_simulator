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
///
/// [TrafficNetColumns] is the other half of what the renderer is told: what
/// it needs of the network itself — the signal heads and the plans that
/// time them — once per lane-graph object rather than once per sub-step.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'lane_graph.dart';
import 'node_control.dart';
import 'site_vehicles.dart';
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
  /// A frame over columns the caller filled: a host replaying a recorded
  /// sample, or a test placing vehicles where it wants them. The same
  /// contract as a published frame — the lists are not written again once
  /// they are handed over.
  AgentFrame.fromColumns({
    required this.count,
    required this.timeUs,
    this.worldEpochS = 0,
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
  static final AgentFrame empty = AgentFrame.fromColumns(
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
  ///
  /// [site] and [sitesRev] are the site columns and revision the frame will
  /// carry (`siteOrd`/`siteLane`, site-access.md §7.6, §13.1): accepted now
  /// so the facade can pass them, and read by nothing until the wire lands
  /// (package F, docs/plans/t4a-implementation.md §2). A vehicle inside a
  /// site already publishes element −1, which the renderer does not draw.
  AgentFrame publish(VehicleTable table,
      {required int timeUs,
      double worldEpochS = 0,
      int graphRev = 0,
      SiteVehicles? site,
      int sitesRev = 0}) {
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
    return latest = AgentFrame.fromColumns(
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

/// What the renderer needs of the network itself, beyond where the vehicles
/// are (§13.1, §13.6): the signal heads, and the plans that time them.
///
/// One per lane-graph object — built with the graph, and again when a
/// junction override refreshes its controls — and handed to every frame by
/// reference, so it costs nothing per sub-step. The same heads and
/// [SignalPlan.stateAt] are what the road agent was offered for its own
/// lamps (C3): the function the arbiter asks is the function the lamps are
/// drawn by, so a light and the car waiting at it cannot disagree.
///
/// Stops, stubs and the traffic view's node list arrive with the slices
/// that have them.
class TrafficNetColumns {
  TrafficNetColumns._({
    required this.graphRev,
    required this.controlsRev,
    required this.plans,
    required this.headNode,
    required this.headPlan,
    required this.headLeg,
    required this.headPhase,
    required this.headDirE,
    required this.headDirN,
    required this.headHalfWidth,
    required this.headR,
  });

  /// No network: no heads.
  static final TrafficNetColumns empty = TrafficNetColumns._(
    graphRev: 0,
    controlsRev: 0,
    plans: const [],
    headNode: Int32List(0),
    headPlan: Int32List(0),
    headLeg: Int32List(0),
    headPhase: Int8List(0),
    headDirE: Float32List(0),
    headDirN: Float32List(0),
    headHalfWidth: Float32List(0),
    headR: Float32List(0),
  );

  /// The agents' revisions these were built at.
  final int graphRev, controlsRev;

  /// The signalised nodes' plans, the controls' own list.
  final List<SignalPlan> plans;

  /// One head per leg a vehicle arrives by at a signalised node, of the
  /// legs the tiles draw (`RoadClass.joinsJunctions` — an alley meeting a
  /// crossing gets no mast), in plan order with each node's legs in
  /// heading order: its node (road-graph id), its plan (index in [plans]),
  /// its leg (`RoadNode.legs` index) and the phase that leg waits on.
  final Int32List headNode, headPlan, headLeg;
  final Int8List headPhase;

  /// Unit vector from the node out along the leg, colony east and north.
  final Float32List headDirE, headDirN;

  /// The leg's half width, and the radius of the junction's plate — its
  /// widest drawn leg × [kPlateRadiusPerHalfWidth] — which is where the
  /// tiles stand a leg's mast (road_mesher.dart, `_crossing`).
  final Float32List headHalfWidth, headR;

  int get headCount => headNode.length;

  /// What head [h] shows at agent time [timeUs]: the plan's own clock.
  SignalState stateOf(int h, int timeUs) =>
      plans[headPlan[h]].stateAt(headPhase[h], timeUs);

  /// The heads of [lg]'s signalised nodes.
  factory TrafficNetColumns.of(LaneGraph lg,
      {int graphRev = 0, int controlsRev = 0}) {
    final g = lg.graph;
    final plans = lg.controls.plans;
    final node = <int>[], plan = <int>[], leg = <int>[], phase = <int>[];
    final dirE = <double>[], dirN = <double>[];
    final halfWidth = <double>[], radius = <double>[];
    for (var p = 0; p < plans.length; p++) {
      final n = g.nodes[plans[p].node];
      final r = junctionHalfWidthOf(n) * kPlateRadiusPerHalfWidth;
      for (final k in headingOrder(n)) {
        final l = n.legs[k];
        final ph = plans[p].legPhase[k];
        if (ph < 0 || !l.roadClass.joinsJunctions) continue;
        node.add(n.id);
        plan.add(p);
        leg.add(k);
        phase.add(ph);
        // Headings run from north toward east (`Vec2.heading`).
        dirE.add(math.sin(l.heading));
        dirN.add(math.cos(l.heading));
        halfWidth.add(l.roadClass.halfWidth);
        radius.add(r);
      }
    }
    return TrafficNetColumns._(
      graphRev: graphRev,
      controlsRev: controlsRev,
      plans: plans,
      headNode: Int32List.fromList(node),
      headPlan: Int32List.fromList(plan),
      headLeg: Int32List.fromList(leg),
      headPhase: Int8List.fromList(phase),
      headDirE: Float32List.fromList(dirE),
      headDirN: Float32List.fromList(dirN),
      headHalfWidth: Float32List.fromList(halfWidth),
      headR: Float32List.fromList(radius),
    );
  }
}
