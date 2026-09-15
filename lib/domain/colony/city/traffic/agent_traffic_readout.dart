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
/// - NOISE, from each PIECE's measured load through the routed model's own
///   sampler and formulas (road_noise.dart): a piece throws
///   `roadEmission × RoadNoise.volumeFactor(load)` at its kerbs, as the
///   routed model loads a piece by its own volume against its road's lanes
///   (road_traffic_model.dart `_loadsOnRoads`), where the load is the larger
///   of the piece's speed-based congestion and its flow against its road's
///   lanes at free flow (`AgentTuning.laneFlowPerMin`) — measured vehicles
///   where the routed model has assigned ones, and a quiet piece of a long
///   road as quiet as it is;
/// - LAND VALUE, [RoadNoise.landValue] of that noise, the frontage bonus
///   and the colony's air; and the TAX FACTOR, [RoadNoise.taxFactor] of the
///   built lots' average without the air, exactly 1 until a built lot has
///   been valued (road_traffic_model.dart:566-575, 1905-1918).
///
/// Those come from a PASS of bounded work — the reach fields when their
/// sources or the network have changed, the noise at every lot when the
/// measured loads have — which the agents' own tick runs ([tick], §12.2
/// step 7): begun at a congestion epoch's picture, stepped every sub-step
/// by `AgentTuning.readoutWorkPerStep`. The routed model is not consulted
/// for any of it (C7: nothing assigned is left).
///
/// Every question is a READ: no work, no state, whoever asks and whenever.
/// The views ask when they draw — the road tool's Routes view on the render
/// side, a panel, an inspector — at moments set by the frame rate and by
/// what the player has open. A pass pumped by its readers ran as far as
/// they had asked, on the colony as it stood when they did, and the growth,
/// tax and fire gates reading its answers carried the difference into the
/// colony (§17.4; readout_determinism_test). Driven by the tick, it runs on
/// the same state at the same sub-step in every run fed the same ticks.
///
/// The contract (D47): answers are the last complete picture, and before
/// the first one they punish nothing — no congestion, no routes, every lot
/// reached, no noise, a tax factor of exactly 1, and the land value of a
/// quiet plain street in the colony's air (what the routed model answers
/// before its first pass). A pass's answers are published only at a picture
/// — the sub-step of the congestion epoch that took it — so they change
/// exactly when [passes] moves, never between.
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
import 'traffic_tuning.dart';
import 'vehicle_table.dart';

/// A colony's agents as a [CityTrafficReadout].
class AgentTrafficReadout implements CityTrafficReadout {
  AgentTrafficReadout(this.agents, this.routed)
    : reach = AgentReach(radiusM: agents.city.roadTraffic.tuning.serviceReachM);

  /// Whose measurements and vehicles this reads.
  final CityAgents agents;

  /// What the readout forwards to while the agents are switched off: the
  /// routed model, `CitySim.roadTraffic`.
  final CityTrafficReadout routed;

  /// The reach fields (agent_reach.dart), searched in the readout's pass.
  final AgentReach reach;

  /// Whether the agents answer: they are switched on. Switched off, every
  /// answer is the routed model's.
  bool get _live => agents.enabled;

  /// Whether what the pass published was taken from the agents' tables as
  /// they stand. Switched off and on, the agents start afresh, and until
  /// their first sub-step drops the old picture ([tick]) nothing of it
  /// stands: a read may not drop it itself.
  bool get _current => identical(_tables, agents.buildings);

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
  ///
  /// Gathered afresh at every call, from the vehicle table as it stands: a
  /// read like every other, with nothing kept. A memo kept by picture held
  /// the vehicles of whenever the picture was FIRST asked about, so what a
  /// view drew hung on when some view had asked before it. The Routes view
  /// keys what it drew on [passes] and asks again only when that moves.
  @override
  List<TripRoute> routesThrough(
    String roadId, {
    Set<TripKind>? kinds,
    int limit = 64,
  }) {
    if (!_live) return routed.routesThrough(roadId, kinds: kinds, limit: limit);
    if (!hasRun || limit <= 0) return const [];
    return _collect(roadId, kinds, limit);
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
    return !_current || reach.serviceReach(lotId);
  }

  /// Reach from the stations with safety cover only (D47): a clinic's
  /// ambulance reaching a lot puts no fire out there.
  @override
  bool fireReach(String lotId) {
    if (!_live) return routed.fireReach(lotId);
    return !_current || reach.fireReach(lotId);
  }

  /// Whether goods reach [lotId] from anywhere but its own door.
  @override
  bool deliveryReach(String lotId) {
    if (!_live) return routed.deliveryReach(lotId);
    return !_current || reach.deliveryReach(lotId);
  }

  // ---- Noise, land value, the tax factor (slice 2: measured flow) ---------

  /// The published noise picture of the agents' tables as they stand; null
  /// before one.
  _NoiseFields? get _front => _current ? _noiseFront : null;

  /// Traffic noise at [lotId], 0..1: 0 before a picture, for a lot the
  /// picture does not know, and for one nobody zoned or built on.
  @override
  double noiseOf(String lotId) {
    if (!_live) return routed.noiseOf(lotId);
    final n = _front;
    final i = n?.graph.lotNoOf(lotId);
    return i == null ? 0.0 : n!.noise[i].toDouble();
  }

  /// Land value of [lotId] in the colony's air: a quiet plain street's
  /// before a picture and for a lot it does not know.
  @override
  double landValueOf(String lotId) {
    if (!_live) return routed.landValueOf(lotId);
    final pollution = agents.city.pollution;
    final n = _front;
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
    return _average(agents.city.pollution);
  }

  double _average(double pollution) {
    final raw = _front?.landValueRaw ?? RoadNoise.baseLandValue;
    return (raw - RoadNoise.pollutionPenalty(pollution)).clamp(0.0, 1.0);
  }

  /// The land the ROADS make, on the tax take: [RoadNoise.taxFactor] of the
  /// built lots' average without the colony's air, which already costs it
  /// through happiness and health — exactly 1 until a built lot is valued.
  @override
  double get taxLandValueFactor {
    if (!_live) return routed.taxLandValueFactor;
    final n = _front;
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

  static const int _idle = 0, _loads = 1, _reach = 2, _lots = 3, _done = 4;
  int _phase = _idle;
  int _cursor = 0;
  LaneGraph? _passLg;
  int _passPicture = -1;
  int _loadsPicture = -1;
  bool _loadsMoved = false;
  double _lvSum = 0;
  int _lvCount = 0;

  /// Passes the readout has published (reach and noise together).
  int publishedPasses = 0;

  bool get _passing => _phase != _idle && _phase != _done;

  /// Every buffer the pass keeps from one sub-step to the next, by name into
  /// [into], for the allocation test (§15.2) — the reach fields' and the two
  /// noise pictures', which change places at every publish: the same pair,
  /// never a new one, while the network keeps its pieces and lots.
  void collectBuffers(Map<String, Object> into, String name) {
    reach.collectBuffers(into, '$name.reach');
    void noise(String k, _NoiseFields? f) {
      if (f == null) return;
      into['$name.$k.emission'] = f.emission;
      into['$name.$k.raw'] = f.raw;
      into['$name.$k.noise'] = f.noise;
      into['$name.$k.bonus'] = f.bonus;
    }

    noise('front', _noiseFront);
    noise('back', _noiseBack);
  }

  /// The readout's share of one agent sub-step (§12.2 step 7), run by the
  /// agents after the statistics have rolled up; [picture] when this
  /// sub-step's congestion epoch took one. Nothing else does the pass's
  /// work: a question never does.
  ///
  /// At a picture a finished pass is published, and a new one is begun on
  /// the loads just pictured if none is in flight. Every sub-step the pass
  /// in flight does `AgentTuning.readoutWorkPerStep` of work; one that
  /// finishes at a picture's own sub-step is published at once, since that
  /// is still the picture, and one that finishes on any other waits for the
  /// next: answers change when [passes] does. A pass the network changed
  /// under is dropped — what it gathered was the old network's — and begun
  /// again at the next picture, which is the new network's.
  void tick({required bool picture}) {
    final tables = agents.buildings;
    if (!identical(tables, _tables)) {
      _tables = tables;
      _resetPass();
    }
    final lg = agents.laneGraph;
    if (tables == null || lg == null) return;
    if (_passing && !identical(lg, _passLg)) _abortPass();
    if (picture) {
      if (_phase == _done) _publish();
      if (_phase == _idle && agents.stats.hasRun) _begin(lg, tables);
    }
    if (!_passing) return;
    _step(AgentTuning.readoutWorkPerStep);
    if (picture && _phase == _done) _publish();
  }

  /// Runs a pass on the latest picture to its end and publishes it now,
  /// whatever the budget: for tests that read the answers of the picture
  /// they have just taken. A pass in flight on that picture is finished; one
  /// on an older picture, or on another network, is begun again.
  void settle() {
    final tables = agents.buildings;
    if (!identical(tables, _tables)) {
      _tables = tables;
      _resetPass();
    }
    final lg = agents.laneGraph;
    if (tables == null || lg == null || !agents.stats.hasRun) return;
    if (_phase == _idle ||
        !identical(lg, _passLg) ||
        _passPicture != agents.pictures) {
      _begin(lg, tables);
    }
    while (_passing) {
      _step(1 << 30);
    }
    _publish();
  }

  void _resetPass() {
    reach.reset();
    _noiseFront = null;
    _noiseBack = null;
    _sampler = null;
    _abortPass();
  }

  void _abortPass() {
    reach.abort();
    _phase = _idle;
    _passLg = null;
  }

  void _begin(LaneGraph lg, BuildingTable tables) {
    _passLg = lg;
    _passPicture = agents.pictures;
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
    _loadsPicture = agents.stats.pictures;
    _loadsMoved = false;
    _lvSum = 0;
    _lvCount = 0;
    _phase = _loads;
  }

  void _step(int budget) {
    var work = 0;
    while (work < budget && _phase != _idle && _phase != _done) {
      final left = budget - work;
      switch (_phase) {
        case _loads:
          work += _loadsStep(left);
        case _reach:
          work += reach.step(left);
          if (!reach.passing) _phase = _lots;
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

  /// Every piece's emission from its own measured load in the picture the
  /// pass began at: `roadEmission × volumeFactor(load)`, the load from the
  /// piece's congestion and flow ([measuredLoad]) against its road's lanes —
  /// the routed model's piece rule (`_loadsOnRoads`), measured instead of
  /// assigned. The first phase of a pass, so it reads one picture: the
  /// statistics write theirs again at the next epoch, and loads begun on one
  /// and read on another would mix two. Should the next picture come first
  /// all the same (a network too big for a sub-step's budget), the loads
  /// start again on it.
  int _loadsStep(int budget) {
    final g = _passLg!.graph;
    final b = _noiseBack!;
    final stats = agents.stats;
    if (stats.pictures != _loadsPicture) {
      _loadsPicture = stats.pictures;
      _cursor = 0;
      _loadsMoved = false;
    }
    final pic = stats.pictureGraph;
    final cong = stats.pieceCongestion, flow = stats.pieceFlowPerMin;
    // Always the pass's own network (a pass begins at a picture on it, and
    // is dropped when the network changes); a picture on any other would
    // index other pieces, and loads nothing.
    final pictured = pic != null &&
        cong.length == g.pieceCount &&
        (identical(pic, g) || g.sharesStructureWith(pic));
    final aligned = _alignedWithFront(g);
    final front = _noiseFront;
    var work = 0;
    while (_cursor < g.roadCount && work < budget) {
      final r = _cursor++;
      final emission = g.roadEmission[r];
      final lanes = g.roadLanes[r];
      for (var p = g.roadFirstPiece[r]; p < g.roadFirstPiece[r + 1]; p++) {
        final load = pictured
            ? measuredLoad(cong[p].toDouble(), flow[p].toDouble(), lanes)
            : 0.0;
        final e = emission * RoadNoise.volumeFactor(load);
        b.emission[p] = e;
        if (!aligned || front!.emission[p] != e) _loadsMoved = true;
      }
      work += 2 + 2 * (g.roadFirstPiece[r + 1] - g.roadFirstPiece[r]);
    }
    if (_cursor < g.roadCount) return work;
    if (!aligned) _loadsMoved = true;
    _cursor = 0;
    _phase = _reach;
    return work + 1;
  }

  /// A piece's measured load, 0..1: the larger of its speed-based
  /// [congestion] (the traffic both ways along it over the last complete
  /// minute) and its flow against its road's lanes at free flow —
  /// [flowPerMin] vehicles a minute through it, both ways, against [lanes]
  /// lanes of `AgentTuning.laneFlowPerMin` each (§12.3).
  static double measuredLoad(double congestion, double flowPerMin, int lanes) {
    final flow = lanes <= 0
        ? 0.0
        : flowPerMin / (lanes * AgentTuning.laneFlowPerMin);
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
    // The published picture's samples, when they may be carried: a nullable
    // local tested at every lot. Never the picture promoted through a
    // boolean (`carry = front != null && …; carry ? front.raw[i] : …`): this
    // SDK's AOT build (dart 3.13.0-264.0.dev) read through null there on a
    // colony's first pass, before any picture was published — a native
    // access violation in profile and release builds, 25–35 s into the
    // City Builder, that no JIT test sees (tool/aot_traffic_smoke.dart).
    final Float64List? carried = _loadsMoved ? null : _noiseFront?.raw;
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
      final kept = carried != null ? carried[i] : double.nan;
      if (!kept.isNaN) {
        noise = kept;
      } else {
        final before = sampler.work;
        noise = sampler.noiseAtEN(g.lotE[i], g.lotN[i], b.emission);
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
