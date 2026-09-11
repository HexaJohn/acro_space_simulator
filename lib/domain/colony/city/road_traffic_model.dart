// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Where the colony's traffic goes, and what it leaves behind.
///
/// Trips start at the built lots — commuters from homes to jobs, shoppers
/// from homes to shops, goods from industry and warehouses to the shops and
/// works that need them, fire engines and ambulances from their stations
/// to every lot — and each is sent, all or nothing, down the QUICKEST route
/// over the road graph: speed limits, and the seconds lost at a light, a
/// stop sign or a roundabout. What piles up is congestion on every road,
/// the routes through any road the player clicks, whether a service
/// vehicle can reach a lot at all (a one-way street it may not go against
/// can put a house four kilometres from the fire station across the road),
/// whether goods can reach a shop, and the noise and land value that come
/// with the traffic.
///
/// A twenty-mile city has tens of thousands of roads, so none of this runs
/// in one go. A PASS is sliced into [CityTrafficModel.step]s of bounded
/// work, the owner runs one step a tick, and a pass is started when the
/// roads or the buildings change and otherwise about once a colony day.
/// The caps that keep a step small: lots are aggregated per road stretch
/// before anything is routed, every route search is bounded in time and in
/// nodes, and a big city's origins are sampled — a spatially even stride of
/// them per pass, a different stride each pass, the loads blended — so a
/// pass costs what the sample is, not what the city is. Readers always see
/// the last COMPLETE pass.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'city_building_spec.dart';
import 'city_sim.dart';
import 'parcel.dart';
import 'road_catalog.dart';
import 'road_graph.dart';
import 'road_noise.dart';

/// Why a vehicle is on the road. The Traffic Routes view filters by it.
enum TripKind { commuter, shopper, goods, service }

/// One routed trip, as the Traffic Routes view draws it.
class TripRoute {
  const TripRoute({
    required this.kind,
    required this.weight,
    required this.roadIds,
    required this.polyline,
  });

  final TripKind kind;

  /// Vehicles per peak on it (scaled, in a sampled city, to the whole).
  final double weight;

  /// The roads it uses, in order, each once per visit.
  final List<String> roadIds;

  /// Its path, colony-local metres, from where it leaves its origin's road
  /// to where it stops on its destination's.
  final List<Vec2> polyline;
}

/// What stands on a lot, as the model counts it.
class TrafficLot {
  const TrafficLot(this.spec, {this.occupancy = 1.0});

  /// A zoned lot with nothing on it yet: no trips, but its noise matters
  /// to whether a home grows there.
  const TrafficLot.bare()
      : spec = null,
        occupancy = 0;

  final CityBuildingSpec? spec;

  /// How full it is, 0..1 — a grown building fills over time.
  final double occupancy;

  bool get built => spec != null;
}

/// Looks a lot up by id: its building, bare zoning, or null for a lot the
/// model can ignore (unzoned and empty).
typedef TrafficLotSource = TrafficLot? Function(String lotId);

/// What a building does to the traffic.
class TrafficRole {
  const TrafficRole._();

  /// Stores that ship goods though nobody works there.
  static const Set<String> goodsStoreTypes = {
    'warehouse',
    'silo2',
    'freightyard',
    'spaceport',
  };

  /// A shop: shoppers go there.
  static bool isShop(CityBuildingSpec s) => s.group == 'com';

  /// Industry, zoned or hand-placed: it makes goods.
  static bool isIndustry(CityBuildingSpec s) =>
      s.group == 'ind' || s.group == 'res-x';

  /// Sends lorries out: industry, warehouses, the spaceport.
  static bool shipsGoods(CityBuildingSpec s) =>
      isIndustry(s) || goodsStoreTypes.contains(s.type);

  /// Commerce and industry: they need goods delivered.
  static bool needsDeliveries(CityBuildingSpec s) =>
      s.group == 'com' || s.group == 'ind';

  /// A station whose vehicles answer calls: police, fire, ambulance.
  static bool sendsServiceVehicles(CityBuildingSpec s) =>
      (s.services['safety'] ?? 0) > 0 || (s.services['health'] ?? 0) > 0;
}

/// The model's numbers.
class TrafficTuning {
  const TrafficTuning({
    this.commuteTripsPerResident = 0.5,
    this.shopTripsPerResident = 0.2,
    this.goodsTripsPerJob = 0.2,
    this.goodsTripsPerStore = 5,
    this.serviceTripsPerStation = 4,
    this.outsideShopShare = 0.1,
    this.decaySec = const [900.0, 420.0, 1200.0, 600.0],
    this.laneCapacity = 600,
    this.dirtLaneCapacity = 160,
    this.serviceReachM = 4000,
    this.maxTripSec = 1500,
    this.maxSettled = 3000,
    this.maxOriginsPerPass = 1500,
    this.workPerStep = 60000,
    this.routesPerOrigin = 2,
    this.maxRouteEdges = 300000,
    this.cadenceSec,
    this.minRepassSec = 2,
  });

  /// Vehicles per peak each resident puts on the road to work, and to the
  /// shops.
  final double commuteTripsPerResident, shopTripsPerResident;

  /// Lorries per peak per industrial job, and per warehouse (which has no
  /// jobs to count).
  final double goodsTripsPerJob, goodsTripsPerStore;

  /// Vehicles per peak each police, fire or ambulance station sends out.
  final double serviceTripsPerStation;

  /// Shop jobs per resident a colony needs before its people stop driving
  /// OUT of it to shop.
  final double outsideShopShare;

  /// How far each [TripKind] will go: a destination [decaySec] further
  /// away is e times less likely (the gravity model's distance decay).
  final List<double> decaySec;

  /// Vehicles per peak one lane carries before the road is full: a paved
  /// lane, and a dirt one — the first upgrade pressure a colony feels.
  final double laneCapacity, dirtLaneCapacity;

  /// Route metres within which a fire engine or ambulance counts as
  /// reaching a lot.
  final double serviceReachM;

  /// Longest trip anyone makes, seconds, and the most junctions one route
  /// search may settle — the bounds that keep a search local in a big city.
  final double maxTripSec;
  final int maxSettled;

  /// Origin stretches routed per pass; a bigger city is sampled.
  final int maxOriginsPerPass;

  /// Work units one [CityTrafficModel.step] does (a node settled, an edge
  /// relaxed or priced, a lot, a road segment looked at for noise). Every
  /// stage of a pass resumes where the last step stopped, so a step
  /// overruns this by at most one junction's edges, one lot's noise probe,
  /// or the routes it keeps for the view as a kind of trip finishes (at
  /// most [routesPerOrigin] chains of at most [maxSettled] edges).
  final int workPerStep;

  /// Routes kept per origin and kind for the Traffic Routes view, and the
  /// most route edges kept in all.
  final int routesPerOrigin, maxRouteEdges;

  /// Colony seconds between passes when nothing changes; null for one
  /// colony day.
  final double? cadenceSec;

  /// Colony seconds a change of buildings waits after the last pass began
  /// before it starts another — a growing city changes every tick.
  final double minRepassSec;
}

/// Routed traffic over a [RoadGraph]. See the library comment.
class CityTrafficModel {
  CityTrafficModel(RoadGraph graph, {this.tuning = const TrafficTuning()})
      : _graph = graph,
        _search = _Search(graph.nodeCount);

  final TrafficTuning tuning;

  RoadGraph _graph;
  _Search _search;

  /// The graph passes run on — which may be newer than the last published
  /// pass's.
  RoadGraph get graph => _graph;

  _Results? _pub;
  _Phase _phase = _Phase.idle;
  TrafficLotSource? _source;

  /// Passes completed.
  int passes = 0;

  /// Work units the last [step] did.
  int lastStepWork = 0;

  /// Passes on this graph, for the origin stride.
  int _stride = 0;

  bool get passing => _phase != _Phase.idle;

  /// Whether a pass has been published.
  bool get hasRun => _pub != null;

  /// Move to [g]: a pass in flight is dropped (its lots and roads are the
  /// old ones), the last published results stay readable until the next
  /// pass on [g] replaces them.
  void useGraph(RoadGraph g) {
    if (identical(g, _graph)) return;
    _graph = g;
    _search = _Search(g.nodeCount);
    _phase = _Phase.idle;
    _stride = 0;
    _roadEmission = null;
    _roadBonus = null;
  }

  /// Start a pass over the lots [source] describes. A pass in flight is
  /// dropped.
  void beginPass(TrafficLotSource source) {
    final g = _graph;
    _source = source;
    _phase = _Phase.gather;
    _lotCursor = 0;
    _lotFlags = Uint8List(g.lotCount);
    _groupOf.clear();
    _gPiece.clear();
    _gMask.clear();
    for (var k = 0; k < 4; k++) {
      _gProdL[k].clear();
      _gAttrL[k].clear();
    }
    _svcLots.clear();
    _goodsLots.clear();
    _resTotal = _jobsTotal = _shopTotal = 0;
    _goodsDemand = _goodsSupply = 0;
  }

  /// Run a whole pass now: for tests and small tools.
  void runPass(TrafficLotSource source) {
    beginPass(source);
    while (passing) {
      step(maxWork: 1 << 30);
    }
  }

  /// Do up to [maxWork] (default [TrafficTuning.workPerStep]) units of the
  /// pass in flight. True when this step published the pass.
  bool step({int? maxWork}) {
    if (_phase == _Phase.idle) {
      lastStepWork = 0;
      return false;
    }
    final budget = maxWork ?? tuning.workPerStep;
    var work = 0;
    while (work < budget && _phase != _Phase.idle) {
      switch (_phase) {
        case _Phase.gather:
          work += _gather(budget - work);
        case _Phase.service:
          work += _field(budget - work, service: true);
        case _Phase.goods:
          work += _field(budget - work, service: false);
        case _Phase.assign:
          work += _assign(budget - work);
        case _Phase.noise:
          work += _noise(budget - work);
        case _Phase.idle:
          break;
      }
    }
    lastStepWork = work;
    return _phase == _Phase.idle;
  }

  // ---- Answers (from the last complete pass) --------------------------------

  /// The worst road's load against its lanes, 0..1 — the colony's
  /// congestion, as the commute penalty reads it. 0 before a pass.
  double get peakCongestion => (_pub?.peak ?? 0).clamp(0.0, 1.0);

  /// Congestion averaged over the vehicles: what a typical trip meets.
  double get averageCongestion => _pub?.average ?? 0;

  /// Load over capacity on [roadId] (its worst stretch), 0 for a road the
  /// last pass did not know.
  double congestionOf(String roadId) {
    final p = _pub;
    final r = p?.graph.roadNoOf(roadId);
    return r == null ? 0 : p!.roadCong[r];
  }

  /// Vehicles per peak on [roadId] (its busiest stretch).
  double volumeOf(String roadId) {
    final p = _pub;
    final r = p?.graph.roadNoOf(roadId);
    return r == null ? 0 : p!.roadVol[r];
  }

  /// Whether the kept route sample was cut short by
  /// [TrafficTuning.maxRouteEdges].
  bool get routesTruncated => _pub?.routesTruncated ?? false;

  /// The trips that use [roadId], heaviest first — at most [limit] of
  /// them, of [kinds] (all when null). In a sampled city these are the
  /// last pass's sample, weighted up to the whole.
  List<TripRoute> routesThrough(String roadId,
      {Set<TripKind>? kinds, int limit = 64}) {
    final p = _pub;
    if (p == null) return const [];
    final g = p.graph;
    final r = g.roadNoOf(roadId);
    if (r == null) return const [];
    final hits = <_Route>[];
    for (final route in p.routes) {
      if (kinds != null && !kinds.contains(route.kind)) continue;
      var through = g.pieceRoad[route.originPiece] == r ||
          g.pieceRoad[g.edgePiece[route.destEdge]] == r;
      for (var k = 0; !through && k < route.edges.length; k++) {
        if (g.pieceRoad[g.edgePiece[route.edges[k]]] == r) through = true;
      }
      if (through) hits.add(route);
    }
    hits.sort((a, b) => b.weight.compareTo(a.weight));
    return [for (final h in hits.take(limit)) _tripRoute(g, h)];
  }

  /// Route metres from the nearest police, fire or ambulance station to
  /// [lotId], over the one-way streets the way they run — null when none
  /// is within [TrafficTuning.serviceReachM] (or before a pass).
  double? serviceDistanceTo(String lotId) {
    final p = _pub;
    if (p == null) return null;
    final d = p.reachDistance(lotId, p.svcDist, p.svcOnPiece);
    return d <= tuning.serviceReachM ? d : null;
  }

  /// Whether a service vehicle reaches [lotId]. True before the first pass
  /// and for a lot the last pass did not know — a lot is not punished for
  /// the model not having looked yet.
  bool serviceReach(String lotId) {
    final p = _pub;
    if (p == null || p.graph.lotNoOf(lotId) == null) return true;
    return serviceDistanceTo(lotId) != null;
  }

  /// Whether goods can reach [lotId] — from a works, a warehouse, the
  /// spaceport, or from off-world through the landing site — over the
  /// one-way streets the way they run. True before the first pass and for
  /// a lot the last pass did not know.
  bool deliveryReach(String lotId) {
    final p = _pub;
    if (p == null || p.graph.lotNoOf(lotId) == null) return true;
    return p.reachDistance(lotId, p.goodsDist, p.goodsOnPiece).isFinite;
  }

  /// Traffic noise at [lotId], 0..1 (0 before a pass).
  double noiseOf(String lotId) {
    final p = _pub;
    final i = p?.graph.lotNoOf(lotId);
    return i == null ? 0 : p!.lotNoise[i];
  }

  /// Land value of [lotId], 0..1, in air of [pollution].
  double landValueOf(String lotId, {double pollution = 0}) {
    final p = _pub;
    final i = p?.graph.lotNoOf(lotId);
    if (i == null) return RoadNoise.landValue(noise: 0, pollution: pollution);
    return RoadNoise.landValue(
        noise: p!.lotNoise[i], bonus: p.lotBonus[i], pollution: pollution);
  }

  /// Land value averaged over the built lots, in air of [pollution].
  double averageLandValue({double pollution = 0}) {
    final raw = _pub?.landValueRaw ?? RoadNoise.baseLandValue;
    return (raw - RoadNoise.pollutionPenalty(pollution)).clamp(0.0, 1.0);
  }

  // ---- The pass ------------------------------------------------------------

  // Gather: lots aggregated into GROUPS — one per (piece, access mask), so
  // the lots a road stretch serves are routed once, not one by one.
  int _lotCursor = 0;
  Uint8List _lotFlags = Uint8List(0);
  static const int _flagNoise = 1, _flagBuilt = 2;
  final Map<int, int> _groupOf = {};
  final List<int> _gPiece = [], _gMask = [];
  final List<List<double>> _gProdL = [[], [], [], []];
  final List<List<double>> _gAttrL = [[], [], [], []];
  final List<int> _svcLots = [], _goodsLots = [];
  double _resTotal = 0, _jobsTotal = 0, _shopTotal = 0;
  double _goodsDemand = 0, _goodsSupply = 0;

  // Groups frozen for routing.
  late Int32List _grpPiece, _grpMask, _pieceGroups;
  late List<Float64List> _prod, _attr;

  // Fields.
  Float64List _svcDist = Float64List(0), _goodsDist = Float64List(0);
  Map<int, double> _svcOnPiece = {}, _goodsOnPiece = {};

  // Assignment.
  List<int> _sampled = const [];
  int _assignCursor = 0;
  bool _originActive = false;
  int _originGroup = -1;

  // Where the origin in hand is — searching, pricing its destinations,
  // weighing and sharing one kind of trip at a time, the flows onto the
  // tree — and where in that stage: each resumes from [_cursor].
  _Stage _stage = _Stage.search;
  int _cursor = 0;
  int _kind = 0;
  double _sumW = 0;
  List<int> _topG = const [];
  List<double> _topF = const [];

  double _totalProd = 0, _sampledProd = 0;
  int _strideOf = 1;
  late Float64List _passVol, _gBest, _gFlow, _gW, _nodeFlow;
  late Int32List _gEdge;
  final _IntBuf _gTouched = _IntBuf();
  List<_Route> _routes = [];
  int _routeEdges = 0;
  bool _routesCut = false;

  // Blended loads, for publishing.
  late Float64List _newVol, _newCong, _roadVol, _roadCong;
  double _peak = 0, _average = 0;

  // Noise.
  RoadNoiseSampler? _sampler;
  late Float64List _emission;
  late Float32List _lotNoise, _lotBonus;
  Float64List? _roadEmission, _roadBonus;
  int _noiseCursor = 0;
  double _lvSum = 0;
  int _lvCount = 0;

  int _groupFor(int piece, int mask) {
    final key = piece * 4 + mask;
    final g = _groupOf[key];
    if (g != null) return g;
    final ng = _gPiece.length;
    _groupOf[key] = ng;
    _gPiece.add(piece);
    _gMask.add(mask);
    for (var k = 0; k < 4; k++) {
      _gProdL[k].add(0);
      _gAttrL[k].add(0);
    }
    return ng;
  }

  /// A lot's look-up and classification, in work units: a few map probes.
  static const int _lotWork = 6;

  int _gather(int budget) {
    final g = _graph;
    final src = _source!;
    final t = tuning;
    var work = 0;
    while (_lotCursor < g.lotCount && work < budget) {
      final i = _lotCursor++;
      work += _lotWork;
      final lot = src(g.lotIds[i]);
      if (lot == null) continue;
      _lotFlags[i] = _flagNoise;
      final spec = lot.spec;
      if (spec == null) continue;
      _lotFlags[i] |= _flagBuilt;
      final piece = g.lotPiece[i];
      // A lot no road reaches puts nobody on the roads.
      if (piece < 0) continue;
      final occ = lot.occupancy.clamp(0.0, 1.0);
      final residents = spec.housing * occ;
      final jobs = spec.jobs * occ;
      final gi = _groupFor(piece, g.lotDirs[i]);
      _resTotal += residents;
      _jobsTotal += jobs;
      _gProdL[0][gi] += residents * t.commuteTripsPerResident;
      _gProdL[1][gi] += residents * t.shopTripsPerResident;
      _gAttrL[0][gi] += jobs;
      if (TrafficRole.isShop(spec)) {
        final a = math.max(1.0, jobs);
        _gAttrL[1][gi] += a;
        _shopTotal += a;
      }
      if (TrafficRole.shipsGoods(spec)) {
        final trips = jobs * t.goodsTripsPerJob +
            (spec.storageBonus > 0 ? t.goodsTripsPerStore : 0);
        _gProdL[2][gi] += trips;
        _goodsSupply += trips;
        _goodsLots.add(i);
      }
      if (TrafficRole.needsDeliveries(spec)) {
        final a = math.max(1.0, jobs);
        _gAttrL[2][gi] += a;
        _goodsDemand += a * t.goodsTripsPerJob;
      }
      if (TrafficRole.sendsServiceVehicles(spec)) {
        _gProdL[3][gi] += t.serviceTripsPerStation;
        _svcLots.add(i);
      }
      _gAttrL[3][gi] += 1;
    }
    if (_lotCursor >= g.lotCount) {
      _finishGather();
      work++;
    }
    return work;
  }

  /// The landing site joins as a group of its own — the colony's door to
  /// the world: where people work and shop when the colony has too few
  /// jobs and shops, where the goods it does not make come in from, and
  /// where the goods it has too many of go.
  void _finishGather() {
    final g = _graph;
    final t = tuning;
    if (g.rootPiece >= 0) {
      final gi = _groupFor(g.rootPiece, g.rootDirs);
      _gAttrL[0][gi] += math.max(0.0, _resTotal - _jobsTotal);
      _gAttrL[1][gi] +=
          math.max(0.0, t.outsideShopShare * _resTotal - _shopTotal);
      _gProdL[2][gi] += math.max(0.0, _goodsDemand - _goodsSupply);
      if (t.goodsTripsPerJob > 0) {
        _gAttrL[2][gi] +=
            math.max(0.0, _goodsSupply - _goodsDemand) / t.goodsTripsPerJob;
      }
    }
    final nG = _gPiece.length;
    _grpPiece = Int32List.fromList(_gPiece);
    _grpMask = Int32List.fromList(_gMask);
    _prod = [for (var k = 0; k < 4; k++) Float64List.fromList(_gProdL[k])];
    _attr = [for (var k = 0; k < 4; k++) Float64List.fromList(_gAttrL[k])];
    _pieceGroups = Int32List(g.pieceCount * 3)
      ..fillRange(0, g.pieceCount * 3, -1);
    for (var gi = 0; gi < nG; gi++) {
      _pieceGroups[_grpPiece[gi] * 3 + _grpMask[gi] - 1] = gi;
    }
    _beginField(service: true);
  }

  // ---- Reach fields: distance from the nearest service station (bounded),
  // and from the nearest source of goods (unbounded), over directed edges.

  void _beginField({required bool service}) {
    final g = _graph;
    final s = _search;
    s.clear();
    s.bound = service ? tuning.serviceReachM : double.infinity;
    s.maxSettled = 1 << 30;
    final onPiece = <int, double>{};
    for (final i in service ? _svcLots : _goodsLots) {
      _seedDistance(g.lotPiece[i], g.lotS[i], g.lotDirs[i], onPiece);
    }
    if (!service && g.rootPiece >= 0) {
      _seedDistance(g.rootPiece, g.rootS, g.rootDirs, onPiece);
    }
    if (service) {
      _svcOnPiece = onPiece;
      _phase = _Phase.service;
    } else {
      _goodsOnPiece = onPiece;
      _phase = _Phase.goods;
    }
  }

  /// Seed the search with a vehicle leaving arc [s] of [piece] in the
  /// directions [mask] allows: it reaches the node ahead, and passes every
  /// lot ahead of it on its own piece ([onPiece]: the smallest travel
  /// coordinate a source sits at, per piece and direction).
  void _seedDistance(int piece, double s, int mask, Map<int, double> onPiece) {
    final g = _graph;
    if (mask & RoadGraph.forwardBit != 0 && g.pieceFwdEdge[piece] >= 0) {
      _search.seed(g.pieceTo[piece], g.pieceS1[piece] - s);
      final c = s - g.pieceS0[piece];
      final k = piece * 2;
      final prev = onPiece[k];
      if (prev == null || c < prev) onPiece[k] = c;
    }
    if (mask & RoadGraph.backwardBit != 0 && g.pieceBwdEdge[piece] >= 0) {
      _search.seed(g.pieceFrom[piece], s - g.pieceS0[piece]);
      final c = g.pieceS1[piece] - s;
      final k = piece * 2 + 1;
      final prev = onPiece[k];
      if (prev == null || c < prev) onPiece[k] = c;
    }
  }

  int _field(int budget, {required bool service}) {
    final g = _graph;
    final work = _search.run(g, g.edgeLength, budget);
    if (!_search.done) return work;
    final dist = Float64List(g.nodeCount)
      ..fillRange(0, g.nodeCount, double.infinity);
    final touched = _search.touched;
    for (var k = 0; k < touched.length; k++) {
      final n = touched[k];
      if (_search.settled[n] == 1) dist[n] = _search.dist[n];
    }
    if (service) {
      _svcDist = dist;
      _beginField(service: false);
    } else {
      _goodsDist = dist;
      _beginAssign();
    }
    return work + 1;
  }

  // ---- Assignment ----------------------------------------------------------

  void _beginAssign() {
    final g = _graph;
    final nG = _grpPiece.length;
    final origins = <int>[];
    _totalProd = 0;
    for (var gi = 0; gi < nG; gi++) {
      final p = _prod[0][gi] + _prod[1][gi] + _prod[2][gi] + _prod[3][gi];
      if (p <= 0) continue;
      origins.add(gi);
      _totalProd += p;
    }
    // A stride through the origins, a different offset each pass: every
    // pass samples the whole city evenly, and successive passes cover it.
    _strideOf = math.max(1, (origins.length / tuning.maxOriginsPerPass).ceil());
    final offset = _stride % _strideOf;
    _stride++;
    _sampled = [
      for (var k = offset; k < origins.length; k += _strideOf) origins[k]
    ];
    _sampledProd = 0;
    for (final gi in _sampled) {
      _sampledProd += _prod[0][gi] + _prod[1][gi] + _prod[2][gi] + _prod[3][gi];
    }
    _assignCursor = 0;
    _originActive = false;
    _passVol = Float64List(g.pieceCount);
    _gBest = Float64List(nG)..fillRange(0, nG, double.infinity);
    _gFlow = Float64List(nG);
    _gW = Float64List(nG);
    _gEdge = Int32List(nG);
    _gTouched.clear();
    _nodeFlow = Float64List(g.nodeCount);
    _routes = [];
    _routeEdges = 0;
    _routesCut = false;
    _topG = List<int>.filled(tuning.routesPerOrigin, -1);
    _topF = List<double>.filled(tuning.routesPerOrigin, 0);
    _search.bound = tuning.maxTripSec;
    _search.maxSettled = tuning.maxSettled;
    _phase = _Phase.assign;
  }

  int _assign(int budget) {
    final g = _graph;
    var work = 0;
    while (work < budget) {
      if (!_originActive) {
        if (_assignCursor >= _sampled.length) {
          _finishAssign();
          return work + 1;
        }
        _startOrigin(_sampled[_assignCursor]);
        _originActive = true;
        work++;
      }
      switch (_stage) {
        case _Stage.search:
          work += _search.run(g, g.edgeTime, budget - work);
          if (!_search.done) return work;
          _beginPricing();
        case _Stage.price:
          work += _price(budget - work);
        case _Stage.weigh:
          work += _weigh(budget - work);
        case _Stage.share:
          work += _share(budget - work);
        case _Stage.arrive:
          work += _arrive(budget - work);
        case _Stage.tree:
          work += _tree(budget - work);
      }
    }
    return work;
  }

  double _halfDrive(int piece) {
    final g = _graph;
    return 0.5 * g.pieceLength(piece) / g.roadSpeedMps[g.pieceRoad[piece]];
  }

  /// Seed a route search from the middle of origin group [gi]'s piece, in
  /// the directions its lots may leave by.
  void _startOrigin(int gi) {
    final g = _graph;
    _originGroup = gi;
    _stage = _Stage.search;
    _search.clear();
    final piece = _grpPiece[gi];
    final mask = _grpMask[gi];
    final half = _halfDrive(piece);
    final fe = g.pieceFwdEdge[piece], be = g.pieceBwdEdge[piece];
    if (mask & RoadGraph.forwardBit != 0 && fe >= 0) {
      _search.seed(g.pieceTo[piece], g.edgeTime[fe] - half);
    }
    if (mask & RoadGraph.backwardBit != 0 && be >= 0) {
      _search.seed(g.pieceFrom[piece], g.edgeTime[be] - half);
    }
  }

  // The search from one origin is done. What follows prices every
  // destination group it reached (arriving at the middle of its piece, by a
  // direction its lots accept), shares each kind's trips over them by the
  // gravity rule, keeps the heaviest routes, and puts the flows on the
  // shortest-path tree — each stage resumable, so no step does more than
  // its budget however far the search reached.

  void _beginPricing() {
    final gi = _originGroup;
    final originPiece = _grpPiece[gi];
    final originMask = _grpMask[gi];
    // Destinations on the origin's own stretch that it can drive straight
    // to — same street, a direction both accept — cost a nominal half
    // stretch and never touch a junction (edge -1: no route through the
    // network). The rest of that stretch is reached round the network like
    // anywhere else.
    final originHalf = _halfDrive(originPiece);
    for (var m = 1; m <= 3; m++) {
      if (m & originMask == 0) continue;
      final dg = _pieceGroups[originPiece * 3 + m - 1];
      if (dg < 0) continue;
      _gTouched.add(dg);
      _gBest[dg] = originHalf;
      _gEdge[dg] = -1;
    }
    _stage = _Stage.price;
    _cursor = 0;
  }

  /// Price the destinations: every edge out of every settled node arrives
  /// on a piece, and the groups there that accept that direction are
  /// reached for the node's time plus half the piece.
  int _price(int budget) {
    final g = _graph;
    final s = _search;
    final order = s.order;
    var work = 0;
    while (_cursor < order.length && work < budget) {
      final u = order[_cursor++];
      final du = s.dist[u];
      work++;
      for (var j = g.outStart[u]; j < g.outStart[u + 1]; j++) {
        work++;
        final e = g.outEdges[j];
        final q = g.edgePiece[e];
        final bit = g.edgeForward[e] == 1
            ? RoadGraph.forwardBit
            : RoadGraph.backwardBit;
        final cost = du + _halfDrive(q);
        for (var m = 1; m <= 3; m++) {
          if (m & bit == 0) continue;
          final dg = _pieceGroups[q * 3 + m - 1];
          if (dg < 0) continue;
          if (cost < _gBest[dg]) {
            if (_gBest[dg] == double.infinity) _gTouched.add(dg);
            _gBest[dg] = cost;
            _gEdge[dg] = e;
          }
        }
      }
    }
    if (_cursor >= order.length) _nextKind(0);
    return work;
  }

  /// On to the first kind from [from] this origin makes trips of, or to
  /// the flows when none is left.
  void _nextKind(int from) {
    _cursor = 0;
    _sumW = 0;
    for (var k = from; k < 4; k++) {
      if (_prod[k][_originGroup] > 0) {
        _kind = k;
        _stage = _Stage.weigh;
        return;
      }
    }
    _stage = _Stage.arrive;
  }

  /// The gravity weight of every destination for the kind in hand: what
  /// it attracts, discounted by how far away it is.
  int _weigh(int budget) {
    final attr = _attr[_kind];
    final decay = tuning.decaySec[_kind];
    var work = 0;
    while (_cursor < _gTouched.length && work < budget) {
      final dg = _gTouched[_cursor++];
      work++;
      final a = attr[dg];
      final w = a > 0 ? a * math.exp(-_gBest[dg] / decay) : 0.0;
      _gW[dg] = w;
      _sumW += w;
    }
    if (_cursor >= _gTouched.length) {
      if (_sumW > 0) {
        _stage = _Stage.share;
        _cursor = 0;
        _topG.fillRange(0, _topG.length, -1);
        _topF.fillRange(0, _topF.length, 0);
      } else {
        _nextKind(_kind + 1);
      }
    }
    return work;
  }

  /// The kind's trips shared by weight; the heaviest destinations noted
  /// for the route view.
  int _share(int budget) {
    final prod = _prod[_kind][_originGroup];
    final keep = _topG.length;
    var work = 0;
    while (_cursor < _gTouched.length && work < budget) {
      final dg = _gTouched[_cursor++];
      work++;
      final w = _gW[dg];
      if (w <= 0) continue;
      final f = prod * w / _sumW;
      _gFlow[dg] += f;
      // A trip that never leaves its own stretch has no route to show.
      if (_gEdge[dg] < 0) continue;
      for (var t = 0; t < keep; t++) {
        if (f > _topF[t]) {
          for (var m = keep - 1; m > t; m--) {
            _topF[m] = _topF[m - 1];
            _topG[m] = _topG[m - 1];
          }
          _topF[t] = f;
          _topG[t] = dg;
          break;
        }
      }
    }
    if (_cursor >= _gTouched.length) {
      for (var t = 0; t < keep; t++) {
        if (_topG[t] >= 0) {
          work += _keepRoute(TripKind.values[_kind], _topF[t], _topG[t]);
        }
      }
      _nextKind(_kind + 1);
    }
    return work;
  }

  /// Each destination's flow onto its arrival stretch and the node it is
  /// entered from; the scratch reset for the next origin.
  int _arrive(int budget) {
    final g = _graph;
    final originPiece = _grpPiece[_originGroup];
    var work = 0;
    while (_cursor < _gTouched.length && work < budget) {
      final dg = _gTouched[_cursor++];
      work++;
      final f = _gFlow[dg];
      if (f > 0) {
        final e = _gEdge[dg];
        if (e < 0) {
          _passVol[originPiece] += f;
        } else {
          _passVol[g.edgePiece[e]] += f;
          _nodeFlow[g.edgeFrom[e]] += f;
        }
      }
      _gBest[dg] = double.infinity;
      _gFlow[dg] = 0;
      _gW[dg] = 0;
    }
    if (_cursor >= _gTouched.length) {
      _gTouched.clear();
      _stage = _Stage.tree;
      _cursor = _search.order.length - 1;
    }
    return work;
  }

  /// Back up the shortest-path tree to the origin — reverse settle order
  /// is a topological order of it — and on to the next origin.
  int _tree(int budget) {
    final g = _graph;
    final s = _search;
    final order = s.order;
    final originPiece = _grpPiece[_originGroup];
    var work = 0;
    while (_cursor >= 0 && work < budget) {
      final v = order[_cursor--];
      work++;
      final f = _nodeFlow[v];
      if (f == 0) continue;
      _nodeFlow[v] = 0;
      final e = s.pred[v];
      if (e >= 0) {
        _passVol[g.edgePiece[e]] += f;
        _nodeFlow[g.edgeFrom[e]] += f;
      } else {
        _passVol[originPiece] += f;
      }
    }
    if (_cursor < 0) {
      _originActive = false;
      _assignCursor++;
      _stage = _Stage.search;
    }
    return work;
  }

  int _keepRoute(TripKind kind, double weight, int destGroup) {
    if (_routesCut) return 0;
    final g = _graph;
    final s = _search;
    final destEdge = _gEdge[destGroup];
    final chain = <int>[];
    var v = g.edgeFrom[destEdge];
    while (s.pred[v] >= 0) {
      final e = s.pred[v];
      chain.add(e);
      v = g.edgeFrom[e];
    }
    if (_routeEdges + chain.length > tuning.maxRouteEdges) {
      _routesCut = true;
      return chain.length;
    }
    _routeEdges += chain.length;
    final originPiece = _grpPiece[_originGroup];
    final mask = _grpMask[_originGroup];
    final forward = mask & RoadGraph.forwardBit != 0 &&
        g.pieceFwdEdge[originPiece] >= 0 &&
        v == g.pieceTo[originPiece];
    _routes.add(_Route(kind, weight, originPiece, forward, destEdge,
        Int32List.fromList(chain.reversed.toList())));
    return chain.length;
  }

  /// Scale the sample up to the whole city, blend with the last pass where
  /// the city was sampled, and read the loads against the lanes.
  void _finishAssign() {
    final g = _graph;
    final t = tuning;
    final scale = _sampledProd > 0 ? _totalProd / _sampledProd : 1.0;
    final prev = _pub;
    final blend = prev != null && identical(prev.graph, g) && _strideOf > 1
        ? 1.0 / _strideOf
        : 1.0;
    final nP = g.pieceCount;
    _newVol = Float64List(nP);
    _newCong = Float64List(nP);
    _roadVol = Float64List(g.roadCount);
    _roadCong = Float64List(g.roadCount);
    var peak = 0.0, sumVC = 0.0, sumV = 0.0;
    for (var p = 0; p < nP; p++) {
      final old = blend < 1 ? prev!.pieceVol[p] : 0.0;
      final vol = (1 - blend) * old + blend * scale * _passVol[p];
      final r = g.pieceRoad[p];
      final road = g.roads[r];
      final lanes = road.lanes?.laneCount ?? (road.oneWay ? 1 : 2);
      final cap = lanes *
          (road.roadClass.paved ? t.laneCapacity : t.dirtLaneCapacity);
      final cong = cap <= 0 ? 0.0 : vol / cap;
      _newVol[p] = vol;
      _newCong[p] = cong;
      if (vol > _roadVol[r]) _roadVol[r] = vol;
      if (cong > _roadCong[r]) _roadCong[r] = cong;
      if (cong > peak) peak = cong;
      sumVC += vol * cong;
      sumV += vol;
    }
    _peak = peak;
    _average = sumV > 0 ? sumVC / sumV : 0;
    for (final route in _routes) {
      route.weight *= scale;
    }
    _beginNoise();
  }

  // ---- Noise and land value -------------------------------------------------

  void _beginNoise() {
    final g = _graph;
    final roadEmission = _roadEmission ??= Float64List.fromList(
        [for (final road in g.roads) RoadType.of(road).noiseEmission]);
    _roadBonus ??= Float64List.fromList(
        [for (final road in g.roads) RoadNoise.frontageBonus(road)]);
    _emission = Float64List(g.pieceCount);
    for (var p = 0; p < g.pieceCount; p++) {
      _emission[p] = roadEmission[g.pieceRoad[p]] *
          RoadNoise.volumeFactor(_newCong[p]);
    }
    _sampler = RoadNoiseSampler(g);
    _lotNoise = Float32List(g.lotCount);
    _lotBonus = Float32List(g.lotCount);
    _noiseCursor = 0;
    _lvSum = 0;
    _lvCount = 0;
    _phase = _Phase.noise;
  }

  int _noise(int budget) {
    final g = _graph;
    final sampler = _sampler!;
    final bonusOf = _roadBonus!;
    var work = 0;
    while (_noiseCursor < g.lotCount && work < budget) {
      final i = _noiseCursor++;
      work++;
      final flags = _lotFlags[i];
      if (flags & _flagNoise == 0) continue;
      final before = sampler.work;
      final noise = sampler.noiseAt(Vec2(g.lotE[i], g.lotN[i]), _emission);
      work += sampler.work - before;
      final piece = g.lotPiece[i];
      final bonus = piece < 0 ? 0.0 : bonusOf[g.pieceRoad[piece]];
      _lotNoise[i] = noise;
      _lotBonus[i] = bonus;
      if (flags & _flagBuilt != 0) {
        _lvSum += RoadNoise.baseLandValue + bonus - RoadNoise.noiseWeight * noise;
        _lvCount++;
      }
    }
    if (_noiseCursor >= g.lotCount) {
      _publish();
      work++;
    }
    return work;
  }

  void _publish() {
    _pub = _Results(
      graph: _graph,
      pieceVol: _newVol,
      roadVol: _roadVol,
      roadCong: _roadCong,
      peak: _peak,
      average: _average,
      svcDist: _svcDist,
      svcOnPiece: _svcOnPiece,
      goodsDist: _goodsDist,
      goodsOnPiece: _goodsOnPiece,
      lotNoise: _lotNoise,
      lotBonus: _lotBonus,
      landValueRaw:
          _lvCount == 0 ? RoadNoise.baseLandValue : _lvSum / _lvCount,
      routes: List.unmodifiable(_routes),
      routesTruncated: _routesCut,
    );
    passes++;
    _phase = _Phase.idle;
    _sampler = null;
    _source = null;
    _routes = [];
    _sampled = const [];
  }

  TripRoute _tripRoute(RoadGraph g, _Route route) {
    final pts = <Vec2>[];
    final ids = <String>[];
    void addRoad(int r) {
      final id = g.roads[r].id;
      if (ids.isEmpty || ids.last != id) ids.add(id);
    }

    void addPts(List<Vec2> more) {
      for (final p in more) {
        if (pts.isNotEmpty && pts.last.distanceTo(p) < 1e-6) continue;
        pts.add(p);
      }
    }

    final op = route.originPiece;
    final or = g.pieceRoad[op];
    final oMid = (g.pieceS0[op] + g.pieceS1[op]) / 2;
    addRoad(or);
    addPts(g.polylineOf(
        or, oMid, route.originForward ? g.pieceS1[op] : g.pieceS0[op]));
    for (final e in route.edges) {
      final q = g.edgePiece[e];
      final r = g.pieceRoad[q];
      addRoad(r);
      final fwd = g.edgeForward[e] == 1;
      addPts(g.polylineOf(r, fwd ? g.pieceS0[q] : g.pieceS1[q],
          fwd ? g.pieceS1[q] : g.pieceS0[q]));
    }
    final dq = g.edgePiece[route.destEdge];
    final dr = g.pieceRoad[dq];
    final dMid = (g.pieceS0[dq] + g.pieceS1[dq]) / 2;
    addRoad(dr);
    final dFwd = g.edgeForward[route.destEdge] == 1;
    addPts(g.polylineOf(dr, dFwd ? g.pieceS0[dq] : g.pieceS1[dq], dMid));
    return TripRoute(
      kind: route.kind,
      weight: route.weight,
      roadIds: List.unmodifiable(ids),
      polyline: List.unmodifiable(pts),
    );
  }
}

/// A [CitySim]'s traffic: its road graph, cached against the roads, and a
/// [CityTrafficModel] fed from its lots and stepped from its tick.
///
/// Reads the sim through its public state only — the layout, the placed
/// and grown buildings, the junction overrides, the roads revision — so
/// the sim holds one of these and calls [advance] from its own tick, and
/// nothing here reaches back into how the sim works.
class CityRoadTraffic {
  CityRoadTraffic(this.sim, {this.tuning = const TrafficTuning()});

  final CitySim sim;
  final TrafficTuning tuning;

  RoadGraph? _graph;
  CityTrafficModel? _model;
  int _layoutVersion = -1, _roadsRevision = -1, _overrides = -1;
  int _placed = -1, _grown = -1;
  bool _dirty = true;
  bool _graphChanged = true;
  double _sincePass = 0;

  /// The road graph as the roads stand now (rebuilt when they have changed).
  RoadGraph get graph {
    _sync();
    return _graph!;
  }

  CityTrafficModel get model {
    _sync();
    return _model!;
  }

  /// Whether a pass has been published — until then the sim should keep
  /// its own frontage-local congestion.
  bool get hasRun => _model?.hasRun ?? false;

  /// The colony day, colony seconds: the tick's own day length (an Earth
  /// day is 120 s of play, scaled by the body's rotation, 20..1200 s).
  static double colonyDaySec(CitySim sim) {
    const refDaySeconds = 120.0;
    final rot = sim.body.siderealRotationPeriod.abs();
    final dayLen = rot <= 1 ? refDaySeconds : refDaySeconds * (rot / 86400.0);
    return dayLen.clamp(20.0, 1200.0);
  }

  /// Rebuild the graph when the roads (or the overrides) have changed.
  /// Integer compares otherwise: this runs every tick.
  void _sync() {
    final layout = sim.layout;
    if (_graph != null &&
        layout.version == _layoutVersion &&
        sim.roadsRevision == _roadsRevision &&
        sim.junctionOverrides.length == _overrides) {
      return;
    }
    _layoutVersion = layout.version;
    _roadsRevision = sim.roadsRevision;
    _overrides = sim.junctionOverrides.length;
    final g = RoadGraph.of(layout, overrides: sim.junctionOverrides.values);
    _graph = g;
    final m = _model;
    if (m == null) {
      _model = CityTrafficModel(g, tuning: tuning);
    } else {
      m.useGraph(g);
    }
    _graphChanged = true;
  }

  /// Step the model by one bounded slice. A pass starts when the roads
  /// have changed, when the buildings have (at most every
  /// [TrafficTuning.minRepassSec]), and otherwise every colony day.
  void advance(double dt) {
    if (dt <= 0) return;
    _sync();
    final m = _model!;
    _sincePass += dt;
    if (sim.parcelBuildings.length != _placed ||
        sim.grownParcels.length != _grown) {
      _placed = sim.parcelBuildings.length;
      _grown = sim.grownParcels.length;
      _dirty = true;
    }
    if (_graphChanged) {
      // A pass on the old roads is worthless: start again on the new ones.
      _graphChanged = false;
      _dirty = false;
      _sincePass = 0;
      m.beginPass(_lotState);
    } else if (!m.passing &&
        (!m.hasRun ||
            (_dirty && _sincePass >= tuning.minRepassSec) ||
            _sincePass >= (tuning.cadenceSec ?? colonyDaySec(sim)))) {
      _dirty = false;
      _sincePass = 0;
      m.beginPass(_lotState);
    }
    if (m.passing) m.step();
  }

  TrafficLot? _lotState(String id) {
    final placed = sim.parcelBuildings[id];
    if (placed != null) return TrafficLot(placed);
    final parcel = sim.layout.parcelById(id);
    if (parcel == null || parcel.use == ParcelUse.unzoned) return null;
    final grown = sim.parcelGrownSpec(id, parcel.use);
    if (grown == null) return const TrafficLot.bare();
    return TrafficLot(grown, occupancy: sim.parcelUtil(id));
  }

  double get peakCongestion => model.peakCongestion;
  double congestionOf(String roadId) => model.congestionOf(roadId);
  double volumeOf(String roadId) => model.volumeOf(roadId);
  List<TripRoute> routesThrough(String roadId,
          {Set<TripKind>? kinds, int limit = 64}) =>
      model.routesThrough(roadId, kinds: kinds, limit: limit);
  bool serviceReach(String lotId) => model.serviceReach(lotId);
  bool deliveryReach(String lotId) => model.deliveryReach(lotId);
  double noiseOf(String lotId) => model.noiseOf(lotId);
  double landValueOf(String lotId) =>
      model.landValueOf(lotId, pollution: sim.pollution);
  double get averageLandValue =>
      model.averageLandValue(pollution: sim.pollution);

  /// The multiplier the colony's land value puts on its tax take,
  /// 0.85..1.15 (see [RoadNoise.taxFactor]).
  double get taxLandValueFactor => RoadNoise.taxFactor(averageLandValue);
}

// ---- Internals ---------------------------------------------------------------

enum _Phase { idle, gather, service, goods, assign, noise }

/// The stages of routing one origin — see [CityTrafficModel._assign].
enum _Stage { search, price, weigh, share, arrive, tree }

class _Route {
  _Route(this.kind, this.weight, this.originPiece, this.originForward,
      this.destEdge, this.edges);
  final TripKind kind;
  double weight;
  final int originPiece;
  final bool originForward;
  final int destEdge;
  final Int32List edges;
}

class _Results {
  _Results({
    required this.graph,
    required this.pieceVol,
    required this.roadVol,
    required this.roadCong,
    required this.peak,
    required this.average,
    required this.svcDist,
    required this.svcOnPiece,
    required this.goodsDist,
    required this.goodsOnPiece,
    required this.lotNoise,
    required this.lotBonus,
    required this.landValueRaw,
    required this.routes,
    required this.routesTruncated,
  });

  final RoadGraph graph;
  final Float64List pieceVol, roadVol, roadCong;
  final double peak, average;
  final Float64List svcDist, goodsDist;
  final Map<int, double> svcOnPiece, goodsOnPiece;
  final Float32List lotNoise, lotBonus;
  final double landValueRaw;
  final List<_Route> routes;
  final bool routesTruncated;

  /// Route metres to [lotId] in a reach field: into its piece from the
  /// node behind it, in a direction it accepts — or from a source on its
  /// own piece behind it. Infinite when unreached or unknown.
  double reachDistance(
      String lotId, Float64List nodeDist, Map<int, double> onPiece) {
    final g = graph;
    final i = g.lotNoOf(lotId);
    if (i == null) return double.infinity;
    final piece = g.lotPiece[i];
    if (piece < 0) return double.infinity;
    final s = g.lotS[i];
    final mask = g.lotDirs[i];
    var best = double.infinity;
    if (mask & RoadGraph.forwardBit != 0 && g.pieceFwdEdge[piece] >= 0) {
      final c = s - g.pieceS0[piece];
      best = math.min(best, nodeDist[g.pieceFrom[piece]] + c);
      final m = onPiece[piece * 2];
      if (m != null && m <= c + 1e-6) best = math.min(best, c - m);
    }
    if (mask & RoadGraph.backwardBit != 0 && g.pieceBwdEdge[piece] >= 0) {
      final c = g.pieceS1[piece] - s;
      best = math.min(best, nodeDist[g.pieceTo[piece]] + c);
      final m = onPiece[piece * 2 + 1];
      if (m != null && m <= c + 1e-6) best = math.min(best, c - m);
    }
    return best;
  }
}

/// A growable list of ints in a typed buffer.
class _IntBuf {
  Int32List _a = Int32List(64);
  int length = 0;

  void add(int v) {
    if (length == _a.length) {
      final b = Int32List(_a.length * 2)..setRange(0, length, _a);
      _a = b;
    }
    _a[length++] = v;
  }

  int operator [](int i) => _a[i];

  void clear() => length = 0;
}

/// A resumable Dijkstra over a [RoadGraph]'s directed edges. State lives
/// in arrays sized to the graph and is reset through the nodes it touched,
/// so a search that settles fifty nodes costs fifty nodes whatever the size
/// of the city.
class _Search {
  _Search(int n)
      : dist = Float64List(n)..fillRange(0, n, double.infinity),
        pred = Int32List(n)..fillRange(0, n, -1),
        settled = Uint8List(n);

  final Float64List dist;
  final Int32List pred;
  final Uint8List settled;
  final _IntBuf touched = _IntBuf();

  /// Nodes in the order they were settled.
  final _IntBuf order = _IntBuf();

  Float64List _hk = Float64List(64);
  Int32List _hn = Int32List(64);
  int _hs = 0;

  /// Distances past this are not explored; the search stops after
  /// [maxSettled] nodes.
  double bound = double.infinity;
  int maxSettled = 1 << 30;

  bool done = true;

  void clear() {
    for (var k = 0; k < touched.length; k++) {
      final n = touched[k];
      dist[n] = double.infinity;
      pred[n] = -1;
      settled[n] = 0;
    }
    touched.clear();
    order.clear();
    _hs = 0;
    done = false;
  }

  void seed(int n, double d) {
    if (d >= dist[n] || d > bound) return;
    if (dist[n] == double.infinity) touched.add(n);
    dist[n] = d;
    pred[n] = -1;
    _push(n, d);
  }

  /// Settle nodes until the search is exhausted, bounded, full — or
  /// [budget] units (pops and relaxations) are spent. Returns the units.
  int run(RoadGraph g, Float64List weight, int budget) {
    var work = 0;
    final outStart = g.outStart, outEdges = g.outEdges, to = g.edgeTo;
    while (_hs > 0 && work < budget) {
      final d = _hk[0];
      final u = _hn[0];
      _pop();
      work++;
      if (settled[u] == 1 || d > dist[u]) continue;
      if (d > bound) {
        _hs = 0;
        break;
      }
      settled[u] = 1;
      order.add(u);
      if (order.length >= maxSettled) {
        _hs = 0;
        break;
      }
      for (var k = outStart[u]; k < outStart[u + 1]; k++) {
        work++;
        final e = outEdges[k];
        final v = to[e];
        if (settled[v] == 1) continue;
        final nd = d + weight[e];
        if (nd < dist[v] && nd <= bound) {
          if (dist[v] == double.infinity) touched.add(v);
          dist[v] = nd;
          pred[v] = e;
          _push(v, nd);
        }
      }
    }
    if (_hs == 0) done = true;
    return work;
  }

  void _push(int n, double k) {
    if (_hs == _hk.length) {
      _hk = Float64List(_hk.length * 2)..setRange(0, _hs, _hk);
      _hn = Int32List(_hn.length * 2)..setRange(0, _hs, _hn);
    }
    var i = _hs++;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (_hk[p] <= k) break;
      _hk[i] = _hk[p];
      _hn[i] = _hn[p];
      i = p;
    }
    _hk[i] = k;
    _hn[i] = n;
  }

  void _pop() {
    _hs--;
    if (_hs == 0) return;
    final k = _hk[_hs];
    final n = _hn[_hs];
    var i = 0;
    while (true) {
      var c = 2 * i + 1;
      if (c >= _hs) break;
      if (c + 1 < _hs && _hk[c + 1] < _hk[c]) c++;
      if (_hk[c] >= k) break;
      _hk[i] = _hk[c];
      _hn[i] = _hn[c];
      i = c;
    }
    _hk[i] = k;
    _hn[i] = n;
  }
}
