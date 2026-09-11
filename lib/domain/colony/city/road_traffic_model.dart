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
/// work: every stage of it — the per-stretch and per-junction sweeps that
/// open and close a pass as much as the route searches — resumes where the
/// last step stopped, and the buffers it fills are allocated when the graph
/// arrives, not when a pass needs them. The owner runs one step a tick, and
/// a pass is started when the roads or the buildings change and otherwise
/// about once a colony day. Lots are aggregated per road stretch before
/// anything is routed, and every route search is bounded in time and in
/// junctions.
///
/// A big city's origins are split into a WINDOW of shares, by the road they
/// are on (every piece of one drawn road in one share), and a pass routes
/// one share. Each share keeps the load its latest pass put on every
/// stretch, and what is published is their SUM — every origin counted once,
/// nothing scaled up — so a big city reads what it would if every origin
/// were routed every pass. (Scaling a sample up to the whole put the
/// sample's own streets at several times their load and their neighbours
/// at none, and the worst stretch — the colony's congestion — measured the
/// sampling, not the traffic.) When the roads change, each share's loads
/// are carried onto the new stretches by road id until its next pass
/// re-routes it: a road edit shows at once, and the city re-routes around
/// it share by share. Readers always see the last COMPLETE window.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'city_building_spec.dart';
import 'city_sim.dart';
import 'parcel.dart';
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

  /// Vehicles per peak on it: its origin stretch's trips of [kind] to its
  /// destination stretch — never scaled.
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

  /// What the model counts of the lot, as one number: which building (by
  /// identity) and how full it is, to an eighth; 1 for bare zoning. Two
  /// looks at a lot with one key put the same trips on the road, so a lot
  /// whose key has moved since a pass counted it is a change the next pass
  /// should see — the house that went up, the floor it grew, the tenants
  /// that moved in.
  int get stateKey {
    final s = spec;
    if (s == null) return 1;
    final eighths = (occupancy.clamp(0.0, 1.0) * 8).round();
    return 2 + (((identityHashCode(s) & 0x3ffffff) << 4) | eighths);
  }
}

/// Looks a lot up by id: its building, bare zoning, or null for a lot the
/// model can ignore (unzoned and empty).
typedef TrafficLotSource = TrafficLot? Function(String lotId);

/// A building that is not on one of the layout's lots — one the colony's
/// grid placed — hung on the road graph where it is entered from
/// ([RoadGraph.attachFootprint]). It makes and draws trips like a built lot,
/// and a station or a works among them seeds the reach fields; there is no
/// lot to ask its noise or land value of.
class TrafficSite {
  const TrafficSite(
    this.spec, {
    required this.piece,
    required this.sM,
    required this.dirs,
    this.occupancy = 1.0,
  });

  final CityBuildingSpec spec;

  /// The piece it is entered from, the arc along that piece's road, and
  /// the access mask ([RoadGraph.forwardBit] / [RoadGraph.backwardBit]).
  final int piece;
  final double sM;
  final int dirs;

  /// How full it is, 0..1.
  final double occupancy;
}

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
    this.maxWindow = 16,
    this.workPerStep = 60000,
    this.routesPerOrigin = 2,
    this.maxRouteEdges = 300000,
    this.cadenceSec,
    this.minRepassSec = 2,
    this.scanLotsPerTick = 64,
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

  /// Origin stretches one pass routes. A city with more is split into a
  /// window of shares, a pass routing one share (see the library comment).
  final int maxOriginsPerPass;

  /// The most shares a window is split into. Each keeps a load per road
  /// stretch — eight bytes a stretch a share, so sixteen shares of a
  /// sixty-thousand-stretch city are under eight megabytes — and a city
  /// past [maxOriginsPerPass] times this routes more origins a pass rather
  /// than keeping more shares.
  final int maxWindow;

  /// Work units one [CityTrafficModel.step] does (a node settled, an edge
  /// relaxed or priced, a lot, a road segment looked at for noise, a
  /// stretch or a junction swept at a stage boundary). Every stage of a
  /// pass resumes where the last step stopped, so a step overruns this by
  /// at most one junction's edges, one lot's noise probe, one road's
  /// stretches, or the routes it keeps for the view as a kind of trip
  /// finishes (at most [routesPerOrigin] chains of at most [maxSettled]
  /// edges).
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

  /// Lots [CityRoadTraffic] looks at each tick for a building that has
  /// changed since a pass counted it.
  final int scanLotsPerTick;
}

/// Routed traffic over a [RoadGraph]. See the library comment.
class CityTrafficModel {
  CityTrafficModel(RoadGraph graph, {this.tuning = const TrafficTuning()})
      : _graph = graph,
        _resGraph = graph,
        _search = _Search(graph.nodeCount) {
    _allocate(graph);
  }

  final TrafficTuning tuning;

  RoadGraph _graph;
  _Search _search;

  /// The graph passes run on — which may be newer than the last published
  /// window's.
  RoadGraph get graph => _graph;

  _Results? _pub;
  _Phase _phase = _Phase.idle;
  TrafficLotSource? _source;
  List<TrafficSite> _sites = const [];

  /// Passes completed — each routes one share of the window.
  int passes = 0;

  /// Work units the last [step] did.
  int lastStepWork = 0;

  bool get passing => _phase != _Phase.idle;

  /// Whether a window has been published.
  bool get hasRun => _pub != null;

  /// The shares the window is split into (0 before the first pass has
  /// counted the origins) — so a window is this many passes.
  int get shares => _window;

  /// Whether a pass is owed whatever the clock says: the window is not full
  /// yet, or part of it was routed on roads, or under junction plans, that
  /// have changed since.
  bool get needsRefresh {
    if (_window == 0 || !_graph.sharesStructureWith(_resGraph)) return true;
    for (var k = 0; k < _window; k++) {
      if (_resState[k] != _fresh) return true;
    }
    return false;
  }

  /// Move to [g]. The same network re-planned or renamed
  /// ([RoadGraph.sharesStructureWith]) changes nothing a pass has indexed:
  /// the pass in flight carries on under the new plans, and if they change
  /// what a route costs the window is owed a re-route under them. A
  /// different network drops the pass in flight (its lots and roads are
  /// the old ones); the last published window stays readable, and the next
  /// pass carries the window's loads across to the new roads.
  void useGraph(RoadGraph g) {
    final old = _graph;
    if (identical(g, old)) return;
    _graph = g;
    if (g.sharesStructureWith(old)) {
      if (!identical(g.edgeTime, old.edgeTime)) {
        _markStale();
        // Part of the pass in flight was routed under the old plans: its
        // share is owed another.
        if (passing) _passStale = true;
      }
      return;
    }
    _search = _Search(g.nodeCount);
    _phase = _Phase.idle;
    _source = null;
    _sites = const [];
    _allocate(g);
  }

  /// Start a pass over the lots [source] describes and the [sites] off the
  /// plat. A pass in flight is dropped.
  void beginPass(TrafficLotSource source,
      {List<TrafficSite> sites = const []}) {
    _source = source;
    _sites = sites;
    _cursor = 0;
    _cursor2 = 0;
    _passStale = false;
    _phase = _Phase.reset;
    if (_graph.sharesStructureWith(_resGraph)) return;
    var carried = false;
    for (final v in _resVol) {
      if (v != null) carried = true;
    }
    if (!carried) {
      _resGraph = _graph;
      return;
    }
    _remapped = List<Float64List?>.filled(_window, null);
    _remapShare = 0;
    _phase = _Phase.remap;
  }

  /// Run passes now until the whole window is routed on the current roads
  /// and published: for tests and small tools.
  void runPass(TrafficLotSource source,
      {List<TrafficSite> sites = const []}) {
    for (var guard = 0; guard < 1000; guard++) {
      beginPass(source, sites: sites);
      while (passing) {
        step(maxWork: 1 << 30);
      }
      if (!needsRefresh) return;
    }
  }

  /// Do up to [maxWork] (default [TrafficTuning.workPerStep]) units of the
  /// pass in flight. True when this step ended the pass.
  bool step({int? maxWork}) {
    if (_phase == _Phase.idle) {
      lastStepWork = 0;
      return false;
    }
    final budget = maxWork ?? tuning.workPerStep;
    var work = 0;
    while (work < budget && _phase != _Phase.idle) {
      final left = budget - work;
      switch (_phase) {
        case _Phase.remap:
          work += _remap(left);
        case _Phase.reset:
          work += _reset(left);
        case _Phase.gather:
          work += _gather(left);
        case _Phase.count:
          work += _count(left);
        case _Phase.pick:
          work += _pick(left);
        case _Phase.seed:
          work += _seed(left);
        case _Phase.field:
          work += _field(left);
        case _Phase.fill:
          work += _fill(left);
        case _Phase.clear:
          work += _clear(left);
        case _Phase.assign:
          work += _assign(left);
        case _Phase.keep:
          work += _keep(left);
        case _Phase.loads:
          work += _loadsOnRoads(left);
        case _Phase.noise:
          work += _noise(left);
        case _Phase.idle:
          break;
      }
    }
    lastStepWork = work;
    return _phase == _Phase.idle;
  }

  // ---- Answers (from the last complete window) ------------------------------

  /// The worst road's load against its lanes, 0..1 — the colony's
  /// congestion, as the commute penalty reads it. 0 before a window.
  double get peakCongestion => (_pub?.peak ?? 0).clamp(0.0, 1.0);

  /// Congestion averaged over the vehicles: what a typical trip meets.
  double get averageCongestion => _pub?.average ?? 0;

  /// Load over capacity on [roadId] (its worst stretch), 0 for a road the
  /// last window did not know.
  double congestionOf(String roadId) {
    final p = _pub;
    final r = p?.graph.roadNoOf(roadId);
    return r == null ? 0 : p!.loads.roadCong[r];
  }

  /// Vehicles per peak on [roadId] (its busiest stretch).
  double volumeOf(String roadId) {
    final p = _pub;
    final r = p?.graph.roadNoOf(roadId);
    return r == null ? 0 : p!.loads.roadVol[r];
  }

  /// Whether the kept route sample was cut short by
  /// [TrafficTuning.maxRouteEdges].
  bool get routesTruncated => _pub?.routesTruncated ?? false;

  /// The trips that use [roadId], heaviest first — at most [limit] of
  /// them, of [kinds] (all when null): each share's heaviest routes from
  /// its latest pass, at their own weights.
  List<TripRoute> routesThrough(String roadId,
      {Set<TripKind>? kinds, int limit = 64}) {
    final p = _pub;
    if (p == null) return const [];
    final hits = <_Route>[];
    RoadGraph? lastG;
    int? lastR;
    for (final share in p.routes) {
      for (final route in share) {
        if (kinds != null && !kinds.contains(route.kind)) continue;
        final g = route.graph;
        if (!identical(g, lastG)) {
          lastG = g;
          lastR = g.roadNoOf(roadId);
        }
        final r = lastR;
        if (r == null) continue;
        var through = g.pieceRoad[route.originPiece] == r ||
            g.pieceRoad[g.edgePiece[route.destEdge]] == r;
        for (var k = 0; !through && k < route.edges.length; k++) {
          if (g.pieceRoad[g.edgePiece[route.edges[k]]] == r) through = true;
        }
        if (through) hits.add(route);
      }
    }
    hits.sort((a, b) => b.weight.compareTo(a.weight));
    return [for (final h in hits.take(limit)) _tripRoute(h.graph, h)];
  }

  /// Route metres from the nearest police, fire or ambulance station to
  /// [lotId], over the one-way streets the way they run — null when none
  /// is within [TrafficTuning.serviceReachM] (or before a window).
  double? serviceDistanceTo(String lotId) {
    final p = _pub;
    if (p == null) return null;
    final d = p.reachDistance(lotId, p.loads.svcDist, p.svcOnPiece);
    return d <= tuning.serviceReachM ? d : null;
  }

  /// Whether a service vehicle reaches [lotId]. True before the first
  /// window and for a lot the last window did not know — a lot is not
  /// punished for the model not having looked yet.
  bool serviceReach(String lotId) {
    final p = _pub;
    if (p == null || p.graph.lotNoOf(lotId) == null) return true;
    return serviceDistanceTo(lotId) != null;
  }

  /// Whether goods can reach [lotId] — from a works, a warehouse, the
  /// spaceport, or from off-world through the landing site — over the
  /// one-way streets the way they run. True before the first window and
  /// for a lot the last window did not know.
  bool deliveryReach(String lotId) {
    final p = _pub;
    if (p == null || p.graph.lotNoOf(lotId) == null) return true;
    return p
        .reachDistance(lotId, p.loads.goodsDist, p.goodsOnPiece)
        .isFinite;
  }

  /// Traffic noise at [lotId], 0..1 (0 before a window).
  double noiseOf(String lotId) {
    final p = _pub;
    final i = p?.graph.lotNoOf(lotId);
    return i == null ? 0 : p!.loads.lotNoise[i];
  }

  /// Land value of [lotId], 0..1, in air of [pollution].
  double landValueOf(String lotId, {double pollution = 0}) {
    final p = _pub;
    final i = p?.graph.lotNoOf(lotId);
    if (i == null) return RoadNoise.landValue(noise: 0, pollution: pollution);
    return RoadNoise.landValue(
        noise: p!.loads.lotNoise[i],
        bonus: p.loads.lotBonus[i],
        pollution: pollution);
  }

  /// Land value averaged over the built lots, in air of [pollution] — the
  /// base value in that air when none is built.
  double averageLandValue({double pollution = 0}) {
    final raw = _pub?.landValueRaw ?? RoadNoise.baseLandValue;
    return (raw - RoadNoise.pollutionPenalty(pollution)).clamp(0.0, 1.0);
  }

  /// Built lots the last window valued (0 before one).
  int get builtLots => _pub?.builtLots ?? 0;

  /// The multiplier the colony's land value puts on its tax take,
  /// 0.85..1.15 ([RoadNoise.taxFactor]) — exactly 1 until a window has
  /// valued a built lot. A colony with no land to value — a grid colony, a
  /// plat nobody has built on — has no land value to tax by; its air alone
  /// must not cut its take.
  double taxFactor({double pollution = 0}) {
    final p = _pub;
    if (p == null || p.builtLots == 0) return 1.0;
    return RoadNoise.taxFactor(averageLandValue(pollution: pollution));
  }

  /// The [TrafficLot.stateKey] graph lot [lot] had when a pass last
  /// gathered it (0 when the source ignored it); -1 before any has.
  int lotKeyAt(int lot) => _lotKey[lot];

  /// How many of the graph's lots (from the first) carry a key from the
  /// newest pass that has gathered them: all of them between passes and
  /// once the pass in flight is past its gather, none while a pass is yet
  /// to gather. A lot past this is about to be looked at anyway.
  int get gatheredLots => switch (_phase) {
        _Phase.idle => _graph.lotCount,
        _Phase.remap || _Phase.reset => 0,
        _Phase.gather => math.min(_cursor, _graph.lotCount),
        _ => _graph.lotCount,
      };

  // ---- Per-graph buffers ------------------------------------------------------
  //
  // Sized to the graph and allocated when it arrives (the tick a graph
  // arrives on is the tick that built it), then reset pass by pass by
  // budgeted stages: no stage boundary sweeps the network in one go.

  late Uint8List _lotFlags;
  late Int32List _lotKey;
  late Int32List _pieceGroups;
  late Float64List _passVol, _nodeFlow, _emission;
  late Int32List _remapOf;
  late List<_Loads> _loads;
  int _back = 0;
  late RoadNoiseSampler _sampler;

  void _allocate(RoadGraph g) {
    final nL = g.lotCount, nP = g.pieceCount;
    _lotFlags = Uint8List(nL);
    _lotKey = Int32List(nL)..fillRange(0, nL, -1);
    _pieceGroups = Int32List(nP * 3)..fillRange(0, nP * 3, -1);
    _passVol = Float64List(nP);
    _nodeFlow = Float64List(g.nodeCount);
    _emission = Float64List(nP);
    _remapOf = Int32List(nP);
    _loads = [_Loads(g), _Loads(g)];
    _back = 0;
    _sampler = RoadNoiseSampler(g);
    // The group table held the old graph's pieces.
    _gPiece.clear();
    _gMask.clear();
  }

  // ---- The pass: state ---------------------------------------------------------

  // Where the stage in hand is.
  int _cursor = 0, _cursor2 = 0;

  // Gather: lots aggregated into GROUPS — one per (piece, access mask), so
  // the lots a road stretch serves are routed once, not one by one. The
  // group of a (piece, mask) is found through [_pieceGroups].
  static const int _flagNoise = 1, _flagBuilt = 2;
  final _IntBuf _gPiece = _IntBuf(), _gMask = _IntBuf();
  final List<_DblBuf> _prod = List.generate(4, (_) => _DblBuf());
  final List<_DblBuf> _attr = List.generate(4, (_) => _DblBuf());
  final _Sources _svc = _Sources(), _goods = _Sources();
  double _resTotal = 0, _jobsTotal = 0, _shopTotal = 0;
  double _goodsDemand = 0, _goodsSupply = 0;

  // The window: shares of the origins, each with the load its latest pass
  // put on every stretch of [_resGraph], and the routes it kept.
  static const int _missing = 0, _stale = 1, _fresh = 2;
  int _window = 0;
  RoadGraph _resGraph;
  List<Float64List?> _resVol = const [];
  List<List<_Route>> _resRoutes = const [];
  Uint8List _resState = Uint8List(0);
  Uint8List _resCut = Uint8List(0);
  int _resNext = 0;
  int _shareNo = 0;
  bool _willPublish = false;
  bool _passStale = false;
  int _originCount = 0;
  List<Float64List?> _remapped = const [];
  int _remapShare = 0;

  // Reach fields.
  bool _fieldService = true;
  Map<int, List<double>> _onPiece = {};
  Map<int, List<double>> _svcOnPiece = {}, _goodsOnPiece = {};

  // Assignment.
  final _IntBuf _sampled = _IntBuf();
  int _assignCursor = 0;
  bool _originActive = false;
  int _originGroup = -1;

  // Where the origin in hand is — searching, pricing its destinations,
  // weighing and sharing one kind of trip at a time, the flows onto the
  // tree — and where in that stage: each resumes from [_cursor].
  _Stage _stage = _Stage.search;
  int _kind = 0;
  double _sumW = 0;
  List<int> _topG = const [];
  List<double> _topF = const [];
  final _DblBuf _gBest = _DblBuf(), _gFlow = _DblBuf(), _gW = _DblBuf();
  final _IntBuf _gEdge = _IntBuf();
  final _IntBuf _gTouched = _IntBuf();
  List<_Route> _routes = [];
  int _routeEdges = 0, _routeCap = 0;
  bool _routesCut = false;

  // Loads, noise, land value.
  double _peak = 0, _sumVC = 0, _sumV = 0;
  double _lvSum = 0;
  int _lvCount = 0;

  void _markStale() {
    for (var k = 0; k < _window; k++) {
      if (_resState[k] == _fresh) _resState[k] = _stale;
    }
  }

  /// The share of the window the lots on [piece] are routed in.
  int _shareOf(int piece) =>
      _window <= 1 ? 0 : _graph.roadKey[_graph.pieceRoad[piece]] % _window;

  double _prodOf(int gi) =>
      _prod[0][gi] + _prod[1][gi] + _prod[2][gi] + _prod[3][gi];

  // ---- Remap: the window's loads onto new roads -------------------------------

  /// Carry each share's loads from the roads they were routed on to the
  /// roads as they now stand: a road by its id; the pieces of a road the
  /// edit cut (`r12x0`, `r12x1`) from the road they were cut from, at the
  /// piece nearest; a new road from nothing. Until its next pass a share
  /// shows what its origins drove before the edit, so the published window
  /// is the whole city's traffic from the first pass after an edit.
  int _remap(int budget) {
    final g = _graph, old = _resGraph;
    var work = 0;
    while (_cursor2 < g.roadCount && work < budget) {
      final r = _cursor2++;
      var id = g.roads[r].id;
      var o = old.roadNoOf(id);
      final same = o != null;
      work += 2;
      while (o == null) {
        final up = _parentId(id);
        if (up == null) break;
        id = up;
        o = old.roadNoOf(id);
        work++;
      }
      for (var p = g.roadFirstPiece[r]; p < g.roadFirstPiece[r + 1]; p++) {
        work++;
        if (o == null) {
          _remapOf[p] = -1;
        } else if (same) {
          // The same id is the same geometry: arcs line up.
          _remapOf[p] = old.pieceAt(o, (g.pieceS0[p] + g.pieceS1[p]) / 2);
        } else {
          _remapOf[p] = old.pieceNear(
              o, g.pointAt(r, (g.pieceS0[p] + g.pieceS1[p]) / 2));
          work += old.roadRecs[o].sampleCount;
        }
      }
    }
    if (_cursor2 < g.roadCount) return work;
    final nP = g.pieceCount;
    while (_remapShare < _window && work < budget) {
      final src = _resVol[_remapShare];
      if (src == null) {
        _remapShare++;
        continue;
      }
      final dst = _remapped[_remapShare] ??= Float64List(nP);
      while (_cursor < nP && work < budget) {
        final q = _remapOf[_cursor];
        dst[_cursor++] = q < 0 ? 0.0 : src[q];
        work++;
      }
      if (_cursor >= nP) {
        _remapShare++;
        _cursor = 0;
      }
    }
    if (_remapShare < _window) return work;
    for (var k = 0; k < _window; k++) {
      _resVol[k] = _remapped[k];
      // Their edges were the old graph's.
      _resRoutes[k] = const [];
      _resCut[k] = 0;
      if (_resState[k] == _fresh) _resState[k] = _stale;
    }
    _remapped = const [];
    _resGraph = g;
    _cursor = 0;
    _cursor2 = 0;
    _phase = _Phase.reset;
    return work + 1;
  }

  /// The road [id] was cut from (`r12x0x3` from `r12x0`), or null for one
  /// laid as it is.
  static String? _parentId(String id) {
    final i = id.lastIndexOf('x');
    if (i <= 0 || i == id.length - 1) return null;
    for (var k = i + 1; k < id.length; k++) {
      final c = id.codeUnitAt(k);
      if (c < 0x30 || c > 0x39) return null;
    }
    return id.substring(0, i);
  }

  // ---- Gather ------------------------------------------------------------------

  /// The last pass's groups off the piece table, and the tables cleared.
  int _reset(int budget) {
    var work = 0;
    while (_cursor < _gPiece.length && work < budget) {
      final i = _cursor++;
      _pieceGroups[_gPiece[i] * 3 + _gMask[i] - 1] = -1;
      work++;
    }
    if (_cursor < _gPiece.length) return work;
    _gPiece.clear();
    _gMask.clear();
    for (var k = 0; k < 4; k++) {
      _prod[k].clear();
      _attr[k].clear();
    }
    _svc.clear();
    _goods.clear();
    _resTotal = _jobsTotal = _shopTotal = 0;
    _goodsDemand = _goodsSupply = 0;
    _cursor = 0;
    _cursor2 = 0;
    _phase = _Phase.gather;
    return work + 1;
  }

  int _groupFor(int piece, int mask) {
    final slot = piece * 3 + mask - 1;
    final found = _pieceGroups[slot];
    if (found >= 0) return found;
    final ng = _gPiece.length;
    _pieceGroups[slot] = ng;
    _gPiece.add(piece);
    _gMask.add(mask);
    for (var k = 0; k < 4; k++) {
      _prod[k].add(0);
      _attr[k].add(0);
    }
    return ng;
  }

  /// A lot's look-up and classification, in work units: a few map probes
  /// and the building's arithmetic — weighed against a route search's
  /// units, so a gather step costs what a routing step does.
  static const int _lotWork = 12;

  int _gather(int budget) {
    final g = _graph;
    final src = _source!;
    final nL = g.lotCount;
    var work = 0;
    while (_cursor < nL && work < budget) {
      final i = _cursor++;
      work += _lotWork;
      _lotFlags[i] = 0;
      final lot = src(g.lotIds[i]);
      if (lot == null) {
        _lotKey[i] = 0;
        continue;
      }
      _lotKey[i] = lot.stateKey;
      _lotFlags[i] = _flagNoise;
      final spec = lot.spec;
      if (spec == null) continue;
      _lotFlags[i] |= _flagBuilt;
      _addBuilding(spec, lot.occupancy, g.lotPiece[i], g.lotS[i], g.lotDirs[i]);
    }
    if (_cursor < nL) return work;
    final sites = _sites;
    while (_cursor2 < sites.length && work < budget) {
      final site = sites[_cursor2++];
      work += _lotWork;
      _addBuilding(site.spec, site.occupancy, site.piece, site.sM, site.dirs);
    }
    if (_cursor2 < sites.length) return work;
    _finishGather();
    return work + 1;
  }

  /// A building's trips, onto the group of the stretch it is entered from.
  void _addBuilding(CityBuildingSpec spec, double occupancy, int piece,
      double s, int dirs) {
    // A building no road reaches puts nobody on the roads.
    if (piece < 0 || dirs == 0) return;
    final t = tuning;
    final occ = occupancy.clamp(0.0, 1.0);
    final residents = spec.housing * occ;
    final jobs = spec.jobs * occ;
    final gi = _groupFor(piece, dirs);
    _resTotal += residents;
    _jobsTotal += jobs;
    _prod[0][gi] += residents * t.commuteTripsPerResident;
    _prod[1][gi] += residents * t.shopTripsPerResident;
    _attr[0][gi] += jobs;
    if (TrafficRole.isShop(spec)) {
      final a = math.max(1.0, jobs);
      _attr[1][gi] += a;
      _shopTotal += a;
    }
    if (TrafficRole.shipsGoods(spec)) {
      final trips = jobs * t.goodsTripsPerJob +
          (spec.storageBonus > 0 ? t.goodsTripsPerStore : 0);
      _prod[2][gi] += trips;
      _goodsSupply += trips;
      _goods.add(piece, s, dirs);
    }
    if (TrafficRole.needsDeliveries(spec)) {
      final a = math.max(1.0, jobs);
      _attr[2][gi] += a;
      _goodsDemand += a * t.goodsTripsPerJob;
    }
    if (TrafficRole.sendsServiceVehicles(spec)) {
      _prod[3][gi] += t.serviceTripsPerStation;
      _svc.add(piece, s, dirs);
    }
    _attr[3][gi] += 1;
  }

  /// The landing site joins as a group of its own — the colony's door to
  /// the world: where people work and shop when the colony has too few
  /// jobs and shops, where the goods it does not make come in from, and
  /// where the goods it has too many of go.
  void _finishGather() {
    final g = _graph;
    final t = tuning;
    if (g.rootPiece >= 0 && g.rootDirs != 0) {
      final gi = _groupFor(g.rootPiece, g.rootDirs);
      _attr[0][gi] += math.max(0.0, _resTotal - _jobsTotal);
      _attr[1][gi] +=
          math.max(0.0, t.outsideShopShare * _resTotal - _shopTotal);
      _prod[2][gi] += math.max(0.0, _goodsDemand - _goodsSupply);
      if (t.goodsTripsPerJob > 0) {
        _attr[2][gi] +=
            math.max(0.0, _goodsSupply - _goodsDemand) / t.goodsTripsPerJob;
      }
      _goods.add(g.rootPiece, g.rootS, g.rootDirs);
    }
    final nG = _gPiece.length;
    _gBest.setLength(nG);
    _gFlow.setLength(nG);
    _gW.setLength(nG);
    _gEdge.setLength(nG);
    _originCount = 0;
    _cursor = 0;
    _phase = _Phase.count;
  }

  // ---- The share this pass routes -----------------------------------------------

  /// Count the origins, and reset the per-group scratch of the routing.
  int _count(int budget) {
    final nG = _gPiece.length;
    var work = 0;
    while (_cursor < nG && work < budget) {
      final gi = _cursor++;
      work++;
      _gBest[gi] = double.infinity;
      _gFlow[gi] = 0;
      _gW[gi] = 0;
      if (_prodOf(gi) > 0) _originCount++;
    }
    if (_cursor < nG) return work;
    _decideWindow(_originCount);
    _cursor = 0;
    _sampled.clear();
    _phase = _Phase.pick;
    return work + 1;
  }

  /// Size the window for [origins]: one share per
  /// [TrafficTuning.maxOriginsPerPass], at most [TrafficTuning.maxWindow].
  /// A window is re-cut only when the city has outgrown it (or shrunk
  /// from it) twice over — every re-cut starts the shares again, and the
  /// last published window has to serve until they are all routed.
  void _decideWindow(int origins) {
    final most = math.max(1, tuning.maxWindow);
    final ideal = math.max(1,
        math.min(most, (origins / math.max(1, tuning.maxOriginsPerPass)).ceil()));
    if (_window == 0 || ideal > 2 * _window || 2 * ideal < _window) {
      _window = ideal;
      _resVol = List<Float64List?>.filled(ideal, null);
      _resRoutes = List<List<_Route>>.filled(ideal, const []);
      _resState = Uint8List(ideal);
      _resCut = Uint8List(ideal);
      _resNext = 0;
      _resGraph = _graph;
    }
    _shareNo = _resNext % _window;
  }

  /// This pass's origins: the groups of its share that make trips.
  int _pick(int budget) {
    final nG = _gPiece.length;
    var work = 0;
    while (_cursor < nG && work < budget) {
      final gi = _cursor++;
      work++;
      if (_prodOf(gi) > 0 && _shareOf(_gPiece[gi]) == _shareNo) {
        _sampled.add(gi);
      }
    }
    if (_cursor < nG) return work;
    // A window with a share never routed is not published: it would be
    // missing that share's traffic.
    _willPublish = true;
    for (var k = 0; k < _window; k++) {
      if (k != _shareNo && _resState[k] == _missing) _willPublish = false;
    }
    if (_willPublish) {
      work += _beginSeeds(service: true);
    } else {
      _cursor = 0;
      _phase = _Phase.clear;
    }
    return work + 1;
  }

  // ---- Reach fields: distance from the nearest service station (bounded),
  // and from the nearest source of goods (unbounded), over directed edges.

  /// Ready the search for a field; the work of clearing the last one back.
  int _beginSeeds({required bool service}) {
    _fieldService = service;
    final s = _search;
    final work = s.clear();
    s.bound = service ? tuning.serviceReachM : double.infinity;
    s.maxSettled = 1 << 30;
    _onPiece = <int, List<double>>{};
    _cursor = 0;
    _phase = _Phase.seed;
    return work;
  }

  int _seed(int budget) {
    final src = _fieldService ? _svc : _goods;
    var work = 0;
    while (_cursor < src.length && work < budget) {
      final k = _cursor++;
      work += 2 + _seedDistance(src.piece[k], src.s[k], src.dirs[k], _onPiece);
    }
    if (_cursor < src.length) return work;
    if (_fieldService) {
      _svcOnPiece = _onPiece;
    } else {
      _goodsOnPiece = _onPiece;
    }
    _phase = _Phase.field;
    return work + 1;
  }

  /// Seed the search with a vehicle leaving arc [s] of [piece] in the
  /// directions [mask] allows: it reaches the node ahead, and passes every
  /// lot ahead of it on its own piece ([onPiece]: the travel coordinates the
  /// sources sit at, per piece and direction, ascending). Work units back.
  int _seedDistance(
      int piece, double s, int mask, Map<int, List<double>> onPiece) {
    final g = _graph;
    var work = 0;
    if (mask & RoadGraph.forwardBit != 0 && g.pieceFwdEdge[piece] >= 0) {
      _search.seed(g.pieceTo[piece], g.pieceS1[piece] - s);
      work += _insertSorted(
          onPiece[piece * 2] ??= <double>[], s - g.pieceS0[piece]);
    }
    if (mask & RoadGraph.backwardBit != 0 && g.pieceBwdEdge[piece] >= 0) {
      _search.seed(g.pieceFrom[piece], s - g.pieceS0[piece]);
      work += _insertSorted(
          onPiece[piece * 2 + 1] ??= <double>[], g.pieceS1[piece] - s);
    }
    return work;
  }

  /// [v] into ascending [list]; the elements moved, plus one.
  static int _insertSorted(List<double> list, double v) {
    var i = list.length;
    list.add(v);
    while (i > 0 && list[i - 1] > v) {
      list[i] = list[i - 1];
      i--;
    }
    list[i] = v;
    return list.length - i;
  }

  int _field(int budget) {
    final g = _graph;
    final work = _search.run(g, g.edgeLength, budget);
    if (!_search.done) return work;
    _cursor = 0;
    _phase = _Phase.fill;
    return work + 1;
  }

  /// The settled distances into the field being published.
  int _fill(int budget) {
    final nN = _graph.nodeCount;
    final b = _loads[_back];
    final dst = _fieldService ? b.svcDist : b.goodsDist;
    final s = _search;
    var work = 0;
    while (_cursor < nN && work < budget) {
      final n = _cursor++;
      work++;
      dst[n] = s.settled[n] == 1 ? s.dist[n] : double.infinity;
    }
    if (_cursor < nN) return work;
    if (_fieldService) {
      work += _beginSeeds(service: false);
    } else {
      _cursor = 0;
      _phase = _Phase.clear;
    }
    return work + 1;
  }

  // ---- Assignment ----------------------------------------------------------------

  /// The pass's stretch loads and junction flows zeroed, then routing.
  int _clear(int budget) {
    final nP = _graph.pieceCount;
    final total = nP + _graph.nodeCount;
    var work = 0;
    while (_cursor < total && work < budget) {
      final end = math.min(total, _cursor + (budget - work));
      if (_cursor < nP) {
        final e = math.min(end, nP);
        _passVol.fillRange(_cursor, e, 0);
        work += e - _cursor;
        _cursor = e;
      } else {
        _nodeFlow.fillRange(_cursor - nP, end - nP, 0);
        work += end - _cursor;
        _cursor = end;
      }
    }
    if (_cursor < total) return work;
    _assignCursor = 0;
    _originActive = false;
    _stage = _Stage.search;
    _gTouched.clear();
    _routes = [];
    _routeEdges = 0;
    _routesCut = false;
    _routeCap = math.max(1, tuning.maxRouteEdges ~/ _window);
    _topG = List<int>.filled(tuning.routesPerOrigin, -1);
    _topF = List<double>.filled(tuning.routesPerOrigin, 0);
    _search.bound = tuning.maxTripSec;
    _search.maxSettled = tuning.maxSettled;
    _phase = _Phase.assign;
    return work + 1;
  }

  int _assign(int budget) {
    final g = _graph;
    var work = 0;
    while (work < budget) {
      if (!_originActive) {
        if (_assignCursor >= _sampled.length) {
          _cursor = 0;
          _phase = _Phase.keep;
          return work + 1;
        }
        work += _startOrigin(_sampled[_assignCursor]);
        _originActive = true;
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
  /// the directions its lots may leave by. The work of clearing the last
  /// search back.
  int _startOrigin(int gi) {
    final g = _graph;
    _originGroup = gi;
    _stage = _Stage.search;
    final work = _search.clear();
    final piece = _gPiece[gi];
    final mask = _gMask[gi];
    final half = _halfDrive(piece);
    final fe = g.pieceFwdEdge[piece], be = g.pieceBwdEdge[piece];
    if (mask & RoadGraph.forwardBit != 0 && fe >= 0) {
      _search.seed(g.pieceTo[piece], g.edgeTime[fe] - half);
    }
    if (mask & RoadGraph.backwardBit != 0 && be >= 0) {
      _search.seed(g.pieceFrom[piece], g.edgeTime[be] - half);
    }
    return work;
  }

  // The search from one origin is done. What follows prices every
  // destination group it reached (arriving at the middle of its piece, by a
  // direction its lots accept), shares each kind's trips over them by the
  // gravity rule, keeps the heaviest routes, and puts the flows on the
  // shortest-path tree — each stage resumable, so no step does more than
  // its budget however far the search reached.

  void _beginPricing() {
    final gi = _originGroup;
    final originPiece = _gPiece[gi];
    final originMask = _gMask[gi];
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
    final originPiece = _gPiece[_originGroup];
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
    final originPiece = _gPiece[_originGroup];
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
    if (_routeEdges + chain.length > _routeCap) {
      _routesCut = true;
      return chain.length;
    }
    _routeEdges += chain.length;
    final originPiece = _gPiece[_originGroup];
    final mask = _gMask[_originGroup];
    final forward = mask & RoadGraph.forwardBit != 0 &&
        g.pieceFwdEdge[originPiece] >= 0 &&
        v == g.pieceTo[originPiece];
    _routes.add(_Route(g, kind, weight, originPiece, forward, destEdge,
        Int32List.fromList(chain.reversed.toList())));
    return chain.length;
  }

  // ---- The share's loads into the window, and the window's onto the roads ------

  /// This pass's loads become its share's.
  int _keep(int budget) {
    final nP = _graph.pieceCount;
    final k = _shareNo;
    var dst = _resVol[k];
    if (dst == null || dst.length != nP) dst = _resVol[k] = Float64List(nP);
    var work = 0;
    if (_cursor < nP) {
      final end = math.min(nP, _cursor + budget);
      dst.setRange(_cursor, end, _passVol, _cursor);
      work += end - _cursor;
      _cursor = end;
    }
    if (_cursor < nP) return work;
    _resRoutes[k] = List.unmodifiable(_routes);
    _resCut[k] = _routesCut ? 1 : 0;
    _resState[k] = _passStale ? _stale : _fresh;
    _resNext = (k + 1) % _window;
    if (!_willPublish) {
      _endPass();
      return work + 1;
    }
    _cursor = 0;
    _peak = 0;
    _sumVC = 0;
    _sumV = 0;
    _phase = _Phase.loads;
    return work + 1;
  }

  /// Every stretch's load — the sum of the shares' — against its lanes.
  int _loadsOnRoads(int budget) {
    final g = _graph;
    final t = tuning;
    final b = _loads[_back];
    final shares = _resVol;
    final nS = _window;
    var work = 0;
    while (_cursor < g.roadCount && work < budget) {
      final r = _cursor++;
      final cap = g.roadLanes[r] *
          (g.roadPaved[r] == 1 ? t.laneCapacity : t.dirtLaneCapacity);
      final emission = g.roadEmission[r];
      var rv = 0.0, rc = 0.0;
      for (var p = g.roadFirstPiece[r]; p < g.roadFirstPiece[r + 1]; p++) {
        var vol = 0.0;
        for (var k = 0; k < nS; k++) {
          vol += shares[k]![p];
        }
        work += nS + 1;
        final cong = cap <= 0 ? 0.0 : vol / cap;
        _emission[p] = emission * RoadNoise.volumeFactor(cong);
        if (vol > rv) rv = vol;
        if (cong > rc) rc = cong;
        if (cong > _peak) _peak = cong;
        _sumVC += vol * cong;
        _sumV += vol;
      }
      b.roadVol[r] = rv;
      b.roadCong[r] = rc;
    }
    if (_cursor < g.roadCount) return work;
    _cursor = 0;
    _lvSum = 0;
    _lvCount = 0;
    _phase = _Phase.noise;
    return work + 1;
  }

  // ---- Noise and land value -------------------------------------------------------

  int _noise(int budget) {
    final g = _graph;
    final sampler = _sampler;
    final bonusOf = g.roadBonus;
    final b = _loads[_back];
    var work = 0;
    while (_cursor < g.lotCount && work < budget) {
      final i = _cursor++;
      work++;
      final flags = _lotFlags[i];
      if (flags & _flagNoise == 0) {
        b.lotNoise[i] = 0;
        b.lotBonus[i] = 0;
        continue;
      }
      final before = sampler.work;
      final noise = sampler.noiseAt(Vec2(g.lotE[i], g.lotN[i]), _emission);
      work += sampler.work - before;
      final piece = g.lotPiece[i];
      final bonus = piece < 0 ? 0.0 : bonusOf[g.pieceRoad[piece]];
      b.lotNoise[i] = noise;
      b.lotBonus[i] = bonus;
      if (flags & _flagBuilt != 0) {
        _lvSum += RoadNoise.baseLandValue + bonus - RoadNoise.noiseWeight * noise;
        _lvCount++;
      }
    }
    if (_cursor < g.lotCount) return work;
    _publish();
    return work + 1;
  }

  void _publish() {
    var cut = false;
    for (var k = 0; k < _window; k++) {
      if (_resCut[k] == 1) cut = true;
    }
    _pub = _Results(
      graph: _graph,
      loads: _loads[_back],
      peak: _peak,
      average: _sumV > 0 ? _sumVC / _sumV : 0,
      svcOnPiece: _svcOnPiece,
      goodsOnPiece: _goodsOnPiece,
      landValueRaw:
          _lvCount == 0 ? RoadNoise.baseLandValue : _lvSum / _lvCount,
      builtLots: _lvCount,
      routes: List.unmodifiable(_resRoutes),
      routesTruncated: cut,
    );
    // The next pass writes the other set; this one is the readers'.
    _back ^= 1;
    _endPass();
  }

  void _endPass() {
    passes++;
    _phase = _Phase.idle;
    _source = null;
    _sites = const [];
    _routes = [];
    _sampled.clear();
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

/// A [CitySim]'s traffic: its road graph, kept up to date with the roads,
/// and a [CityTrafficModel] fed from its lots and grid buildings and
/// stepped from its tick.
///
/// Reads the sim through its public state only — the layout, the placed
/// and grown buildings, the grid, the junction overrides, the roads
/// revision — so the sim holds one of these and calls [advance] from its
/// own tick, and nothing here reaches back into how the sim works.
class CityRoadTraffic {
  CityRoadTraffic(this.sim, {this.tuning = const TrafficTuning()});

  final CitySim sim;
  final TrafficTuning tuning;

  RoadGraph? _graph;
  CityTrafficModel? _model;
  int _layoutVersion = -1, _roadsRevision = -1, _overrides = -1;
  int _placed = -1, _grown = -1, _gridUtils = -1, _gridGrown = -1;
  bool _dirty = true;
  bool _graphChanged = true;
  double _sincePass = 0;
  int _scanCursor = 0;

  /// Where each grid building hangs on the graph, by anchor cell — kept
  /// while the network's structure stands.
  final Map<int, ({CityBuildingSpec spec, PieceAccess? at})> _attached = {};
  RoadGraph? _attachGraph;

  /// The road graph as the roads stand now (rebuilt, or re-planned, when
  /// they have changed).
  RoadGraph get graph {
    _sync();
    return _graph!;
  }

  CityTrafficModel get model {
    _sync();
    return _model!;
  }

  /// Whether a window has been published — until then the sim should keep
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

  /// Bring the graph up to date when the roads, the plat or the overrides
  /// have moved. Integer compares otherwise: this runs every tick.
  ///
  /// A re-cut plat is a new graph. Otherwise the change may be one routing
  /// never reads — a road renamed — or only the player's junction
  /// overrides, and the graph is patched ([RoadGraph.refreshedFor]) rather
  /// than rebuilt: a rebuild walks every road and lot, and a light toggled
  /// in the Junctions view should cost neither that nor the pass in flight.
  void _sync() {
    final layout = sim.layout;
    final version = layout.version;
    final rev = sim.roadsRevision;
    final ov = sim.junctionOverrides.length;
    final old = _graph;
    if (old != null &&
        version == _layoutVersion &&
        rev == _roadsRevision &&
        ov == _overrides) {
      return;
    }
    _roadsRevision = rev;
    _overrides = ov;
    RoadGraph? g;
    if (old != null && version == _layoutVersion) {
      g = old.refreshedFor(layout, overrides: sim.junctionOverrides.values);
    }
    _layoutVersion = version;
    g ??= RoadGraph.of(layout, overrides: sim.junctionOverrides.values);
    if (identical(g, old)) return;
    _graph = g;
    final m = _model;
    if (m == null || old == null) {
      _model = CityTrafficModel(g, tuning: tuning);
      _graphChanged = true;
      return;
    }
    m.useGraph(g);
    // A patched graph keeps the pass in flight; the model says whether it
    // owes a re-route ([CityTrafficModel.needsRefresh]).
    if (!g.sharesStructureWith(old)) _graphChanged = true;
  }

  /// Step the model by one bounded slice. A pass starts when the roads
  /// have changed, when the window owes one, when the buildings have (at
  /// most every [TrafficTuning.minRepassSec]), and otherwise every colony
  /// day.
  void advance(double dt) {
    if (dt <= 0) return;
    _sync();
    final m = _model!;
    _sincePass += dt;
    if (sim.parcelBuildings.length != _placed ||
        sim.grownParcels.length != _grown ||
        sim.utils.length != _gridUtils ||
        sim.grown.length != _gridGrown) {
      _placed = sim.parcelBuildings.length;
      _grown = sim.grownParcels.length;
      _gridUtils = sim.utils.length;
      _gridGrown = sim.grown.length;
      _dirty = true;
    }
    if (!_dirty) _scan(m);
    if (_graphChanged) {
      // A pass on the old roads is worthless: start again on the new ones.
      _graphChanged = false;
      _begin(m);
    } else if (!m.passing &&
        (!m.hasRun ||
            m.needsRefresh ||
            (_dirty && _sincePass >= tuning.minRepassSec) ||
            _sincePass >= (tuning.cadenceSec ?? colonyDaySec(sim)))) {
      _begin(m);
    }
    if (m.passing) m.step();
  }

  void _begin(CityTrafficModel m) {
    _dirty = false;
    _sincePass = 0;
    m.beginPass(_lotState, sites: _gridSites(m.graph));
  }

  /// Look at a few lots a tick for one whose building has changed since a
  /// pass counted it — built on, grown a floor, filled up, burned down.
  /// The counts of placed and growing lots miss all of that (a lot starts
  /// growing, and is counted, while it is still bare ground), and a colony
  /// day is twenty minutes of play on a slow-turning world. A handful of
  /// look-ups a tick, so no tick pays for a walk of the plat; a small
  /// colony is looked over every tick, a sprawl every few hundred.
  void _scan(CityTrafficModel m) {
    final limit = m.gatheredLots;
    if (limit <= 0) return;
    final ids = m.graph.lotIds;
    var n = math.min(tuning.scanLotsPerTick, limit);
    while (n-- > 0) {
      if (_scanCursor >= limit) _scanCursor = 0;
      final i = _scanCursor++;
      final known = m.lotKeyAt(i);
      if (known < 0) continue;
      if ((_lotState(ids[i])?.stateKey ?? 0) != known) {
        _dirty = true;
        return;
      }
    }
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

  /// The grid's buildings — hand-placed utilities and grown zone cells —
  /// as sites on the road graph. The colony's 2D builder and its in-world
  /// streets are one map ([CitySim.buildingParcels]): a police station
  /// placed on the grid answers calls along the streets drawn past it. Each
  /// hangs on the nearest road within reach of its footprint, by the
  /// hand-drawn lot's rule, and where it hangs is kept while the network's
  /// structure stands, so a pass looks up only the buildings new since.
  List<TrafficSite> _gridSites(RoadGraph g) {
    if (g.roadCount == 0 || (sim.utils.isEmpty && sim.grown.isEmpty)) {
      return const [];
    }
    final cached = _attachGraph;
    if (cached == null || !g.sharesStructureWith(cached)) {
      _attached.clear();
      _attachGraph = g;
    }
    final out = <TrafficSite>[];
    for (final e in sim.occupiedCells()) {
      final anchor = e.key;
      final spec = e.value;
      if (sim.abandoned.contains(anchor)) continue;
      var hit = _attached[anchor];
      if (hit == null || !identical(hit.spec, spec)) {
        final fp = sim.parcelForCell(anchor, spec);
        hit = (
          spec: spec,
          at: g.attachFootprint(fp.polygon, centroid: fp.centroid),
        );
        _attached[anchor] = hit;
      }
      final at = hit.at;
      if (at == null) continue;
      out.add(TrafficSite(spec,
          piece: at.piece,
          sM: at.sM,
          dirs: at.dirs,
          occupancy: sim.utilFactor(anchor)));
    }
    return out;
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
  /// 0.85..1.15 ([CityTrafficModel.taxFactor]) — exactly 1 for a colony
  /// with no built lot on its plat, polluted or not. So the tax line can
  /// take it as it is: a grid colony's take (and every test's funds) stays
  /// what it was. Gating it on [hasRun] instead would not: a small
  /// colony's first window is published on its first tick.
  double get taxLandValueFactor => model.taxFactor(pollution: sim.pollution);
}

// ---- Internals ---------------------------------------------------------------------

enum _Phase {
  idle,
  remap,
  reset,
  gather,
  count,
  pick,
  seed,
  field,
  fill,
  clear,
  assign,
  keep,
  loads,
  noise,
}

/// The stages of routing one origin — see [CityTrafficModel._assign].
enum _Stage { search, price, weigh, share, arrive, tree }

class _Route {
  _Route(this.graph, this.kind, this.weight, this.originPiece,
      this.originForward, this.destEdge, this.edges);

  /// The graph its piece and edge numbers are for.
  final RoadGraph graph;
  final TripKind kind;
  final double weight;
  final int originPiece;
  final bool originForward;
  final int destEdge;
  final Int32List edges;
}

/// One set of the arrays a window publishes. A model holds two per graph:
/// readers have one while the pass in flight fills the other.
class _Loads {
  _Loads(RoadGraph g)
      : roadVol = Float64List(g.roadCount),
        roadCong = Float64List(g.roadCount),
        svcDist = Float64List(g.nodeCount),
        goodsDist = Float64List(g.nodeCount),
        lotNoise = Float32List(g.lotCount),
        lotBonus = Float32List(g.lotCount);

  final Float64List roadVol, roadCong, svcDist, goodsDist;
  final Float32List lotNoise, lotBonus;
}

class _Results {
  _Results({
    required this.graph,
    required this.loads,
    required this.peak,
    required this.average,
    required this.svcOnPiece,
    required this.goodsOnPiece,
    required this.landValueRaw,
    required this.builtLots,
    required this.routes,
    required this.routesTruncated,
  });

  final RoadGraph graph;
  final _Loads loads;
  final double peak, average;
  final Map<int, List<double>> svcOnPiece, goodsOnPiece;
  final double landValueRaw;
  final int builtLots;
  final List<List<_Route>> routes;
  final bool routesTruncated;

  /// Route metres to [lotId] in a reach field: into its piece from the
  /// node behind it, in a direction it accepts — or from the nearest source
  /// on its own piece behind it. Infinite when unreached or unknown.
  double reachDistance(
      String lotId, Float64List nodeDist, Map<int, List<double>> onPiece) {
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
      best = math.min(best, _behind(onPiece[piece * 2], c));
    }
    if (mask & RoadGraph.backwardBit != 0 && g.pieceBwdEdge[piece] >= 0) {
      final c = g.pieceS1[piece] - s;
      best = math.min(best, nodeDist[g.pieceTo[piece]] + c);
      best = math.min(best, _behind(onPiece[piece * 2 + 1], c));
    }
    return best;
  }

  /// Metres back from travel coordinate [c] to the nearest source at or
  /// behind it among the ascending coordinates [sorted] — the largest one
  /// not past [c] — or infinity when every source is ahead.
  static double _behind(List<double>? sorted, double c) {
    if (sorted == null || sorted.isEmpty || sorted[0] > c + 1e-6) {
      return double.infinity;
    }
    var lo = 0, hi = sorted.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (sorted[mid] <= c + 1e-6) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return c - sorted[lo];
  }
}

/// A growable list of ints in a typed buffer.
class _IntBuf {
  Int32List _a = Int32List(64);
  int length = 0;

  void add(int v) {
    if (length == _a.length) _grow(length + 1);
    _a[length++] = v;
  }

  /// [n] entries; those past the old length hold whatever they held.
  void setLength(int n) {
    if (n > _a.length) _grow(n);
    length = n;
  }

  void _grow(int n) {
    var c = _a.length;
    while (c < n) {
      c *= 2;
    }
    _a = Int32List(c)..setRange(0, length, _a);
  }

  int operator [](int i) => _a[i];
  void operator []=(int i, int v) => _a[i] = v;

  void clear() => length = 0;
}

/// A growable list of doubles in a typed buffer.
class _DblBuf {
  Float64List _a = Float64List(64);
  int length = 0;

  void add(double v) {
    if (length == _a.length) _grow(length + 1);
    _a[length++] = v;
  }

  /// [n] entries; those past the old length hold whatever they held.
  void setLength(int n) {
    if (n > _a.length) _grow(n);
    length = n;
  }

  void _grow(int n) {
    var c = _a.length;
    while (c < n) {
      c *= 2;
    }
    _a = Float64List(c)..setRange(0, length, _a);
  }

  double operator [](int i) => _a[i];
  void operator []=(int i, double v) => _a[i] = v;

  void clear() => length = 0;
}

/// Where the sources of a reach field sit: a piece, the arc along its
/// road, the directions they leave by.
class _Sources {
  final _IntBuf piece = _IntBuf(), dirs = _IntBuf();
  final _DblBuf s = _DblBuf();

  int get length => piece.length;

  void add(int p, double sM, int d) {
    piece.add(p);
    s.add(sM);
    dirs.add(d);
  }

  void clear() {
    piece.clear();
    s.clear();
    dirs.clear();
  }
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

  /// Forget the last search, through the nodes it touched. Returns how many
  /// that was, plus one: the work, for the caller's budget.
  int clear() {
    final count = touched.length;
    for (var k = 0; k < count; k++) {
      final n = touched[k];
      dist[n] = double.infinity;
      pred[n] = -1;
      settled[n] = 0;
    }
    touched.clear();
    order.clear();
    _hs = 0;
    done = false;
    return count + 1;
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
