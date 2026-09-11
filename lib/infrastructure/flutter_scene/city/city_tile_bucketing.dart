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
/// And a tile with a deck on piers takes, beside its own roads, the ground
/// roads of the tiles round it that pass within a pier's reach of that deck
/// ([CityTileBucket.corridors]). A road belongs to the tile its middle lies
/// in, and the road under a deck near a tile's edge is as often as not the
/// neighbour's, which the deck's piers would stand in. They are in the key,
/// so moving one re-cuts the deck's tile; a tile with no deck takes none,
/// and keys and builds exactly as it always did.
///
/// So too a deck's end where just one other end meets it: whether the two
/// turn off one another there — an L, whose inside parapets stand in each
/// other's lanes — or one road goes on through ([CityBucketPlan.endBends]).
/// Only the whole body's roads can say, since the other leg can be any
/// tile's; it is in the key of the deck's tile, so turning the other leg
/// re-cuts it. Both are the keyed cut's work ([CityTileBucketer.keyTiles]):
/// a cut culled for range never looks for either.
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
import 'road_deck.dart' show RoadCorridors;
import 'road_mesher.dart' show RoadMesher;

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

  /// The ground roads of other tiles that pass within a pier's reach of
  /// one of this tile's decks, as their carriageways (see the library
  /// docs). Empty for a tile with no deck on piers, and until the cut is
  /// keyed ([CityTileBucketer.keyTiles]).
  final List<CityTileCorridor> corridors = [];

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

  /// Per body: the widest half width and the count of road ends meeting at
  /// each quantised end point — one entry for the roads on the ground
  /// there, one for each deck end (see [CityTileBucketer.endKeyOf]).
  final Map<String, Map<int, (double, int)>> endHalf = {};

  /// Per body: every end of every piece of elevated rail, body-fixed.
  final Map<String, List<Vector3>> transitEnds = {};

  /// Per body: its buildings — an empty list for a body with only patches
  /// or roads.
  final Map<String, List<BuildingSnapshot>> byBody = {};

  /// Per body: the end-table keys ([CityTileBucketer.endKeyOf]) where a
  /// deck's end and the one other end meeting it turn off one another —
  /// their inward headings more than 20° off straight on — as a deck's
  /// parapets read them ([CityTileBucketer.bendsOf]). Empty until the cut
  /// is keyed ([CityTileBucketer.keyTiles]), and on a body nobody raised a
  /// road on.
  final Map<String, Set<int>> endBends = {};

  /// Whether any road on any body is sealed.
  bool sealedWorld = false;

  final Map<String, ColonyTangentBasis> _bases = {};

  /// The frame's roads, in its order, and the cell size they were cut at:
  /// what the keyed cut's passes read ([CityTileBucketer.keyTiles]).
  List<RoadSnapshot> _roads = const [];
  double _tileM = 0;

  /// Whether the keyed cut's passes have run: they add to the tiles, so
  /// once.
  bool _passed = false;
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
  ///
  /// [keyed] false leaves every tile's [CityTileBucket.structureKey] empty,
  /// and its corridors and the bodies' bends ungathered, for [keyTiles] to
  /// do once the caller knows it wants them: hashing a big colony's content
  /// is a large part of a cut, and a cut the renderer is about to cull for
  /// range shows none of it (see [CityCutGate]).
  static CityBucketPlan bucket(
    WorldSnapshot snap, {
    required Map<String, Vector3> anchors,
    required double tileM,
    bool keyed = true,
  }) {
    final plan = CityBucketPlan._(Map.of(anchors))
      .._roads = snap.roads
      .._tileM = tileM;
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
    // Deck ends — body, point, lift, half width — for [_tableDeckEnds].
    final deckEnds = <(String, Vector3, double, double)>[];
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
      // Whether it has a deck at all: the snapshot carries lifts for a deck
      // and only for one, and a deck laid flush has a lift of 0 like the
      // ground.
      final onDeck = r.lifts.isNotEmpty;
      // Widest carriageway meeting each road END, so a sidewalk can stop
      // short of its crossing instead of bridging the intersecting street.
      // Legs split from one crossing land on (nearly) the same point — the
      // junction pass tolerates 8 m of drift — so a coarse quantised key
      // groups them. A deck's end waits for the rest of the cut, to be
      // tabled with the ends it meets by the grade-separation rule
      // ([_tableDeckEnds]): an overpass's end is none of the crossing under
      // it. The count says whether anything ELSE meets there: a dead end
      // keeps its pavement all the way to the kerb line.
      if (!cls.isElevated) {
        if (onDeck) {
          deckEnds
            ..add((r.body, first, lift0, r.halfWidthM))
            ..add((r.body, last, lift1, r.halfWidthM));
        } else {
          final table = plan.endHalf[r.body] ??= {};
          void meet(Vector3 p) {
            final k = endKeyOf(p.x, p.y, p.z);
            final prev = table[k];
            table[k] = prev == null
                ? (r.halfWidthM, 1)
                : (math.max(prev.$1, r.halfWidthM), prev.$2 + 1);
          }

          meet(first);
          meet(last);
        }
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
            isStart: true, liftM: lift0, onDeck: onDeck));
        tileFor(r.body, last).ends.add(CityTileEnd(
            last, penult, r.halfWidthM, cls, cls.paved, r.collector,
            liftM: lift1, onDeck: onDeck));
      }
      if (cls == RoadClass.transit) {
        (plan.transitEnds[r.body] ??= [])
          ..add(first)
          ..add(last);
      }
    }
    _tableDeckEnds(plan.endHalf, deckEnds);
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
    if (keyed) keyTiles(plan);
    return plan;
  }

  /// Give every tile with a deck on piers the ground roads of other tiles
  /// that come within a pier's reach of one of its decks
  /// ([CityTileBucket.corridors]), in the frame's road order. Only such
  /// tiles: a tile with no deck has no pier to keep out of anything, so
  /// every other tile — every tile of a colony nobody raised a road in —
  /// takes none, and costs the cut one look at each road's lifts.
  ///
  /// The reach is measured on bounds, points against points, grown by
  /// [RoadCorridors.reachM] — past which [RoadCorridors.blocks] turns a
  /// pier away from nothing — so the test can let in a road that will not
  /// matter, and never leaves out one that would. A road is held first to
  /// the bounds of all of a tile's decks together, grown for the widest of
  /// them, and only then to each deck: most roads of a big city come near
  /// no deck at all, and every road against every deck was, in a player's
  /// city with a few hundred decks, most of what a cut cost.
  static void _gatherCorridors(CityBucketPlan plan) {
    // Every deck on piers with its points' bounds, grouped by tile in the
    // cut's order: each tile's decks, the bounds of them all, and the
    // widest deck's half width.
    final groups = <(
      CityTileBucket,
      List<(RoadSnapshot, Float64List)>,
      Float64List,
      double,
    )>[];
    for (final t in plan.tiles.values) {
      List<(RoadSnapshot, Float64List)>? decks;
      Float64List? all;
      var widest = 0.0;
      for (final r in t.roads) {
        if (!_onPiers(r)) continue;
        final d = _boundsOf(r.points);
        (decks ??= []).add((r, d));
        if (all == null) {
          all = Float64List.fromList(d);
        } else {
          for (var k = 0; k < 3; k++) {
            all[k] = math.min(all[k], d[k]);
            all[k + 3] = math.max(all[k + 3], d[k + 3]);
          }
        }
        widest = math.max(widest, r.halfWidthM);
      }
      if (decks != null) groups.add((t, decks, all!, widest));
    }
    if (groups.isEmpty) return;
    for (final r in plan._roads) {
      final pts = r.points;
      final n = pts.length ~/ 3;
      // The roads a tile's own corridors take (see `CityTileMeshJob`).
      if (n < 2 || _classOf(r).isElevated) continue;
      Float64List? box;
      String? owner;
      for (final (t, decks, all, widest) in groups) {
        if (t.bodyId != r.body) continue;
        final b = box ??= _boundsOf(pts);
        if (!_within(
            b, all, RoadCorridors.reachM(widest, r.halfWidthM) + 1.0)) {
          continue;
        }
        for (final (deck, d) in decks) {
          if (!_within(
              b, d, RoadCorridors.reachM(deck.halfWidthM, r.halfWidthM) + 1.0)) {
            continue;
          }
          // A road of the deck's own tile is one of its corridors already.
          owner ??= _ownerOf(plan, r);
          if (owner != t.key) {
            t.corridors.add(CityTileCorridor(pts, r.halfWidthM));
          }
          // Once to a tile, however many of its decks the road comes near.
          break;
        }
      }
    }
  }

  /// Whether the boxes [a] and [b] (as [_boundsOf] makes them) come within
  /// [pad] of one another along every axis.
  static bool _within(Float64List a, Float64List b, double pad) =>
      a[0] - pad <= b[3] &&
      a[1] - pad <= b[4] &&
      a[2] - pad <= b[5] &&
      a[3] + pad >= b[0] &&
      a[4] + pad >= b[1] &&
      a[5] + pad >= b[2];

  /// The key of the tile [r] belongs to: the cell its middle point lies
  /// in, as [bucket] put it there.
  static String _ownerOf(CityBucketPlan plan, RoadSnapshot r) {
    final pts = r.points;
    final m = (pts.length ~/ 3 ~/ 2) * 3;
    final (ie, iN) = plan._bases[r.body]!
        .cellOf(Vector3(pts[m], pts[m + 1], pts[m + 2]), plan._tileM);
    return '${r.body}/$ie/$iN';
  }

  /// cos 20°: two ends meeting less than that off straight on are one road
  /// going on, and a deck's parapet goes on with it.
  static const double straightOnCos = 0.94;

  /// Fill [CityBucketPlan.endBends]: at every end of a deck where the
  /// body's end table counts just two ends, whether the two turn off one
  /// another.
  ///
  /// Two passes over the frame's roads, the second only on a body that has
  /// such an end. First the deck ends wanted, by the point they stand at: a
  /// road on the ground has no parapet to hold back, so a body nobody
  /// raised a road on is done with at one look at each road's lifts. Then
  /// every end the table counted — the roads that are not elevated — at a
  /// point wanted, with its level and its inward heading. Each deck end
  /// wanted is then held to the one end there that MEETS it by the rule
  /// the table counted it by ([RoadMesher.liftsSeparated], see
  /// [_tableDeckEnds]): a deck end has a key of its own, and the end it
  /// meets — a road on the ground it is graded into, or a deck a few
  /// metres off its lift — keys another, so no key can pair them.
  static void _findBends(CityBucketPlan plan) {
    // body → point key → the deck ends wanted there: road, which end, its
    // lift and its own key.
    Map<String, Map<int, List<(RoadSnapshot, bool, double, int)>>>? wanted;
    for (final r in plan._roads) {
      final l = r.lifts;
      if (l.isEmpty || _classOf(r).isElevated) continue;
      final p = r.points;
      final n = p.length ~/ 3;
      final table = plan.endHalf[r.body];
      if (n < 2 || table == null) continue;
      for (final first in const [true, false]) {
        final i = first ? 0 : 3 * n - 3;
        final lift = first ? l.first : l.last;
        final k = endKeyAt(p, i, lift);
        if (table[k]?.$2 != 2) continue;
        (((wanted ??= {})[r.body] ??= {})[endKeyAt(p, i)] ??= [])
            .add((r, first, lift, k));
      }
    }
    if (wanted == null) return;
    // body → point key → every end there: road, which end, its deck's lift
    // (null on the ground) and its inward heading.
    final ends = <String, Map<int, List<(RoadSnapshot, bool, double?, Vector3)>>>{};
    for (final r in plan._roads) {
      final points = wanted[r.body];
      if (points == null || _classOf(r).isElevated) continue;
      final p = r.points;
      final n = p.length ~/ 3;
      if (n < 2) continue;
      final l = r.lifts;
      for (final first in const [true, false]) {
        final i = first ? 0 : 3 * n - 3, j = first ? 3 : 3 * n - 6;
        final at = endKeyAt(p, i);
        if (!points.containsKey(at)) continue;
        final inward =
            Vector3(p[j] - p[i], p[j + 1] - p[i + 1], p[j + 2] - p[i + 2]);
        ((ends[r.body] ??= {})[at] ??= []).add(
            (r, first, l.isEmpty ? null : (first ? l.first : l.last), inward));
      }
    }
    wanted.forEach((body, points) {
      points.forEach((at, decks) {
        final here = ends[body]?[at] ?? const [];
        for (final (r, first, lift, key) in decks) {
          Vector3? mine, other;
          var meeting = 0;
          for (final (o, oFirst, oLift, inward) in here) {
            if (identical(o, r) && oFirst == first) {
              mine = inward;
            } else if (!RoadMesher.liftsSeparated(
                oLift ?? 0.0, oLift != null, lift, true)) {
              other = inward;
              meeting++;
            }
          }
          if (meeting == 1 && mine != null && _turns(mine, other!)) {
            (plan.endBends[body] ??= {}).add(key);
          }
        }
      });
    });
  }

  /// Whether two ends leaving one joint along [u] and [v] turn off one
  /// another rather than going on (see [straightOnCos]). A degenerate end
  /// has no heading, and reads as going on.
  static bool _turns(Vector3 u, Vector3 v) {
    if (u.length < 1e-6 || v.length < 1e-6) return false;
    return u.normalized.dot(v.normalized) > -straightOnCos;
  }

  /// Whether [r]'s first and its last end turn off the one other end that
  /// meets each, as a body's [bends] ([CityBucketPlan.endBends]) have them:
  /// where a deck's parapets hold back (see `CityTileMeshJob`). Never for a
  /// road on the ground, which has no parapet — every road the generator
  /// lays.
  static (bool, bool) bendsOf(RoadSnapshot r, Set<int> bends) {
    final l = r.lifts, p = r.points;
    if (l.isEmpty || bends.isEmpty || p.length < 6) return (false, false);
    return (
      bends.contains(endKeyAt(p, 0, l.first)),
      bends.contains(endKeyAt(p, 3 * (p.length ~/ 3) - 3, l.last)),
    );
  }

  /// Whether [r] stands on piers anywhere: a deck the tool raised clear of
  /// the ground at some point, or one carrying a plan's bridge, whose lift
  /// stands on the deck's. No road the generator lays has a deck.
  static bool _onPiers(RoadSnapshot r) {
    final l = r.lifts;
    if (l.isEmpty || l.length != r.points.length ~/ 3) return false;
    if (_classOf(r).isElevated) return false;
    if (r.bridges.isNotEmpty) return true;
    for (final v in l) {
      if (v > RoadElevation.structureClearM) return true;
    }
    return false;
  }

  /// The least x, y, z of [points] (xyz triplets), then the greatest.
  static Float64List _boundsOf(List<double> points) {
    final b = Float64List(6)
      ..[0] = double.infinity
      ..[1] = double.infinity
      ..[2] = double.infinity
      ..[3] = -double.infinity
      ..[4] = -double.infinity
      ..[5] = -double.infinity;
    for (var i = 0; i + 2 < points.length; i += 3) {
      for (var k = 0; k < 3; k++) {
        final v = points[i + k];
        if (v < b[k]) b[k] = v;
        if (v > b[k + 3]) b[k + 3] = v;
      }
    }
    return b;
  }

  /// Write every tile's structure key in [plan] — what [bucket] does itself
  /// unless told not to. Only once the cut is whole: a tile's key reads the
  /// body's end table and the tile's ends, which every road can add to.
  ///
  /// First, once for the plan, what only a cut that is kept needs and a
  /// key reads: the corridors its decks' piers keep out of
  /// ([CityTileBucket.corridors]), and the bends their parapets hold back
  /// at ([CityBucketPlan.endBends]).
  static void keyTiles(CityBucketPlan plan) {
    if (!plan._passed) {
      plan._passed = true;
      _gatherCorridors(plan);
      _findBends(plan);
    }
    final transitHash = <String, int>{
      for (final e in plan.transitEnds.entries) e.key: _hashPoints(e.value),
    };
    for (final t in plan.tiles.values) {
      t.structureKey = structureKeyOf(t,
          endHalf: plan.endHalf[t.bodyId] ?? const {},
          endBends: plan.endBends[t.bodyId] ?? const {},
          transitHash: transitHash[t.bodyId] ?? 0);
    }
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

  /// The end-table key of a road end at ([x], [y], [z]), body-fixed: for an
  /// end on a deck, with its [deckLiftM] above the drape (null for a road
  /// on the ground). A key made on one isolate compares only with keys made
  /// on it — the table's on the UI thread, a worker's own matching of two
  /// ends on the worker — and never crosses between them (`Object.hash` is
  /// salted per isolate).
  ///
  /// Ten metres of position. The roads on the ground at a point share one
  /// entry; a deck end has one of its own, keyed by its lift to the bit —
  /// a deck laid flush included — which holds the ends it meets
  /// ([_tableDeckEnds]). The tool's elevation steps are three metres and
  /// up, inside both the 10 m cell and the junction pass's 8 m tolerance,
  /// so without its lift an overpass's end above a crossing fused into it
  /// and shared its pull-backs and its dead-end count.
  static int endKeyOf(double x, double y, double z, [double? deckLiftM]) {
    final ex = (x / 10).round(), ey = (y / 10).round(), ez = (z / 10).round();
    return deckLiftM == null
        ? Object.hash(ex, ey, ez, 0)
        : Object.hash(ex, ey, ez, 1, deckLiftM);
  }

  /// The same key read straight off a road's [points] at [i].
  static int endKeyAt(List<double> points, int i, [double? deckLiftM]) =>
      endKeyOf(points[i], points[i + 1], points[i + 2], deckLiftM);

  /// Table a cut's deck ends — body, point, lift, half width, as [bucket]
  /// gathers them — once every road on the ground is in.
  ///
  /// Each deck end's entry ([endKeyOf] with its lift) holds the widest
  /// carriageway and the count of the ends at its point it MEETS by the
  /// grade-separation rule ([RoadMesher.liftsSeparated], the rule the
  /// junction pass draws the plate by): the decks short of the grade
  /// separation from it, itself among them, and the roads on the ground
  /// there wherever it is graded into it — and each deck so graded counts
  /// on the ground's entry in turn. Which ends meet is a question of
  /// pairs — two decks three metres apart meet, and a third three metres
  /// over the second meets it and not the first — that no step of lift in
  /// a key can answer. (Two-metre steps parted the legs of the junctions
  /// the tiles draw — decks at 20 and 24 m, a road sunk three metres into
  /// a cutting and the street it was cut into — and each leg ran its
  /// pavement across the plate as though nothing met it there.)
  static void _tableDeckEnds(Map<String, Map<int, (double, int)>> endHalf,
      List<(String, Vector3, double, double)> decks) {
    if (decks.isEmpty) return;
    final byPoint = <(String, int), List<(int, double, double)>>{};
    for (final (body, p, lift, half) in decks) {
      (byPoint[(body, endKeyOf(p.x, p.y, p.z))] ??= [])
          .add((endKeyOf(p.x, p.y, p.z, lift), lift, half));
    }
    byPoint.forEach((at, here) {
      final table = endHalf[at.$1] ??= {};
      final ground = table[at.$2];
      var withDecks = ground;
      for (final (key, lift, half) in here) {
        final graded = !RoadMesher.liftsSeparated(0, false, lift, true);
        var widest = 0.0, n = 0;
        if (graded && ground != null) {
          widest = ground.$1;
          n = ground.$2;
        }
        for (final (_, other, otherHalf) in here) {
          if (RoadMesher.liftsSeparated(other, true, lift, true)) continue;
          widest = math.max(widest, otherHalf);
          n++;
        }
        table[key] = (widest, n);
        if (graded && withDecks != null) {
          withDecks = (math.max(withDecks.$1, half), withDecks.$2 + 1);
        }
      }
      if (withDecks != null) table[at.$2] = withDecks;
    });
  }

  /// Everything of [r] a tile's build reads, hashed: its class, flags,
  /// widths and tapers, decoration, and every point, bridge and lift in
  /// order. Not its id: a road re-split into the very same geometry
  /// builds the very same tile.
  static int roadHash(RoadSnapshot r) {
    var h = 0x9E3779B9;
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
    var h = 0x7F4A7C15;
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

  /// The structure key of [t], with the body's [endHalf] table, its
  /// [endBends] and the hash of its transit ends (see the library docs for
  /// what goes in and why). Also writes [CityTileBucket.roadHashes].
  static String structureKeyOf(
    CityTileBucket t, {
    required Map<int, (double, int)> endHalf,
    Set<int> endBends = const {},
    int transitHash = 0,
  }) {
    var h = 0x2545F491;
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
          endHalf[endKeyAt(p, 0, r.lifts.isEmpty ? null : r.lifts.first)]);
      h = _mixEnd(h,
          endHalf[endKeyAt(p, last, r.lifts.isEmpty ? null : r.lifts.last)]);
      // And of a deck's ends, whether each turns off the other end meeting
      // it, whichever tile that is. Not of a road on the ground's, which
      // has no parapet to hold back: the generator's keys are as they were.
      if (r.lifts.isNotEmpty) {
        final (b0, b1) = bendsOf(r, endBends);
        h = _mix(h, (b0 ? 1 : 0) | (b1 ? 2 : 0));
      }
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
          (e.paved ? 1 : 0) |
              (e.collector ? 2 : 0) |
              (e.isStart ? 4 : 0) |
              (e.onDeck ? 8 : 0));
      h = _mixD(h, e.liftM);
    }
    for (final j in t.junctions) {
      h = _mixV(h, j.at);
      h = _mix(h, j.lights);
      h = _mix(h, j.stopsSet ? 1 : 0);
      h = _mixList(h, j.stopPoints);
    }
    // The other tiles' roads the tile's decks keep their piers out of:
    // none in a tile with no deck, whose key is what it always was.
    for (final c in t.corridors) {
      h = _mixD(h, c.halfWidthM);
      h = _mixList(h, c.pointsBF);
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

/// Where the tiles of a colony culled for range were: enough to tell, frame
/// by frame, when the camera is back within range, without cutting the
/// frame to find out (see [CityCutGate]).
class CityCullBounds {
  CityCullBounds();

  /// The bounds of every tile of [plan].
  factory CityCullBounds.ofPlan(CityBucketPlan plan) {
    final b = CityCullBounds();
    for (final t in plan.tiles.values) {
      b.add(t.bodyId, t.centreBF, t.halfDiagonalM);
    }
    return b;
  }

  final List<String> _bodies = [];
  final List<Vector3> _centres = [];
  final List<double> _halfDiagonals = [];

  /// A tile on [bodyId], centred at [centreBF], [halfDiagonalM] from its
  /// centre to its corners.
  void add(String bodyId, Vector3 centreBF, double halfDiagonalM) {
    _bodies.add(bodyId);
    _centres.add(centreBF);
    _halfDiagonals.add(halfDiagonalM);
  }

  /// Tiles held.
  int get length => _bodies.length;

  /// What the last [nearestM] measured; infinity until one has.
  double lastNearestM = double.infinity;

  /// The least distance from the focus to any of the tiles, measured the
  /// way the renderer measures a tile — its centre's distance less its half
  /// diagonal, floored at zero — with [focusBF] the focus in each body's
  /// frame. A body it gives none for (one the frame does not carry) is
  /// passed over, as the renderer passes over its tiles; with nothing left,
  /// infinity.
  double nearestM(Vector3? Function(String bodyId) focusBF) {
    final focus = <String, Vector3?>{};
    var nearest = double.infinity;
    for (var i = 0; i < _bodies.length; i++) {
      final body = _bodies[i];
      final f = focus.putIfAbsent(body, () => focusBF(body));
      if (f == null) continue;
      final d = math.max(0.0, (_centres[i] - f).length - _halfDiagonals[i]);
      if (d < nearest) nearest = d;
    }
    return lastNearestM = nearest;
  }
}

/// When the renderer cuts the frame again.
///
/// A frame captured every tick carries new lists with the same contents,
/// so identity alone would re-cut two hundred thousand buildings sixty
/// times a second. The frame's structure signature is the change detector:
/// its counts, which the old rebuild key used, with the road network's
/// revision and overrides beside them ([CityTileBucketer.roadsSignature]).
///
/// And a colony out of range is not cut at all. The renderer used to forget
/// the signature with the tiles when the camera left range, so the next
/// frame cut the colony again only to find it out of range and drop it
/// again — a whole cut, hashing and all, on every frame for as long as the
/// colony stayed out of range, which from the flight view is most of an
/// orbit. A [cull] keeps the signature and the dropped tiles' bounds: the
/// colony is cut again when its structure changes, or when the camera comes
/// back within range of where its tiles were, and on no other frame.
class CityCutGate {
  String _signature = '';
  Object? _buildings, _roads, _patches;
  CityCullBounds? _culled;

  /// The signature of the last cut: '' before the first, and after a
  /// [reset].
  String get signature => _signature;

  /// The dropped tiles' bounds while the colony is culled for range, else
  /// null.
  CityCullBounds? get culled => _culled;

  /// Whether [snap], of structure [signature], wants cutting: its lists
  /// are new and the signature moved, or its colony is culled and back
  /// within [rangeM] of the camera ([focusBF] as for
  /// [CityCullBounds.nearestM]). Notes the frame's lists either way.
  bool wantsCut(
    WorldSnapshot snap,
    String signature, {
    required double rangeM,
    required Vector3? Function(String bodyId) focusBF,
  }) {
    final sameLists = identical(snap.buildings, _buildings) &&
        identical(snap.roads, _roads) &&
        identical(snap.patches, _patches);
    _buildings = snap.buildings;
    _roads = snap.roads;
    _patches = snap.patches;
    if (!sameLists && signature != _signature) return true;
    final culled = _culled;
    return culled != null && culled.nearestM(focusBF) <= rangeM;
  }

  /// A frame of structure [signature] was cut.
  void cut(String signature) {
    _signature = signature;
    _culled = null;
  }

  /// The colony was culled for range, its tiles within [bounds]. The
  /// signature stands, so a frame of the same structure is not cut again
  /// until the camera is back within range of [bounds].
  void cull(CityCullBounds bounds) => _culled = bounds;

  /// Forget every cut: the next frame with anything in it is cut.
  void reset() {
    _signature = '';
    _buildings = _roads = _patches = null;
    _culled = null;
  }
}

/// The content hash's arithmetic, for the hashes built on it elsewhere (the
/// instant path's road keys) and for the test that holds the web's product
/// to the VM's.
class CityHash32 {
  const CityHash32._();

  /// One step of the hash: [h] — a seed or a step's result, below 2³² — and
  /// the low 32 bits of [v], to a value below 2³² (see [_mix]).
  static int mix(int h, int v) => _mix(h, v);

  /// One step over two 32-bit words at once (see [_mixPair]).
  static int mixPair(int h, int lo, int hi) => _mixPair(h, lo, hi);

  /// [a] × [b] modulo 2³², computed the way the web computes it (see
  /// [_mul32]).
  static int mulSplit(int a, int b) => _mul32Split(a, b);
}

/// One step of the content hash: the running value and one 32-bit word,
/// through a multiply and an xorshift.
///
/// For EQUALITY only — two cuts' keys for a tile are compared, never
/// bucketed — and only ever on the UI thread, so it need be stable within a
/// run and nothing more (as the strings' own hash codes are). Both halves
/// of the step can be undone, so for a given word it maps running values
/// one to one: two contents differing in a single word never meet, and
/// ones differing in more meet by chance, one time in 2³².
///
/// Thirty-two bits because the web build compiles this too, and on the web
/// an int is a double: a 64-bit multiplier cannot even be written there
/// (dart2js refuses the literal, and the release's web job fails with it),
/// and a product past 2⁵³ loses its low bits. In 32 bits, with the product
/// split where it would pass that (see [_mul32]), the VM and the web
/// compute the same keys.
int _mix(int h, int v) {
  final x = _mul32((h ^ v) & 0xFFFFFFFF, 0x85EBCA6B);
  return x ^ (x >>> 13);
}

/// [a] × [b] modulo 2³², both below 2³². The VM's 64-bit product is exact
/// as it stands; the web's is not past 2⁵³, so there the multiply is split
/// at 16 bits of [a] and no partial product passes 2⁴⁸.
int _mul32(int a, int b) => _web ? _mul32Split(a, b) : (a * b) & 0xFFFFFFFF;

int _mul32Split(int a, int b) =>
    ((a & 0xFFFF) * b + ((((a >>> 16) * b) & 0xFFFF) << 16)) & 0xFFFFFFFF;

/// One step over a double's two 32-bit halves at once, [lo] and [hi], each
/// through its own odd multiplier: a change to either half alone always
/// moves the result, as a change of the one word does in [_mix], and a
/// change to both meets another by chance, one time in 2³². Half the steps
/// of taking the halves one at a time — and the doubles are most of what a
/// big colony's hash costs, so with this the 32-bit cut costs about what
/// the 64-bit one did.
int _mixPair(int h, int lo, int hi) {
  final a = (h ^ lo) & 0xFFFFFFFF, b = hi & 0xFFFFFFFF;
  // The VM's sum can pass 2⁶³ and wrap; modulo 2³² it is still exact.
  final x = _web
      ? (_mul32Split(a, 0x85EBCA6B) + _mul32Split(b, 0xC2B2AE35)) & 0xFFFFFFFF
      : (a * 0x85EBCA6B + b * 0xC2B2AE35) & 0xFFFFFFFF;
  return x ^ (x >>> 13);
}

/// A double into the hash, to the micrometre: any real change of anything
/// a tile draws is bigger, and the same capture of the same ground gives
/// the same doubles. Both 32-bit halves of the micrometres go in, as a
/// body-fixed coordinate is some 2⁴¹ of them.
int _mixD(int h, double d) {
  if (!d.isFinite || d.abs() >= 9e12) return _mix(h, d.hashCode);
  final q = (d * 1e6).round();
  // The high half: a shift on the VM; on the web, where shifts see only 32
  // bits, the same floor division, exact below 2⁵³.
  return _mixPair(h, q, _web ? (q / 4294967296).floor() : q >> 32);
}

int _mixV(int h, Vector3 v) => _mixD(_mixD(_mixD(h, v.x), v.y), v.z);

/// A list with its length first, so where one list ends and the next begins
/// is part of the hash.
///
/// A typed list of doubles — every road's points, as the capture and the
/// wire both make them — is read as its 32-bit words, a double's two halves
/// to a step ([_mixPair]): the same doubles are the same bits, and reading
/// them is less work than quantising each one, over the millions of points
/// a big colony's roads hold (the cut runs on the UI thread, on every road
/// edit). A 32-bit view is there on the web as well, where a 64-bit one is
/// not. Anything else is quantised double by double.
int _mixList(int h, List<double> v) {
  h = _mix(h, v.length);
  if (v is Float64List) {
    final words = Uint32List.view(v.buffer, v.offsetInBytes, v.length * 2);
    for (var i = 0; i + 1 < words.length; i += 2) {
      h = _mixPair(h, words[i], words[i + 1]);
    }
    return h;
  }
  for (var i = 0; i < v.length; i++) {
    h = _mixD(h, v[i]);
  }
  return h;
}

/// Whether this is the web, where an int is a double.
const bool _web = identical(0, 0.0);

/// An end-table entry (or its absence) into the hash.
int _mixEnd(int h, (double, int)? e) =>
    e == null ? _mix(h, -1) : _mixD(_mix(h, e.$2), e.$1);
