// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A tile's members as typed columns: the shape a tile crosses to a worker
/// in.
///
/// The request used to carry the tile's snapshot OBJECTS, and an isolate
/// send deep-copies whatever it is handed on the sending thread — every
/// snapshot's four strings, every road's points as a growable list of
/// boxed doubles (a near tile: two hundred roads, forty points each, three
/// doubles a point — twenty-odd thousand heap objects), every bridge list,
/// every record. Measured on the moving-camera sweep, one tile's send was
/// up to twenty-five milliseconds of the UI thread: the single worst
/// per-frame cost left in the colony renderer, and the one the budget
/// loop cannot slice.
///
/// A typed list crosses as ONE block — the VM copies its bytes with a
/// memcpy and never walks its elements — so the same tile packed into a
/// few `Float64List`s and `Int32List`s is a fraction of a millisecond to
/// send, however many points its roads have. The only strings that still
/// travel are the ones the meshing needs as strings: each building's id
/// (the archetype seed), and the type, colony and body names, which repeat
/// across a tile and go once each through a small per-tile table.
///
/// The application snapshots are the wire format and stay as they are;
/// this is the renderer's own packing of them, built once per tile on the
/// UI thread ([fromSnapshots]), sent as many times as the tile is re-keyed
/// (a tier change, a camera cell crossed), and unpacked back into the very
/// same snapshot classes on the worker ([toSnapshots]) so the mesher runs
/// unchanged over what it always read. The round trip is exact: every
/// field of every snapshot comes back equal, nulls included, which the
/// mesher's byte-identical output depends on — with one exception by
/// design, a road's id, which the frame carries for the road tool's
/// overlays and the meshing never reads (a string per road would cost every
/// tile's pack, and every send).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../../application/snapshot/world_snapshot.dart';
import '../../../domain/colony/city/parcel.dart';
import '../../../domain/shared/vector3.dart';

/// A road end that falls in a tile: where, the point just inside it, and
/// what the road is. Body-fixed; the junction pass anchors it.
class CityTileEnd {
  const CityTileEnd(this.at, this.next, this.halfWidthM, this.roadClass,
      this.paved, this.collector,
      {this.isStart = false, this.liftM = 0, bool? onDeck})
      : onDeck = onDeck ?? liftM != 0;
  final Vector3 at, next;
  final double halfWidthM;
  final RoadClass roadClass;
  final bool paved, collector;

  /// This end is its road's FIRST point — in the direction of travel, since
  /// the frame flips a reversed one-way road. What the traffic-light warrant
  /// reads to tell a one-way road leaving a junction from one arriving.
  final bool isStart;

  /// The road's deck above the drape at this end (0 at grade). Ends at
  /// different heights are not one junction: an overpass end is not a leg
  /// of the crossing under it.
  final double liftM;

  /// The road has a deck ([RoadEnd.onDeck]): the cut sets it from whether
  /// the snapshot carries lifts, since a deck laid flush has a lift of 0
  /// as a draped road does. Unsaid, any lift at all is a deck.
  final bool onDeck;
}

/// A player's override of one junction in a tile (the Junctions view),
/// body-fixed: lights forced on (1), off (0) or left to the warrant (-1),
/// and a point 12 m out along each leg that stops (xyz triplets; see
/// [stopsSet] for what an empty list means).
class CityTileJunction {
  const CityTileJunction(this.at, this.lights, this.stopPoints,
      {bool? stopsSet})
      : _stopsSet = stopsSet;
  final Vector3 at;
  final int lights;
  final List<double> stopPoints;
  final bool? _stopsSet;

  /// Whether the player chose which legs stop. Clear, the junction keeps
  /// the warrant's default stop legs whatever [stopPoints] holds; set with
  /// no points, NO leg stops — the one case an empty list alone cannot say
  /// (see `JunctionSnapshot.stopsSet`). Unsaid, it is whether there are any
  /// points, which is what the list alone meant.
  bool get stopsSet => _stopsSet ?? stopPoints.isNotEmpty;
}

/// A road of another tile that passes within a pier's reach of one of the
/// tile's decks, as a pier keeps out of it: its body-fixed points (xyz
/// triplets) and its half width, and nothing else (see `RoadCorridors`).
/// A road belongs to the tile its middle lies in, and the road under a
/// deck need not be the deck's.
class CityTileCorridor {
  const CityTileCorridor(this.pointsBF, this.halfWidthM);
  final List<double> pointsBF;
  final double halfWidthM;
}

/// A tile's members as the mesher reads them: the snapshot lists, rebuilt
/// from [CityTileColumns] on the side that meshes.
class CityTileMembers {
  const CityTileMembers({
    required this.buildings,
    required this.roads,
    required this.patches,
    required this.ends,
    required this.roadEnds,
    required this.transitEnds,
    this.junctions = const [],
    this.corridors = const [],
    this.roadEndBent = const [],
    this.sites = const [],
  });

  /// The site access plans the tile draws, per colony, as frames of just
  /// the tile's own sites (docs/plans/site-access.md §5.3): empty unless the
  /// request was cut with `CityMeshKnobs.siteAccess` on.
  final List<CitySiteFrame> sites;

  /// The player's junction overrides that fall in the tile.
  final List<CityTileJunction> junctions;

  /// The ground roads of other tiles that the tile's decks keep their piers
  /// out of — none in a tile with no deck, which is every tile the
  /// generator lays (see `CityTileBucketer`).
  final List<CityTileCorridor> corridors;

  final List<BuildingSnapshot> buildings;
  final List<RoadSnapshot> roads;

  /// The tile's patches, as the columns they already were in the frame:
  /// the mesher reads them by index (see `city_patch_columns.dart`).
  final CityPatchColumns patches;
  final List<CityTileEnd> ends;

  /// Per road, in [roads] order: what the body's end table says of its two
  /// ends — the widest carriageway meeting the end and how many ends meet
  /// there — at `[2 * i]` for the road's first point and `[2 * i + 1]` for
  /// its last, or null where the table has no entry (elevated roads are
  /// not tabled).
  final List<(double, int)?> roadEnds;

  /// Per road end, as [roadEnds]: whether it and the one other end that
  /// meets it turn off one another — only ever a deck's end, and worked
  /// out on the UI thread off the whole body's roads, since the other leg
  /// can be any tile's (see `CityBucketPlan.endBends`). Past its length —
  /// a tile whose members were handed over without it — false.
  final List<bool> roadEndBent;

  /// Every end of elevated rail on the body within reach of an end of one
  /// of the tile's transit roads, body-fixed: what decides whether an end
  /// is free and takes a terminal.
  final List<Vector3> transitEnds;
}

/// One tile's buildings, roads, patches and ends as typed columns.
///
/// Every numeric field is a `Float64List` (positions, quaternions, sizes,
/// half widths, the roads' points, bridge spans and lifts concatenated with
/// a list of per-road starts), every enum, count and flag an `Int32List`,
/// the facade colours a `Uint32List` — ARGB is an unsigned word, and a
/// signed column would hand back a negative — and the strings the meshing
/// cannot do without a `List<String>`. Plain typed lists, on purpose, not
/// a `TransferableTypedData`: a transfer CONSUMES its lists, and a tile
/// sends the same columns every time it is re-keyed, so the packing must
/// survive the send. A plain typed list is copied as a block instead.
class CityTileColumns {
  const CityTileColumns._({
    required this.strings,
    required this.buildingIds,
    required this.buildingStrings,
    required this.buildingF,
    required this.buildingI,
    required this.buildingColors,
    required this.roadStrings,
    required this.roadPoints,
    required this.roadPointStarts,
    required this.roadBridges,
    required this.roadBridgeStarts,
    required this.roadLifts,
    required this.roadLiftStarts,
    required this.roadCuts,
    required this.roadCutStarts,
    required this.sites,
    required this.roadF,
    required this.roadI,
    required this.patches,
    required this.endF,
    required this.endI,
    required this.roadEndHalf,
    required this.roadEndCount,
    required this.bentRoadEnds,
    required this.transitEnds,
    required this.junctionF,
    required this.junctionI,
    required this.junctionStops,
    required this.junctionStopStarts,
    required this.corridorPoints,
    required this.corridorPointStarts,
    required this.corridorHalf,
  });

  /// The per-tile string table: each distinct type, colony and body name
  /// once. The string columns hold indices into it.
  final List<String> strings;

  /// Building ids, one per building — the archetype seed, and the one
  /// string per member that cannot be tabled because it never repeats.
  final List<String> buildingIds;

  /// Per building: type, colonyId, body as [strings] indices.
  final Int32List buildingStrings;

  /// Per building: px, py, pz, qw, qx, qy, qz, lat, lon, siteWidthM,
  /// siteDepthM, gateXM, gateWM.
  final Float64List buildingF;

  /// Per building: siteKindIndex, flags ([cornerFlag]), siteSlot.
  final Int32List buildingI;

  /// Per building: colorArgb.
  final Uint32List buildingColors;

  /// Per road: colonyId, body as [strings] indices.
  final Int32List roadStrings;

  /// Every road's points, one after another; road i's are
  /// `[roadPointStarts[i], roadPointStarts[i + 1])`.
  final Float64List roadPoints;
  final Int32List roadPointStarts;

  /// Every road's bridge spans, likewise.
  final Float64List roadBridges;
  final Int32List roadBridgeStarts;

  /// Every raised or sunk road's deck above the drape, one per point,
  /// likewise — an empty range for a road on the ground, which is nearly
  /// every road, so a colony nobody lifted a road in carries no lift bytes
  /// at all. The road's [hasLiftsFlag] says the same, for the unpack.
  final Float64List roadLifts;
  final Int32List roadLiftStarts;

  /// Every road's kerb cuts (`RoadSnapshot.kerbCuts`), likewise: an empty
  /// range for a road with none.
  final Float64List roadCuts;
  final Int32List roadCutStarts;

  /// The tile's site access plans, per colony, as frames of just its own
  /// sites (see [CityTileMembers.sites]). Their chunks are typed lists too,
  /// so they cross as blocks.
  final List<CitySiteFrame> sites;

  /// Per road: halfWidthM, startHalfWidthM, endHalfWidthM — the last two
  /// meaningful only where the road's flags say the snapshot had them.
  final Float64List roadF;

  /// Per road: roadClassIndex, flags ([sealedFlag], [soundWallsFlag],
  /// [collectorFlag], [hasStartHalfFlag], [hasEndHalfFlag],
  /// [hasLiftsFlag]) with the road's decoration above them (see
  /// [decorationShift]).
  final Int32List roadI;

  /// The tile's patches. Not packed here: the frame already holds its
  /// patches as columns (see `city_patch_columns.dart`), and a tile's share
  /// is gathered from them — typed lists and a string table of its own, so
  /// it crosses to a worker as blocks like everything else in here.
  final CityPatchColumns patches;

  /// Per end: at (3), next (3), halfWidthM, liftM.
  final Float64List endF;

  /// Per end: roadClass index, flags ([pavedFlag], [endCollectorFlag],
  /// [endStartFlag], [endDeckFlag]).
  final Int32List endI;

  /// Per road end (two per road, first then last): the widest half width
  /// meeting there, and how many ends meet — or [noEntry] where the body's
  /// table has none, in which case the half width is zero and unread.
  final Float64List roadEndHalf;
  final Int32List roadEndCount;

  /// The road ends, as indices into [roadEndCount], where the two ends that
  /// meet turn off one another ([CityTileMembers.roadEndBent]). Empty but
  /// in a tile with a deck bent at a joint.
  final Int32List bentRoadEnds;

  /// Transit ends, three doubles each.
  final Float64List transitEnds;

  /// Per junction override: at (3).
  final Float64List junctionF;

  /// Per junction override: lights (-1, 0, 1), flags ([stopsSetFlag]).
  final Int32List junctionI;

  /// Every override's stop points, one after another; override i's are
  /// `[junctionStopStarts[i], junctionStopStarts[i + 1])`.
  final Float64List junctionStops;
  final Int32List junctionStopStarts;

  /// Every corridor's points, one after another; corridor i's are
  /// `[corridorPointStarts[i], corridorPointStarts[i + 1])` and its half
  /// width `corridorHalf[i]` (see [CityTileMembers.corridors]). Empty but
  /// in a tile with a deck.
  final Float64List corridorPoints;
  final Int32List corridorPointStarts;
  final Float64List corridorHalf;

  static const int cornerFlag = 1;
  static const int sealedFlag = 1;
  static const int soundWallsFlag = 2;
  static const int collectorFlag = 4;
  static const int hasStartHalfFlag = 8;
  static const int hasEndHalfFlag = 16;
  static const int hasLiftsFlag = 32;

  /// A road's `RoadDecoration` index rides its flags word from this bit,
  /// [decorationMask] wide: an enum that only ever grows, clear of every
  /// flag below it.
  static const int decorationShift = 8;
  static const int decorationMask = 0xFF;
  static const int pavedFlag = 1;
  static const int endCollectorFlag = 2;
  static const int endStartFlag = 4;
  static const int endDeckFlag = 8;
  static const int stopsSetFlag = 1;
  static const int noEntry = -1;

  static const int _buildingF = 13;
  static const int _buildingI = 3;
  static const int _endF = 8;

  int get buildingCount => buildingIds.length;
  int get roadCount => roadPointStarts.length - 1;
  int get patchCount => patches.length;
  int get endCount => endI.length ~/ 2;
  int get transitEndCount => transitEnds.length ~/ 3;
  int get junctionCount => junctionI.length ~/ 2;
  int get corridorCount => corridorHalf.length;

  /// How many of [transitEnds] lie within [radiusM] of the body-fixed
  /// point ([x], [y], [z]) — the terminal test, read straight off the
  /// column. The distance is the one `(other - at).length` computes,
  /// term for term, so the answer is the answer the vectors gave; what is
  /// gone is the vector per pair, on a test the mesher runs for every end
  /// of every transit road against every transit end in reach.
  int transitEndsNear(double x, double y, double z, double radiusM) {
    final t = transitEnds;
    var n = 0;
    for (var i = 0; i + 2 < t.length; i += 3) {
      final dx = t[i] - x, dy = t[i + 1] - y, dz = t[i + 2] - z;
      if (math.sqrt(dx * dx + dy * dy + dz * dz) < radiusM) n++;
    }
    return n;
  }

  /// Bytes the send copies as blocks: every typed column. The strings are
  /// on top of this, one object each.
  int get typedBytes =>
      buildingStrings.lengthInBytes +
      buildingF.lengthInBytes +
      buildingI.lengthInBytes +
      buildingColors.lengthInBytes +
      roadStrings.lengthInBytes +
      roadPoints.lengthInBytes +
      roadPointStarts.lengthInBytes +
      roadBridges.lengthInBytes +
      roadBridgeStarts.lengthInBytes +
      roadLifts.lengthInBytes +
      roadLiftStarts.lengthInBytes +
      roadCuts.lengthInBytes +
      roadCutStarts.lengthInBytes +
      sites.fold<int>(
          0,
          (n, f) => f.chunks.fold<int>(
              n, (m, g) => m + g.byteLength + g.plan.byteLength)) +
      roadF.lengthInBytes +
      roadI.lengthInBytes +
      patches.typedBytes +
      endF.lengthInBytes +
      endI.lengthInBytes +
      roadEndHalf.lengthInBytes +
      roadEndCount.lengthInBytes +
      bentRoadEnds.lengthInBytes +
      transitEnds.lengthInBytes +
      junctionF.lengthInBytes +
      junctionI.lengthInBytes +
      junctionStops.lengthInBytes +
      junctionStopStarts.lengthInBytes +
      corridorPoints.lengthInBytes +
      corridorPointStarts.lengthInBytes +
      corridorHalf.lengthInBytes;

  /// Pack a tile's members. [roadEnds] has two entries per road, in
  /// [roads] order (see [CityTileMembers.roadEnds]); [patches] are the
  /// tile's own already-gathered columns (see [CityTilePatchRefs.gather]);
  /// [junctions] are the player's overrides the tile's junction pass may
  /// need; [corridors] the other tiles' roads its decks' piers keep out of;
  /// [roadEndBent] as [roadEnds], or empty where no end of the tile's is
  /// bent (see [CityTileMembers.roadEndBent]).
  factory CityTileColumns.fromSnapshots({
    required List<BuildingSnapshot> buildings,
    required List<RoadSnapshot> roads,
    required CityPatchColumns patches,
    required List<CityTileEnd> ends,
    required List<(double, int)?> roadEnds,
    required List<Vector3> transitEnds,
    List<CityTileJunction> junctions = const [],
    List<CityTileCorridor> corridors = const [],
    List<bool> roadEndBent = const [],
    List<CitySiteFrame> sites = const [],
  }) {
    if (roadEnds.length != 2 * roads.length) {
      throw ArgumentError(
          'roadEnds has ${roadEnds.length} entries for ${roads.length} roads');
    }
    if (roadEndBent.isNotEmpty && roadEndBent.length != roadEnds.length) {
      throw ArgumentError('roadEndBent has ${roadEndBent.length} entries '
          'for ${roadEnds.length} road ends');
    }
    final table = <String>[];
    final index = <String, int>{};
    int intern(String s) => index.putIfAbsent(s, () {
          table.add(s);
          return table.length - 1;
        });

    final nb = buildings.length;
    final buildingIds = List<String>.generate(nb, (i) => buildings[i].id,
        growable: false);
    final buildingStrings = Int32List(nb * 3);
    final buildingF = Float64List(nb * _buildingF);
    final buildingI = Int32List(nb * _buildingI);
    final buildingColors = Uint32List(nb);
    for (var i = 0; i < nb; i++) {
      final b = buildings[i];
      buildingStrings[i * 3] = intern(b.type);
      buildingStrings[i * 3 + 1] = intern(b.colonyId);
      buildingStrings[i * 3 + 2] = intern(b.body);
      final f = i * _buildingF;
      buildingF[f] = b.px;
      buildingF[f + 1] = b.py;
      buildingF[f + 2] = b.pz;
      buildingF[f + 3] = b.qw;
      buildingF[f + 4] = b.qx;
      buildingF[f + 5] = b.qy;
      buildingF[f + 6] = b.qz;
      buildingF[f + 7] = b.lat;
      buildingF[f + 8] = b.lon;
      buildingF[f + 9] = b.siteWidthM;
      buildingF[f + 10] = b.siteDepthM;
      buildingF[f + 11] = b.gateXM;
      buildingF[f + 12] = b.gateWM;
      buildingI[i * _buildingI] = b.siteKindIndex;
      buildingI[i * _buildingI + 1] = b.corner ? cornerFlag : 0;
      buildingI[i * _buildingI + 2] = b.siteSlot;
      buildingColors[i] = b.colorArgb;
    }

    final nr = roads.length;
    var pointCount = 0, bridgeCount = 0, liftCount = 0, cutCount = 0;
    for (final r in roads) {
      pointCount += r.points.length;
      bridgeCount += r.bridges.length;
      liftCount += r.lifts.length;
      cutCount += r.kerbCuts.length;
    }
    final roadCuts = Float64List(cutCount);
    final roadCutStarts = Int32List(nr + 1);
    final roadStrings = Int32List(nr * 2);
    final roadPoints = Float64List(pointCount);
    final roadPointStarts = Int32List(nr + 1);
    final roadBridges = Float64List(bridgeCount);
    final roadBridgeStarts = Int32List(nr + 1);
    final roadLifts = Float64List(liftCount);
    final roadLiftStarts = Int32List(nr + 1);
    final roadF = Float64List(nr * 3);
    final roadI = Int32List(nr * 2);
    final roadEndHalf = Float64List(nr * 2);
    final roadEndCount = Int32List(nr * 2);
    var pAt = 0, bAt = 0, lAt = 0, kAt = 0;
    for (var i = 0; i < nr; i++) {
      final r = roads[i];
      roadStrings[i * 2] = intern(r.colonyId);
      roadStrings[i * 2 + 1] = intern(r.body);
      roadPointStarts[i] = pAt;
      roadPoints.setRange(pAt, pAt + r.points.length, r.points);
      pAt += r.points.length;
      roadBridgeStarts[i] = bAt;
      roadBridges.setRange(bAt, bAt + r.bridges.length, r.bridges);
      bAt += r.bridges.length;
      roadLiftStarts[i] = lAt;
      roadLifts.setRange(lAt, lAt + r.lifts.length, r.lifts);
      lAt += r.lifts.length;
      roadCutStarts[i] = kAt;
      roadCuts.setRange(kAt, kAt + r.kerbCuts.length, r.kerbCuts);
      kAt += r.kerbCuts.length;
      roadF[i * 3] = r.halfWidthM;
      roadF[i * 3 + 1] = r.startHalfWidthM ?? 0;
      roadF[i * 3 + 2] = r.endHalfWidthM ?? 0;
      roadI[i * 2] = r.roadClassIndex;
      roadI[i * 2 + 1] = (r.sealed ? sealedFlag : 0) |
          (r.soundWalls ? soundWallsFlag : 0) |
          (r.collector ? collectorFlag : 0) |
          (r.startHalfWidthM != null ? hasStartHalfFlag : 0) |
          (r.endHalfWidthM != null ? hasEndHalfFlag : 0) |
          (r.lifts.isNotEmpty ? hasLiftsFlag : 0) |
          ((r.decoration & decorationMask) << decorationShift);
      for (var k = 0; k < 2; k++) {
        final e = roadEnds[i * 2 + k];
        roadEndHalf[i * 2 + k] = e?.$1 ?? 0;
        roadEndCount[i * 2 + k] = e?.$2 ?? noEntry;
      }
    }
    roadPointStarts[nr] = pAt;
    roadBridgeStarts[nr] = bAt;
    roadLiftStarts[nr] = lAt;
    roadCutStarts[nr] = kAt;
    var bentCount = 0;
    for (final b in roadEndBent) {
      if (b) bentCount++;
    }
    final bentRoadEnds = Int32List(bentCount);
    for (var i = 0, k = 0; i < roadEndBent.length; i++) {
      if (roadEndBent[i]) bentRoadEnds[k++] = i;
    }

    final ne = ends.length;
    final endF = Float64List(ne * _endF);
    final endI = Int32List(ne * 2);
    for (var i = 0; i < ne; i++) {
      final e = ends[i];
      final f = i * _endF;
      endF[f] = e.at.x;
      endF[f + 1] = e.at.y;
      endF[f + 2] = e.at.z;
      endF[f + 3] = e.next.x;
      endF[f + 4] = e.next.y;
      endF[f + 5] = e.next.z;
      endF[f + 6] = e.halfWidthM;
      endF[f + 7] = e.liftM;
      endI[i * 2] = e.roadClass.index;
      endI[i * 2 + 1] = (e.paved ? pavedFlag : 0) |
          (e.collector ? endCollectorFlag : 0) |
          (e.isStart ? endStartFlag : 0) |
          (e.onDeck ? endDeckFlag : 0);
    }

    final transit = Float64List(transitEnds.length * 3);
    for (var i = 0; i < transitEnds.length; i++) {
      transit[i * 3] = transitEnds[i].x;
      transit[i * 3 + 1] = transitEnds[i].y;
      transit[i * 3 + 2] = transitEnds[i].z;
    }

    final nj = junctions.length;
    var stopCount = 0;
    for (final j in junctions) {
      stopCount += j.stopPoints.length;
    }
    final junctionF = Float64List(nj * 3);
    final junctionI = Int32List(nj * 2);
    final junctionStops = Float64List(stopCount);
    final junctionStopStarts = Int32List(nj + 1);
    var sAt = 0;
    for (var i = 0; i < nj; i++) {
      final j = junctions[i];
      junctionF[i * 3] = j.at.x;
      junctionF[i * 3 + 1] = j.at.y;
      junctionF[i * 3 + 2] = j.at.z;
      junctionI[i * 2] = j.lights;
      junctionI[i * 2 + 1] = j.stopsSet ? stopsSetFlag : 0;
      junctionStopStarts[i] = sAt;
      junctionStops.setRange(sAt, sAt + j.stopPoints.length, j.stopPoints);
      sAt += j.stopPoints.length;
    }
    junctionStopStarts[nj] = sAt;

    final nc = corridors.length;
    var corridorPointCount = 0;
    for (final c in corridors) {
      corridorPointCount += c.pointsBF.length;
    }
    final corridorPoints = Float64List(corridorPointCount);
    final corridorPointStarts = Int32List(nc + 1);
    final corridorHalf = Float64List(nc);
    var cAt = 0;
    for (var i = 0; i < nc; i++) {
      final c = corridors[i];
      corridorPointStarts[i] = cAt;
      corridorPoints.setRange(cAt, cAt + c.pointsBF.length, c.pointsBF);
      cAt += c.pointsBF.length;
      corridorHalf[i] = c.halfWidthM;
    }
    corridorPointStarts[nc] = cAt;

    return CityTileColumns._(
      strings: List<String>.of(table, growable: false),
      buildingIds: buildingIds,
      buildingStrings: buildingStrings,
      buildingF: buildingF,
      buildingI: buildingI,
      buildingColors: buildingColors,
      roadStrings: roadStrings,
      roadPoints: roadPoints,
      roadPointStarts: roadPointStarts,
      roadBridges: roadBridges,
      roadBridgeStarts: roadBridgeStarts,
      roadLifts: roadLifts,
      roadLiftStarts: roadLiftStarts,
      roadCuts: roadCuts,
      roadCutStarts: roadCutStarts,
      sites: List<CitySiteFrame>.of(sites, growable: false),
      roadF: roadF,
      roadI: roadI,
      patches: patches,
      endF: endF,
      endI: endI,
      roadEndHalf: roadEndHalf,
      roadEndCount: roadEndCount,
      bentRoadEnds: bentRoadEnds,
      transitEnds: transit,
      junctionF: junctionF,
      junctionI: junctionI,
      junctionStops: junctionStops,
      junctionStopStarts: junctionStopStarts,
      corridorPoints: corridorPoints,
      corridorPointStarts: corridorPointStarts,
      corridorHalf: corridorHalf,
    );
  }

  /// The members back as snapshots, field for field.
  ///
  /// A road's points, bridges and lifts come back as `Float64List` VIEWS
  /// over the columns rather than growable copies: the mesher only reads
  /// them, a view costs nothing to make, and the doubles are the same
  /// doubles, so the geometry is the geometry the snapshot objects gave. A
  /// road on the ground gets the shared empty lift list it went in with.
  /// A road's id does not come back: it never went (see the library docs).
  CityTileMembers toSnapshots() {
    final nb = buildingCount;
    final buildings = List<BuildingSnapshot>.generate(nb, (i) {
      final f = i * _buildingF;
      return BuildingSnapshot(
        id: buildingIds[i],
        type: strings[buildingStrings[i * 3]],
        colonyId: strings[buildingStrings[i * 3 + 1]],
        body: strings[buildingStrings[i * 3 + 2]],
        px: buildingF[f],
        py: buildingF[f + 1],
        pz: buildingF[f + 2],
        qw: buildingF[f + 3],
        qx: buildingF[f + 4],
        qy: buildingF[f + 5],
        qz: buildingF[f + 6],
        lat: buildingF[f + 7],
        lon: buildingF[f + 8],
        siteWidthM: buildingF[f + 9],
        siteDepthM: buildingF[f + 10],
        gateXM: buildingF[f + 11],
        gateWM: buildingF[f + 12],
        siteKindIndex: buildingI[i * _buildingI],
        corner: buildingI[i * _buildingI + 1] & cornerFlag != 0,
        siteSlot: buildingI[i * _buildingI + 2],
        colorArgb: buildingColors[i],
      );
    }, growable: false);

    final nr = roadCount;
    final roads = List<RoadSnapshot>.generate(nr, (i) {
      final flags = roadI[i * 2 + 1];
      return RoadSnapshot(
        colonyId: strings[roadStrings[i * 2]],
        body: strings[roadStrings[i * 2 + 1]],
        points: Float64List.sublistView(
            roadPoints, roadPointStarts[i], roadPointStarts[i + 1]),
        halfWidthM: roadF[i * 3],
        roadClassIndex: roadI[i * 2],
        sealed: flags & sealedFlag != 0,
        soundWalls: flags & soundWallsFlag != 0,
        collector: flags & collectorFlag != 0,
        bridges: Float64List.sublistView(
            roadBridges, roadBridgeStarts[i], roadBridgeStarts[i + 1]),
        startHalfWidthM: flags & hasStartHalfFlag != 0 ? roadF[i * 3 + 1] : null,
        endHalfWidthM: flags & hasEndHalfFlag != 0 ? roadF[i * 3 + 2] : null,
        decoration: (flags >> decorationShift) & decorationMask,
        lifts: flags & hasLiftsFlag != 0
            ? Float64List.sublistView(
                roadLifts, roadLiftStarts[i], roadLiftStarts[i + 1])
            : const <double>[],
        kerbCuts: roadCutStarts[i + 1] > roadCutStarts[i]
            ? Float64List.sublistView(
                roadCuts, roadCutStarts[i], roadCutStarts[i + 1])
            : const <double>[],
      );
    }, growable: false);
    final roadEnds = List<(double, int)?>.generate(nr * 2, (i) {
      final n = roadEndCount[i];
      return n == noEntry ? null : (roadEndHalf[i], n);
    }, growable: false);
    final roadEndBent = List<bool>.filled(nr * 2, false);
    for (final i in bentRoadEnds) {
      roadEndBent[i] = true;
    }

    final ends = List<CityTileEnd>.generate(endCount, (i) {
      final f = i * _endF;
      final flags = endI[i * 2 + 1];
      return CityTileEnd(
        Vector3(endF[f], endF[f + 1], endF[f + 2]),
        Vector3(endF[f + 3], endF[f + 4], endF[f + 5]),
        endF[f + 6],
        // Clamped like every other decode of the index: RoadClass only
        // grows, and a class this build does not know is read as the
        // newest one it does, never thrown on.
        RoadClass.values[endI[i * 2].clamp(0, RoadClass.values.length - 1)],
        flags & pavedFlag != 0,
        flags & endCollectorFlag != 0,
        isStart: flags & endStartFlag != 0,
        liftM: endF[f + 7],
        onDeck: flags & endDeckFlag != 0,
      );
    }, growable: false);

    final transit = List<Vector3>.generate(
        transitEnds.length ~/ 3,
        (i) => Vector3(
            transitEnds[i * 3], transitEnds[i * 3 + 1], transitEnds[i * 3 + 2]),
        growable: false);

    final junctions = List<CityTileJunction>.generate(junctionCount, (i) {
      return CityTileJunction(
        Vector3(junctionF[i * 3], junctionF[i * 3 + 1], junctionF[i * 3 + 2]),
        junctionI[i * 2],
        Float64List.sublistView(
            junctionStops, junctionStopStarts[i], junctionStopStarts[i + 1]),
        stopsSet: junctionI[i * 2 + 1] & stopsSetFlag != 0,
      );
    }, growable: false);

    final corridors = List<CityTileCorridor>.generate(
        corridorCount,
        (i) => CityTileCorridor(
            Float64List.sublistView(corridorPoints, corridorPointStarts[i],
                corridorPointStarts[i + 1]),
            corridorHalf[i]),
        growable: false);

    return CityTileMembers(
      buildings: buildings,
      roads: roads,
      // Already columns; the mesher reads them as such.
      patches: patches,
      ends: ends,
      roadEnds: roadEnds,
      transitEnds: transit,
      junctions: junctions,
      corridors: corridors,
      roadEndBent: roadEndBent,
      sites: sites,
    );
  }
}

/// A tile's share of the frame's patches: indices into the frame's
/// [CityPatchColumns], collected as the frame is bucketed and gathered into
/// columns of the tile's own when the tile is packed for a worker.
///
/// Indices rather than objects because there are no objects: the frame
/// keeps its patches as columns, and a list of six hundred thousand
/// snapshots spread across the tiles would put back exactly the heap the
/// columns took out of the old-generation marker's walk.
class CityTilePatchRefs {
  CityPatchColumns? _source;
  Int32List _indices = Int32List(32);
  int _n = 0;

  int get length => _n;

  /// The frame's columns the rows index — null before the first [add].
  /// What the tile's structure key reads its road cells from.
  CityPatchColumns? get source => _source;

  /// Row [i] of [source] belongs to this tile. Every row of a tile comes
  /// from the one frame it was bucketed from.
  void add(CityPatchColumns source, int i) {
    assert(_source == null || identical(_source, source),
        'a tile refers into the one frame it was bucketed from');
    _source ??= source;
    if (_n == _indices.length) {
      _indices = Int32List(_n * 2)..setRange(0, _n, _indices);
    }
    _indices[_n++] = i;
  }

  /// The rows, as a view over the buffer: valid until the next [add].
  Int32List get indices => Int32List.sublistView(_indices, 0, _n);

  /// The tile's patches as columns of their own (see
  /// [CityPatchColumns.gather]).
  CityPatchColumns gather() =>
      _source?.gather(indices) ?? CityPatchColumns.empty;
}
