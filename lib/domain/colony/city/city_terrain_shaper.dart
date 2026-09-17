// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import '../../shared/vector3.dart';
import '../../terrain/cubed_sphere.dart';
import '../../terrain/terrain_brush.dart';
import '../../terrain/terrain_lod.dart';
import '../surface_placement.dart';
import 'city_building_spec.dart';
import 'city_layout.dart';
import 'city_sim.dart';
import 'parcel.dart';
import 'site_access/site_grade.dart';
import 'spatial_index.dart';

/// The lateral resolution the renderer meshes chunk [k] of a body of
/// [radiusM] at among the edit [brushes] near it: [editResolutionFor], a
/// colony's own brushes — content with [CityTerrainShaper.colonyVoxelM] or
/// coarser — judged on the datum as they always were, and anything finer (a
/// road cut through relief, a crater) on the ground it lies on.
///
/// `TerrainNodes` meshes every leaf at this and nothing else: the one place
/// the renderer's choice is made, pure, so a test holds the choice the
/// renderer makes. Judged on the ground, a generated town's leaves were
/// boosted — 38 and 47 of them in view of a two- and a four-block town —
/// and its terrain's triangles doubled.
int colonyEditResolutionFor(
  ChunkKey k,
  double radiusM,
  int resolution,
  Iterable<TerrainBrush> brushes, {
  int maxBoost = 4,
  double voxelsAcrossBrush = 8,
  double? circumradiusM,
}) =>
    editResolutionFor(k, radiusM, resolution, brushes,
        maxBoost: maxBoost,
        voxelsAcrossBrush: voxelsAcrossBrush,
        circumradiusM: circumradiusM,
        datumTestFromVoxelM: CityTerrainShaper.colonyVoxelM);

/// Turns a colony's layout into terrain deformation.
///
/// A city does not sit on the landscape, it re-cuts it: building sites are
/// levelled, roads are graded through rises and over dips, and a quarry eats a
/// stepped hole out of the ground. All of that is expressed as [TerrainBrush]
/// edits, so it composes with the existing crater/excavation machinery,
/// survives LOD (the brushes are analytic, evaluated at any sample rate), and
/// is authoritative — the deformed surface is what a lander touches down on.
///
/// Emission is INCREMENTAL and keyed: each parcel, road and pit contributes one
/// brush, recorded once. Re-emitting every tick would grow the edit list without
/// bound and, because brushes compose by ordered `min`/`max`, would also make
/// the composed field depend on how long the game had been running.
class CityTerrainShaper {
  const CityTerrainShaper({
    this.padMarginM = 6,
    this.padFalloffM = 14,
    this.roadFalloffM = 6,
    this.padEdgeM = 0.6,
    this.voxelM = colonyVoxelM,
    this.corridorReliefTolM = 0.5,
    this.corridorCrossFallTolM = 1.0,
    this.corridorVoxelsAcross = 4,
    this.corridorVoxelsAcrossFalloff = 3,
    this.minCorridorVoxelM = 1,
    this.corridorCurveHalfM = 5,
    this.corridorCurveCrossFallTolM = 0.03,
    this.siteCorridorTolM = 0.25,
    this.siteCorridorReliefTolM = 0.5,
  });

  /// How far a levelled pad extends beyond the building footprint.
  final double padMarginM;

  /// Width of the ring easing a pad back into natural ground. This is the
  /// "softly" in soft levelling — a colony should look bulldozed, not stamped.
  final double padFalloffM;

  final double roadFalloffM;

  /// How far a LOT pad eases off past its own boundary. Deliberately tiny: see
  /// the call site — anything wide re-levels the neighbour.
  final double padEdgeM;

  /// Voxel size (m) the city's brushes are content to be meshed at — see
  /// [TerrainBrush.minVoxelM]. Derived from their radii, a lot pad asks for
  /// ~5 m and a road corridor for 1 m, which forces the quadtree to level
  /// 15-17 under every street: a six-block colony measured 1,133 resident
  /// chunks against ~590 for the same ground unbuilt. At 15 m the whole
  /// colony sits at level 13 (boosted). The trade is edge sharpness: pad
  /// rims and road shoulders are smoothed at this scale, which the ground
  /// patches cover inside the colony. First-test value; tune from the studio.
  ///
  /// Not for a road that cuts or fills: see [corridorReliefTolM].
  final double voxelM;

  /// [voxelM] as the world tick grades with it. The renderer keys its edit
  /// boost on it (`editResolutionFor`'s `datumTestFromVoxelM`): a brush this
  /// coarse is a colony's own, and is boosted as it always was.
  static const double colonyVoxelM = 15;

  /// How far (m) the ground around a graded road may stand off the grade it
  /// is cut to before the road asks for a finer mesh than [voxelM].
  ///
  /// A road is drawn on its corridor — the analytic field, exactly — but the
  /// ground is drawn from a MESH of that field, and at [voxelM] a mesh
  /// cannot hold a cut eight metres wide: the lattice lands a sample in it
  /// here and there and smooths the rest back up to the hillside. A road
  /// cut through the edge of a levelled lot on the dev site was drawn in
  /// pieces, the grass of that smoothing across it between them, 4.5 m over
  /// the carriageway where the cut was 5 m deep. Ground within this of the
  /// road's grade — a town founded on its own hillside, every generated
  /// street — the coarse mesh carries (to the kerb, give or take the
  /// ribbon's lift), and those corridors keep [voxelM].
  final double corridorReliefTolM;

  /// How steep a cross-fall (m, from the carriageway's centre to its edge)
  /// the coarse mesh may leave a corridor levelled flat across before the
  /// road asks for a finer one. Separate from [corridorReliefTolM]: a plane
  /// meshes exactly at any voxel, so a road on a side slope is off only
  /// where its flat bench is cut into it — the starter streets' 0.3 m, which
  /// read fine; a generated town's streets fall to 0.7 m — and a metre is a
  /// bench cut into a hillside. A flat bench is off by half its cross-fall
  /// at half its width, which is why this is twice [corridorReliefTolM].
  final double corridorCrossFallTolM;

  /// Voxels across a road's carriageway (its full width) when its corridor
  /// cuts or fills past [corridorReliefTolM]: four puts the cells whose
  /// vertices draw the carriageway inside its levelled core, so the mesh
  /// under the road IS the road's grade (a one-way: 2 m, within 0.1 m of it).
  final double corridorVoxelsAcross;

  /// Voxels across a corridor's easing ([roadFalloffM]) when it cuts or
  /// fills past [corridorReliefTolM]: the finer voxel is no coarser than
  /// that, however wide the road. [corridorVoxelsAcross] alone asked a
  /// four-lane for 4 m, and its leaves were meshed a level coarser than a
  /// one-way's: a 6 m ease meshed in a voxel and a half, the square start
  /// behind each segment smoothed into a hump 0.8 m over the carriageway
  /// along 14% of it.
  final double corridorVoxelsAcrossFalloff;

  /// Floor (m) under that finer voxel, so a narrow path cannot drag the
  /// quadtree past the levels a road needs.
  final double minCorridorVoxelM;

  /// Half the length (m) of the vertical curve a segment cut fine meets
  /// the grade before it with ([corridorCurve], `TerrainBrush.curveHalfM`),
  /// where the segments either side are long enough. Ten metres of curve
  /// turn a grade of 1.86 at 0.19 per metre, which the fine voxel meshes
  /// within 0.08 m; the six-metre ease of a square start alone was 1.05.
  final double corridorCurveHalfM;

  /// How far (m) a vertical curve may tilt the carriageway across where a
  /// road bends at the knot ([corridorCurve]): measured along the next
  /// segment, the curve runs square to it, and the carriageway through a
  /// bend is not.
  final double corridorCurveCrossFallTolM;

  /// Brushes for everything in [city] that is not yet shaped.
  ///
  /// [groundRadiusAt] returns the natural ground radius (m from the body
  /// centre) along a body-fixed direction — normally the terrain field's own
  /// query, so a pad levels to the real ground rather than to the datum sphere.
  ///
  /// The caller records each returned brush and adds its key to
  /// [CitySim.shapedTerrain]. The one exception is a raised or sunk road's
  /// segment that is not simply one graded piece: on piers or in a tunnel
  /// it is shaped by NOT touching the ground, and where it runs onto a
  /// bridge or into a portal it is cut or filled piece by piece. Its own
  /// key is added to [CitySim.shapedTerrain] here, with no brush to record
  /// under it, so it is settled once like every other segment.
  List<({String key, TerrainBrush brush})> pending(
    CitySim city, {
    required double bodyRadiusM,
    required double Function(Vector3 dirBF) groundRadiusAt,
    int tick = 0,
    SurfacePlacement placement = const SurfacePlacement(),
  }) {
    final out = <({String key, TerrainBrush brush})>[];
    final latRad = city.cityLat * math.pi / 180.0;
    final lonRad = city.cityLon * math.pi / 180.0;

    // Every direction asked of the ground in this call, answered once. A
    // pad asks its centre twice (datum, anchor) and each corner twice
    // (relief, outline), a corridor asks each sample as the end of one
    // segment and the start of the next, anchor and datum both, and a
    // lot's corners are its neighbours' corners: a road edit's re-plat
    // asked 52 samples for 14 places. Each is a march of the composed
    // field through every brush the town has laid there — milliseconds on
    // real ground — and the whole batch runs inside one tick, so the
    // repeats were a frozen frame. Exact: the ground does not change
    // during a call (its brushes are recorded after it returns), so an
    // answer is the answer. A direction with a zero component, whose sign
    // a relief sampler may read and whose key cannot tell it, is asked.
    final asked = <Vector3, double>{};
    double ground(Vector3 dir) {
      if (dir.x == 0 || dir.y == 0 || dir.z == 0) return groundRadiusAt(dir);
      return asked[dir] ??= groundRadiusAt(dir);
    }

    /// Direction from the body centre to a local point. Only the DIRECTION is
    /// taken from this, so the datum radius it is built at does not matter.
    Vector3 dirOf(Vec2 local) => placement
        .place(
          radius: bodyRadiusM,
          lat: latRad,
          lon: lonRad,
          east: local.e,
          north: local.n,
        )
        .position
        .normalized;

    /// Ground radius under a local point.
    double groundUnder(Vec2 local) => ground(dirOf(local));

    /// The point on the REAL GROUND under a local point.
    ///
    /// Brushes must be anchored HERE, not on the datum sphere. Every brush
    /// culls samples outside its own bounding radius — tens of metres for a
    /// building pad — and a body's ground sits hundreds of metres off its
    /// datum (885 m below it at a typical lunar site). Anchored on the datum,
    /// every ground sample fell outside the bound, so `apply` returned the
    /// density untouched and the brush did NOTHING: pads never levelled their
    /// lots and road corridors were never graded, which is exactly how it
    /// looked — buildings sitting on raw relief and roads clipping through it.
    Vector3 onGround(Vec2 local) {
      final dir = dirOf(local);
      return dir * ground(dir);
    }

    // ---- Building pads -------------------------------------------------
    for (final (parcel, spec) in city.buildingParcels()) {
      // A lot that follows the land is draped, not levelled.
      if (!parcel.graded) continue;
      final key = 'pad:${parcel.id}';
      if (city.shapedTerrain.contains(key)) continue;

      final centre = parcel.centroid;
      final extent = parcel.buildableExtent;
      // A pit still circumscribes: a quarry is round, and nothing tiles
      // against it.
      final radius =
          math.sqrt(extent.width * extent.width + extent.depth * extent.depth) /
                  2 +
              padMarginM;

      // Level to the ground under the CENTRE of the lot, so the cut and the
      // fill roughly balance instead of the whole site being raised to its
      // highest corner.
      final datum = groundUnder(centre);
      final relief = _reliefAcross(parcel, groundUnder);

      out.add((
        key: key,
        brush: _isPit(spec)
            ? TerrainBrush.steppedPit(
                centreBF: onGround(centre),
                radiusM: radius,
                datumRadiusM: datum,
                depthM: pitDepthFor(radius),
                benches: benchesFor(radius),
                falloffM: padFalloffM * 3,
                tick: tick,
                minVoxelM: voxelM,
              )
            : TerrainBrush.padPoly(
                centreBF: onGround(centre),
                // The lot's own outline, on the ground. Every parcel is a
                // polygon — lots taper wherever a road bends — so a rectangle
                // either overhangs the neighbour or misses its own corners.
                polygonBF: [for (final v in parcel.polygon) onGround(v)],
                datumRadiusM: datum,
                falloffM: padEdgeM,
                // The bound must clear the relief actually being moved.
                maxCutM: math.max(20, relief * 1.5),
                tick: tick,
                minVoxelM: voxelM,
              ),
      ));
    }

    // ---- Road corridors ------------------------------------------------
    for (final road in city.layout.roads) {
      // A road that follows the land is draped, not graded — see
      // [RoadSpline.graded]; a sprawl of them would be a hundred thousand
      // permanent edits to the ground. A raised or sunk road does NOT
      // follow the land, whatever it was first laid as: a suburb's street
      // dragged up onto a deck (Adjust Roads keeps `graded`) is shaped to
      // its deck like any other, or its first stretch would be a slab
      // floating over the hillside, too low for piers and never filled.
      final deck = road.deck;
      if (!road.graded && deck == null) continue;
      final pts = road.sample(stepM: corridorStepM);
      if (pts.length < 2) continue;
      // Keyed by WIDTH as well as by place. The key is the record that a
      // corridor was cut, and an upgrade keeps a road's id: keyed by place
      // alone, a street widened to an avenue kept its street's corridor
      // for ever, the avenue's edges riding the unshaped hillside.
      final hw = road.halfWidth.toStringAsFixed(2);
      if (deck != null) {
        _deckCorridor(city, road, deck, pts, hw, out,
            bodyRadiusM: bodyRadiusM,
            dirOf: dirOf,
            groundUnder: groundUnder,
            tick: tick);
        continue;
      }
      final todo = [
        for (var i = 1; i < pts.length; i++)
          if (!city.shapedTerrain.contains('road:${road.id}:$hw:$i')) i,
      ];
      if (todo.isEmpty) continue;
      // Meshed finer where the colony's voxel cannot carry the ground it was
      // laid over, and for a stretch either side ([_fineSegments]).
      final fine = _fineSegments(city, road, pts, todo, hw, groundUnder);
      final fineM = _fineVoxelM(road.halfWidth);
      for (final i in todo) {
        final key = 'road:${road.id}:$hw:$i';
        final a = pts[i - 1], b = pts[i];
        if (fine.contains(i)) city.fineCorridors.add(key);
        // A segment cut fine meets the grade before it in a vertical curve
        // ([corridorCurve]) — that segment's datums as it was cut, or as it
        // is about to be.
        ({double inGrade, double halfM})? curve;
        if (fine.contains(i) && i >= 2) {
          final prev = city.corridorDatums['road:${road.id}:$hw:${i - 1}'] ??
              (todo.contains(i - 1)
                  ? (groundUnder(pts[i - 2]), groundUnder(a))
                  : null);
          if (prev != null) {
            curve = corridorCurve(pts[i - 2], a, b, prev.$1, prev.$2,
                groundUnder(a), groundUnder(b), road.halfWidth);
          }
        }
        out.add((
          key: key,
          brush: TerrainBrush.cutFill(
            startBF: onGround(a),
            endBF: onGround(b),
            radiusM: fine.contains(i)
                ? fineCoreM(road.halfWidth)
                : road.halfWidth,
            datumRadiusM: groundUnder(a),
            datumRadiusEndM: groundUnder(b),
            falloffM: roadFalloffM,
            tick: tick,
            minVoxelM: fine.contains(i) ? fineM : voxelM,
            // Meshed finely enough to show how it meets the segment before
            // it, a fine segment meets it flat across the carriageway
            // ([TerrainBrush.squareStart]), and is levelled a voxel past its
            // kerbs ([fineCoreM]). A coarse one is cut as it always was.
            squareStart: fine.contains(i),
            curveInGrade: curve?.inGrade ?? 0,
            curveHalfM: curve?.halfM ?? 0,
          ),
        ));
      }
    }

    // ---- Site access corridors ------------------------------------------
    // Last, because brushes compose in record order: a site's drive is cut
    // into the pad it leaves and the road it meets, not under them.
    _siteCorridors(city, out,
        groundUnder: groundUnder, dirOf: dirOf, tick: tick);
    return out;
  }

  /// How far (m) a site's access corridor may stand off the pad it leaves
  /// before the ground under it is cut, where its run is too short to
  /// qualify on length alone (§6.3).
  ///
  /// A downtown drive crosses only the pavement; on flat ground its pad and
  /// its kerb are the same height, and cutting a metre of ground to say so
  /// would put a brush under every lot in a generated town.
  final double siteCorridorTolM;

  /// How far (m) a site's access corridor may cut or fill before it asks to
  /// be meshed finer than [voxelM] — its own [corridorReliefTolM].
  ///
  /// Its own because it is judged differently: a road's corridor is judged
  /// against the ground it was laid over, a site's against the two heights
  /// it grades between, which are known without asking the ground five
  /// times a segment.
  final double siteCorridorReliefTolM;

  /// The CAP (m) on how far a site's access corridor eases back into the
  /// ground past the width it levels — §6.3's `roadFalloffM` half of
  /// `min(roadFalloffM, clearance)`, tightened to the corridor's own levelled
  /// half width.
  ///
  /// Narrower than a road's on purpose. Sites stand shoulder to shoulder,
  /// and a six-metre ease reaches nine metres from the chord: on the dev
  /// kit a street car park's drive eased over the solar farm's throat 8.9 m
  /// away and pulled it 3.8 cm off the grade it is drawn on — the capture
  /// reads back one corridor's own datums, not the whole composed field, so
  /// a neighbour that reaches into a corridor is a drawing error, not a
  /// softer edge.
  ///
  /// The CLEARANCE half is [siteCorridorClearanceM], measured per segment:
  /// this cap alone is not a clearance, and on a generated town it buried
  /// the neighbours (§6.3 as built, the R5 review round 2).
  double siteCorridorFalloffM(double halfM) => math.min(roadFalloffM, halfM);

  /// §6.3's `clearance`: the plan distance (m) from the chord [a] → [b] to
  /// the nearest OTHER graded parcel's boundary, or infinity where no graded
  /// parcel lies within [reachM] of it.
  ///
  /// This is the whole of the R5 review's round-2 repair. A corridor's ease
  /// is a full-weight edit at its levelled edge falling to nothing
  /// [siteCorridorFalloffM] further out, and at a drive's 4.0–4.5 m half
  /// width that reaches 8–9 m from the chord — past the lot line of any
  /// generated town. The ground it moved out there is ground a NEIGHBOUR's
  /// paving is still drawn on: its own pad datum, cut before this corridor
  /// and never re-cut, because the site section records each lot's
  /// `sitepad:` re-cut ahead of the corridors. On a 2-block town that left
  /// one lot 1.25 m under its own pad, and on a 4-block town 139 plan points
  /// over 0.1 m and 75 over 0.5 m.
  ///
  /// Only GRADED parcels: a draped lot is drawn on the land, whatever the
  /// land does. Only OTHER parcels: the corridor's far end IS this site's
  /// own pad, and it must reach it — the site's own platform is a clearance
  /// too, but a lateral distance is the wrong way to measure it, and the
  /// call site handles it by the length of the chord ON the parcel instead.
  ///
  /// A lot the chord runs THROUGH is skipped as well: measured from its
  /// boundary it reads as a hard zero, and a lot the corridor already
  /// crosses cannot be a clearance from it. That is the set-back throat's
  /// case exactly (§3.7a) — it crosses a row of unbuilt access easements on
  /// purpose, and it is the lots BESIDE them that its ease must not reach.
  /// Without it every starter-kit throat would lose its verge and become a
  /// vertical-walled trench up to 40 m deep.
  ///
  /// Plan distance, as everything about a corridor is (`planLevel`), over
  /// [CityLayout.parcelsNear] in plat order: no hashing, no iteration order
  /// to depend on, and a box no wider than the ease can reach.
  static double siteCorridorClearanceM(
      CityLayout layout, String ownId, Vec2 a, Vec2 b, double reachM) {
    final box = Box2(
      (a.e < b.e ? a.e : b.e) - reachM,
      (a.n < b.n ? a.n : b.n) - reachM,
      (a.e > b.e ? a.e : b.e) + reachM,
      (a.n > b.n ? a.n : b.n) + reachM,
    );
    var best = double.infinity;
    for (final p in layout.parcelsNear(box)) {
      if (!p.graded || p.id == ownId) continue;
      final poly = p.polygon;
      if (poly.length < 3) continue;
      if (_chordCrosses(p, a, b)) continue;
      for (var i = 0; i < poly.length; i++) {
        final d = _segSegDistM(a, b, poly[i], poly[(i + 1) % poly.length]);
        if (d < best) best = d;
      }
    }
    return best;
  }

  /// Does the chord [a] → [b] run through [parcel]? Sampled every
  /// [_crossSampleM] along it, which is the same answer a clip would give
  /// for anything as wide as a lot and is what `SiteCorridorRun` measures
  /// its off-parcel stretch with.
  static bool _chordCrosses(Parcel parcel, Vec2 a, Vec2 b) {
    final len = a.distanceTo(b);
    final n = len <= _crossSampleM ? 1 : (len / _crossSampleM).ceil();
    for (var i = 0; i <= n; i++) {
      final t = i / n;
      if (parcel.contains(Vec2(a.e + (b.e - a.e) * t, a.n + (b.n - a.n) * t))) {
        return true;
      }
    }
    return false;
  }

  static const double _crossSampleM = 2;

  /// The least plan distance (m) between the segments [a] → [b] and
  /// [c] → [d]: zero where they cross, otherwise the nearest of the four
  /// point-to-segment distances.
  static double _segSegDistM(Vec2 a, Vec2 b, Vec2 c, Vec2 d) {
    double cross(Vec2 o, Vec2 p, Vec2 q) =>
        (p.e - o.e) * (q.n - o.n) - (p.n - o.n) * (q.e - o.e);
    final d1 = cross(c, d, a), d2 = cross(c, d, b);
    final d3 = cross(a, b, c), d4 = cross(a, b, d);
    if (((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0))) return 0;
    var m = _pointSegDistM(a, c, d);
    final m2 = _pointSegDistM(b, c, d);
    if (m2 < m) m = m2;
    final m3 = _pointSegDistM(c, a, b);
    if (m3 < m) m = m3;
    final m4 = _pointSegDistM(d, a, b);
    return m4 < m ? m4 : m;
  }

  static double _pointSegDistM(Vec2 p, Vec2 a, Vec2 b) {
    final ex = b.e - a.e, en = b.n - a.n;
    final len2 = ex * ex + en * en;
    var t = len2 <= 1e-12 ? 0.0 : ((p.e - a.e) * ex + (p.n - a.n) * en) / len2;
    t = t < 0 ? 0 : (t > 1 ? 1 : t);
    return p.distanceTo(Vec2(a.e + ex * t, a.n + en * t));
  }

  /// Site access corridors and the pads they grade to
  /// (docs/plans/site-access.md §6.3): each plan's drive and access road cut
  /// into the ground the way a road corridor is, at the plan's own heights,
  /// so what the renderer draws sits on the ground.
  ///
  /// Once per plan revision, never per frame: the decision — cut, or nothing
  /// to cut — is settled in [CitySim.shapedSites] whichever way it goes, and
  /// the whole walk is skipped while the book's `sitesRev` has not moved.
  ///
  /// Scoped: only the site's own corridor, and only the stretch its ramp
  /// covers. A sprawl lot is draped, not graded, and adds nothing.
  void _siteCorridors(
    CitySim city,
    List<({String key, TerrainBrush brush})> out, {
    required double Function(Vec2) groundUnder,
    required Vector3 Function(Vec2) dirOf,
    required int tick,
  }) {
    final book = city.siteAccess;
    final chunks = book.chunks;
    if (chunks.isEmpty) return;
    if (city.siteShapedRev == book.sitesRev) return;
    final layout = city.layout;
    final minOffM = math.max(layout.settings.sidewalkM + 0.5, 3.0);
    for (final chunk in chunks) {
      for (var k = 0; k < chunk.siteCount; k++) {
        final id = chunk.siteId(k);
        // The cheapest test first, and it settles nothing: a lot that
        // follows the land is draped, and a cell (no parcel at all) has no
        // lot line to cross. A map lookup a site, where a settled key is a
        // string built and hashed — and a sprawl is tens of thousands of
        // draped lots this walk passes over every time the book moves.
        final parcel = layout.parcelById(id);
        if (parcel == null || !parcel.graded) continue;
        final rev = chunk.rev(k);
        final runKey = SiteGrade.runKey(id, rev);
        if (city.shapedSites.contains(runKey)) continue;
        final run = SiteCorridorRun.of(chunk.plan(k), parcel: parcel);
        if (run == null) {
          city.shapedSites.add(runKey);
          city.siteCutRev.remove(id);
          continue;
        }
        // The pad the corridor grades to: the datum its brush cut, or —
        // before it is cut, in this same call — the ground under the
        // centroid, which is exactly what that brush will use.
        final padDatum =
            city.padDatums[SiteGrade.padKey(id)] ?? groundUnder(parcel.centroid);
        // The kerb it grades from: the ground where it meets the road,
        // which IS that road's corridor once cut. Asked of the ground
        // rather than modelled from the road's datums, so the corridor ties
        // into whatever is actually there (§6.3 as built).
        final kerbDatum = groundUnder(run.kerbAt);
        city.shapedSites.add(runKey);
        // §6.3's cut clause, per SEGMENT: a corridor that leaves the lot in
        // several short stubs, none of them longer than the pavement it
        // crosses, is one the design says to leave alone. The decision is
        // still the whole run's — the ramp is derived along the chain
        // (§6.3 as built), and half a cut run would draw the rest of itself
        // on datums nothing cut.
        if (run.maxSegOffParcelM <= minOffM &&
            (padDatum - kerbDatum).abs() <= siteCorridorTolM) {
          city.siteCutRev.remove(id);
          continue;
        }
        // Meshed as finely as a road's corridor where it cuts or fills past
        // what the colony's voxel carries: a mesh cannot hold an eight-metre
        // cut at fifteen metres, and the drive would be drawn in pieces with
        // the hillside smoothed across it ([corridorReliefTolM]).
        final fine = (padDatum - kerbDatum).abs() > siteCorridorReliefTolM;
        // The platform under the site's own paving, RE-cut after the roads.
        // A road corridor eases [roadFalloffM] past its kerb, which on a
        // slope is inside the lot line, and it is recorded after the pad:
        // the platform edge the plan's paving is drawn on had been taken
        // with it (1.13 m on the dev kit's one street car park). The same
        // brush, the same datum — so a lot no road reaches is untouched —
        // under its own key, and only for a site whose ground this call is
        // moving anyway.
        final padKey = SiteGrade.padRecutKey(id, rev);
        final spec = city.parcelBuildings[id];
        if (!city.shapedTerrain.contains(padKey) &&
            spec != null &&
            !_isPit(spec)) {
          out.add((
            key: padKey,
            // Anchored on the platform it re-cuts, not on the ground: the
            // lot is already levelled to it, so this asks the ground
            // nothing at all, and the bound reaches past whatever has since
            // been eased over its edge.
            brush: TerrainBrush.padPoly(
              centreBF: dirOf(parcel.centroid) * padDatum,
              polygonBF: [for (final v in parcel.polygon) dirOf(v) * padDatum],
              datumRadiusM: padDatum,
              falloffM: padEdgeM,
              maxCutM: math.max(20, (padDatum - kerbDatum).abs() * 1.5),
              tick: tick,
              minVoxelM: voxelM,
            ),
          ));
        }
        for (var i = 0; i < run.length; i++) {
          final key = SiteGrade.corridorKey(id, rev, run.segs[i]);
          if (city.shapedTerrain.contains(key)) continue;
          final (d0, d1) = run.datumsOf(i, padDatum, kerbDatum);
          // §6.3's `falloffM = min(roadFalloffM, clearance)`, with the
          // clearance a real clearance: how far this segment's chord stands
          // from the nearest other graded lot line, less the width the
          // corridor levels. The ease stops at the lot line, so it cannot
          // move ground the neighbour's paving is still drawn on its own pad
          // datum ([siteCorridorClearanceM]). Where there is room it is the
          // cap, exactly as it was.
          //
          // A segment that runs ON the lot it serves has no clearance at
          // all: every metre beside it is this site's OWN platform, levelled
          // to `padDatum` and re-cut under `sitepad:` just above — before
          // this corridor, so nothing puts it back. A house drive climbing
          // its front garden pulled the lot's own paving 2.18 m under the
          // ground that way (lot-r3x1x1x0-l4 on the 4-block town). Measured
          // by the chord's on-parcel length, not by a lateral distance: a
          // set-back throat ENDS on its own lot line, which laterally reads
          // as a hard zero, and there — at the pad end of the ramp — the
          // corridor's datum IS the pad's and the ease moves nothing.
          final halfM = run.halfM[i];
          final capM = siteCorridorFalloffM(halfM);
          final chordM = run.a[i].distanceTo(run.b[i]);
          final offM = i < run.segOffParcelM.length
              ? run.segOffParcelM[i]
              : chordM;
          final double easeM;
          if (chordM - offM > minPieceM) {
            easeM = 0;
          } else {
            final clearM = siteCorridorClearanceM(
                layout, id, run.a[i], run.b[i], halfM + capM);
            easeM = math.max(0.0, math.min(capM, clearM - halfM));
          }
          // Anchored on the GRADE, not on the ground under it — a deck
          // corridor's rule ([_deckCorridor]), for the same reason. Its ends
          // must be the two datums it grades between: anchored on ground
          // that is metres off them, the chord tilts and every point along
          // it reads a little further on than it is. The bound reaches past
          // the cut, or the brush culls the very samples it is there to
          // move. Sized from the grade's own drop rather than from the
          // ground under it, so the ground is asked once per site and not
          // once per knot.
          out.add((
            key: key,
            brush: TerrainBrush.cutFill(
              startBF: dirOf(run.a[i]) * d0,
              endBF: dirOf(run.b[i]) * d1,
              radiusM: halfM,
              datumRadiusM: d0,
              datumRadiusEndM: d1,
              falloffM: easeM,
              maxCutM: math.max(40.0, (d1 - d0).abs() + deckCutMarginM),
              tick: tick,
              minVoxelM: fine ? _fineVoxelM(run.halfM[i]) : voxelM,
              // Levelled by where the ground stands IN PLAN under the run,
              // not by projecting onto its rising chord
              // ([TerrainBrush.planLevel]). A site's corridor drops a whole
              // platform cut over the length of a throat, and past about a
              // metre of fall per metre along, the 3-D projection sends a
              // sample offset radially from that chord to a far-off place
              // along it, where the lateral test then rejects it: the ends
              // cut, the middle left standing hillside, and the drive drawn
              // buried in it — 77.7 m of it on a kit founded in the Alps,
              // 156.3 m in the Andes (`site_ground_probe_test`). It is also
              // the rule the capture reads back
              // (`SiteCorridorRun.radiusAt`), so the two agree exactly
              // however steep the throat.
              planLevel: true,
            ),
          ));
        }
        // What the capture tests before it builds a corridor run at all: a
        // site with a cut corridor reads its datums back, and every other
        // site — every house lot with a driveway — keeps the §6.4 table and
        // pays nothing for the run it does not have.
        city.siteCutRev[id] = rev;
      }
    }
    city.siteShapedRev = book.sitesRev;
  }

  /// The vertical curve a segment cut fine, from [knot] to [after], meets
  /// the segment before it (from [before] to [knot]) with
  /// (`TerrainBrush.curveHalfM`): the grade before it and the curve's half
  /// length — or null for none, and it starts square and level
  /// (`TerrainBrush.squareStart`). [beforeDatum] and [knotDatumIn] are the
  /// datums the segment before it was cut to, [knotDatum] and [afterDatum]
  /// this one's; [halfWidthM] is the road's.
  ///
  /// [corridorCurveHalfM], but no more than a quarter of either segment —
  /// a curve at each end of a segment, and the grade carried on behind
  /// each, never meet — nor reaching further behind the knot (twice its
  /// half length) than a round start's easing does ([fineCoreM] and
  /// [roadFalloffM]), and none shorter than half a metre. None where the two
  /// segments do not meet at
  /// one datum (the one before cut to ground since moved), and none where
  /// the road bends at [knot] so far that the curve, square to this
  /// segment, would tilt the carriageway across by more than
  /// [corridorCurveCrossFallTolM]: there a level start is flat across.
  ///
  /// Public for the frame a road is laid in, before its corridor is cut:
  /// it is drawn on the curve it is about to be cut with.
  ({double inGrade, double halfM})? corridorCurve(
      Vec2 before,
      Vec2 knot,
      Vec2 after,
      double beforeDatum,
      double knotDatumIn,
      double knotDatum,
      double afterDatum,
      double halfWidthM) {
    if ((knotDatumIn - knotDatum).abs() > 1e-6) return null;
    final l0 = before.distanceTo(knot), l1 = knot.distanceTo(after);
    if (l0 <= 1e-6 || l1 <= 1e-6) return null;
    final h = math.min(
        math.min(corridorCurveHalfM,
            (fineCoreM(halfWidthM) + roadFalloffM) / 2),
        math.min(l0, l1) / 4);
    if (h < 0.5) return null;
    final g0 = (knotDatumIn - beforeDatum) / l0;
    final g1 = (afterDatum - knotDatum) / l1;
    final ae = (knot.e - before.e) / l0, an = (knot.n - before.n) / l0;
    final be = (after.e - knot.e) / l1, bn = (after.n - knot.n) / l1;
    if (ae * be + an * bn <= 0) return null;
    final bend = (ae * bn - an * be).abs();
    if (math.max(g0.abs(), g1.abs()) * halfWidthM * bend >
        corridorCurveCrossFallTolM) {
      return null;
    }
    return (inGrade: g0, halfM: h);
  }

  /// The voxel (m) a plain graded road's corridor, [halfWidthM] either side
  /// of its centreline, asks to be meshed at where the colony's voxel cannot
  /// carry it ([_fineSegments]): [corridorVoxelsAcross] across its
  /// carriageway and [corridorVoxelsAcrossFalloff] across its easing,
  /// whichever is finer, no finer than [minCorridorVoxelM]. A one-way or a
  /// two-lane: 2 m either way; a four-lane or wider: 2 m, not a quarter of
  /// its width.
  double _fineVoxelM(double halfWidthM) => math.max(
      minCorridorVoxelM,
      math.min(halfWidthM * 2 / corridorVoxelsAcross,
          roadFalloffM / corridorVoxelsAcrossFalloff));

  /// How far (m) from its centreline a corridor cut fine ([_fineSegments])
  /// is levelled flat: one of its voxels ([_fineVoxelM]) past the edge of a
  /// carriageway [halfWidthM] either side of it, before its cut or fill
  /// eases back into the ground.
  ///
  /// A mesh cannot turn a corner inside a voxel: the cell across a cut's
  /// foot is drawn as a slope from the floor to the wall, and levelled only
  /// to the kerb, that slope stood up to 0.18 m over the edge of a re-laid
  /// one-way's ribbon (a tenth of its half width in, 3% of its length)
  /// where the field under it was flat. A voxel past the kerb the foot is a
  /// cell outside the carriageway, the verge a cutting has anyway.
  double fineCoreM(double halfWidthM) =>
      halfWidthM + _fineVoxelM(halfWidthM);

  /// Which segments of [road] (1-based, segment i ending at knot i of its
  /// `sample(stepM: corridorStepM)`) [pending] would cut fine if it ran now:
  /// [_fineSegments] over those not yet shaped, on the ground [groundUnder]
  /// answers under a local point. Empty for a road [pending] does not cut
  /// plainly (one that follows the land, or has a deck).
  ///
  /// For the frame a road is laid, before its corridor is cut: it is drawn
  /// on the corridor it is about to be cut to, square starts and all.
  Set<int> fineSegmentsAhead(CitySim city, RoadSpline road,
      double Function(Vec2 local) groundUnder) {
    if (!road.graded || road.deck != null) return const {};
    final pts = road.sample(stepM: corridorStepM);
    if (pts.length < 2) return const {};
    final hw = road.halfWidth.toStringAsFixed(2);
    final todo = [
      for (var i = 1; i < pts.length; i++)
        if (!city.shapedTerrain.contains('road:${road.id}:$hw:$i')) i,
    ];
    if (todo.isEmpty) return const {};
    return _fineSegments(city, road, pts, todo, hw, groundUnder);
  }

  /// How many segments either side of one the colony's voxel cannot carry
  /// are meshed as finely as it: a road meshed fine where it cuts and coarse
  /// right up to it is drawn in pieces at the seam — the live one-way was
  /// buried a quarter metre along the two segments beside its cut — while
  /// a trunk road run past one levelled lot need not be fine for kilometres.
  static const int corridorFineSpan = 2;

  /// Which of the segments [todo] of a plain graded road (segment i from
  /// knot i - 1 to knot i of [pts]; [hw] its half width as keyed) are cut
  /// to be meshed finer than [voxelM]: those the ground they are laid over
  /// stands off the grade they are cut to by more than the coarse mesh
  /// carries ([corridorReliefTolM], [corridorCrossFallTolM]), those
  /// [CitySim.fineCorridors] already holds, and those within
  /// [corridorFineSpan] of either.
  ///
  /// Per segment, on the ground as it stands before this call: the ground a
  /// quarter, half and three quarters along against the straight grade
  /// between its knots (what the cut takes out, or the fill puts in, under
  /// the carriageway), then either side of its middle one coarse voxel past
  /// its edge — the ground the coarse mesh would smooth over it — their
  /// mean against the grade and their fall across it.
  ///
  /// Not the brushes laid in the same call: a colony laid in one call — a
  /// generated town, the starter kit, founded on pristine ground — is cut
  /// from the ground its roads were laid over, and keeps the colony's
  /// voxel. A road the player lays through the town is judged on the town
  /// it is laid through. That judgement is kept ([CitySim.fineCorridors]):
  /// a load re-grades the colony in one call, where the lot the road was
  /// laid through is levelled beside it and cannot be seen.
  Set<int> _fineSegments(CitySim city, RoadSpline road, List<Vec2> pts,
      List<int> todo, String hw, double Function(Vec2) groundUnder) {
    if (voxelM <= 0) return const {}; // derived from each brush's radius
    if (_fineVoxelM(road.halfWidth) >= voxelM) return const {};
    final halfW = road.halfWidth;
    final lat = halfW + voxelM;
    bool carried(int i) {
      final a = pts[i - 1], b = pts[i];
      final da = groundUnder(a), db = groundUnder(b);
      for (final t in const [0.25, 0.5, 0.75]) {
        final g = groundUnder(a + (b - a) * t);
        if ((g - (da + (db - da) * t)).abs() > corridorReliefTolM) return false;
      }
      final run = b - a;
      final len = run.length;
      if (len < 1e-6) return true;
      final side = Vec2(-run.n / len, run.e / len);
      final m = a + run * 0.5;
      final gl = groundUnder(m + side * lat), gr = groundUnder(m - side * lat);
      return ((gl + gr) / 2 - (da + db) / 2).abs() <= corridorReliefTolM &&
          (gl - gr).abs() / (2 * lat) * halfW <= corridorCrossFallTolM;
    }

    final hit = <int>{
      for (final i in todo)
        if (city.fineCorridors.contains('road:${road.id}:$hw:$i') ||
            !carried(i))
          i,
    };
    if (hit.isEmpty) return hit;
    return {
      for (final i in todo)
        if (hit.any((h) => (h - i).abs() <= corridorFineSpan)) i,
    };
  }

  /// Spacing (m) of a road corridor's knots: a road is graded as straight
  /// segments between its `sample(stepM: corridorStepM)` points, one brush
  /// each ([pending]). Not the road's own spacing: `sample` rounds each
  /// span UP to whole steps, so a 64.5 m road has knots every 21.5 m and a
  /// 48.00000000000001 m one every 16 m — see [corridorGround].
  static const double corridorStepM = 24;

  /// Record that [brush], returned by [pending] under [key], has been laid
  /// on [city]'s ground — what every caller of [pending] does with each
  /// brush it records.
  ///
  /// A road corridor's segment also keeps the datum radii it was cut to
  /// ([CitySim.corridorDatums]): the road is drawn on them
  /// ([corridorGround]), not on the ground read back at its knots.
  static void markShaped(CitySim city, String key, TerrainBrush brush) {
    city.shapedTerrain.add(key);
    // A lot's pad also keeps the datum it was levelled to
    // ([CitySim.padDatums]): its paving is drawn on that, and its access
    // corridor grades to it at the lot line
    // (docs/plans/site-access.md §6.3, §6.4).
    // Under the PAD's own key only: the site section re-cuts the same
    // platform under a key of its own (`SiteGrade.padRecutKey`), and
    // recording that too would leave an entry per site per plan revision
    // that nothing ever reads.
    if (brush.kind == TerrainBrushKind.padPoly && key.startsWith('pad:')) {
      city.padDatums[key] = brush.datumRadiusM;
    }
    if (brush.kind == TerrainBrushKind.cutFill) {
      city.corridorDatums[key] = (brush.datumRadiusM, brush.datumRadiusEndM);
      // And the vertical curve it meets the segment before it with, if any
      // ([CitySim.corridorCurves]).
      if (brush.curveHalfM > 0) {
        city.corridorCurves[key] = (brush.curveInGrade, brush.curveHalfM);
      } else {
        city.corridorCurves.remove(key);
      }
    }
  }

  /// The ground a plain corridor — a graded road with no deck, as [pending]
  /// cuts it — leaves under [pts], the road's own points in order, as radii
  /// from the body centre written into [out].
  ///
  /// [knots] are the corridor's knots (`road.sample(stepM: corridorStepM)`),
  /// segment j running from knot j to knot j + 1; [datumStart] and
  /// [datumEnd] are the radii segment j is cut to at its two knots, and
  /// [halfWidthM] is the road's half width. Read back from the brushes' own
  /// rules rather than asked of the field at every point, which in a built
  /// colony is a march through every brush there: segment j is cut or
  /// filled to the straight line between its datums, at full weight within
  /// [halfWidthM] of its chord; each segment after it, recorded after it,
  /// holds the last metres before its own first knot at that knot's datum
  /// and eases out over [roadFalloffM] ([TerrainBrush.falloffWeight]).
  ///
  /// The datums are the ones the shaper CUT to ([CitySim.corridorDatums]),
  /// not the ground read back at the knots once it has. A knot's ground is
  /// not its segment's datum wherever the next segment's easing reaches
  /// back over it — and on a curve it always does, its knots metres apart:
  /// taken for a datum, that pulled-down ground drew a whole segment on the
  /// wrong line, a curved street buried 9.6 m where it crossed a levelled
  /// lot's edge. Before a segment is cut its datums are the ground at its
  /// knots, which is exactly what [pending] will measure: the road is drawn
  /// on the ground it is about to be graded to.
  ///
  /// Only this corridor's own brushes: whatever was laid over it since — a
  /// crossing road's corridor recorded after it, reaching over its end, or
  /// a crater — is not modelled. The frame asks the ground itself at the
  /// points such a brush can reach (`_drapeRoad` in the world snapshot).
  ///
  /// Measured in the colony's plane (metres east and north) plus the rise
  /// between knots: over a corridor segment the body's curve is
  /// millimetres. A brush reads a point's place along its chord in three
  /// dimensions — the chord rising from one datum to the next — so a
  /// point the next segment's cap pulls below a steep chord reads a little
  /// further along it, and the ground is the height that agrees with
  /// itself: found by iterating, a few passes, as the rise over a segment
  /// is small against its length.
  ///
  /// Each segment's chord is worked out once, not per point and pass, and
  /// nothing is allocated per point: this ran every frame for every graded
  /// road until the snapshot cached its result.
  ///
  /// [fine], where given, says which segments [pending] cut fine
  /// ([CitySim.fineCorridors]): levelled [fineCoreM] either side, not
  /// [halfWidthM], and square at their start (`TerrainBrush.squareStart`).
  /// Null is every segment cut at the colony's voxel, as it always was.
  ///
  /// [curves], where given, holds for each segment the vertical curve it
  /// meets the one before it with — its grade in and its half length
  /// ([CitySim.corridorCurves], [corridorCurve]) — or null for none. Such a
  /// segment is read in plan, as its brush reads it
  /// (`TerrainBrush.curveHalfM`).
  void corridorGround(
    List<Vec2> pts,
    List<Vec2> knots,
    List<double> datumStart,
    List<double> datumEnd,
    double halfWidthM,
    List<double> out, {
    List<bool>? fine,
    List<(double, double)?>? curves,
  }) {
    final m = knots.length - 1;
    assert(m >= 1, 'a corridor has at least one segment');
    assert(datumStart.length >= m && datumEnd.length >= m);
    assert(out.length >= pts.length);
    if (m < 1) return;
    // Each segment's chord: its first knot, its run in plan, its rise.
    final ke = Float64List(m + 1), kn = Float64List(m + 1);
    for (var k = 0; k <= m; k++) {
      ke[k] = knots[k].e;
      kn[k] = knots[k].n;
    }
    final de = Float64List(m), dn = Float64List(m);
    final plan2 = Float64List(m), rise = Float64List(m), len3 = Float64List(m);
    for (var j = 0; j < m; j++) {
      de[j] = ke[j + 1] - ke[j];
      dn[j] = kn[j + 1] - kn[j];
      plan2[j] = de[j] * de[j] + dn[j] * dn[j];
      rise[j] = datumEnd[j] - datumStart[j];
      len3[j] = plan2[j] + rise[j] * rise[j];
    }
    // Where (pe, pn) lies along segment [j] in plan, 0 at its first knot
    // and 1 at its last: which segment a point runs along. A segment of no
    // length is always passed (its brush levels nothing — `cutFill`).
    double plan(double pe, double pn, int j) => plan2[j] <= 1e-9
        ? 1
        : ((pe - ke[j]) * de[j] + (pn - kn[j]) * dn[j]) / plan2[j];
    // How far (squared, in plan) (pe, pn) lies from segment [j]'s chord.
    double near2(double pe, double pn, int j) {
      var t = plan2[j] <= 1e-9 ? 0.0 : plan(pe, pn, j);
      t = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
      final ce = ke[j] + de[j] * t - pe, cn = kn[j] + dn[j] * t - pn;
      return ce * ce + cn * cn;
    }

    // Each segment's levelled half width: the carriageway's, or a fine
    // segment's wider core.
    final core = Float64List(m);
    var widest = halfWidthM;
    for (var j = 0; j < m; j++) {
      core[j] = fine != null && fine[j] ? fineCoreM(halfWidthM) : halfWidthM;
      if (core[j] > widest) widest = core[j];
    }
    final reach = widest + roadFalloffM;
    final reach2 = reach * reach;
    var own = 0;
    for (var i = 0; i < pts.length; i++) {
      final pe = pts[i].e, pn = pts[i].n;
      // The segment the point runs along: the nearest to it, searched on
      // from the last point's — the points are in order, so it only moves
      // on. Not the first whose far knot the point has not passed: a road
      // whose first metre doubles back (a generated street's hook off the
      // node it leaves) has a first segment every later point lies BEHIND,
      // and a whole street was drawn at its first datum, 0.6 m in the
      // ground 100 m on.
      while (own < m - 1 && near2(pe, pn, own + 1) <= near2(pe, pn, own)) {
        own++;
      }
      var t0 = plan(pe, pn, own);
      t0 = t0 < 0 ? 0.0 : (t0 > 1 ? 1.0 : t0);
      // The ground before this corridor, as far as it matters: wherever
      // the point's own segment levels it outright, not at all.
      final before = datumStart[own] + rise[own] * t0;
      final first = own > 0 ? own - 1 : 0;
      var r = before;
      // Run to the fixed point, not a set number of passes: on a steep chord
      // under the next segment's easing each pass keeps a share of the
      // error — about (1 - w) * rise^2 / len^3 of it, half at a 155% grade —
      // and eight passes left a road drawn downhill across a lot's step
      // 7 cm off its ground. The drape is cached, so this is paid once.
      for (var pass = 0; pass < 400; pass++) {
        var v = before;
        // The segments in the order they were recorded: the one before (its
        // end cap, overruled by the point's own segment), its own, and
        // those after it whose first knot's cap reaches back to the point.
        for (var j = first; j < m; j++) {
          if (j > own + 1) {
            final ex = pe - ke[j], en = pn - kn[j];
            if (ex * ex + en * en > reach2) break;
          }
          if (plan2[j] <= 1e-9) continue;
          final curve = curves == null ? null : curves[j];
          if (curve != null) {
            // A vertical curve at its start (`TerrainBrush.curveHalfM`):
            // read in plan, whatever the point's height.
            final (g0, h) = curve;
            final planLen = math.sqrt(plan2[j]);
            final u = plan(pe, pn, j);
            final x = u * planLen;
            final g1 = rise[j] / planLen;
            final double target;
            if (x < -h) {
              target = datumStart[j] + g0 * x;
            } else if (x <= h) {
              target = datumStart[j] +
                  g0 * x +
                  (g1 - g0) * (x + h) * (x + h) / (4 * h);
            } else if (u < 1) {
              target = datumStart[j] + g1 * x;
            } else {
              target = datumEnd[j];
            }
            final double w;
            if (u > 1) {
              final ce = ke[j + 1] - pe, cn = kn[j + 1] - pn;
              w = TerrainBrush.falloffWeight(
                  math.sqrt(ce * ce + cn * cn), core[j], roadFalloffM);
            } else {
              final ce = ke[j] + de[j] * u - pe, cn = kn[j] + dn[j] * u - pn;
              final lateral = math.sqrt(ce * ce + cn * cn);
              w = u >= 0
                  ? TerrainBrush.falloffWeight(lateral, core[j], roadFalloffM)
                  : TerrainBrush.falloffWeight(math.max(-x - h, 0.0), 0, h) *
                      TerrainBrush.falloffWeight(
                          math.max(lateral - core[j], 0.0), 0, roadFalloffM);
            }
            if (w <= 0) continue;
            v = v * (1 - w) + target * w;
            continue;
          }
          // Where the point, at radius r, projects along the segment's
          // chord as its brush projects it: in three dimensions.
          var t = ((pe - ke[j]) * de[j] +
                  (pn - kn[j]) * dn[j] +
                  (r - datumStart[j]) * rise[j]) /
              len3[j];
          if (t < 0 && fine != null && fine[j]) {
            // Behind a square start (`TerrainBrush.squareStart`): eased by
            // the distance behind the line across it and outside its edges.
            final ce = ke[j] + de[j] * t - pe, cn = kn[j] + dn[j] * t - pn;
            final behind = -t * math.sqrt(len3[j]);
            final out = math.max(math.sqrt(ce * ce + cn * cn) - core[j], 0.0);
            final w = TerrainBrush.falloffWeight(
                math.sqrt(behind * behind + out * out), 0, roadFalloffM);
            if (w <= 0) continue;
            v = v * (1 - w) + datumStart[j] * w;
            continue;
          }
          t = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
          final ce = ke[j] + de[j] * t - pe, cn = kn[j] + dn[j] * t - pn;
          final w = TerrainBrush.falloffWeight(
              math.sqrt(ce * ce + cn * cn), core[j], roadFalloffM);
          if (w <= 0) continue;
          v = v * (1 - w) + (datumStart[j] + rise[j] * t) * w;
        }
        final moved = (v - r).abs();
        r = v;
        if (moved < 1e-5) break;
      }
      out[i] = r;
    }
  }

  /// How far past the deepest cut or tallest fill a deck corridor's bound
  /// reaches: the brush must be anchored within its bound of the real
  /// ground or it culls every sample (see `onGround` above).
  static const double deckCutMarginM = 10;

  /// The corridor of a raised or sunk road ([RoadSpline.deck]).
  ///
  /// Graded to the DECK, not to the ground: each 24 m segment is cut or
  /// filled to the deck's own straight grade line, so the road that looks
  /// level on its embankment is the road the ground was shaped to. Where
  /// it stands on piers or runs in a tunnel nothing is emitted — a
  /// cut-and-fill is a radial prism, which under a bridge would raise an
  /// earth wall to the deck and over a tunnel would open a trench to the
  /// sky.
  ///
  /// Clipped, not classified: the survey cuts its structure and tunnel
  /// ranges every 8 m, anywhere along a segment, and judged by its midpoint
  /// a segment straddling a bridge's end either left up to 12 m of graded
  /// deck unfilled (a slab floating over the hillside, too low for piers)
  /// or ran its prism 12 m under the bridge. So only a segment's GRADED
  /// pieces ([gradedPieces]) are cut or filled, each to the deck between
  /// its own ends. A segment that is one piece keeps its key; one that
  /// splits keys its pieces `'<key>:<j>'` for the caller to record. Either
  /// way nothing is asked about again: a segment with no piece, or several,
  /// has its own key recorded here, straight into [CitySim.shapedTerrain]
  /// (the caller only records the keys it gets a brush for).
  void _deckCorridor(
    CitySim city,
    RoadSpline road,
    RoadDeck deck,
    List<Vec2> pts,
    String hw,
    List<({String key, TerrainBrush brush})> out, {
    required double bodyRadiusM,
    required Vector3 Function(Vec2) dirOf,
    required double Function(Vec2) groundUnder,
    required int tick,
  }) {
    // Arc along the 24 m samples, scaled to the length its deck's ranges
    // were measured on ([RoadDeck.rangeLengthM]; a curve's 24 m chords run
    // a little short of it) — or, for a deck saved before it knew that, to
    // the road's own length as indexed (the 2 m samples it was cut from).
    final cum = <double>[0];
    for (var i = 1; i < pts.length; i++) {
      cum.add(cum[i - 1] + pts[i].distanceTo(pts[i - 1]));
    }
    final lengthM = deck.rangeLengthM ??
        city.layout.roadIndex.byId(road.id)?.lengthM ??
        cum.last;
    final scale = cum.last <= 1e-9 ? 1.0 : lengthM / cum.last;
    for (var i = 1; i < pts.length; i++) {
      final key = 'road:${road.id}:$hw:$i';
      if (city.shapedTerrain.contains(key)) continue;
      final sA = cum[i - 1] * scale, sB = cum[i] * scale;
      final pieces = gradedPieces(deck, sA, sB);
      // Settled here unless it is one piece, whose brush the caller
      // records under this same key.
      if (pieces.length != 1) city.shapedTerrain.add(key);
      final a = pts[i - 1], b = pts[i];
      // A cut at a range's end lands on the chord between the samples, at
      // its share of the segment's arc. The segment's own ends are the
      // samples themselves, so an unclipped segment is the brush it was.
      Vec2 at(double s) => s <= sA
          ? a
          : s >= sB
              ? b
              : a + (b - a) * ((s - sA) / (sB - sA));
      for (var j = 0; j < pieces.length; j++) {
        final (g0, g1) = pieces[j];
        final pa = at(g0), pb = at(g1);
        final datumA = bodyRadiusM + deck.heightAt(g0, lengthM);
        final datumB = bodyRadiusM + deck.heightAt(g1, lengthM);
        final fill = math.max((datumA - groundUnder(pa)).abs(),
            (datumB - groundUnder(pb)).abs());
        out.add((
          key: pieces.length == 1 ? key : '$key:$j',
          brush: TerrainBrush.cutFill(
            // Anchored on the deck, which is within the bound of the ground
            // because the bound reaches past the fill.
            startBF: dirOf(pa) * datumA,
            endBF: dirOf(pb) * datumB,
            radiusM: road.halfWidth,
            datumRadiusM: datumA,
            datumRadiusEndM: datumB,
            // An embankment's side eases out over half again its height: a
            // six-metre falloff under a twelve-metre fill is a cliff.
            falloffM: math.max(roadFalloffM, fill * 1.5),
            maxCutM: math.max(40.0, fill + deckCutMarginM),
            tick: tick,
            minVoxelM: voxelM,
          ),
        ));
      }
    }
  }

  /// A graded piece shorter than this is left to its neighbours' falloff:
  /// a brush a metre long is an edit to the ground that shapes nothing.
  static const double minPieceM = 1;

  /// What is left of the arc range [sA]..[sB] of [deck]'s road once its
  /// stretches on piers and underground are cut out: the pieces that run
  /// near enough the ground to be cut or filled to it, in order, each
  /// longer than [minPieceM].
  static List<(double, double)> gradedPieces(
      RoadDeck deck, double sA, double sB) {
    final off = [
      for (final r in [...deck.structures, ...deck.tunnels])
        if (r.$2 > sA && r.$1 < sB) r,
    ]..sort((x, y) => x.$1.compareTo(y.$1));
    final out = <(double, double)>[];
    var from = sA;
    for (final (a, b) in off) {
      if (a - from > minPieceM) out.add((from, a));
      if (b > from) from = b;
    }
    if (sB - from > minPieceM) out.add((from, sB));
    return out;
  }

  /// Peak-to-trough ground relief across a parcel, sampled at its corners and
  /// centre — enough to size the cut without a full raster of the lot.
  double _reliefAcross(Parcel parcel, double Function(Vec2) groundUnder) {
    var lo = double.infinity, hi = -double.infinity;
    for (final v in [...parcel.polygon, parcel.centroid]) {
      final r = groundUnder(v);
      lo = math.min(lo, r);
      hi = math.max(hi, r);
    }
    return hi - lo;
  }

  /// Which buildings dig instead of levelling.
  bool _isPit(CityBuildingSpec spec) => spec.siteKind == SiteKind.pit;

  /// Pit depth from its radius. Real open-pit mines run roughly 1:4 depth to
  /// width at a stable bench angle, and holding to that is what makes a big
  /// quarry read as genuinely huge rather than as a wide scrape.
  double pitDepthFor(double radiusM) => (radiusM * 0.5).clamp(12.0, 900.0);

  /// One bench per ~25 m of depth, which is the working height of real
  /// haul-truck terraces.
  int benchesFor(double radiusM) =>
      (pitDepthFor(radiusM) / 25).round().clamp(3, 24);
}
