// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// How each node of the network controls the traffic entering it, and the
/// signal clock (docs/plans/agent-traffic.md §3.2, §3.7).
///
/// Nothing here decides a junction. The road network already did:
/// `RoadNode.plan` is the one warrant the tiles draw by and the routed model
/// times by (`junctionPlanForNetwork`), with the player's override applied.
/// This file only READS that answer and says what it means to a vehicle —
/// which legs stop, which give way, which phase of a light each leg waits
/// on — so a light the player sees is a light the agents wait at.
///
/// Signal state is not stored anywhere. It is a pure function of the agent
/// clock ([SignalPlan.stateAt]) in integer microseconds, which the arbiter
/// and the renderer both call: a stored phase would have to be stepped,
/// saved and kept in agreement with the lamps, and could drift from either.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../parcel.dart';
import '../road_graph.dart';
import '../road_junction.dart';
import 'agent_kind.dart';
import 'traffic_rng.dart';

/// What [node]'s plan means to traffic (§3.2): the network's own plan,
/// read, never re-decided.
///
/// [stub] marks a ground dead end where an outside connection leaves the map
/// (slice 8); no stub resolves before then.
NodeControlKind controlKindOf(RoadNode node, {bool stub = false}) {
  final legs = node.legs;
  if (legs.length <= 1) {
    // A deck that stops in the air, or under the ground, is no turning
    // place the player built: the traffic view draws it as an error.
    if (!node.atGrade) return NodeControlKind.danglingDeck;
    return stub ? NodeControlKind.stub : NodeControlKind.deadEnd;
  }
  final plan = node.plan;
  switch (plan.control) {
    case JunctionControl.none:
      // The warrant never leaves three legs without a plan today; should it,
      // the arbiter falls back to rank and the right-hand rule.
      return legs.length == 2
          ? NodeControlKind.continuation
          : NodeControlKind.uncontrolled;
    case JunctionControl.merge:
      // A merge with no ramp is a seam — the 6→4 drop, a class change on a
      // limited-access road, a ring's join — where lanes carry on.
      for (final l in legs) {
        if (l.roadClass == RoadClass.ramp) return NodeControlKind.rampMerge;
      }
      return NodeControlKind.continuation;
    case JunctionControl.stop:
      for (var i = 0; i < legs.length; i++) {
        final l = legs[i];
        if (l.inbound && l.roadClass.carriesCars && !plan.stopLegs.contains(i)) {
          return NodeControlKind.stop;
        }
      }
      return NodeControlKind.allWayStop;
    case JunctionControl.signals:
      return NodeControlKind.signals;
    case JunctionControl.roundabout:
      return NodeControlKind.roundabout;
  }
}

/// A junction proper: three legs or more under a control a driver obeys.
/// Only these get the adjacent-lane straight connectors (rule 5, §3.5), and
/// only these are drawn with a plate the lanes stop short of.
bool isRealJunction(NodeControlKind k) => switch (k) {
      NodeControlKind.stop ||
      NodeControlKind.allWayStop ||
      NodeControlKind.signals ||
      NodeControlKind.roundabout ||
      NodeControlKind.uncontrolled =>
        true,
      NodeControlKind.deadEnd ||
      NodeControlKind.stub ||
      NodeControlKind.danglingDeck ||
      NodeControlKind.continuation ||
      NodeControlKind.rampMerge =>
        false,
    };

/// A place a vehicle can turn round (§3.6). A deck that ends in the air is
/// one too: a car that drove onto it must be able to come back.
bool isTurningPlace(NodeControlKind k) =>
    k == NodeControlKind.deadEnd ||
    k == NodeControlKind.stub ||
    k == NodeControlKind.danglingDeck;

/// The renderer's junction geometry, so a vehicle stops at the bar the
/// tiles draw (road_mesher.dart, `_crossing` and `_roundabout`): a crossing
/// plate of radius `maxHalfWidth × 1.45` with its stop bars at 0.92 of it; a
/// roundabout of radius `max(14, maxHalfWidth × 2 + 6)` with its yield line
/// at 0.96 of it.
const double kPlateRadiusPerHalfWidth = 1.45;
const double kStopBarAt = 0.92;
const double kRoundaboutMinRadiusM = 14;
const double kYieldLineAt = 0.96;

/// Metres before [kind]'s node that a lane ends at, and after it that a
/// lane starts at: the drawn stop bar or yield line, so the connectors
/// cross the plate. Zero where nothing is drawn (§3.5).
double stopBackOf(NodeControlKind kind, double maxHalfWidthM) => switch (kind) {
      NodeControlKind.stop ||
      NodeControlKind.allWayStop ||
      NodeControlKind.signals =>
        maxHalfWidthM * kPlateRadiusPerHalfWidth * kStopBarAt,
      NodeControlKind.roundabout =>
        math.max(kRoundaboutMinRadiusM, maxHalfWidthM * 2 + 6) * kYieldLineAt,
      NodeControlKind.deadEnd ||
      NodeControlKind.stub ||
      NodeControlKind.danglingDeck ||
      NodeControlKind.continuation ||
      NodeControlKind.rampMerge ||
      NodeControlKind.uncontrolled =>
        0,
    };

/// The widest leg at [node], as the tiles measure it: over the legs that
/// join a drawn junction (`RoadClass.joinsJunctions` — the tiles never see
/// an alley's or a path's end), and over every leg where none does.
double junctionHalfWidthOf(RoadNode node) {
  var drawn = 0.0, any = 0.0;
  for (final l in node.legs) {
    final hw = l.roadClass.halfWidth;
    if (hw > any) any = hw;
    if (l.roadClass.joinsJunctions && hw > drawn) drawn = hw;
  }
  return drawn > 0 ? drawn : any;
}

/// A signal head's colour. Append-only: the renderer's lamp layer indexes
/// by it.
enum SignalState { red, amber, green, allRed }

/// One signalised node's phases and clock (§3.7).
///
/// Inbound legs are grouped into two axes by heading: a leg joins the first
/// leg's axis when it runs within 45° of parallel or opposite to it, and the
/// other axis otherwise. Where that grouping would put two crossing legs on
/// one green — a Y, three legs within a right angle — every inbound leg
/// gets a phase of its own. Each phase is green, amber, then all-red, in
/// turn; a two-phase cycle is 32 s.
///
/// The offset is a hash of the junction's WHOLE-METRE position — the key its
/// override is stored under — so a light keeps its offset when a road is
/// split elsewhere, across saves and across sessions.
class SignalPlan {
  SignalPlan._(this.node, this.legPhase, this.phaseCount, this.offsetUs);

  static const int greenUs = 12000000;
  static const int amberUs = 3000000;
  static const int allRedUs = 1000000;

  /// One phase's share of the cycle.
  static const int phaseUs = greenUs + amberUs + allRedUs;

  /// The [RoadGraph] node this plan runs.
  final int node;

  /// The phase each of the node's legs ([RoadNode.legs] order) waits on, or
  /// −1 for a leg nothing arrives along.
  final Int8List legPhase;

  final int phaseCount;

  /// Where in its cycle this light stands at agent time 0.
  final int offsetUs;

  int get cycleUs => phaseCount * phaseUs;

  /// The plan of [node], whose control is signals.
  factory SignalPlan.of(RoadNode node) {
    final legs = node.legs;
    final order = headingOrder(node);
    final inbound = <int>[
      for (final k in order)
        if (legs[k].inbound) k,
    ];
    final phase = Int8List(legs.length)..fillRange(0, legs.length, -1);
    var count = 1;
    if (inbound.isNotEmpty) {
      final h0 = legs[inbound.first].heading;
      final axis = Int8List(inbound.length);
      var nAxis1 = 0;
      for (var i = 0; i < inbound.length; i++) {
        if (!_parallel(legs[inbound[i]].heading, h0)) {
          axis[i] = 1;
          nAxis1++;
        }
      }
      // Degenerate: two legs sharing an axis that cross each other.
      var degenerate = false;
      for (var i = 0; i < inbound.length && !degenerate; i++) {
        for (var j = i + 1; j < inbound.length; j++) {
          if (axis[i] == axis[j] &&
              !_parallel(legs[inbound[i]].heading, legs[inbound[j]].heading)) {
            degenerate = true;
            break;
          }
        }
      }
      if (degenerate) {
        for (var i = 0; i < inbound.length; i++) {
          phase[inbound[i]] = i;
        }
        count = inbound.length;
      } else {
        for (var i = 0; i < inbound.length; i++) {
          phase[inbound[i]] = axis[i];
        }
        count = nAxis1 > 0 ? 2 : 1;
      }
    }
    final cycle = count * phaseUs;
    final offset = fnv1a32(JunctionOverride.keyFor(node.at)) % cycle;
    return SignalPlan._(node.id, phase, count, offset);
  }

  /// Whether two headings run within 45° of parallel or of opposite.
  static bool _parallel(double a, double b) =>
      math.cos(a - b).abs() >= math.cos(math.pi / 4) - 1e-9;

  /// The light [phase] shows at agent time [timeUs]: integer arithmetic only,
  /// the one function both the arbiter and the renderer ask.
  SignalState stateAt(int phase, int timeUs) {
    if (phase < 0 || phase >= phaseCount) return SignalState.red;
    final t = (timeUs + offsetUs) % cycleUs;
    final k = t ~/ phaseUs;
    if (k != phase) return SignalState.red;
    final w = t - k * phaseUs;
    if (w < greenUs) return SignalState.green;
    if (w < greenUs + amberUs) return SignalState.amber;
    return SignalState.allRed;
  }

  /// The state the leg a vehicle arrives by ([RoadNode.legs] index) shows.
  SignalState legStateAt(int leg, int timeUs) =>
      stateAt(legPhase[leg], timeUs);
}

/// [node]'s legs, as indices into [RoadNode.legs], sorted by heading (ties
/// by index), so the order does not depend on which road end happened to be
/// clustered first.
List<int> headingOrder(RoadNode node) {
  final legs = node.legs;
  return List<int>.generate(legs.length, (i) => i)
    ..sort((a, b) {
      final c = legs[a].heading.compareTo(legs[b].heading);
      return c != 0 ? c : a.compareTo(b);
    });
}

/// Every node's control, as one set of columns: what the graph's plans mean
/// to traffic, and the only part of the lane graph a patched `RoadGraph`
/// (an override toggled, a road renamed) changes.
///
/// Per node: the [NodeControlKind], the stop back-off, the signal plan, and
/// its legs in heading order with a stop flag each. Per directed edge,
/// about the leg it ARRIVES by: whether a vehicle must halt there, whether
/// it gives way, and which signal phase it waits on.
class NodeControls {
  NodeControls._({
    required this.kind,
    required this.stopBack,
    required this.signalOf,
    required this.plans,
    required this.legStart,
    required this.legOrder,
    required this.legStops,
    required this.edgeStops,
    required this.edgeYields,
    required this.edgePhase,
  });

  /// [NodeControlKind.index] per node.
  final Uint8List kind;

  /// Metres the lanes stop short of each node ([stopBackOf]).
  final Float32List stopBack;

  /// Per node: its index in [plans], or −1 for a node without lights.
  final Int32List signalOf;

  /// The signalised nodes' plans, in node order.
  final List<SignalPlan> plans;

  /// Node n's legs in heading order are
  /// `legOrder[legStart[n] .. legStart[n + 1] − 1]`, each with a stop flag
  /// in [legStops] (1: the leg stops — a stop plan's stop leg, or every
  /// inbound leg of an all-way stop).
  final Int32List legStart, legOrder;
  final Uint8List legStops;

  /// Per directed edge, about its arriving leg: 1 when a vehicle must come
  /// to rest at the line before entering.
  final Uint8List edgeStops;

  /// 1 when a vehicle arriving along the edge gives way to others: a
  /// stopping leg, a roundabout entry, a ramp at its merge, a lower-rank leg
  /// at an uncontrolled node.
  final Uint8List edgeYields;

  /// The signal phase the edge's arriving leg waits on, or −1.
  final Int8List edgePhase;

  NodeControlKind kindOf(int node) => NodeControlKind.values[kind[node]];

  /// The plan of [node], or null where there are no lights.
  SignalPlan? planOf(int node) {
    final i = signalOf[node];
    return i < 0 ? null : plans[i];
  }

  /// The controls of every node of [g]. [stubNode] marks, per node, the
  /// ground dead ends an outside connection resolved onto (slice 8); null
  /// for none.
  factory NodeControls.of(RoadGraph g, {Uint8List? stubNode}) {
    final nN = g.nodeCount, nE = g.edgeCount;
    final kind = Uint8List(nN);
    final stopBack = Float32List(nN);
    final signalOf = Int32List(nN)..fillRange(0, nN, -1);
    final plans = <SignalPlan>[];
    final legStart = Int32List(nN + 1);
    var nLegs = 0;
    for (var n = 0; n < nN; n++) {
      nLegs += g.nodes[n].legs.length;
    }
    final legOrder = Int32List(nLegs);
    final legStops = Uint8List(nLegs);
    // The highest rank arriving at each uncontrolled node, where rank is who
    // gives way to whom.
    final topRank = Int32List(nN)..fillRange(0, nN, -1);
    var at = 0;
    for (var n = 0; n < nN; n++) {
      final node = g.nodes[n];
      final stub = stubNode != null && n < stubNode.length && stubNode[n] != 0;
      final k = controlKindOf(node, stub: stub);
      kind[n] = k.index;
      stopBack[n] = stopBackOf(k, junctionHalfWidthOf(node));
      if (k == NodeControlKind.signals) {
        signalOf[n] = plans.length;
        plans.add(SignalPlan.of(node));
      }
      legStart[n] = at;
      final legs = node.legs;
      for (final leg in headingOrder(node)) {
        legOrder[at] = leg;
        final l = legs[leg];
        final stops = l.inbound &&
            (k == NodeControlKind.allWayStop ||
                (k == NodeControlKind.stop && node.plan.stopLegs.contains(leg)));
        legStops[at] = stops ? 1 : 0;
        if (l.inbound && l.roadClass.tier.rank > topRank[n]) {
          topRank[n] = l.roadClass.tier.rank;
        }
        at++;
      }
    }
    legStart[nN] = at;

    final edgeStops = Uint8List(nE);
    final edgeYields = Uint8List(nE);
    final edgePhase = Int8List(nE)..fillRange(0, nE, -1);
    for (var e = 0; e < nE; e++) {
      final n = g.edgeTo[e];
      final leg = g.edgeLeg[e];
      if (leg < 0) continue;
      final node = g.nodes[n];
      final l = node.legs[leg];
      final k = NodeControlKind.values[kind[n]];
      final stops = k == NodeControlKind.allWayStop ||
          (k == NodeControlKind.stop && node.plan.stopLegs.contains(leg));
      edgeStops[e] = stops ? 1 : 0;
      final yields = stops ||
          k == NodeControlKind.roundabout ||
          (k == NodeControlKind.rampMerge && l.roadClass == RoadClass.ramp) ||
          (k == NodeControlKind.uncontrolled &&
              l.roadClass.tier.rank < topRank[n]);
      edgeYields[e] = yields ? 1 : 0;
      final plan = signalOf[n] < 0 ? null : plans[signalOf[n]];
      if (plan != null) edgePhase[e] = plan.legPhase[leg];
    }

    return NodeControls._(
      kind: kind,
      stopBack: stopBack,
      signalOf: signalOf,
      plans: List.unmodifiable(plans),
      legStart: legStart,
      legOrder: legOrder,
      legStops: legStops,
      edgeStops: edgeStops,
      edgeYields: edgeYields,
      edgePhase: edgePhase,
    );
  }
}
