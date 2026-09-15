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
/// The agents answer all of it. SLICE 1 answered what they measure:
/// congestion and volumes from vehicle speeds and flows (traffic_stats.dart),
/// and the routes through a road, which are the locked routes of the
/// vehicles driving now. SLICE 2 answers the rest from the same
/// measurements and the agents' own network:
///
/// - REACH — service, fire and delivery — from bounded multi-source searches
///   over the lane graph's directed edges ([AgentReach], agent_reach.dart);
/// - NOISE, from each road's MEASURED load through the routed model's own
///   sampler and formulas (road_noise.dart): a piece throws
///   `roadEmission × RoadNoise.volumeFactor(load)` at its kerbs, where the
///   load is the larger of the road's speed-based congestion and its flow
///   against a lane at free flow ([kLaneFlowPerMin]) — measured vehicles
///   where the routed model has assigned ones;
/// - LAND VALUE, [RoadNoise.landValue] of that noise, the frontage bonus
///   and the colony's air; and the TAX FACTOR, [RoadNoise.taxFactor] of the
///   built lots' average without the air, exactly 1 until a built lot has
///   been valued (road_traffic_model.dart:566-575, 1905-1918).
///
/// Those come from a PASS of bounded work — the reach fields when their
/// sources or the network have changed, the noise at every lot when the
/// measured loads have — which the readout pumps itself: once each time the
/// agent clock has moved when something asks, so no query costs more than a
/// budget's work and every answer after it is an array read. The routed
/// model is not consulted for any of it (C7: nothing assigned is left).
///
/// The contract (D47): answers are the last complete picture, and before
/// the first one they punish nothing — no congestion, no routes, every lot
/// reached, no noise, a tax factor of exactly 1, and the land value of a
/// quiet plain street in the colony's air (what the routed model answers
/// before its first pass). A pass's answers are published only at a picture
/// — at the first question after the congestion epoch that took it — so
/// they change exactly when [passes] moves, never between.
///
/// Once a colony's agents have taken a picture, the colony answers through
/// this readout for good (E37). Switched off, it forwards every answer to
/// the routed model and keeps only [passes] its own, so neither switch —
/// to the agents, or back — can take a view's key back.
library;

import 'dart:typed_data';

import '../parcel.dart';
import '../road_graph.dart';
import '../road_noise.dart';
import '../traffic_readout.dart';
import 'agent_kind.dart';
import 'agent_reach.dart';
import 'building_table.dart';
import 'city_agents.dart';
import 'lane_graph.dart';
import 'slot_pool.dart';
import 'traffic_stats.dart';
import 'vehicle_table.dart';

/// Vehicles one lane carries a minute at free flow: the flow against which
/// a road's measured volume is a load of 1 (§12.3's `laneFlowPerMin`). Kept
/// here, beside the only formula that reads it, until the tuning panel
/// wants it as a knob.
const double kLaneFlowPerMin = 30;

/// Work units the readout's pass may do each time it is pumped — the routed
/// model's own step budget (`TrafficTuning.workPerStep`), in the same units:
/// a label settled, an edge relaxed, a building or a lot looked at, an index
/// cell or road segment the noise sampler measured.
const int kReadoutWorkPerPump = 60000;

/// A colony's agents as a [CityTrafficReadout].
class AgentTrafficReadout implements CityTrafficReadout {
  AgentTrafficReadout(this.agents, this.routed)
    : reach = AgentReach(radiusM: agents.city.roadTraffic.tuning.serviceReachM);

  /// Whose measurements and vehicles this reads.
  final CityAgents agents;

  /// What the readout forwards to while the agents are switched off: the
  /// routed model, `CitySim.roadTraffic`.
  final CityTrafficReadout routed;

  /// The reach fields (agent_reach.dart), pumped with the noise pass.
  final AgentReach reach;

  /// Routes asked for since the last picture, by road, kinds and limit: the
  /// Routes view asks for the same road every frame while it is selected.
  final Map<String, List<TripRoute>> _routes = {};
  int _routesPictures = -1;

  /// Whether the agents answer: they are switched on. Switched off, every
  /// answer is the routed model's.
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
  List<TripRoute> routesThrough(
    String roadId, {
    Set<TripKind>? kinds,
    int limit = 64,
  }) {
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

  // ---- Reach (slice 2: the agents' own searches) --------------------------

  /// Whether a police car, fire engine or ambulance reaches [lotId] the way
  /// the one-way streets run ([AgentReach.serviceReach]).
  @override
  bool serviceReach(String lotId) {
    if (!_live) return routed.serviceReach(lotId);
    pump();
    return reach.serviceReach(lotId);
  }

  /// Reach from the stations with safety cover only (D47): a clinic's
  /// ambulance reaching a lot puts no fire out there.
  @override
  bool fireReach(String lotId) {
    if (!_live) return routed.fireReach(lotId);
    pump();
    return reach.fireReach(lotId);
  }

  /// Whether goods reach [lotId] from anywhere but its own door.
  @override
  bool deliveryReach(String lotId) {
    if (!_live) return routed.deliveryReach(lotId);
    pump();
    return reach.deliveryReach(lotId);
  }

  // ---- Noise, land value, the tax factor (slice 2: measured flow) ---------

  /// Traffic noise at [lotId], 0..1: 0 before a picture, for a lot the
  /// picture does not know, and for one nobody zoned or built on.
  @override
  double noiseOf(String lotId) {
    if (!_live) return routed.noiseOf(lotId);
    pump();
    final n = _noiseFront;
    final i = n?.graph.lotNoOf(lotId);
    return i == null ? 0.0 : n!.noise[i].toDouble();
  }

  /// Land value of [lotId] in the colony's air: a quiet plain street's
  /// before a picture and for a lot it does not know.
  @override
  double landValueOf(String lotId) {
    if (!_live) return routed.landValueOf(lotId);
    pump();
    final pollution = agents.city.pollution;
    final n = _noiseFront;
    final i = n?.graph.lotNoOf(lotId);
    if (i == null) return RoadNoise.landValue(noise: 0, pollution: pollution);
    return RoadNoise.landValue(
      noise: n!.noise[i].toDouble(),
      bonus: n.bonus[i].toDouble(),
      pollution: pollution,
    );
  }

  /// Land value averaged over the built lots, in the colony's air — the
  /// base value in that air when none is built, or before a picture.
  @override
  double get averageLandValue {
    if (!_live) return routed.averageLandValue;
    pump();
    return _average(agents.city.pollution);
  }

  double _average(double pollution) {
    final raw = _noiseFront?.landValueRaw ?? RoadNoise.baseLandValue;
    return (raw - RoadNoise.pollutionPenalty(pollution)).clamp(0.0, 1.0);
  }

  /// The land the ROADS make, on the tax take: [RoadNoise.taxFactor] of the
  /// built lots' average without the colony's air, which already costs it
  /// through happiness and health — exactly 1 until a built lot is valued.
  @override
  double get taxLandValueFactor {
    if (!_live) return routed.taxLandValueFactor;
    pump();
    final n = _noiseFront;
    if (n == null || n.builtLots == 0) return 1.0;
    return RoadNoise.taxFactor(_average(0));
  }

  // ---- The pass ----------------------------------------------------------------

  /// The published noise picture, and the one a pass fills.
  _NoiseFields? _noiseFront, _noiseBack;
  RoadNoiseSampler? _sampler;

  /// Whose tables the published answers were taken from: the colony's agents
  /// start afresh when they are switched off and on, and nothing published
  /// of their old tables stands.
  BuildingTable? _tables;
  int _pumpUs = -1;
  int _pumpPictures = -1;

  static const int _idle = 0, _reach = 1, _loads = 2, _lots = 3, _done = 4;
  int _phase = _idle;
  int _cursor = 0;
  LaneGraph? _passLg;
  bool _loadsMoved = false;
  double _lvSum = 0;
  int _lvCount = 0;

  /// Passes the readout has published (reach and noise together).
  int publishedPasses = 0;

  /// Brings the answers up to the agents' latest picture, a budget's work at
  /// a time: at most once per move of the agent clock, however many
  /// questions are asked in between. Every answer calls it first.
  ///
  /// At a picture — the first call after a congestion epoch — a finished
  /// pass is published, a new one is begun if none is in flight, and the
  /// pass is stepped; one that finishes within that same call is published
  /// at once, since nothing has read an answer since the picture. Between
  /// pictures the pass in flight is stepped, and one that finishes waits
  /// for the next picture: answers change when [passes] does.
  void pump() {
    final tables = agents.buildings;
    if (!identical(tables, _tables)) {
      _tables = tables;
      _resetPass();
    }
    if (tables == null) return;
    final now = agents.timeUs;
    if (now == _pumpUs) return;
    _pumpUs = now;
    final lg = agents.laneGraph;
    if (lg == null || !agents.stats.hasRun) return;
    if (_phase != _idle && _phase != _done && !identical(lg, _passLg)) {
      // The network changed under the pass: what it gathered was the old
      // one's. Begun again on the new one at once.
      _begin(lg, tables);
    }
    final pictures = agents.pictures;
    if (pictures == _pumpPictures) {
      if (_phase != _idle && _phase != _done) _step(kReadoutWorkPerPump);
      return;
    }
    _pumpPictures = pictures;
    if (_phase == _done) _publish();
    if (_phase == _idle) _begin(lg, tables);
    _step(kReadoutWorkPerPump);
    if (_phase == _done) _publish();
  }

  /// Runs the pass to its end and publishes it now, whatever the budget: for
  /// tests that read the answers of the picture they have just taken.
  void settle() {
    pump();
    final tables = agents.buildings, lg = agents.laneGraph;
    if (tables == null || lg == null || !agents.stats.hasRun) return;
    if (_phase == _idle || !identical(lg, _passLg)) _begin(lg, tables);
    while (_phase != _done) {
      _step(1 << 30);
    }
    _publish();
  }

  void _resetPass() {
    reach.reset();
    _noiseFront = null;
    _noiseBack = null;
    _sampler = null;
    _phase = _idle;
    _passLg = null;
    _pumpUs = -1;
    _pumpPictures = -1;
  }

  void _begin(LaneGraph lg, BuildingTable tables) {
    _passLg = lg;
    reach.begin(lg, tables);
    final g = lg.graph;
    var b = _noiseBack;
    if (b == null || b.pieceCount != g.pieceCount || b.lotCount != g.lotCount) {
      b = _noiseBack = _NoiseFields(g);
    }
    b.graph = g;
    final s = _sampler;
    if (s == null || !identical(s.graph, g)) _sampler = RoadNoiseSampler(g);
    _cursor = 0;
    _loadsMoved = false;
    _lvSum = 0;
    _lvCount = 0;
    _phase = _reach;
  }

  void _step(int budget) {
    var work = 0;
    while (work < budget && _phase != _idle && _phase != _done) {
      final left = budget - work;
      switch (_phase) {
        case _reach:
          work += reach.step(left);
          if (!reach.passing) _phase = _loads;
        case _loads:
          work += _loadsStep(left);
        case _lots:
          work += _lotsStep(left);
      }
    }
  }

  void _publish() {
    reach.publish();
    final b = _noiseBack!;
    _noiseBack = _noiseFront;
    _noiseFront = b;
    b.landValueRaw = _lvCount == 0
        ? RoadNoise.baseLandValue
        : _lvSum / _lvCount;
    b.builtLots = _lvCount;
    publishedPasses++;
    _phase = _idle;
    _passLg = null;
  }

  /// Whether per-piece and per-lot arrays on [g] line up with the published
  /// picture's: the same roads cut into the same pieces, the same lots.
  bool _alignedWithFront(RoadGraph g) {
    final f = _noiseFront;
    return f != null && g.sharesStructureWith(f.graph);
  }

  /// Every piece's emission from its road's measured load — the picture's
  /// congestion and volume, read by road id so a picture taken on the
  /// network before a rebuild still lands on the roads that kept their
  /// ids.
  int _loadsStep(int budget) {
    final g = _passLg!.graph;
    final b = _noiseBack!;
    final stats = agents.stats;
    final aligned = _alignedWithFront(g);
    final front = _noiseFront;
    var work = 0;
    while (_cursor < g.roadCount && work < budget) {
      final r = _cursor++;
      final id = g.roads[r].id;
      final e =
          g.roadEmission[r] *
          RoadNoise.volumeFactor(
            measuredLoad(
              stats.congestionOf(id),
              stats.volumeOf(id),
              g.roadLanes[r],
            ),
          );
      for (var p = g.roadFirstPiece[r]; p < g.roadFirstPiece[r + 1]; p++) {
        b.emission[p] = e;
        if (!aligned || front!.emission[p] != e) _loadsMoved = true;
      }
      work += 2 + g.roadFirstPiece[r + 1] - g.roadFirstPiece[r];
    }
    if (_cursor < g.roadCount) return work;
    if (!aligned) _loadsMoved = true;
    _cursor = 0;
    _phase = _lots;
    return work + 1;
  }

  /// A road's measured load, 0..1: the larger of its speed-based congestion
  /// ([congestion], its worst piece over the last complete minute) and its
  /// flow against its lanes at free flow — [volume] vehicles through its
  /// busiest piece, both ways, over the last [kWindowBuckets] minutes,
  /// against [lanes] lanes of [kLaneFlowPerMin] each.
  static double measuredLoad(double congestion, double volume, int lanes) {
    final flow = lanes <= 0
        ? 0.0
        : volume / kWindowBuckets / (lanes * kLaneFlowPerMin);
    final load = congestion > flow ? congestion : flow;
    return load < 0 ? 0.0 : (load > 1 ? 1.0 : load);
  }

  /// Noise and the frontage bonus at every lot, and the built lots' land
  /// value. A lot is sampled only when the loads or the network moved since
  /// the published picture, and only when someone zoned or built on it — a
  /// lot nobody has has no noise to ask about (the routed model's rule,
  /// road_traffic_model.dart:1558-1588).
  int _lotsStep(int budget) {
    final g = _passLg!.graph;
    final b = _noiseBack!;
    final front = _noiseFront;
    final carry = !_loadsMoved && front != null;
    final sampler = _sampler!;
    final city = agents.city;
    var work = 0;
    while (_cursor < g.lotCount && work < budget) {
      final i = _cursor++;
      work += 4;
      final id = g.lotIds[i];
      // As the routed model sees a lot (`CityRoadTraffic._lotState`): a
      // placed building; else nothing on unzoned ground; else zoning, built
      // on once it has grown past its foundations.
      var built = city.parcelBuildings.containsKey(id);
      if (!built) {
        final parcel = city.layout.parcelById(id);
        if (parcel == null || parcel.use == ParcelUse.unzoned) {
          b.raw[i] = double.nan;
          b.noise[i] = 0;
          b.bonus[i] = 0;
          continue;
        }
        built = city.parcelGrownSpec(id, parcel.use) != null;
      }
      double noise;
      final carried = carry ? front.raw[i] : double.nan;
      if (!carried.isNaN) {
        noise = carried;
      } else {
        final before = sampler.work;
        noise = sampler.noiseAt(Vec2(g.lotE[i], g.lotN[i]), b.emission);
        work += sampler.work - before;
      }
      final piece = g.lotPiece[i];
      final bonus = piece < 0 ? 0.0 : g.roadBonus[g.pieceRoad[piece]];
      b.raw[i] = noise;
      b.noise[i] = noise;
      b.bonus[i] = bonus;
      if (built) {
        _lvSum +=
            RoadNoise.baseLandValue + bonus - RoadNoise.noiseWeight * noise;
        _lvCount++;
      }
    }
    if (_cursor < g.lotCount) return work;
    _phase = _done;
    return work + 1;
  }
}

/// One noise picture, sized to a road graph's pieces and lots. The readout
/// holds two: readers have one while its pass fills the other.
class _NoiseFields {
  _NoiseFields(RoadGraph g)
    : graph = g,
      pieceCount = g.pieceCount,
      lotCount = g.lotCount,
      emission = Float64List(g.pieceCount),
      raw = Float64List(g.lotCount),
      noise = Float32List(g.lotCount),
      bonus = Float32List(g.lotCount);

  RoadGraph graph;
  final int pieceCount, lotCount;

  /// Per piece: what it throws at its kerbs.
  final Float64List emission;

  /// Per lot: the noise sampled there, as sampled (NaN where it was not:
  /// nobody zoned or built on it), so a picture that carries it values the
  /// land exactly as the pass that sampled it did.
  final Float64List raw;

  /// Per lot: the noise the readout answers (0 where nobody zoned or built),
  /// and what its frontage adds to its land value — stored as the routed
  /// model stores them (`_Loads.lotNoise`, `lotBonus`).
  final Float32List noise, bonus;

  /// The built lots' land value averaged without the air, and how many.
  double landValueRaw = RoadNoise.baseLandValue;
  int builtLots = 0;
}
