// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// What a site access plan DRAWS (docs/plans/site-access.md §5.4): the
/// structural tiers of a site — its paving, its driveway, aisle, access-road
/// and throat ribbons, its turnaround pads, its gate and the paint on its
/// stalls.
///
/// A pure static class like `LotFeatures`, with no material and no draw of
/// its own: every surface goes into the tile's existing feature builders
/// (`featureApron` on the road material, `featureSolid` on the facade). Every
/// point is placed from the frame alone — `up·(datum + ptUp) + east·e +
/// north·n` minus the tile's anchor — so a worker draws a site from the
/// columns its request carries and nothing else.
///
/// **Tiers (§5.4).** A site is BIG when its pave area reaches
/// [bigPaveAreaM2] or its access roads reach [bigAccessRoadM]; MID-VISIBLE
/// when it is big or its pave area reaches [midPaveAreaM2]. A home (≈ 55–65 m²
/// of drive and pad) is neither, so the reference town's mostly-home tiles add
/// nothing at mid and far.
///
/// | Element | far | mid | near | detail |
/// |---|---|---|---|---|
/// | Access-road ribbons | big (bare) | big | ✓ + edge kerbs | – |
/// | Driveway/aisle/throat ribbons, turnaround pads | big | big | ✓ | – |
/// | Paves (fan-triangulated rings) | big | mid-visible (rings only) | ✓ | – |
/// | Gate posts | – | – | big | – |
/// | Stall paint | – | – | big | small |
///
/// Determinism: no `hashCode`, no `Random`, no clock, no map iteration. The
/// output of a site is a pure function of its plan rows and heights, so two
/// isolates that mesh one tile agree to the byte.
library;

import 'dart:math' as math;

import '../../../application/snapshot/city_site_frame.dart';
import '../../../domain/colony/city/site_access/site_access_constants.dart';
import '../../../domain/colony/city/site_access/site_access_plan.dart';
import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/shared/vector3.dart';
import '../coord_convert.dart';
import 'city_texture_bakes.dart';
import 'city_tile_bucketing.dart' show CityHash32, CityTileSite;
import 'city_tile_mesher.dart' show CityTier;
import 'lot_features.dart' show LotEdging;
import 'oriented_box.dart';
import 'road_mesher.dart';
import 'site_dressing_mesher.dart';

/// What a tile draws a site at: the tile's own tier, or the detail layer's
/// pass over the buildings round the eye.
enum SiteDrawTier { far, mid, near, detail }

/// How big a site's plan draws (§5.4): the two thresholds, measured once.
class SiteDrawSize {
  const SiteDrawSize(this.paveAreaM2, this.accessRoadM);

  /// Total area of the plan's pave rings, square metres.
  final double paveAreaM2;

  /// Total length of the plan's access-road segments, metres.
  final double accessRoadM;

  /// Drawn at every tier, far included.
  bool get big =>
      paveAreaM2 >= SiteAccessMesher.bigPaveAreaM2 ||
      accessRoadM >= SiteAccessMesher.bigAccessRoadM;

  /// Its paves are drawn at mid.
  bool get midVisible => big || paveAreaM2 >= SiteAccessMesher.midPaveAreaM2;
}

/// One site waiting for its tile: the frame and row to draw, the body it is
/// on, and the tile whose new build will have it.
class InstantSite {
  const InstantSite(this.bodyId, this.frame, this.geometry, this.site,
      this.tileKey);
  final String bodyId;
  final CitySiteFrame frame;
  final SiteChunkGeometry geometry;
  final int site;
  final String tileKey;
}

/// Which sites the instant path draws: those whose plan is new since the
/// last cut, until their tiles catch up.
///
/// The road tool's twin (`instant_road_nodes.dart`): a tile is meshed on a
/// worker and lands seconds after the frame that changed it, which for a
/// drive the player has just caused to be laid reads as nothing happening.
/// A site is known by its book slot AND its key (its plan `rev` mixed with
/// its heights), so a re-planned site is new and a re-published one that
/// draws the same is not.
class InstantSiteTracker {
  /// Sites a single cut may hand the instant path. A player's edit moves a
  /// plan or two; a cut past this — a colony loaded, a town generated — is
  /// the tiles' to bring in.
  static int maxEditedPerCut = 64;

  final Map<String, Set<int>> _seen = {};
  final Map<int, InstantSite> _pending = {};
  final Map<String, int> _revision = {};

  /// A site's identity: its book slot and its key, in two 32-bit lanes
  /// packed into 53 bits (the most an int holds exactly on the web).
  static int contentKey(int slot, int siteKey) {
    final lo = CityHash32.mix(CityHash32.mix(0x1B873593, slot), siteKey);
    final hi = CityHash32.mix(CityHash32.mix(0x2545F491, siteKey), slot);
    return (hi & 0x1FFFFF) * 0x100000000 + lo;
  }

  /// Note a new cut: the sites whose plan is new join the pending set, and
  /// pending sites the cut no longer has leave it.
  void noteCut(Iterable<(String bodyId, String tileKey, List<CityTileSite>)> tiles) {
    final now = <String, Map<int, InstantSite>>{};
    for (final (bodyId, tileKey, sites) in tiles) {
      final on = now[bodyId] ??= {};
      for (final s in sites) {
        final key = contentKey(s.geometry.siteSlot(s.site),
            s.geometry.siteKey(s.site));
        on[key] = InstantSite(bodyId, s.frame, s.geometry, s.site, tileKey);
      }
    }
    final touched = <String>{};
    _pending.removeWhere((k, e) {
      final gone = !(now[e.bodyId]?.containsKey(k) ?? false);
      if (gone) touched.add(e.bodyId);
      return gone;
    });
    for (final entry in now.entries) {
      final body = entry.key;
      final sites = entry.value;
      final seen = _seen[body];
      final edited = seen == null
          ? sites.keys.toList()
          : [
              for (final k in sites.keys)
                if (!seen.contains(k)) k,
            ];
      _seen[body] = sites.keys.toSet();
      if (edited.isEmpty || edited.length > maxEditedPerCut) continue;
      for (final k in edited) {
        if (_pending.containsKey(k)) continue;
        _pending[k] = sites[k]!;
        touched.add(body);
      }
    }
    _seen.removeWhere((body, _) => !now.containsKey(body));
    for (final body in touched) {
      _revision[body] = (_revision[body] ?? 0) + 1;
    }
  }

  /// Drop every pending site whose tile [showsCurrent]. True when any went.
  bool retire(bool Function(String tileKey) showsCurrent) {
    if (_pending.isEmpty) return false;
    final touched = <String>{};
    _pending.removeWhere((_, e) {
      final done = showsCurrent(e.tileKey);
      if (done) touched.add(e.bodyId);
      return done;
    });
    for (final body in touched) {
      _revision[body] = (_revision[body] ?? 0) + 1;
    }
    return touched.isNotEmpty;
  }

  Set<String> get bodies => {for (final e in _pending.values) e.bodyId};

  bool hasPendingOn(String bodyId) =>
      _pending.values.any((e) => e.bodyId == bodyId);

  Iterable<InstantSite> pendingOn(String bodyId) =>
      _pending.values.where((e) => e.bodyId == bodyId);

  int get pendingCount => _pending.length;

  /// Moves whenever [bodyId]'s pending set does: what its node is keyed on.
  int revisionOf(String bodyId) => _revision[bodyId] ?? 0;

  void reset() {
    _seen.clear();
    _pending.clear();
    for (final body in _revision.keys.toList()) {
      _revision[body] = _revision[body]! + 1;
    }
  }
}

/// One station of a site ribbon: the point, its radial, the unit normal
/// across it, its arc from the ribbon's first point, and the colony-local
/// (east, north) it came from — what the pave rings are measured in, so a
/// ribbon can be cut where a ring already carries the surface.
class _Station {
  const _Station(this.p, this.up, this.side, this.s, this.e, this.n);
  final Vector3 p, up, side;
  final double s, e, n;
}

abstract final class SiteAccessMesher {
  /// How far a site's paving rides over its point heights (§5.4): over the
  /// zoned-lot patch (0.05 and up) and the building's slab (0.08–0.10), under
  /// nothing else.
  static const double paveLiftM = 0.13;

  /// Paint on the paving, as the road's paint rides its ribbon.
  static const double paintLiftM = paveLiftM + RoadMesher.paintLiftM;

  /// A site is mid-visible at this pave area, and big at [bigPaveAreaM2] or
  /// [bigAccessRoadM] of access road (§5.4).
  static const double midPaveAreaM2 = 150.0;
  static const double bigPaveAreaM2 = 1500.0;
  static const double bigAccessRoadM = 40.0;

  /// The face an access road's edge kerb drops at the near tier.
  static const double edgeKerbFaceM = 0.10;

  /// The throat's lift ease (§5.4): the dropped kerb at the road, the walk's
  /// top over the pavement band, then the site's own paving.
  ///
  /// The crossing rides one paint's lift over the walk the whole way: the
  /// flags themselves ramp from [RoadMesher.cutTopLiftM] at the dropped kerb
  /// to [RoadMesher.walkTopLiftM] at their back edge over the same
  /// [throatRampM] band, so a throat drawn at the walk's own heights would be
  /// buried under it for its whole crossing.
  static const double throatKerbLiftM =
      RoadMesher.cutTopLiftM + RoadMesher.paintLiftM;
  static const double throatWalkLiftM =
      RoadMesher.walkTopLiftM + RoadMesher.paintLiftM;
  static const double throatRampM = 3.0;
  static const double throatSettleM = 1.5;

  /// Half width of a painted stall line.
  static const double stallLineHalfM = 0.06;

  /// A gate post: its side and its height.
  static const double gatePostM = 0.35;
  static const double gatePostHeightM = 2.6;

  /// A throat's lift [d] metres from its kerb node (§5.4): one paint's lift
  /// over the dropped kerb, one paint's lift over the flags at the back of
  /// the pavement band, and the site's own paving a settle later.
  ///
  /// The walk under it ramps from [RoadMesher.cutTopLiftM] to
  /// [RoadMesher.walkTopLiftM] across the same [throatRampM] band, so the
  /// difference over the whole crossing is exactly [RoadMesher.paintLiftM].
  static double throatLiftAt(double d) {
    if (d <= 0) return throatKerbLiftM;
    if (d < throatRampM) {
      return throatKerbLiftM +
          (throatWalkLiftM - throatKerbLiftM) * (d / throatRampM);
    }
    if (d < throatRampM + throatSettleM) {
      final t = (d - throatRampM) / throatSettleM;
      return throatWalkLiftM + (paveLiftM - throatWalkLiftM) * t;
    }
    return paveLiftM;
  }

  /// The draw tier of a tile at [tier]. A detail job asks for
  /// [SiteDrawTier.detail] itself.
  static SiteDrawTier tierFor(CityTier tier) => switch (tier) {
        CityTier.near => SiteDrawTier.near,
        CityTier.mid => SiteDrawTier.mid,
        CityTier.far => SiteDrawTier.far,
      };

  /// [plan]'s size class (§5.4). Cheap: one pass over its rings and its
  /// segments.
  static SiteDrawSize sizeOf(SiteAccessPlan plan) {
    var area = 0.0;
    for (var r = 0; r < plan.paveCount; r++) {
      area += _ringArea(plan, r);
    }
    var road = 0.0;
    for (var k = 0; k < plan.segCount; k++) {
      if (plan.segKind(k) == SiteSegmentKind.accessRoad) road += plan.segLenM(k);
    }
    return SiteDrawSize(area, road);
  }

  /// Every site of [frames] into [apron] (the road material) and [solid]
  /// (the facade), at [tier]. The tile's own sites, as its request carries
  /// them (`CityTileMembers.sites`).
  ///
  /// With [cars] and [glow] a BIG site's near tier also takes its dressing
  /// — its lamps and the cars baked into its stalls (§5.4, R6), at most
  /// [carBudget] of them over all the sites here, and none on a site the
  /// frame says agent traffic manages (§5.5). Returns the cars placed.
  static int emitAll(
    List<CitySiteFrame> frames, {
    required MeshBuilder apron,
    required MeshBuilder solid,
    required Vector3 anchorBF,
    required SiteDrawTier tier,
    MeshBuilder? cars,
    MeshBuilder? glow,
    int carBudget = 0,
    bool airless = false,
  }) {
    var placed = 0;
    for (final frame in frames) {
      for (var c = 0; c < frame.chunks.length; c++) {
        final geo = frame.chunks[c];
        for (var site = 0; site < geo.siteCount; site++) {
          placed += emit(
            apron: apron,
            solid: solid,
            frame: frame,
            geo: geo,
            site: site,
            anchorBF: anchorBF,
            tier: tier,
            cars: cars,
            glow: glow,
            carBudget: carBudget - placed,
            airless: airless,
            agentManaged: frame.isAgentManaged(c, site),
          );
        }
      }
    }
    return placed;
  }

  /// One site of [geo] into the builders, at [tier]. Returns the baked lot
  /// cars placed (0 without [cars]).
  static int emit({
    required MeshBuilder apron,
    required MeshBuilder solid,
    required CitySiteFrame frame,
    required SiteChunkGeometry geo,
    required int site,
    required Vector3 anchorBF,
    required SiteDrawTier tier,
    MeshBuilder? cars,
    MeshBuilder? glow,
    int carBudget = 0,
    bool airless = false,
    bool agentManaged = false,
  }) {
    final chunk = geo.plan;
    final plan = chunk.plan(site);
    if (plan.segCount == 0 && plan.paveCount == 0) return 0;
    final size = sizeOf(plan);
    // What this tier draws of a site this size.
    final bool paves, ribbons, kerbs, gate, stalls;
    switch (tier) {
      case SiteDrawTier.far:
        paves = size.big;
        ribbons = size.big;
        kerbs = false;
        gate = false;
        stalls = false;
      case SiteDrawTier.mid:
        paves = size.midVisible;
        ribbons = size.big;
        kerbs = false;
        gate = false;
        stalls = false;
      case SiteDrawTier.near:
        paves = true;
        ribbons = true;
        kerbs = true;
        gate = size.big;
        stalls = size.big;
      case SiteDrawTier.detail:
        // The detail layer draws what the near tile left: the small sites'
        // paint. A big site's paint is already in its tile.
        paves = false;
        ribbons = false;
        kerbs = false;
        gate = false;
        stalls = !size.big;
    }
    if (!paves && !ribbons && !kerbs && !gate && !stalls) return 0;

    final p0 = chunk.ptStart(site);
    Vector3 at(int p) =>
        frame.localToBodyFixed(plan.ptE(p), plan.ptN(p), geo.ptUp(p0 + p)) -
        anchorBF;

    if (paves) _emitPaves(apron, plan, at, anchorBF);
    if (ribbons) {
      for (var k = 0; k < plan.segCount; k++) {
        _emitSegment(apron, plan, at, anchorBF, k, kerbs: false);
      }
      _emitTurnarounds(apron, frame, plan, at, anchorBF);
    }
    if (kerbs) {
      for (var k = 0; k < plan.segCount; k++) {
        if (plan.segKind(k) != SiteSegmentKind.accessRoad) continue;
        _emitSegment(apron, plan, at, anchorBF, k, kerbs: true);
      }
    }
    if (gate) _emitGate(solid, frame, plan, at, anchorBF);
    if (!stalls) return 0;
    // The paint, and the dressing that goes with it (§5.4, R6): the bays
    // marked, the arrows on the drives, the hatch on the loading bays —
    // and, where the caller hands over the builders, the lamps and the
    // cars in the stalls.
    _emitStalls(apron, frame, geo, site, plan, anchorBF);
    final d = SiteDraw(frame, geo, site, anchorBF);
    SiteDressingMesher.emitArrows(apron, d);
    SiteDressingMesher.emitBayHatch(apron, d);
    if (glow != null) SiteDressingMesher.emitLamps(solid, glow, d);
    if (cars == null || glow == null || agentManaged || carBudget <= 0) {
      return 0;
    }
    return SiteDressingMesher.emitLotCars(cars, glow, d,
        maxCars: math.min(maxLotCars, carBudget), airless: airless);
  }

  /// The most cars one site bakes, whatever the tile's budget: the ceiling
  /// the legacy `emitLot` kept, carried over when it was deleted (R7).
  static const int maxLotCars = 12;

  /// The DRESSING of one plan-served building's site (§5.4, §5.5, R6),
  /// drawn with its lot furniture: its fence ring with the plan's gaps, its
  /// sign, its footpaths, and — for a site its own tile does not dress
  /// (anything but a BIG one) — its paint, arrows, hatch, lamps, wheel
  /// stops and the cars in its stalls.
  ///
  /// Returns the cars placed. [full] is the building's own tier: pickets
  /// rather than a coarse fence, and the wheel stops.
  static int emitDressing({
    required MeshBuilder apron,
    required MeshBuilder solid,
    required MeshBuilder glow,
    required MeshBuilder cars,
    required CitySiteFrame frame,
    required SiteChunkGeometry geo,
    required int site,
    required Vector3 anchorBF,
    required bool full,
    required LotEdging edging,
    required bool sign,
    required double signScale,
    required bool airless,
    required bool agentManaged,
    required int carBudget,
  }) {
    final d = SiteDraw(frame, geo, site, anchorBF);
    SiteDressingMesher.emitFenceRing(solid, d, edging, coarse: !full);
    if (sign) SiteDressingMesher.emitSign(solid, glow, d, signScale);
    SiteDressingMesher.emitFootpaths(apron, d);
    final small = !sizeOf(d.plan).big;
    if (!small) return 0;
    if (full) SiteDressingMesher.emitWheelStops(apron, d);
    return emit(
      apron: apron,
      solid: solid,
      frame: frame,
      geo: geo,
      site: site,
      anchorBF: anchorBF,
      tier: SiteDrawTier.detail,
      cars: cars,
      glow: glow,
      carBudget: carBudget,
      airless: airless,
      agentManaged: agentManaged,
    );
  }

  // ---- Paving --------------------------------------------------------------------

  /// The plan's pave rings, fan-triangulated: convex and counter-clockwise by
  /// the generation contract (§5.4), so a fan from the first vertex covers
  /// each exactly.
  static void _emitPaves(MeshBuilder m, SiteAccessPlan plan,
      Vector3 Function(int p) at, Vector3 anchorBF) {
    for (var r = 0; r < plan.paveCount; r++) {
      final a = plan.paveStart(r), b = plan.paveStart(r + 1);
      if (b - a < 3) continue;
      final band = _bandOf(plan.paveSurface(r));
      final idx = <int>[];
      for (var i = a; i < b; i++) {
        final p = plan.pavePt(i);
        final world = at(p);
        final up = (world + anchorBF).normalized;
        final (x, y) = _framePoint(plan, plan.ptE(p), plan.ptN(p));
        idx.add(m.vertex(
          (world + up * paveLiftM) * kRenderScale,
          up,
          RoadMesher.bandU(band, _frac(x / RoadMesher.tileM)),
          y / RoadMesher.tileM,
        ));
      }
      for (var i = 1; i + 1 < idx.length; i++) {
        m.triangle(idx[0], idx[i], idx[i + 1]);
      }
    }
  }

  // ---- Ribbons --------------------------------------------------------------------

  /// Segment [k] as a ribbon of its own width, and — with [kerbs] — the
  /// 10 cm edge kerb an access road carries at the near tier instead of its
  /// surface (§5.4).
  static void _emitSegment(MeshBuilder m, SiteAccessPlan plan,
      Vector3 Function(int p) at, Vector3 anchorBF, int k,
      {required bool kerbs}) {
    final n = plan.segPointCount(k);
    if (n < 2) return;
    final rows = <int>[for (var i = 0; i < n; i++) plan.segPoint(k, i)];
    var pts = <Vector3>[for (final p in rows) at(p)];
    var es = <double>[for (final p in rows) plan.ptE(p)];
    var ns = <double>[for (final p in rows) plan.ptN(p)];
    final half = plan.segWidthM(k) / 2;
    if (half <= 0) return;
    final throat = plan.segFlags(k) & kSegThroat != 0;
    // A throat crosses the pavement: it leaves the kerb at the dropped-kerb
    // height, rises to the walk's top over the pavement band and settles
    // onto the site's paving inside the lot line.
    final fromKerb = throat && _kerbAtStart(plan, k);
    if (throat) {
      // The plan's own stations are its vias — tens of metres apart on an
      // installation's spine. The ease has to be sampled where it bends or
      // the crossing is one long slope from the kerb, so the two knees go in
      // as stations of their own, as `RoadMesher._withStations` does for a
      // dropped kerb.
      var whole = 0.0;
      for (var i = 1; i < pts.length; i++) {
        whole += (pts[i] - pts[i - 1]).length;
      }
      final knees = fromKerb
          ? [throatRampM, throatRampM + throatSettleM]
          : [whole - throatRampM - throatSettleM, whole - throatRampM];
      (pts, es, ns) = _densified(pts, es, ns, [
        for (final d in knees)
          if (d > 1e-3 && d < whole - 1e-3) d,
      ]);
    }
    final st = _stationsOf(pts, es, ns, anchorBF);
    if (st.length < 2) return;
    final total = st.last.s;
    double liftAt(double s) =>
        throat ? throatLiftAt(fromKerb ? s : total - s) : paveLiftM;

    if (kerbs) {
      _emitEdgeKerbs(m, st, half, liftAt);
      return;
    }
    // Where a pave ring already carries the surface the ribbon is cut
    // (§5.4's lift stack), so a drive is not drawn twice, exactly coplanar
    // and in two different bands. Only the flat part is cut: a throat's ramp
    // over the pavement rides above every ring and stays whole.
    final drawn = List<bool>.filled(st.length - 1, true);
    for (var i = 0; i + 1 < st.length; i++) {
      final mid = (st[i].s + st[i + 1].s) / 2;
      if (liftAt(mid) > paveLiftM + 1e-9) continue;
      if (insidePave(plan, (st[i].e + st[i + 1].e) / 2,
          (st[i].n + st[i + 1].n) / 2)) {
        drawn[i] = false;
      }
    }
    final band = throat
        ? CityTextureBakes.roadConcrete
        : CityTextureBakes.roadAsphalt;
    final u0 = RoadMesher.bandU(band, 0), u1 = RoadMesher.bandU(band, 1);
    int? prevL, prevR;
    for (var i = 0; i < st.length; i++) {
      final before = i > 0 && drawn[i - 1];
      final after = i + 1 < st.length && drawn[i];
      if (!before && !after) {
        prevL = null;
        prevR = null;
        continue;
      }
      final k0 = st[i];
      final c = k0.p + k0.up * liftAt(k0.s);
      final v = k0.s / RoadMesher.tileM;
      final l = m.vertex((c - k0.side * half) * kRenderScale, k0.up, u0, v);
      final r = m.vertex((c + k0.side * half) * kRenderScale, k0.up, u1, v);
      if (before && prevL != null && prevR != null) m.quad(prevL, prevR, r, l);
      prevL = l;
      prevR = r;
    }
  }

  /// A kerb down each edge of an access road: a vertical face looking in at
  /// the carriageway, [edgeKerbFaceM] tall under the ribbon's own lift.
  static void _emitEdgeKerbs(MeshBuilder m, List<_Station> st, double half,
      double Function(double s) liftAt) {
    final band = CityTextureBakes.roadConcrete;
    final u0 = RoadMesher.bandU(band, 0.2), u1 = RoadMesher.bandU(band, 0.8);
    for (final sign in const [-1.0, 1.0]) {
      int? prevT, prevB;
      for (final k in st) {
        final lift = liftAt(k.s);
        final edge = k.p + k.side * (half * sign);
        final inward = k.side * -sign;
        final t = m.vertex((edge + k.up * lift) * kRenderScale, inward, u0,
            k.s / RoadMesher.tileM);
        final b = m.vertex(
            (edge + k.up * (lift - edgeKerbFaceM)) * kRenderScale,
            inward,
            u1,
            k.s / RoadMesher.tileM);
        if (prevT != null && prevB != null) {
          if (sign > 0) {
            m.quad(prevB, prevT, t, b);
          } else {
            m.quad(prevT, prevB, b, t);
          }
        }
        prevT = t;
        prevB = b;
      }
    }
  }

  /// The turnaround at every dead end that has one (§2.3): a circle's disc,
  /// or a hammerhead's square apron about its node, on the arm where the
  /// plan gives one.
  static void _emitTurnarounds(MeshBuilder m, CitySiteFrame frame,
      SiteAccessPlan plan, Vector3 Function(int p) at, Vector3 anchorBF) {
    for (var n = 0; n < plan.nodeCount; n++) {
      final kind = plan.nodeTurnKind(n);
      if (kind == TurnaroundKind.none) continue;
      final r = plan.nodeTurnR(n);
      if (!(r > 0)) continue;
      final centre = at(plan.nodePt(n));
      final up = (centre + anchorBF).normalized;
      final band = CityTextureBakes.roadAsphalt;
      final uMid = RoadMesher.bandU(band, 0.5);
      // A pad lies flat on the site's paving, so it is cut at the pave rings
      // exactly as the ribbons are: a triangle whose centre a ring already
      // carries is the ring's own surface drawn again.
      bool covered(Vector3 a, Vector3 b, Vector3 c) {
        final mid = (a + b + c) * (1 / 3) + anchorBF;
        return insidePave(plan, mid.dot(frame.east), mid.dot(frame.north));
      }

      if (kind == TurnaroundKind.circle) {
        const steps = 16;
        final (ax, ay) = _axesOf(frame, plan, up);
        final rim = <Vector3>[
          for (var i = 0; i < steps; i++)
            () {
              final a = 2 * math.pi * i / steps;
              return centre + ax * (r * math.cos(a)) + ay * (r * math.sin(a));
            }(),
        ];
        final keep = <bool>[
          for (var i = 0; i < steps; i++)
            !covered(centre, rim[i], rim[(i + 1) % steps]),
        ];
        var any = false;
        for (final k in keep) {
          any = any || k;
        }
        if (!any) continue;
        final hub = m.vertex(
            (centre + up * paveLiftM) * kRenderScale, up, uMid, 0.5);
        final ring = List<int?>.filled(steps, null);
        int vert(int i) {
          final was = ring[i];
          if (was != null) return was;
          final a = 2 * math.pi * i / steps;
          return ring[i] = m.vertex((rim[i] + up * paveLiftM) * kRenderScale,
              up,
              RoadMesher.bandU(band, 0.5 + 0.4 * math.cos(a)),
              0.5 + 0.4 * math.sin(a));
        }

        for (var i = 0; i < steps; i++) {
          if (!keep[i]) continue;
          m.triangle(hub, vert(i), vert((i + 1) % steps));
        }
        continue;
      }
      // A hammerhead: the clear apron it turns on, square about the node,
      // aligned to its arm when it has one.
      final (ax, ay) = _hammerheadAxes(frame, plan, n, up);
      final h = r / 2;
      final corners = [
        centre - ax * h - ay * h,
        centre + ax * h - ay * h,
        centre + ax * h + ay * h,
        centre - ax * h + ay * h,
      ];
      // `quad(a, b, c, d)` is (a, b, c) and (a, c, d).
      final first = !covered(corners[0], corners[1], corners[2]);
      final second = !covered(corners[0], corners[2], corners[3]);
      if (!first && !second) continue;
      final idx = [
        for (var i = 0; i < 4; i++)
          m.vertex((corners[i] + up * paveLiftM) * kRenderScale, up,
              RoadMesher.bandU(band, i == 1 || i == 2 ? 1 : 0),
              i >= 2 ? 2 * h / RoadMesher.tileM : 0),
      ];
      if (first) m.triangle(idx[0], idx[1], idx[2]);
      if (second) m.triangle(idx[0], idx[2], idx[3]);
    }
  }

  // ---- The gate --------------------------------------------------------------------

  /// The posts of an installation's gate: one each side of the gap the fence
  /// leaves, at the gate node the plan holds (§6.1 step 4).
  static void _emitGate(MeshBuilder m, CitySiteFrame frame, SiteAccessPlan plan,
      Vector3 Function(int p) at, Vector3 anchorBF) {
    final w = plan.gateW;
    if (!(w > 0)) return;
    for (var n = 0; n < plan.nodeCount; n++) {
      if (plan.nodeFlags(n) & kNodeGate == 0) continue;
      final centre = at(plan.nodePt(n));
      final up = (centre + anchorBF).normalized;
      // The gate stands on the envelope's front edge, so its posts sit
      // across the frame's u.
      final (ax, ay) = _axesOf(frame, plan, up);
      for (final s in const [-1.0, 1.0]) {
        OrientedBox.upright(m, centre + ax * (w / 2 * s), ay, up, gatePostM,
            gatePostM, gatePostHeightM);
      }
      return;
    }
  }

  // ---- Stall paint --------------------------------------------------------------------

  /// The line between bays, down each side of every stall the plan lays out
  /// on a bay (§5.4). An `inline` stall is a home drive's own width — there
  /// is no bay to mark — so it takes no paint.
  static void _emitStalls(MeshBuilder m, CitySiteFrame frame,
      SiteChunkGeometry geo, int site, SiteAccessPlan plan, Vector3 anchorBF) {
    final chunk = geo.plan;
    final st0 = chunk.stallStart(site);
    final band = CityTextureBakes.roadWhite;
    final u0 = RoadMesher.bandU(band, 0), u1 = RoadMesher.bandU(band, 1);
    for (var i = 0; i < plan.stallCount; i++) {
      if (plan.stallAngle(i) == StallAngle.inline) continue;
      final len = plan.stallLenM(i), wide = plan.stallWidthM(i);
      if (!(len > 0) || !(wide > 0)) continue;
      final upM = geo.stallUp(st0 + i);
      final centre =
          frame.localToBodyFixed(plan.stallE(i), plan.stallN(i), upM) - anchorBF;
      final up = (centre + anchorBF).normalized;
      // The nose direction in the tangent plane, and the axis across it.
      final nose = _tangent(frame, plan.stallDirE(i), plan.stallDirN(i), up);
      if (nose == null) continue;
      final across = nose.cross(up).normalized;
      for (final s in const [-1.0, 1.0]) {
        final edge = centre + across * (wide / 2 * s);
        final a = edge - nose * (len / 2), b = edge + nose * (len / 2);
        final o = up * paintLiftM;
        final q = [
          m.vertex((a - across * stallLineHalfM + o) * kRenderScale, up, u0, 0),
          m.vertex((a + across * stallLineHalfM + o) * kRenderScale, up, u1, 0),
          m.vertex((b + across * stallLineHalfM + o) * kRenderScale, up, u1,
              len / RoadMesher.tileM),
          m.vertex((b - across * stallLineHalfM + o) * kRenderScale, up, u0,
              len / RoadMesher.tileM),
        ];
        m.quad(q[0], q[1], q[2], q[3]);
      }
    }
  }

  // ---- Frames and helpers ----------------------------------------------------------

  /// [pts] as stations: each point's radial, the unit normal across the
  /// polyline there, its arc from the first, and its colony-local ([es],
  /// [ns]) — the three lists are one row per point.
  static List<_Station> _stationsOf(List<Vector3> pts, List<double> es,
      List<double> ns, Vector3 anchorBF) {
    final out = <_Station>[];
    var s = 0.0;
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i];
      if (i > 0) s += (p - pts[i - 1]).length;
      final ahead = i + 1 < pts.length ? pts[i + 1] - p : p - pts[i - 1];
      if (ahead.length < 1e-6) continue;
      final up = (p + anchorBF).normalized;
      final side = ahead.normalized.cross(up).normalized;
      out.add(_Station(p, up, side, s, es[i], ns[i]));
    }
    return out;
  }

  /// [pts] (with its colony-local [es], [ns]) carrying a point at each arc of
  /// [arcs] that falls strictly inside it. The polyline is unchanged; only
  /// its stations are denser.
  static (List<Vector3>, List<double>, List<double>) _densified(
      List<Vector3> pts,
      List<double> es,
      List<double> ns,
      List<double> arcs) {
    if (arcs.isEmpty || pts.length < 2) return (pts, es, ns);
    final wanted = [...arcs]..sort();
    final op = <Vector3>[pts.first];
    final oe = <double>[es.first], on = <double>[ns.first];
    var d = 0.0, next = 0;
    for (var i = 1; i < pts.length; i++) {
      final seg = pts[i] - pts[i - 1];
      final len = seg.length;
      if (len < 1e-6) continue;
      final d0 = d;
      d += len;
      while (next < wanted.length && wanted[next] <= d0 + 1e-6) {
        next++;
      }
      while (next < wanted.length && wanted[next] < d - 1e-6) {
        final t = (wanted[next] - d0) / len;
        op.add(pts[i - 1] + seg * t);
        oe.add(es[i - 1] + (es[i] - es[i - 1]) * t);
        on.add(ns[i - 1] + (ns[i] - ns[i - 1]) * t);
        next++;
      }
      op.add(pts[i]);
      oe.add(es[i]);
      on.add(ns[i]);
    }
    return (op, oe, on);
  }

  // ---- Pave cover ------------------------------------------------------------------

  /// Whether colony-local ([e], [n]) lies inside any of [plan]'s pave rings.
  ///
  /// A ring carries the surface (§5.4: the ribbons are "cut at pave rings"),
  /// so a ribbon quad or a turnaround pad the ring already covers is left
  /// out rather than drawn a second time, exactly coplanar with it.
  static bool insidePave(SiteAccessPlan plan, double e, double n) {
    for (var r = 0; r < plan.paveCount; r++) {
      if (_insideRing(plan, r, e, n)) return true;
    }
    return false;
  }

  /// Ring [r] is convex by the generation contract, so the point is in it
  /// when it is on the ring's own side of every edge. A ring that is not
  /// convex, or degenerate, reads as not covering: the ribbon is drawn, which
  /// is the safe way to be wrong.
  static bool _insideRing(SiteAccessPlan plan, int r, double e, double n) {
    final a = plan.paveStart(r), b = plan.paveStart(r + 1);
    if (b - a < 3) return false;
    final area = _signedRingArea(plan, r);
    if (area.abs() < 1e-9) return false;
    final want = area > 0 ? 1.0 : -1.0;
    for (var i = a; i < b; i++) {
      final p = plan.pavePt(i);
      final q = plan.pavePt(i + 1 < b ? i + 1 : a);
      final ex = plan.ptE(q) - plan.ptE(p), nx = plan.ptN(q) - plan.ptN(p);
      final cross = ex * (n - plan.ptN(p)) - nx * (e - plan.ptE(p));
      if (cross * want < 0) return false;
    }
    return true;
  }

  /// Whether segment [k]'s FIRST point is its kerb end.
  static bool _kerbAtStart(SiteAccessPlan plan, int k) {
    final from = plan.segFrom(k);
    if (from >= 0 && from < plan.nodeCount &&
        plan.nodeFlags(from) & kNodeKerb != 0) {
      return true;
    }
    return false;
  }

  /// The plan's frame axes (`u` and the `v` that runs into the lot) as unit
  /// tangents at [up].
  static (Vector3, Vector3) _axesOf(
      CitySiteFrame frame, SiteAccessPlan plan, Vector3 up) {
    final ax = _tangent(frame, plan.frameUE, plan.frameUN, up) ?? frame.east;
    return (ax, up.cross(ax).normalized);
  }

  /// A hammerhead's axes: along its arm where the plan gives one, else the
  /// plan's own frame.
  static (Vector3, Vector3) _hammerheadAxes(
      CitySiteFrame frame, SiteAccessPlan plan, int n, Vector3 up) {
    final hx = plan.nodeTurnHx(n), hn = plan.nodeTurnHn(n);
    if (hx * hx + hn * hn < 1e-6) return _axesOf(frame, plan, up);
    final ax = _tangent(frame, hx, hn, up) ?? frame.east;
    return (ax, up.cross(ax).normalized);
  }

  /// A colony-local direction (east, north) as a unit tangent at [up]: the
  /// frame's own east and north, less whatever of them [up] takes.
  static Vector3? _tangent(
      CitySiteFrame frame, double e, double n, Vector3 up) {
    var v = frame.east * e + frame.north * n;
    v = v - up * v.dot(up);
    return v.length < 1e-9 ? null : v.normalized;
  }

  /// Ring [r]'s area, by the shoelace over its points.
  static double _ringArea(SiteAccessPlan plan, int r) =>
      _signedRingArea(plan, r).abs();

  /// Ring [r]'s signed area: positive when its points run counter-clockwise
  /// in the colony's (east, north).
  static double _signedRingArea(SiteAccessPlan plan, int r) {
    final a = plan.paveStart(r), b = plan.paveStart(r + 1);
    if (b - a < 3) return 0;
    var twice = 0.0;
    for (var i = a; i < b; i++) {
      final p = plan.pavePt(i);
      final q = plan.pavePt(i + 1 < b ? i + 1 : a);
      twice += plan.ptE(p) * plan.ptN(q) - plan.ptE(q) * plan.ptN(p);
    }
    return twice / 2;
  }

  /// Colony-local ([e], [n]) in the site's own frame metres.
  static (double, double) _framePoint(SiteAccessPlan plan, double e, double n) {
    final de = e - plan.frameE, dn = n - plan.frameN;
    return (
      de * plan.frameUE + dn * plan.frameUN,
      de * plan.frameVE + dn * plan.frameVN,
    );
  }

  static int _bandOf(PaveSurface s) => switch (s) {
        PaveSurface.asphalt => CityTextureBakes.roadAsphalt,
        PaveSurface.concrete => CityTextureBakes.roadConcrete,
        PaveSurface.gravel => CityTextureBakes.roadShoulder,
      };

  /// [x] into [0, 1), for a texture that tiles.
  static double _frac(double x) {
    final f = x - x.floorToDouble();
    return f.isFinite ? f : 0.0;
  }
}
