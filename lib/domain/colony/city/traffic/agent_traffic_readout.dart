// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What the agents tell the rest of the colony: the traffic readout
/// (docs/plans/agent-traffic.md §12.3, D46, D47).
///
/// Every consumer of traffic — the tax line, the growth gates, the parcel
/// congestion, the lot fires, the road tool's Routes view — reads
/// `CitySim.trafficReadout`, and in an agent colony that is this (E37). No
/// consumer changes; each question has exactly one answerer.
///
/// SLICE 1 answers what the agents measure: congestion and volumes from
/// vehicle speeds and flows (traffic_stats.dart), and the routes through a
/// road, which are the locked routes of the vehicles driving now. Reach,
/// noise, land value and the tax factor are forwarded to the routed model,
/// which keeps advancing beside the agents; slice 2 answers those from the
/// agents' own searches and measured flows, and stops the routed model.
///
/// The contract (D47): answers are the last complete picture, taken every
/// congestion epoch, and before the first one they punish nothing — no
/// congestion, no routes; the forwarded answers keep the routed model's own
/// "every lot reached, no noise, a tax factor of exactly 1" until it has a
/// picture of its own.
///
/// Once a colony's agents have taken a picture, the colony answers through
/// this readout for good (E37). Switched off, it forwards every answer to
/// the routed model and keeps only [passes] its own, so neither switch —
/// to the agents, or back — can take a view's key back.
library;

import '../parcel.dart';
import '../traffic_readout.dart';
import 'agent_kind.dart';
import 'city_agents.dart';
import 'lane_graph.dart';
import 'slot_pool.dart';
import 'vehicle_table.dart';

/// A colony's agents as a [CityTrafficReadout].
class AgentTrafficReadout implements CityTrafficReadout {
  AgentTrafficReadout(this.agents, this.routed);

  /// Whose measurements and vehicles this reads.
  final CityAgents agents;

  /// What slice 1 forwards to: the routed model, `CitySim.roadTraffic`.
  final CityTrafficReadout routed;

  /// Routes asked for since the last picture, by road, kinds and limit: the
  /// Routes view asks for the same road every frame while it is selected.
  final Map<String, List<TripRoute>> _routes = {};
  int _routesPictures = -1;

  /// Whether the agents answer the measured questions: they are switched
  /// on. Switched off, every answer is the routed model's.
  bool get _live => agents.enabled;

  @override
  bool get hasRun => _live ? agents.stats.hasRun : routed.hasRun;

  /// Pictures published: ours, ever, and the routed model's that the
  /// forwarded answers come from, so a view keyed on it redraws whenever
  /// any answer may have changed (D47).
  ///
  /// Never going back. Both counts only grow — ours is the colony's ever
  /// ([CityAgents.pictures]), carried across a switch off and on — and the
  /// sum is never below the routed model's own count, which is what the
  /// colony answered with before the agents took over. So the switch to
  /// the agents cannot take the count back; and since the colony keeps
  /// answering through this once the agents have published (E37), neither
  /// can the switch back.
  @override
  int get passes => agents.pictures + routed.passes;

  @override
  double get peakCongestion {
    if (!_live) return routed.peakCongestion;
    return hasRun ? agents.stats.peakCongestion : 0.0;
  }

  @override
  double get averageCongestion {
    if (!_live) return routed.averageCongestion;
    return hasRun ? agents.stats.averageCongestion : 0.0;
  }

  @override
  double congestionOf(String roadId) {
    if (!_live) return routed.congestionOf(roadId);
    return hasRun ? agents.stats.congestionOf(roadId) : 0.0;
  }

  @override
  double volumeOf(String roadId) {
    if (!_live) return routed.volumeOf(roadId);
    return hasRun ? agents.stats.volumeOf(roadId) : 0.0;
  }

  /// The vehicles on the road now whose locked route uses [roadId]: one
  /// [TripRoute] each, of weight 1, its kind from the trip's purpose, its
  /// roads in route order (each once per visit) and its line from where the
  /// route leaves its first road to where it stops. All weigh the same, so
  /// "heaviest first" is by handle.
  @override
  List<TripRoute> routesThrough(String roadId,
      {Set<TripKind>? kinds, int limit = 64}) {
    if (!_live) return routed.routesThrough(roadId, kinds: kinds, limit: limit);
    if (!hasRun || limit <= 0) return const [];
    final pictures = agents.pictures;
    if (pictures != _routesPictures) {
      _routes.clear();
      _routesPictures = pictures;
    }
    var mask = 0;
    if (kinds != null) {
      for (final k in TripKind.values) {
        if (kinds.contains(k)) mask |= 1 << k.index;
      }
    }
    final key = '$roadId|$mask|$limit';
    return _routes[key] ??= _collect(roadId, kinds, limit);
  }

  List<TripRoute> _collect(String roadId, Set<TripKind>? kinds, int limit) {
    final t = agents.vehicles, lg = agents.laneGraph;
    if (t == null || lg == null) return const [];
    final r = lg.graph.roadNoOf(roadId);
    if (r == null) return const [];
    final hits = <int>[];
    for (var sl = 0; sl < t.highWater; sl++) {
      if (!t.isSlotLive(sl)) continue;
      final kind = TripPurpose.values[t.purpose[sl]].tripKind;
      if (kinds != null && !kinds.contains(kind)) continue;
      if (_uses(t, lg, sl, r)) hits.add(t.handleOf(sl));
    }
    hits.sort();
    final n = hits.length < limit ? hits.length : limit;
    return List<TripRoute>.unmodifiable(<TripRoute>[
      for (var i = 0; i < n; i++) _route(t, lg, SlotPool.slotOf(hits[i])),
    ]);
  }

  /// Whether the route of [sl] runs on graph road [road].
  static bool _uses(VehicleTable t, LaneGraph lg, int sl, int road) {
    for (var i = 0; i < t.routeLen[sl]; i++) {
      final e = lg.laneEdge[t.laneOfRouteEdge(sl, i)];
      if (lg.edgeRoad[e] == road) return true;
    }
    return false;
  }

  TripRoute _route(VehicleTable t, LaneGraph lg, int sl) {
    final g = lg.graph;
    final ids = <String>[];
    final pts = <Vec2>[];
    final n = t.routeLen[sl];
    var lastRoad = -1;
    for (var i = 0; i < n; i++) {
      final e = lg.laneEdge[t.laneOfRouteEdge(sl, i)];
      final road = lg.edgeRoad[e];
      if (road != lastRoad) ids.add(g.roads[road].id);
      lastRoad = road;
      final from = i == 0 ? agents.originTOf(sl) : 0.0;
      final to = i == n - 1 ? t.destS[sl].toDouble() : lg.edgeLen[e];
      final line = g.polylineOf(road, lg.roadArc(e, from), lg.roadArc(e, to));
      for (var k = 0; k < line.length; k++) {
        final p = line[k];
        if (pts.isNotEmpty && pts.last.distanceTo(p) < 1e-6) continue;
        pts.add(p);
      }
    }
    return TripRoute(
      kind: TripPurpose.values[t.purpose[sl]].tripKind,
      weight: 1,
      roadIds: List<String>.unmodifiable(ids),
      polyline: List<Vec2>.unmodifiable(pts),
    );
  }

  // ---- Forwarded to the routed model (slice 1) ---------------------------

  @override
  bool serviceReach(String lotId) => routed.serviceReach(lotId);

  /// Reach from the stations with safety cover only (D47): the routed
  /// model's fire reach, never its service reach — a clinic's ambulance
  /// reaching a lot puts no fire out there.
  @override
  bool fireReach(String lotId) => routed.fireReach(lotId);

  @override
  bool deliveryReach(String lotId) => routed.deliveryReach(lotId);

  @override
  double noiseOf(String lotId) => routed.noiseOf(lotId);

  @override
  double landValueOf(String lotId) => routed.landValueOf(lotId);

  @override
  double get averageLandValue => routed.averageLandValue;

  @override
  double get taxLandValueFactor => routed.taxLandValueFactor;
}
