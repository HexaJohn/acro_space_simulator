// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Cutting a colony's frame into tiles, and what makes a tile the same tile
/// from one cut to the next.
///
/// The renderer re-cuts the frame whenever the colony's structure changes —
/// a building built, a road drawn, upgraded or reversed, a junction
/// overridden, the ground graded. It used to throw every tile away and build
/// the colony again from nothing, which for one road drawn was the whole city
/// blinking out and streaming back over twenty seconds; and an edit that kept
/// every count (an upgrade, a reversal) was not seen at all, because counts
/// were all the cut was keyed on.
///
/// Here the cut is PURE — a frame in, the tiles and the bodies' end tables
/// out — and every tile carries a [CityTileBucket.structureKey] that hashes
/// everything its build reads: every field of every building, every
/// attribute of every road (class, flags, widths, tapers, bridges, lifts,
/// decoration, every point in order), the road-cell patches, the road ENDS
/// that fall in it with the body's end-table entries its roads read, and the
/// junction overrides. Two cuts' keys for a tile are equal exactly when its
/// build would be, so the renderer keeps every tile whose key held — its
/// nodes, its parked tiers, its packed columns — and rebuilds only the ones
/// that moved ([CityTileBucketer.diff]).
///
/// A tile's key depends on more than the members it owns. Road ends go to the
/// tile they lie in, whichever tile owns the road, and the end table a road's
/// sidewalks and turning circles read is body-wide — so upgrading a road
/// re-keys the tile it belongs to, every tile one of its ends lies in, and
/// the tile of every road meeting it end to end, and nothing else.
///
/// Lots are the one member left out. The tiles do not draw them — the zoning
/// node paints the plat on the UI thread (see `CityNodes`) — so a lot zoned
/// or built moves no tile's key, and a zone stroke re-meshes nothing.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../../application/snapshot/world_snapshot.dart';
import '../../../domain/colony/city/parcel.dart';
import '../../../domain/colony/city/road_elevation.dart';
import '../../../domain/colony/city/road_junction.dart' show JunctionOverride;
import '../../../domain/shared/vector3.dart';
import 'city_tile_columns.dart';

/// The colony's tangent frame on its body: up through the root's anchor,
/// east and north across it, and the radius the anchor sits at.
///
/// One frame serves two things that must agree: the grid the colony is cut
/// into tiles by, and the light map's axes (see `_bakeLightMap`).
///
/// The tiles used to be cells of a cube grid in body-fixed metres. On a
/// curved surface that is the wrong shape: a colony's footprint drifts
/// across the grid's slabs — over forty kilometres the surface sags
/// 40²/(8·6371) ≈ 31 m, and the grid's axes are nowhere near the ground's
/// — so a third of the tiles were slivers holding a few buildings each,
/// and every sliver paid the tile's fixed draws. Two arc coordinates
/// across the tangent plane give one tile per footprint, and a point's
/// height above the ground plays no part in which.
class ColonyTangentBasis {
  ColonyTangentBasis.at(Vector3 anchorBF)
      : radiusM = anchorBF.length,
        up = anchorBF.normalized {
    // Any seed off the pole. The light map has always derived east this
    // way, and the tiles must use the same frame.
    final seed = up.z.abs() < 0.9 ? Vector3.unitZ : Vector3.unitX;
    east = up.cross(seed).normalized;
    north = up.cross(east);
  }

  /// The anchor's distance from the body's centre: the surface radius the
  /// arcs are measured on.
  final double radiusM;
  final Vector3 up;
  late final Vector3 east, north;

  /// Arc coordinates of [p] from the anchor, in metres of surface: east
  /// and north along the great circles through it.
  ///
  /// Measured on the DIRECTION of [p], not its position, so a rooftop and
  /// the street below it read the same — and as arc, not tangent-plane
  /// distance, so a cell `CityNodes.tileM` wide holds exactly that much
  /// ground along each axis rather than the little more the gnomonic
  /// projection's foreshortening would let in.
  (double, double) arcOf(Vector3 p) {
    final u = p.normalized;
    return (
      radiusM * math.asin(u.dot(east).clamp(-1.0, 1.0)),
      radiusM * math.asin(u.dot(north).clamp(-1.0, 1.0)),
    );
  }

  /// The grid cell [p] falls in, cells [tileM] of arc on a side.
  (int, int) cellOf(Vector3 p, double tileM) {
    final (e, n) = arcOf(p);
    return ((e / tileM).floor(), (n / tileM).floor());
  }

  /// The centre of cell ([ie], [iN]), on the surface at the anchor's
  /// radius. Exact along either axis and within a metre off it at any
  /// colony's size; the centre only anchors the tile and measures its
  /// distance, and the half diagonal covers the rest.
  Vector3 cellCentre(int ie, int iN, double tileM) {
    final ae = (ie + 0.5) * tileM / radiusM;
    final an = (iN + 0.5) * tileM / radiusM;
    final v = up + east * math.tan(ae) + north * math.tan(an);
    return v.normalized * radiusM;
  }
}

/// One tile of a cut: its members, the ends and overrides that fall in it,
/// and its identity.
class CityTileBucket {
  CityTileBucket(this.key, this.bodyId, this.centreBF, this.halfDiagonalM);

  /// `body/ie/iN`: the body, and the cell of its tangent grid.
  final String key;
  final String bodyId;

  /// The cell's centre, body-fixed: the tile's anchor.
  final Vector3 centreBF;

  /// What the renderer subtracts from the distance to [centreBF] for a
  /// lower bound on the distance to anything in the tile.
  final double halfDiagonalM;

  final List<BuildingSnapshot> buildings = [];
  final List<RoadSnapshot> roads = [];

  /// Per road in [roads], its own content hash ([CityTileBucketer.roadHash]),
  /// written with the [structureKey]: what the instant edited-road path
  /// tells an edited road by.
  final List<int> roadHashes = [];

  /// The tile's patches, as indices into the frame's columns.
  final CityTilePatchRefs patches = CityTilePatchRefs();
  final List<CityTileEnd> ends = [];

  /// The junction overrides the tile's junction pass may need: those within
  /// [CityTileBucketer.junctionReachM] of it.
  final List<CityTileJunction> junctions = [];

  /// Body-centre distance of the outermost building centre in the tile
  /// (0 with no buildings): the shell the camera's altitude is measured
  /// over in `CityNodes.tileCanDetail`.
  double maxRadiusM = 0;

  /// Everything the tile's build reads, hashed (see the library docs).
  /// Five `|`-separated fields — the member counts, then the hash — as
  /// the tier cache's key test expects (see `CityNodes.tierKeyCurrent`).
  String structureKey = '';
}

/// A whole cut of a frame.
class CityBucketPlan {
  CityBucketPlan._(this.anchors);

  /// Every tile, in the order the cut made them.
  final Map<String, CityTileBucket> tiles = {};

  /// Every body's root anchor: the ones the caller already had, untouched
  /// — every tile's offset is measured from one, so it is fixed for the
  /// root's life — and one for each body new to the frame: its first
  /// building, else its first patch, else the middle of its first road.
  final Map<String, Vector3> anchors;

  /// Per body: the widest half width and the count of road ends at each
  /// quantised end point (see [CityTileBucketer.endKeyOf]).
  final Map<String, Map<int, (double, int)>> endHalf = {};

  /// Per body: every end of every piece of elevated rail, body-fixed.
  final Map<String, List<Vector3>> transitEnds = {};

  /// Per body: its buildings — an empty list for a body with only patches
  /// or roads.
  final Map<String, List<BuildingSnapshot>> byBody = {};

  /// Whether any road on any body is sealed.
  bool sealedWorld = false;

  final Map<String, ColonyTangentBasis> _bases = {};
}

/// How a new cut stands against the tiles a renderer holds, by tile key.
class CityBucketDiff {
  const CityBucketDiff(this.kept, this.rekeyed, this.added, this.removed);

  /// The same tile with the same structure: kept as built.
  final List<String> kept;

  /// The same tile with a new structure: it goes on showing what it has
  /// while it rebuilds.
  final List<String> rekeyed;

  /// Tiles new to the cut.
  final List<String> added;

  /// Tiles the cut no longer has.
  final List<String> removed;
}

/// The cut, as pure functions of the frame.
class CityTileBucketer {
  const CityTileBucketer._();

  /// How far round a junction override's point a tile is given it: the
  /// override's own reach plus the junction pass's grouping tolerance, so a
  /// junction whose ends fall across a tile edge is matched by whichever
  /// tile draws it.
  static const double junctionReachM = JunctionOverride.matchM + 8.0;

  /// Cut [snap] into tiles [tileM] on a side, on the tangent grids of the
  /// bodies' [anchors] (any body without one is anchored by the cut).
  static CityBucketPlan bucket(
    WorldSnapshot snap, {
    required Map<String, Vector3> anchors,
    required double tileM,
  }) {
    final plan = CityBucketPlan._(Map.of(anchors));
    ColonyTangentBasis basisOf(String bodyId) => plan._bases.putIfAbsent(
        bodyId, () => ColonyTangentBasis.at(plan.anchors[bodyId]!));
    // The half diagonal stays the cube cell's, not the square's: it is a
    // LOWER bound on the distance to anything in the tile, it leaves
    // headroom for relief and towers standing off the cell's surface, and
    // the tier ranges were tuned against it.
    final halfDiagonalM = tileM * math.sqrt(3) / 2;
    CityTileBucket tileFor(String bodyId, Vector3 p) {
      final basis = basisOf(bodyId);
      final (ie, iN) = basis.cellOf(p, tileM);
      final key = '$bodyId/$ie/$iN';
      return plan.tiles[key] ??= CityTileBucket(
          key, bodyId, basis.cellCentre(ie, iN, tileM), halfDiagonalM);
    }

    for (final b in snap.buildings.values) {
      final p = Vector3(b.px, b.py, b.pz);
      plan.anchors.putIfAbsent(b.body, () => p);
      (plan.byBody[b.body] ??= []).add(b);
      final t = tileFor(b.body, p);
      t.buildings.add(b);
      // The outermost building centre, for the altitude bound in
      // `CityNodes.tileCanDetail`. A centre, not a roof: the bound is on
      // the distance to the point the detail tier is measured to.
      final r = p.length;
      if (r > t.maxRadiusM) t.maxRadiusM = r;
    }
    // By index, off the frame's columns: a tile records WHICH patches are
    // its own and gathers them when it packs (see [CityTilePatchRefs]), so
    // cutting six hundred thousand patches allocates no snapshot for any of
    // them.
    final ps = snap.patches;
    for (var i = 0; i < ps.length; i++) {
      final at = Vector3(ps.px[i], ps.py[i], ps.pz[i]);
      final body = ps.bodyAt(i);
      plan.anchors.putIfAbsent(body, () => at);
      plan.byBody.putIfAbsent(body, () => []);
      tileFor(body, at).patches.add(ps, i);
    }
    for (final r in snap.roads) {
      final pts = r.points;
      final n = pts.length ~/ 3;
      if (n < 2) continue;
      final m = (n ~/ 2) * 3;
      final mid = Vector3(pts[m], pts[m + 1], pts[m + 2]);
      plan.anchors.putIfAbsent(r.body, () => mid);
      plan.byBody.putIfAbsent(r.body, () => []);
      tileFor(r.body, mid).roads.add(r);
      if (r.sealed) plan.sealedWorld = true;
      final cls = _classOf(r);
      final first = Vector3(pts[0], pts[1], pts[2]);
      final last = Vector3(pts[3 * n - 3], pts[3 * n - 2], pts[3 * n - 1]);
      // The deck above the drape at either end: 0 for a road on the ground.
      final lift0 = r.lifts.isEmpty ? 0.0 : r.lifts.first;
      final lift1 = r.lifts.isEmpty ? 0.0 : r.lifts.last;
      // Widest carriageway meeting each road END, so a sidewalk can stop
      // short of its crossing instead of bridging the intersecting street.
      // Legs split from one crossing land on (nearly) the same point — the
      // junction pass tolerates 8 m of drift — so a coarse quantised key
      // groups them; its lift term keeps an overpass's end out of the
      // crossing under it. The count says whether anything ELSE meets
      // there: a dead end keeps its pavement all the way to the kerb line.
      if (!cls.isElevated) {
        final table = plan.endHalf[r.body] ??= {};
        void meet(Vector3 p, double lift) {
          final k = endKeyOf(p.x, p.y, p.z, lift);
          final prev = table[k];
          table[k] = prev == null
              ? (r.halfWidthM, 1)
              : (math.max(prev.$1, r.halfWidthM), prev.$2 + 1);
        }

        meet(first, lift0);
        meet(last, lift1);
      }
      // Every road END, with the point just inside it (for the leg
      // direction), to the tile the end lies in. Roads are already SPLIT at
      // their crossings, so an intersection is simply a place where three
      // or more ends meet. The first point is the start of travel — the
      // frame flips a reversed one-way road — which is what the warrant
      // needs to tell a one-way road leaving a junction from one arriving.
      if (cls.joinsJunctions) {
        final second = Vector3(pts[3], pts[4], pts[5]);
        final penult =
            Vector3(pts[3 * n - 6], pts[3 * n - 5], pts[3 * n - 4]);
        tileFor(r.body, first).ends.add(CityTileEnd(
            first, second, r.halfWidthM, cls, cls.paved, r.collector,
            isStart: true, liftM: lift0));
        tileFor(r.body, last).ends.add(CityTileEnd(
            last, penult, r.halfWidthM, cls, cls.paved, r.collector,
            liftM: lift1));
      }
      if (cls == RoadClass.transit) {
        (plan.transitEnds[r.body] ??= [])
          ..add(first)
          ..add(last);
      }
    }
    // The players' junction overrides, to the tile each lies in — and, near
    // a cell edge, to the tile across it: a junction is drawn by the tile
    // holding its seed end, which can be the neighbour's. Never a tile of
    // their own: an override with nothing round it has nothing to draw.
    for (final j in snap.junctions) {
      if (!plan.anchors.containsKey(j.body)) continue;
      final at = Vector3(j.px, j.py, j.pz);
      final (e, nn) = basisOf(j.body).arcOf(at);
      final tj = CityTileJunction(at, j.lights, j.stopPoints,
          stopsSet: j.stopsSet);
      final cells = <(int, int)>{
        for (final de in [e - junctionReachM, e + junctionReachM])
          for (final dn in [nn - junctionReachM, nn + junctionReachM])
            ((de / tileM).floor(), (dn / tileM).floor()),
      };
      for (final (ie, iN) in cells) {
        plan.tiles['${j.body}/$ie/$iN']?.junctions.add(tj);
      }
    }
    // Each tile's identity, once every road has met every other: the end
    // tables and the tiles' ends are only whole now.
    final transitHash = <String, int>{
      for (final e in plan.transitEnds.entries) e.key: _hashPoints(e.value),
    };
    for (final t in plan.tiles.values) {
      t.structureKey = structureKeyOf(t,
          endHalf: plan.endHalf[t.bodyId] ?? const {},
          transitHash: transitHash[t.bodyId] ?? 0);
    }
    return plan;
  }

  /// How [plan] stands against the tiles [held] — tile key to the
  /// structure key each was built under.
  static CityBucketDiff diff(Map<String, String> held, CityBucketPlan plan) {
    final kept = <String>[], rekeyed = <String>[], added = <String>[];
    for (final t in plan.tiles.values) {
      final was = held[t.key];
      if (was == null) {
        added.add(t.key);
      } else if (was == t.structureKey) {
        kept.add(t.key);
      } else {
        rekeyed.add(t.key);
      }
    }
    return CityBucketDiff(kept, rekeyed, added, [
      for (final k in held.keys)
        if (!plan.tiles.containsKey(k)) k,
    ]);
  }

  /// The end-table key of a road end at ([x], [y], [z]), body-fixed, with
  /// its deck [liftM] above the drape. UI-thread only (`Object.hash` is
  /// salted per isolate).
  ///
  /// Ten metres of position, and the lift in [RoadElevation.nodeMatchM]
  /// steps — with everything within that of the ground counted as the
  /// ground, since a deck end at grade meets the roads there. The tool's
  /// elevation steps are three metres and up, inside both the 10 m cell and
  /// the junction pass's 8 m tolerance, so without the lift an overpass's
  /// end above a crossing fused into it and shared its pull-backs and its
  /// dead-end count.
  static int endKeyOf(double x, double y, double z, [double liftM = 0]) =>
      Object.hash((x / 10).round(), (y / 10).round(), (z / 10).round(),
          liftTermOf(liftM));

  /// The same key read straight off a road's [points] at [i].
  static int endKeyAt(List<double> points, int i, [double liftM = 0]) =>
      endKeyOf(points[i], points[i + 1], points[i + 2], liftM);

  /// The lift's part of an end key: 0 at grade, else the lift in
  /// [RoadElevation.nodeMatchM] steps (never 0).
  static int liftTermOf(double liftM) =>
      liftM.abs() < RoadElevation.nodeMatchM
          ? 0
          : (liftM / RoadElevation.nodeMatchM).round();

  /// Everything of [r] a tile's build reads, hashed: its class, flags,
  /// widths and tapers, decoration, and every point, bridge and lift in
  /// order. Not its id: a road re-split into the very same geometry
  /// builds the very same tile.
  static int roadHash(RoadSnapshot r) {
    var h = 0x14057B7EF767814F;
    h = _mix(h, r.colonyId.hashCode);
    h = _mix(h, r.body.hashCode);
    h = _mix(h, r.roadClassIndex);
    h = _mix(
        h,
        (r.sealed ? 1 : 0) |
            (r.soundWalls ? 2 : 0) |
            (r.collector ? 4 : 0) |
            (r.startHalfWidthM != null ? 8 : 0) |
            (r.endHalfWidthM != null ? 16 : 0));
    h = _mixD(h, r.halfWidthM);
    h = _mixD(h, r.startHalfWidthM ?? 0);
    h = _mixD(h, r.endHalfWidthM ?? 0);
    h = _mix(h, r.decoration);
    h = _mixList(h, r.points);
    h = _mixList(h, r.bridges);
    return _mixList(h, r.lifts);
  }

  /// The road network's content, as far as the frame says it moved: each
  /// colony's roads revision and every junction override. Cheap enough for
  /// every frame — a handful of colonies and overrides — which is when the
  /// renderer asks it, to learn that an edit which kept every count (an
  /// upgrade, a reversal, a light switched off) has happened.
  static int roadsSignature(WorldSnapshot snap) {
    var h = 0x3C6EF372FE94F82B;
    for (final e in snap.roadsRevision.entries) {
      h = _mix(h, e.key.hashCode);
      h = _mix(h, e.value);
    }
    for (final j in snap.junctions) {
      h = _mix(h, j.body.hashCode);
      h = _mixD(h, j.px);
      h = _mixD(h, j.py);
      h = _mixD(h, j.pz);
      h = _mix(h, j.lights);
      h = _mix(h, j.stopsSet ? 1 : 0);
      h = _mixList(h, j.stopPoints);
    }
    return h;
  }

  /// The structure key of [t], with the body's [endHalf] table and the hash
  /// of its transit ends (see the library docs for what goes in and why).
  /// Also writes [CityTileBucket.roadHashes].
  static String structureKeyOf(
    CityTileBucket t, {
    required Map<int, (double, int)> endHalf,
    int transitHash = 0,
  }) {
    var h = 0x2545F4914F6CDD1D;
    for (final b in t.buildings) {
      h = _mix(h, b.id.hashCode);
      h = _mix(h, b.type.hashCode);
      h = _mix(h, b.colonyId.hashCode);
      h = _mix(h, b.body.hashCode);
      h = _mixD(h, b.px);
      h = _mixD(h, b.py);
      h = _mixD(h, b.pz);
      h = _mixD(h, b.qw);
      h = _mixD(h, b.qx);
      h = _mixD(h, b.qy);
      h = _mixD(h, b.qz);
      h = _mixD(h, b.lat);
      h = _mixD(h, b.lon);
      h = _mixD(h, b.siteWidthM);
      h = _mixD(h, b.siteDepthM);
      h = _mix(h, b.siteKindIndex);
      h = _mix(h, b.corner ? 1 : 0);
      h = _mix(h, b.colorArgb);
    }
    t.roadHashes.clear();
    var transit = false;
    for (final r in t.roads) {
      final rh = roadHash(r);
      t.roadHashes.add(rh);
      h = _mix(h, rh);
      // What the body's end table says of the road's two ends — the widest
      // carriageway meeting each and how many ends meet: the pull-back and
      // the turning circle read them, and they move when a road in ANOTHER
      // tile meets this one.
      final p = r.points;
      final last = 3 * (p.length ~/ 3) - 3;
      h = _mixEnd(h,
          endHalf[endKeyAt(p, 0, r.lifts.isEmpty ? 0.0 : r.lifts.first)]);
      h = _mixEnd(h,
          endHalf[endKeyAt(p, last, r.lifts.isEmpty ? 0.0 : r.lifts.last)]);
      if (_classOf(r) == RoadClass.transit) transit = true;
    }
    // A transit road's terminals read every transit end on the body.
    if (transit) h = _mix(h, transitHash);
    final src = t.patches.source;
    var roadCells = 0;
    if (src != null) {
      final rows = t.patches.indices;
      for (var k = 0; k < rows.length; k++) {
        final i = rows[k];
        final kind = src.kind[i];
        if ((kind & CityPatchSnapshot.lotFlag) != 0) continue;
        roadCells++;
        h = _mix(h, kind);
        h = _mixD(h, src.px[i]);
        h = _mixD(h, src.py[i]);
        h = _mixD(h, src.pz[i]);
        h = _mixD(h, src.qw[i]);
        h = _mixD(h, src.qx[i]);
        h = _mixD(h, src.qy[i]);
        h = _mixD(h, src.qz[i]);
        h = _mixD(h, src.sizeM[i]);
        h = _mixD(h, src.depthM[i]);
      }
    }
    for (final e in t.ends) {
      h = _mixV(h, e.at);
      h = _mixV(h, e.next);
      h = _mixD(h, e.halfWidthM);
      h = _mix(h, e.roadClass.index);
      h = _mix(h,
          (e.paved ? 1 : 0) | (e.collector ? 2 : 0) | (e.isStart ? 4 : 0));
      h = _mixD(h, e.liftM);
    }
    for (final j in t.junctions) {
      h = _mixV(h, j.at);
      h = _mix(h, j.lights);
      h = _mix(h, j.stopsSet ? 1 : 0);
      h = _mixList(h, j.stopPoints);
    }
    return '${t.buildings.length}|${t.roads.length}|$roadCells|'
        '${t.ends.length}|${h.toRadixString(16)}';
  }

  static RoadClass _classOf(RoadSnapshot r) =>
      RoadClass.values[r.roadClassIndex.clamp(0, RoadClass.values.length - 1)];

  static int _hashPoints(List<Vector3> points) {
    var h = 0x1B873593;
    for (final p in points) {
      h = _mixV(h, p);
    }
    return h;
  }
}

/// One step of the content hash: a 64-bit multiply-xorshift over the running
/// value. For EQUALITY only — two cuts' keys for a tile are compared, never
/// bucketed — and only ever on the UI thread, so it need be stable within a
/// run and nothing more (as the strings' own hash codes are).
int _mix(int h, int v) {
  final x = (h ^ v) * 0x5851F42D4C957F2D;
  return x ^ (x >>> 29);
}

/// A double into the hash, to the micrometre: any real change of anything
/// a tile draws is bigger, and the same capture of the same ground gives
/// the same doubles.
int _mixD(int h, double d) =>
    _mix(h, d.isFinite && d.abs() < 9e12 ? (d * 1e6).round() : d.hashCode);

int _mixV(int h, Vector3 v) => _mixD(_mixD(_mixD(h, v.x), v.y), v.z);

/// A list with its length first, so where one list ends and the next begins
/// is part of the hash.
///
/// A typed list of doubles — every road's points, as the capture and the
/// wire both make them — is read as its 64-bit words: the same doubles are
/// the same bits, and reading them is half the work of quantising each one,
/// over the millions of points a big colony's roads hold (the cut runs on
/// the UI thread, on every road edit). Anything else, or a platform without
/// 64-bit typed words, is quantised double by double.
int _mixList(int h, List<double> v) {
  h = _mix(h, v.length);
  if (!_web && v is Float64List) {
    final bits = Int64List.view(v.buffer, v.offsetInBytes, v.length);
    for (var i = 0; i < bits.length; i++) {
      h = _mix(h, bits[i]);
    }
    return h;
  }
  for (var i = 0; i < v.length; i++) {
    h = _mixD(h, v[i]);
  }
  return h;
}

/// Whether this is the web, where an int is a double and there is no
/// `Int64List`.
const bool _web = identical(0, 0.0);

/// An end-table entry (or its absence) into the hash.
int _mixEnd(int h, (double, int)? e) =>
    e == null ? _mix(h, -1) : _mixD(_mix(h, e.$2), e.$1);
