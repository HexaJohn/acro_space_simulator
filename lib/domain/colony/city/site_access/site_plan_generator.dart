// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The site plan generator's entry point and dispatch
/// (docs/plans/site-access.md §3.3–§3.9, slice R2 core).
///
/// - [SiteContext]: everything one site's generation reads — the road graph
///   and its structure stamp, the lot (or footprint) polygon and frontage, its
///   spec, its [SiteFrame] and its join slots — plus the emission helpers
///   every generator shares (the site row, joins, kerb nodes, door, pavement
///   point, footpath).
/// - [SiteGeneratedPlan]: what a generator returns. It is computed in full
///   before anything is written, so a generator that fails part way writes
///   nothing (`PlanBuilder` has no rollback).
/// - [planSite]: §3.3's dispatch for one built site, first match wins, with
///   the generators in fall-through order and every demotion counted.
/// - [emitKerbOnly]: the kerbside plan every demotion ends in.
/// - [planSites] / [planCity]: a list of sites (a whole town) into chunks of
///   [kSitesPerChunk], deterministically, in the given order.
///
/// Zero ground reads: nothing here, or in any generator, is handed a ground
/// function (plans never read the terrain, §3.8 steep lots). Determinism
/// (§3.9): no platform hash, draw, clock, map iteration or trigonometry.
library;

import '../city_building_spec.dart';
import '../city_sim.dart';
import '../hash32.dart';
import '../parcel.dart';
import '../road_graph.dart';
import 'car_park_packer.dart';
import 'home_driveway.dart';
import 'installation_access.dart';
import 'site_access_constants.dart';
import 'site_access_plan.dart';
import 'site_envelope.dart';
import 'site_frame.dart';
import 'site_join.dart';
import 'site_plan_builder.dart';
import 'site_program.dart';

/// A generator's finished plan for one site, not yet written.
///
/// Every generator (home, car park, yard, installation) returns one of these
/// or null. [emit] writes exactly one site into the builder: it calls
/// [SiteContext.beginSite] first and `PlanBuilder.endSite` last.
abstract class SiteGeneratedPlan {
  /// The program the plan is (`homeDriveway`, `carPark`, `yard`,
  /// `installation`).
  SiteProgram get program;

  /// Writes the site. [dispatchFlags] are the dispatcher's plan flags
  /// (`kPlanFallback` when a lesser program than the one offered won); the
  /// plan ORs in its own (`kPlanNetwork`, `kPlanAdmitsTrucks`).
  void emit(PlanBuilder b, SiteContext ctx, int dispatchFlags);
}

/// One site's generation inputs. Built once per site per sync; immutable
/// apart from its lazily derived values.
class SiteContext {
  SiteContext._({
    required this.graph,
    required this.graphStamp,
    required this.siteId,
    required this.graphLot,
    required this.parcel,
    required this.spec,
    required List<JoinSlot> slots,
    required List<int> slotRefs,
    required this.trustFrontage,
    required this.lotBuilt,
  })  : _slots = slots,
        _slotRefs = slotRefs;

  /// A graph lot: [parcel] is `graph.lotIds[graphLot]`'s parcel, its slots
  /// are the graph's (slot 0, then slot 1 when packed; slot 2 on request).
  /// [spec] null: unbuilt (§3.3 row 0a, no plan). [lotBuilt] says whether a
  /// graph lot has a building (row 0c's crossed lots); null: none is built.
  factory SiteContext.ofLot(
    RoadGraph graph,
    Parcel parcel,
    CityBuildingSpec? spec, {
    int? graphStamp,
    bool Function(int lot)? lotBuilt,
  }) {
    final lot = graph.lotNoOf(parcel.id);
    final slots = <JoinSlot>[];
    final refs = <int>[];
    if (lot != null) {
      for (var k = 0; k < 2; k++) {
        final ref = graph.joinRefOf(lot, k);
        final slot = graph.joinOfRef(ref);
        if (slot == null) break;
        slots.add(slot);
        refs.add(ref);
      }
    }
    return SiteContext._(
      graph: graph,
      graphStamp: graphStamp ?? graph.structureStamp,
      siteId: parcel.id,
      graphLot: lot ?? -1,
      parcel: parcel,
      spec: spec,
      slots: slots,
      slotRefs: refs,
      trustFrontage: true,
      lotBuilt: lotBuilt ?? _noneBuilt,
    );
  }

  /// A footprint that is no graph lot (a grid cell): its slots from
  /// `RoadGraph.attachFootprintJoins`, every `joinRef` −1, its frontage the
  /// effective one (a cell's stored north edge is fake, §3.1).
  factory SiteContext.ofFootprint(
    RoadGraph graph,
    Parcel parcel,
    CityBuildingSpec? spec, {
    int? graphStamp,
    bool Function(int lot)? lotBuilt,
  }) {
    final slots = graph.attachFootprintJoins(parcel.polygon);
    return SiteContext._(
      graph: graph,
      graphStamp: graphStamp ?? graph.structureStamp,
      siteId: parcel.id,
      graphLot: -1,
      parcel: parcel,
      spec: spec,
      slots: slots.length > 2 ? slots.sublist(0, 2) : slots,
      slotRefs: [for (var k = 0; k < slots.length && k < 2; k++) kJoinRefNone],
      trustFrontage: false,
      lotBuilt: lotBuilt ?? _noneBuilt,
    );
  }

  /// Tests: a context whose slots are given outright (a synthetic slot
  /// probing one §3.3 rule). [slotRefs] default to −1.
  factory SiteContext.debug(
    RoadGraph graph,
    Parcel parcel,
    CityBuildingSpec? spec, {
    required List<JoinSlot> slots,
    List<int>? slotRefs,
    int graphLot = -1,
    int? graphStamp,
    bool trustFrontage = true,
    bool Function(int lot)? lotBuilt,
  }) =>
      SiteContext._(
        graph: graph,
        graphStamp: graphStamp ?? graph.structureStamp,
        siteId: parcel.id,
        graphLot: graphLot,
        parcel: parcel,
        spec: spec,
        slots: slots,
        slotRefs: slotRefs ?? [for (final _ in slots) kJoinRefNone],
        trustFrontage: trustFrontage,
        lotBuilt: lotBuilt ?? _noneBuilt,
      );

  static bool _noneBuilt(int lot) => false;

  /// The graph the joins are resolved against, and its structure stamp
  /// (written to `graphStamp`).
  final RoadGraph graph;
  final int graphStamp;

  /// The plan's site id (the layout's own string instance), and its graph lot
  /// (−1 for a footprint).
  final String siteId;
  final int graphLot;

  /// The site's lot: polygon, stored frontage, side street, graded.
  final Parcel parcel;

  /// The building standing on it; null when unbuilt.
  final CityBuildingSpec? spec;

  final List<JoinSlot> _slots;
  final List<int> _slotRefs;

  /// Whether the stored frontage may be used (false for grid cells).
  final bool trustFrontage;

  /// Whether graph lot `lot` has a building (§3.3 row 0c).
  final bool Function(int lot) lotBuilt;

  /// How many packed slots the site has (0: no access at all, no plan).
  int get slotCount => _slots.length;

  /// Packed slot [k] (0 or 1) and its join handle.
  JoinSlot slot(int k) => _slots[k];
  int slotRef(int k) => _slotRefs[k];

  JoinSlot get slot0 => _slots[0];

  /// The corner lot's side-street slot 2 (placed on the graph on first ask),
  /// and its handle; null / −1 for a footprint or a lot without one.
  JoinSlot? get sideStreetSlot =>
      graphLot < 0 ? null : graph.sideStreetJoinOf(graphLot);
  int get sideStreetRef => graphLot < 0
      ? kJoinRefNone
      : graph.joinRefOf(graphLot, kJoinSlotSideStreet);

  /// The rear alley slot 3 (placed on the graph on first ask) and its handle;
  /// null / −1 for a footprint or a lot with no alley behind it.
  JoinSlot? get alleySlot =>
      graphLot < 0 ? null : graph.rearAlleyJoinOf(graphLot);
  int get alleyRef =>
      graphLot < 0 ? kJoinRefNone : graph.joinRefOf(graphLot, kJoinSlotAlley);

  /// Whether an alley lies behind the lot (§3.9's input-signature term): the
  /// rear search alone, without placing slot 3.
  bool get hasAlleyCandidate => graphLot >= 0 && graph.hasRearAlley(graphLot);

  /// The site frame (§3.1); null for a degenerate polygon.
  late final SiteFrame? frame = SiteFrame.of(
      parcel.polygon, trustFrontage ? parcel.frontage : null, graph.index);

  /// Frame W; 0 without a frame.
  double get widthM => frame?.widthM ?? 0;

  /// The frame's true depth D (the profile's deepest column, its margin
  /// given back); 0 without a frame.
  late final double depthM = frame == null
      ? 0
      : (frame!.profile.maxDepthM > 0
          ? frame!.profile.maxDepthM + kDepthProfileMarginM
          : 0);

  /// Whether the frame had to find an effective frontage and no eligible road
  /// was in reach (§3.1: program `none`, no plan).
  late final bool noFrontageRoad = frame != null &&
      frame!.usedEffectiveFrontage &&
      effectiveFrontage(parcel.polygon, graph.index) == null;

  /// The road of slot [k].
  RoadSpline roadOf(JoinSlot s) => graph.roads[graph.pieceRoad[s.piece]];
  int roadNoOf(JoinSlot s) => graph.pieceRoad[s.piece];

  /// The §3.9 seed: `fnv1a32` over (program version, W and D quantised to
  /// 0.5 m, slot 0's road class ordinal, spec type). Position-free.
  late final int seed = () {
    var h = kFnvOffset32;
    h = fnv1aU32(h, kSiteProgramVersion);
    h = fnv1aU32(h, (widthM / kSeedQuantumM).round());
    h = fnv1aU32(h, (depthM / kSeedQuantumM).round());
    h = fnv1aU32(h, slotCount == 0 ? -1 : roadOf(slot0).roadClass.index);
    return fnv1aU32(h, fnv1a32(spec?.type ?? ''));
  }();

  /// A tie-break bit stream for [tag] (§3.9): `xorshift32(seed ^ fnv1a32(tag))`.
  int tieBreak(String tag) => xorshift32(seed ^ fnv1a32(tag));

  /// Slot [s]'s kerb point in frame metres: `x` along the frontage, `y` (≤ 0
  /// in front of the lot) into it. `-y` is the kerb-to-frontage distance k.
  Vec2 kerbLocal(JoinSlot s) => frame!.toLocal(Vec2(s.kerbE, s.kerbN));

  /// Whether slot [s]'s road has a pavement a throat crosses (V5).
  bool crossesPavement(JoinSlot s) => roadOf(s).roadClass.hasPavement;

  // ---- emission helpers --------------------------------------------------------

  /// Starts this site's row: frame, stamp, lot, [program], [flags], [env].
  void beginSite(PlanBuilder b, SiteProgram program, int flags,
      SiteEnvelope env, {double truckTurnRadiusM = 0}) {
    final f = frame;
    b.beginSite(
      siteId,
      program: program,
      flags: flags,
      graphStamp: graphStamp,
      graphLot: graphLot,
      frameE: f?.origin.e ?? parcel.centroid.e,
      frameN: f?.origin.n ?? parcel.centroid.n,
      frameUE: f?.u.e ?? 1,
      frameUN: f?.u.n ?? 0,
      envX0: env.x0,
      envX1: env.x1,
      envY0: env.y0,
      envY1: env.y1,
      envFrontInset: env.frontInset,
      gateX: env.gateX,
      gateW: env.gateW,
      truckTurnRadiusM: truckTurnRadiusM,
    );
  }

  /// A join on packed slot [k] (0, 1) or, with [k] == `kJoinSlotSideStreet` or
  /// `kJoinSlotAlley`, on the side-street or rear-alley slot: its values
  /// copied from the graph's (V3).
  int addJoin(
    PlanBuilder b,
    int k, {
    SiteJoinKind kind = SiteJoinKind.cut,
    SiteJoinRole role = SiteJoinRole.both,
    double cutHalfM = 0,
    int kerbNode = -1,
    int throatSeg = -1,
  }) {
    final s = switch (k) {
      kJoinSlotSideStreet => sideStreetSlot!,
      kJoinSlotAlley => alleySlot!,
      _ => _slots[k],
    };
    return b.join(
      slot: k,
      ref: switch (k) {
        kJoinSlotSideStreet => sideStreetRef,
        kJoinSlotAlley => alleyRef,
        _ => _slotRefs[k],
      },
      piece: s.piece,
      roadS: s.s,
      right: s.right,
      dirs: s.dirs,
      role: role,
      kind: kind,
      roadNo: graph.pieceRoad[s.piece],
      kerbNode: kerbNode,
      throatSeg: throatSeg,
      cutHalfM: cutHalfM,
    );
  }

  /// The kerb node of plan join [join] on slot [s]: its point EXACTLY on the
  /// slot's kerb point (V3), height ref `kerb`.
  int kerbNode(PlanBuilder b, JoinSlot s, int join) {
    final pt = b.point(s.kerbE, s.kerbN,
        ref: SiteHeightRef.kerb, hJoin: join);
    return b.node(pt, flags: kNodeKerb);
  }

  /// A point at frame ([x], [y]).
  int localPoint(PlanBuilder b, double x, double y,
      {SiteHeightRef ref = SiteHeightRef.pad, int hJoin = kPtNoJoin, double hT = 0}) {
    final w = frame!.toWorld(Vec2(x, y));
    return b.point(w.e, w.n, ref: ref, hJoin: hJoin, hT: hT);
  }

  /// The door, pavement point and the footpath between them (§6.1 steps 5–6,
  /// V11): [doorPt] and [pavementPt] are plan points already written;
  /// [entranceNode] −1 for a kerbside plan.
  void finishPedestrians(PlanBuilder b, int doorPt, int pavementPt,
      {int entranceNode = -1}) {
    b.entrance(doorPt, node: entranceNode);
    b.pavement(pavementPt);
    b.path([pavementPt, doorPt]);
  }

  /// The kerbside plan's pavement point on slot 0 (§6.1, V11): the kerb point
  /// moved [kPavementPointInsetM] along the slot normal into the lot.
  int kerbsidePavementPoint(PlanBuilder b) {
    final s = slot0;
    return b.point(s.kerbE + s.normE * kPavementPointInsetM,
        s.kerbN + s.normN * kPavementPointInsetM,
        ref: SiteHeightRef.kerb, hJoin: 0);
  }

  /// The §6.1 envelope of a site with no paving: the largest free rectangle
  /// inside the side setbacks, fitted to `buildingFootprint`. Empty without a
  /// frame or a spec, or where nothing of 8 × 8 m fits (then the free
  /// rectangle itself, when there is one).
  SiteEnvelope kerbsideEnvelope() {
    final f = frame;
    final sp = spec;
    if (f == null || sp == null) return SiteEnvelope.empty;
    final free = largestFreeRect(f.profile, f.widthM,
        xMin: kSideSetbackM, xMax: f.widthM - kSideSetbackM);
    if (free == null) return SiteEnvelope.empty;
    final foot = buildingFootprint(parcel, sp);
    final fit = fitFootprint(free, foot.width, foot.depth) ?? free;
    return SiteEnvelope(fit.x0, fit.y0, fit.x1, fit.y1);
  }
}

/// Writes [ctx]'s kerbside plan (§2.3): one `kerbside` join on slot 0, no
/// network, the §6.1 envelope, its door, the pavement point at slot 0 and
/// the footpath between them.
void emitKerbOnly(PlanBuilder b, SiteContext ctx, {int flags = 0}) {
  final env = ctx.kerbsideEnvelope();
  ctx.beginSite(b, SiteProgram.kerbOnly, flags & ~kPlanNetwork, env);
  ctx.addJoin(b, 0, kind: SiteJoinKind.kerbside);
  final pave = ctx.kerbsidePavementPoint(b);
  final int door;
  if (env.isEmpty || ctx.frame == null) {
    final ip = interiorPoint(ctx.parcel.polygon);
    door = b.point(ip.e, ip.n);
  } else {
    final (dx, dy) = envelopeDoor(env);
    door = ctx.localPoint(b, dx, dy);
  }
  ctx.finishPedestrians(b, door, pave);
  b.endSite();
}

/// The generator entry points [planSite] dispatches to. [standard] is the
/// real set; tests hand in fakes to pin the dispatch rules (a yard generator
/// that returns a car park, say) without depending on a track's generator.
class SiteGenerators {
  const SiteGenerators({
    this.installation = installationPlanOf,
    this.home = homeDrivewayPlanOf,
    this.yard = yardPlanOf,
    this.carPark = carParkPlanOf,
  });

  /// The generators of `installation_access.dart`, `home_driveway.dart` and
  /// `car_park_packer.dart`.
  static const SiteGenerators standard = SiteGenerators();

  final SiteGeneratedPlan? Function(SiteContext ctx) installation;
  final SiteGeneratedPlan? Function(SiteContext ctx) home;
  final SiteGeneratedPlan? Function(SiteContext ctx) yard;
  final SiteGeneratedPlan? Function(SiteContext ctx) carPark;
}

/// Plans one site into [b] by §3.3 (first match wins) and returns the program
/// written, or null when no plan is stored: unbuilt (row 0a), no join slot,
/// or no eligible road in reach of a frontage-less site (§3.1 `none`).
///
/// Fall-through: installation → kerbOnly; a small installation site → yard →
/// kerbOnly; home (back-out rules 1–4, then §3.4) → kerbOnly; industrial
/// yard → kerbOnly; everything else car park → kerbOnly.
///
/// The yard rule (frozen): `yardPlanOf` tries the car park itself. It returns
/// a `yard` plan, or a `carPark` plan when the apron does not fit (counted
/// `yardNoFit`, flagged `kPlanFallback`), or null exactly when neither fits
/// (counted `yardNoFit`, then `kerbOnly` with `kPlanFallback`; the car park
/// generator is NOT asked again).
///
/// A program lesser than the one offered carries `kPlanFallback` (a yard
/// offered to a small installation site carries it too); row 0c carries
/// `kPlanAccessBlocked`. Each demotion is counted in [stats].
SiteProgram? planSite(PlanBuilder b, SiteContext ctx,
    {SiteProgramStats? stats,
    SiteGenerators generators = SiteGenerators.standard}) {
  final spec = ctx.spec;
  if (spec == null || ctx.slotCount == 0 || ctx.noFrontageRoad) {
    stats?.unplanned++;
    return null;
  }
  final offer = classifyProgram(
    spec: spec,
    slot0: ctx.slot0,
    widthM: ctx.widthM,
    depthM: ctx.depthM,
    hasFrame: ctx.frame != null,
    lotBuilt: ctx.lotBuilt,
  );
  void demote(SiteDemotion d) {
    if (stats != null) stats.demotions[d.index]++;
  }

  SiteProgram kerb(int flags) {
    emitKerbOnly(b, ctx, flags: flags);
    stats?.programs[SiteProgram.kerbOnly.index]++;
    return SiteProgram.kerbOnly;
  }

  SiteProgram written(SiteGeneratedPlan p, int flags) {
    p.emit(b, ctx, flags);
    stats?.programs[p.program.index]++;
    return p.program;
  }

  final od = offer.demotion;
  if (od != null) demote(od);
  switch (offer.program) {
    case SiteProgram.none:
    case SiteProgram.kerbOnly:
      return kerb(offer.flags);
    case SiteProgram.installation:
      final p = generators.installation(ctx);
      if (p != null) return written(p, 0);
      demote(SiteDemotion.installationNoFit);
      return kerb(kPlanFallback);
    case SiteProgram.homeDriveway:
      final rule = homeBackOutFailure(ctx.graph, ctx.slot0, ctx.frame!.v);
      if (rule != null) {
        demote(rule);
        return kerb(kPlanFallback);
      }
      final p = generators.home(ctx);
      if (p != null) return written(p, 0);
      demote(SiteDemotion.homeGeometry);
      return kerb(kPlanFallback);
    case SiteProgram.yard:
      final fell = od == SiteDemotion.installationTooSmall ? kPlanFallback : 0;
      final y = generators.yard(ctx);
      if (y != null && y.program == SiteProgram.yard) return written(y, fell);
      demote(SiteDemotion.yardNoFit);
      if (y != null) return written(y, kPlanFallback);
      return kerb(kPlanFallback);
    case SiteProgram.carPark:
      final c = generators.carPark(ctx);
      if (c != null) return written(c, 0);
      demote(SiteDemotion.carParkNoFit);
      return kerb(kPlanFallback);
  }
}

/// Plans [sites] in order into chunks of at most [kSitesPerChunk] PLANNED
/// sites (sites that store no plan take no row). Deterministic: the same
/// sites in the same order give byte-identical chunks. With [validate], each
/// chunk is checked against V1–V13 in debug builds (`PlanBuilder.build`).
List<SiteAccessChunk> planSites(RoadGraph graph, List<SiteContext> sites,
    {SiteProgramStats? stats,
    bool validate = true,
    SiteGenerators generators = SiteGenerators.standard}) {
  final chunks = <SiteAccessChunk>[];
  var b = PlanBuilder(graph: graph);
  for (final ctx in sites) {
    if (b.siteCount == kSitesPerChunk) {
      chunks.add(b.build(validate: validate));
      b = PlanBuilder(graph: graph);
    }
    planSite(b, ctx, stats: stats, generators: generators);
  }
  if (b.siteCount > 0) chunks.add(b.build(validate: validate));
  return chunks;
}

/// Every BUILT site of [city] as a context over [graph] (default: the city's
/// road graph), in §4.1's order: manual lots, auto lots (both in the
/// layout's list order), then occupied grid cells in ASCENDING anchor order,
/// abandoned cells skipped as BuildingTable skips them.
///
/// The cells are sorted because `CitySim.occupiedCells` walks a set and a map
/// (insertion order: a loaded save can differ from a live town), which §3.9
/// forbids generation to depend on. A convenience for full-town runs, tests
/// and benches; the book keeps its own resumable walk (with its easement
/// sites first, §4.1), and orders its cells the same way.
List<SiteContext> siteContextsOf(CitySim city, {RoadGraph? graph}) {
  final g = graph ?? city.roadGraph;
  final stamp = g.structureStamp;
  bool built(int lot) {
    final id = g.lotIds[lot];
    if (city.parcelBuildings.containsKey(id)) return true;
    final p = city.layout.parcelById(id);
    return p != null && city.parcelGrownSpec(id, p.use) != null;
  }

  // (anchor, walk index, spec): ascending anchor, the walk index breaking
  // the tie of a cell reported twice (grown and a utility), as before.
  final cells = <(int, int, CityBuildingSpec)>[];
  for (final cell in city.occupiedCells()) {
    if (city.abandoned.contains(cell.key)) continue;
    cells.add((cell.key, cells.length, cell.value));
  }
  cells.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2 - b.$2);
  return [
    for (final (parcel, spec) in city.parcelBuiltLots())
      SiteContext.ofLot(g, parcel, spec, graphStamp: stamp, lotBuilt: built),
    for (final (anchor, _, spec) in cells)
      SiteContext.ofFootprint(g, city.parcelForCell(anchor, spec), spec,
          graphStamp: stamp, lotBuilt: built),
  ];
}

/// [siteContextsOf] [city], planned ([planSites]).
List<SiteAccessChunk> planCity(CitySim city,
    {RoadGraph? graph,
    SiteProgramStats? stats,
    bool validate = true,
    SiteGenerators generators = SiteGenerators.standard}) {
  final g = graph ?? city.roadGraph;
  return planSites(g, siteContextsOf(city, graph: g),
      stats: stats, validate: validate, generators: generators);
}
