// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The road network as a DIRECTED GRAPH: junctions, the stretches of
/// carriageway between them, which way traffic may run on each, and the
/// stretch every lot is reached from.
///
/// `ParcelNetwork` answers "does this road touch that one?" — enough to say
/// a lot is connected, not enough to route a car. It has no junctions, no
/// direction and no heights, so a one-way street, a median or a flyover
/// means nothing to it. Routing needs all three. The layout already splits
/// every road at its crossings, so a junction is simply where road ENDS
/// meet — the observation the renderer's junction pass is built on — and
/// this graph is those ends clustered (in plan AND in height: a deck passing
/// over a street is not a junction with it), the stretches between them as
/// edges, one per permitted direction, and every lot hung on the stretch it
/// is entered from.
///
/// Pure: built from a layout, never mutated. Its owner caches one per
/// (layout version, roads revision): the build walks the network once, the
/// routing that reads it runs on a colony-day cadence.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'city_layout.dart';
import 'hash32.dart';
import 'parcel.dart';
import 'road_catalog.dart';
import 'road_junction.dart';
import 'road_noise.dart';
import 'site_access/site_access_constants.dart'
    show kJoinRefNone, kJoinRefSideStreetBase, kJoinSlotSideStreet;
import 'site_access/site_join.dart';
import 'spatial_index.dart';

/// One junction (or a bend, or a dead end): where road ends meet.
class RoadNode {
  RoadNode._({
    required this.id,
    required this.at,
    required this.legs,
    required this.legRoadIds,
    required this.plan,
    required this.atGrade,
    required this.heightM,
    required bool roundaboutPreferred,
    required bool lifted,
  })  : _roundaboutPreferred = roundaboutPreferred,
        _lifted = lifted;

  /// Three collector legs or more: the warrant prefers a roundabout — the
  /// renderer's rule, so the sim times the junction the tiles draw. Kept so
  /// a re-plan under a new override ([RoadGraph.withOverrides]) asks the
  /// warrant the question the build asked. Counted, like [_lifted], over
  /// the legs the plan is read over ([RoadGraph._planOf]).
  final bool _roundaboutPreferred;

  /// A leg on a deck: the road tool's junction, planned by the leg-aware
  /// warrant (see `keepsClassWarrant`).
  final bool _lifted;

  /// This node under a different [plan] — everything else as it is.
  RoadNode _withPlan(JunctionPlan plan) => RoadNode._(
        id: id,
        at: at,
        legs: legs,
        legRoadIds: legRoadIds,
        plan: plan,
        atGrade: atGrade,
        heightM: heightM,
        roundaboutPreferred: _roundaboutPreferred,
        lifted: _lifted,
      );

  /// Index in [RoadGraph.nodes].
  final int id;

  /// Where it is, colony-local metres: the mean of the ends that meet.
  final Vec2 at;

  /// One leg per road end here, as the traffic-light warrant sees it —
  /// every one a way in and out, though the [plan] is read over only the
  /// ones the tiles draw a junction of (`RoadClass.joinsJunctions`).
  final List<JunctionLeg> legs;

  /// The road each of [legs] belongs to.
  final List<String> legRoadIds;

  /// The control and the legs that stop — the warrant's, or the player's
  /// override where one sits within [JunctionOverride.matchM].
  final JunctionPlan plan;

  /// Whether it is on the ground. False for a node on piers or in a
  /// tunnel, which only other decks near its [heightM] can join (the
  /// layout's rule, [CityLayout.levelsSeparated]).
  final bool atGrade;

  /// Deck height above the body datum, or null for a node of draped roads.
  final double? heightM;

  JunctionControl get control => plan.control;

  /// Three or more legs: a place where traffic chooses.
  bool get isJunction => legs.length >= 3;

  /// Seconds a vehicle arriving along leg [leg] loses here: a signal
  /// cycle, a stop, a roundabout's yield — nothing where a road simply
  /// carries on.
  double delayFor(int leg) {
    switch (plan.control) {
      case JunctionControl.signals:
        return RoadGraph.signalDelaySec;
      case JunctionControl.stop:
        return plan.stopLegs.contains(leg) ? RoadGraph.stopDelaySec : 0;
      case JunctionControl.roundabout:
        return RoadGraph.roundaboutDelaySec;
      case JunctionControl.none:
      case JunctionControl.merge:
        return 0;
    }
  }
}

/// The lazily hashed [RoadGraph.structureStamp], one cell per structure.
class _StructureStamp {
  int? value;
}

/// Where a lot is entered from: a road, the arc position on it, and the
/// directions of travel along it from which the lot can be reached (and in
/// which it can be left).
class LotAccess {
  const LotAccess(this.roadId, this.sM, {required this.forward, required this.backward});

  final String roadId;

  /// Metres along the road from its first control.
  final double sM;

  /// Reachable by traffic running first point to last, and last to first.
  final bool forward, backward;
}

/// Where something off the plat — a building the colony's grid placed — is
/// entered from, in the graph's own terms: the piece, the arc along its
/// road, and the access mask ([RoadGraph.forwardBit] /
/// [RoadGraph.backwardBit]).
class PieceAccess {
  const PieceAccess(this.piece, this.sM, this.dirs);

  final int piece;
  final double sM;
  final int dirs;
}

/// The directed road graph. See the library comment.
class RoadGraph {
  RoadGraph._({
    required this.index,
    required this.roads,
    required this.roadRecs,
    required Map<String, int> roadNo,
    required this.slotToRoad,
    required this.roadSpeedMps,
    required this.roadEmission,
    required this.roadBonus,
    required this.roadLanes,
    required this.roadPaved,
    required this.roadKey,
    required this.roadFirstPiece,
    required this.nodes,
    required this.pieceRoad,
    required this.pieceS0,
    required this.pieceS1,
    required this.pieceFrom,
    required this.pieceTo,
    required this.pieceFwdEdge,
    required this.pieceBwdEdge,
    required this.edgeFrom,
    required this.edgeTo,
    required this.edgePiece,
    required this.edgeForward,
    required this.edgeLength,
    required this.edgeTime,
    required this.edgeLeg,
    required this.outStart,
    required this.outEdges,
    required this.lotIds,
    required Map<String, int> lotNo,
    required this.lotPiece,
    required this.lotS,
    required this.lotDirs,
    required this.lotE,
    required this.lotN,
    required this.lotJoinStart,
    required this.joinPiece,
    required this.joinS,
    required this.joinDirs,
    required this.joinRight,
    required this.joinFlags,
    required this.joinRoomM,
    required this.joinKerbE,
    required this.joinKerbN,
    required this.joinNormE,
    required this.joinNormN,
    required this.joinCrossStart,
    required this.joinCrossLot,
    required this.kerbWindows,
    required List<Parcel> parcels,
    required double sidewalkM,
    Map<int, JoinSlot?>? sideStreetJoins,
    required this.rootPiece,
    required this.rootS,
    required this.rootDirs,
    required this.overrides,
    required this.overridesSignature,
    _StructureStamp? stamp,
  })  : _roadNo = roadNo,
        _lotNo = lotNo,
        _parcels = parcels,
        _sidewalkM = sidewalkM,
        _sideStreetJoins = sideStreetJoins ?? {},
        _stamp = stamp ?? _StructureStamp();

  /// The [structureStamp] cell, shared by every copy sharing this graph's
  /// structure ([withOverrides], [refreshedFor]), so it is hashed once.
  final _StructureStamp _stamp;

  /// A deterministic, web-safe 32-bit stamp of this graph's STRUCTURE
  /// (docs/plans/site-access.md §2.3, §4.1): its roads (id, class, dressing,
  /// direction, samples), nodes, pieces, edges, lots, join slots, crossed
  /// lots and kerb windows, and nothing an override or a road rename changes.
  ///
  /// Equal for graphs that [sharesStructureWith] each other; a graph rebuilt
  /// after any structure change stamps differently (up to a 32-bit hash
  /// collision). A rebuild of an unchanged layout stamps the same, which is
  /// right: every join handle and lot index it gives is the same. Hashed on
  /// the first read and kept; stamps are per platform (doubles are hashed by
  /// their bits in the platform's byte order). Signed 32-bit, as a chunk's
  /// `graphStamp` column holds it.
  int get structureStamp => _stamp.value ??= _hashStructure();

  int _hashStructure() {
    var h = kFnvOffset32;
    int word(int x) => h = mul32(h ^ (x & 0xFFFFFFFF), 0x01000193);
    void ints(List<int> xs) {
      word(xs.length);
      for (var i = 0; i < xs.length; i++) {
        word(xs[i]);
      }
    }

    void f64(Float64List xs) {
      word(xs.length);
      ints(xs.buffer.asUint32List(xs.offsetInBytes, xs.length * 2));
    }

    void f32(Float32List xs) {
      word(xs.length);
      ints(xs.buffer.asUint32List(xs.offsetInBytes, xs.length));
    }

    word(roads.length);
    for (var r = 0; r < roads.length; r++) {
      final road = roads[r];
      word(fnv1a32(road.id));
      word(road.roadClass.index);
      word(road.decoration.index);
      word(road.reversed ? 1 : 0);
      f64(roadRecs[r].e);
      f64(roadRecs[r].n);
    }
    ints(roadFirstPiece);
    word(nodes.length);
    for (final node in nodes) {
      final at = Float64List(2)
        ..[0] = node.at.e
        ..[1] = node.at.n;
      f64(at);
      word(node.legs.length);
    }
    ints(pieceRoad);
    f64(pieceS0);
    f64(pieceS1);
    ints(pieceFrom);
    ints(pieceTo);
    ints(edgeFrom);
    ints(edgeTo);
    ints(edgePiece);
    ints(edgeForward);
    f64(edgeLength);
    word(lotIds.length);
    for (final id in lotIds) {
      word(fnv1a32(id));
    }
    ints(lotPiece);
    f64(lotS);
    ints(lotDirs);
    f64(lotE);
    f64(lotN);
    ints(lotJoinStart);
    ints(joinPiece);
    f64(joinS);
    ints(joinDirs);
    ints(joinRight);
    ints(joinFlags);
    f32(joinRoomM);
    f64(joinKerbE);
    f64(joinKerbN);
    f64(joinNormE);
    f64(joinNormN);
    ints(joinCrossStart);
    ints(joinCrossLot);
    ints(kerbWindows.start);
    f64(kerbWindows.lo);
    f64(kerbWindows.hi);
    // Signed, as `SiteAccessChunk.graphStamp` stores it (Int32), so the two
    // compare with ==.
    return (h & 0xFFFFFFFF).toSigned(32);
  }

  /// Two road ends this close in plan (and at one level:
  /// [CityLayout.levelsSeparated] says they meet) are one node — the
  /// renderer's junction tolerance, wide enough to cover the layout's rule
  /// that a road is not cut within 6 m of an end.
  static const double nodeMatchPlanM = 8.0;

  /// A hand-drawn lot is served by a road passing this near it — the same
  /// reach `ParcelNetwork` gives a megaproject's access track.
  static const double manualReachM = 90.0;

  /// Slack beyond two half widths within which a dead end lying against
  /// another road joins it — `ParcelNetwork`'s touch slack, so the graph
  /// connects what the connectivity walk already calls connected.
  static const double attachSlackM = 4.0;

  /// Time lost at a junction, by its control.
  static const double signalDelaySec = 12;
  static const double stopDelaySec = 6;
  static const double roundaboutDelaySec = 3;

  /// Traffic directions, as bits of a lot's access mask.
  static const int forwardBit = 1, backwardBit = 2;

  /// The widest half width any class has: how far out a query must reach to
  /// be sure of every road that could matter to it.
  static final double maxHalfWidth =
      RoadClass.values.fold(0.0, (m, c) => math.max(m, c.halfWidth));

  /// The layout's road index as it stood at the build. The noise pass asks
  /// it what is near a lot; a road it holds that the graph does not (added
  /// since, or rail) is recognised by [slotToRoad] and ignored.
  final SegmentIndex index;

  /// The roads in the graph — every road but rail — by graph road number.
  final List<RoadSpline> roads;
  final List<IndexedRoad> roadRecs;
  final Map<String, int> _roadNo;

  /// Index slot -> graph road number, -1 for a slot not in the graph.
  final Int32List slotToRoad;

  /// Speed limit of each road, metres per second (see [RoadType.speedKmh]).
  final Float64List roadSpeedMps;

  /// What the traffic model reads of each road's menu entry, looked up once
  /// here rather than per pass: the noise it throws at its kerb
  /// ([RoadType.noiseEmission]), what its frontage adds to land value
  /// ([RoadNoise.frontageBonus]), its lanes in total (both ways) and
  /// whether it is paved — a lane's capacity.
  final Float64List roadEmission, roadBonus;
  final Int32List roadLanes;
  final Uint8List roadPaved;

  /// A hash of each road's [baseRoadId], the same on every build: every
  /// piece of one drawn road shares it, and a split's pieces keep their
  /// parent's. The traffic model partitions its passes by it.
  final Int32List roadKey;

  /// Pieces of road r are `roadFirstPiece[r] .. roadFirstPiece[r + 1] - 1`,
  /// in arc order.
  final Int32List roadFirstPiece;

  final List<RoadNode> nodes;

  /// A PIECE is the stretch of one road between two consecutive nodes on
  /// it: usually the whole road (the layout split it at its junctions),
  /// two or more where a dead end joins it part way along. Arc range
  /// [pieceS0]..[pieceS1] from the road's first control; [pieceFrom] is the
  /// node at the first, [pieceTo] at the second; the edge running each way
  /// along it, or -1 where traffic may not.
  final Int32List pieceRoad;
  final Float64List pieceS0, pieceS1;
  final Int32List pieceFrom, pieceTo, pieceFwdEdge, pieceBwdEdge;

  /// Directed edges: from, to, the piece they run along and which way,
  /// metres, and seconds — driving time plus the delay at the node they
  /// arrive at.
  final Int32List edgeFrom, edgeTo, edgePiece;
  final Uint8List edgeForward;
  final Float64List edgeLength, edgeTime;

  /// The leg (an index into [RoadNode.legs] of the node at [edgeTo]) each
  /// edge arrives by: what the arrival delay is read for.
  final Int32List edgeLeg;

  /// Out-edges of node n: `outEdges[outStart[n] .. outStart[n + 1] - 1]`.
  final Int32List outStart, outEdges;

  /// Every lot — manual first, as [CityLayout.parcels] lists them — with
  /// the piece it is entered from (-1: none within reach), the arc position
  /// on that piece's road, and its access mask ([forwardBit] /
  /// [backwardBit]); and its centroid. The piece, arc and mask are ALWAYS
  /// the lot's join slot 0 ([joinPiece], [joinS], [joinDirs] at
  /// `lotJoinStart[i]`), or -1/0/0 when it has none.
  final List<String> lotIds;
  final Map<String, int> _lotNo;
  final Int32List lotPiece;
  final Float64List lotS;
  final Uint8List lotDirs;
  final Float64List lotE, lotN;

  /// JOIN SLOTS (docs/plans/site-access.md §2.2, §3.2): where each lot can
  /// meet its road. Lot i owns slots `lotJoinStart[i] .. lotJoinStart[i +
  /// 1] - 1`, slot 0 first, then slot 1 (a second cut at the far end of a
  /// wide span) when offered; `lotJoinStart` has [lotCount] + 1 entries. A
  /// corner lot's side-street slot is not packed: ask [sideStreetJoinOf].
  ///
  /// Per slot: the piece; the arc on the piece's road from its first control,
  /// quantised to 0.25 m ([joinS]); the access mask, which is
  /// [joinDirsFor] of the road and [joinRight] (one traffic-direction rule
  /// for every lot: a one-way road's direction, a lot's own side only on a
  /// road of two lanes or more each way); 1 when the lot lies right of the road
  /// polyline (first to last) at [joinS]; the `kJoin*` flags
  /// (site_access_constants.dart); the largest kerb-cut half width legal
  /// there (0 for a legacy slot); the kerb point (the centreline at [joinS]
  /// plus the inward normal times the half width) and the unit road normal
  /// into the lot.
  final Int32List lotJoinStart;
  final Int32List joinPiece;
  final Float64List joinS;
  final Uint8List joinDirs;
  final Uint8List joinRight;
  final Uint16List joinFlags;
  final Float32List joinRoomM;
  final Float64List joinKerbE, joinKerbN;
  final Float64List joinNormE, joinNormN;

  /// Slot k's access corridor crosses the AUTO lots (graph lot indices,
  /// ascending) `joinCrossLot[joinCrossStart[k] .. joinCrossStart[k + 1] -
  /// 1]` (§3.7a); `joinCrossStart` has [joinCount] + 1 entries.
  final Int32List joinCrossStart;
  final Int32List joinCrossLot;

  /// Where on each piece a kerb cut may go (§3.2). Reads no override, so
  /// [withOverrides] shares it.
  final KerbWindows kerbWindows;

  /// The lots the slots were placed among, by graph lot index, and the
  /// pavement width they were placed with: what [attachFootprintJoins] needs
  /// to place a footprint's slots by the same rule.
  final List<Parcel> _parcels;
  final double _sidewalkM;

  int get joinCount => joinPiece.length;

  /// Slot 2 of graph lot [lot] (§3.2): a cut on a corner lot's side street,
  /// offered beside its slot 0 on its own road. Null when the lot is no
  /// corner lot, has no slot 0 on its own road, or no cut fits on the side
  /// street. Placed on the first ask and kept (by every graph sharing these
  /// slots: [withOverrides], [refreshedFor]); the answer never depends on
  /// when it is asked.
  JoinSlot? sideStreetJoinOf(int lot) {
    final cache = _sideStreetJoins;
    if (cache.containsKey(lot)) return cache[lot];
    JoinSlot? slot;
    final k = lotJoinStart[lot];
    if (k < lotJoinStart[lot + 1]) {
      final p = _parcels[lot];
      slot = _placer.sideStreetSlot(
        p.polygon,
        roadId: p.roadId,
        sideStreet: p.sideStreet,
        slot0Piece: joinPiece[k],
        slot0Flags: joinFlags[k],
        ownLot: lot,
      );
    }
    cache[lot] = slot;
    return slot;
  }

  /// The side-street slots asked for so far, by graph lot index.
  final Map<int, JoinSlot?> _sideStreetJoins;

  /// The join handle (docs/plans/site-access.md §2.3) of slot [slot] of graph
  /// lot [lot]: the packed join index for slot 0 or 1
  /// (`lotJoinStart[lot] + slot`), `kJoinRefSideStreetBase − lot` for the
  /// side-street slot 2, or `kJoinRefNone` (−1) when the lot has no such
  /// slot. Slot 2 is placed on the first ask ([sideStreetJoinOf]). Sync and
  /// tests only; never per sub-step.
  ///
  /// Every copy sharing this graph's structure ([sharesStructureWith])
  /// answers the same.
  int joinRefOf(int lot, int slot) {
    if (lot < 0 || lot >= lotCount) return kJoinRefNone;
    if (slot == kJoinSlotSideStreet) {
      return sideStreetJoinOf(lot) == null
          ? kJoinRefNone
          : kJoinRefSideStreetBase - lot;
    }
    if (slot < 0 || slot > 1) return kJoinRefNone;
    final k = lotJoinStart[lot] + slot;
    return k < lotJoinStart[lot + 1] ? k : kJoinRefNone;
  }

  /// The join slot a handle from [joinRefOf] names, or null for
  /// `kJoinRefNone` or a handle this graph does not hold. Sync and tests
  /// only: it allocates.
  JoinSlot? joinOfRef(int ref) {
    if (ref >= 0) {
      if (ref >= joinCount) return null;
      return JoinSlot(
        piece: joinPiece[ref],
        s: joinS[ref],
        dirs: joinDirs[ref],
        right: joinRight[ref] == 1,
        flags: joinFlags[ref],
        roomM: joinRoomM[ref],
        kerbE: joinKerbE[ref],
        kerbN: joinKerbN[ref],
        normE: joinNormE[ref],
        normN: joinNormN[ref],
        crossLots: List.unmodifiable(
            joinCrossLot.sublist(joinCrossStart[ref], joinCrossStart[ref + 1])),
      );
    }
    if (ref == kJoinRefNone) return null;
    final lot = kJoinRefSideStreetBase - ref;
    if (lot < 0 || lot >= lotCount) return null;
    return sideStreetJoinOf(lot);
  }

  /// The landing site's place on the network — where the colony meets the
  /// rest of the world, and so where goods it does not make arrive from:
  /// the nearest point of any road to the colony origin. -1 for no roads.
  final int rootPiece;
  final double rootS;
  final int rootDirs;

  /// The player's junction overrides the plans were made with (the ones
  /// that say something), and [overridesSignatureOf] them.
  final List<JunctionOverride> overrides;
  final String overridesSignature;

  int get roadCount => roads.length;
  int get nodeCount => nodes.length;
  int get pieceCount => pieceRoad.length;
  int get edgeCount => edgeFrom.length;
  int get lotCount => lotIds.length;

  /// Graph road number of [roadId], or null for a road not in the graph.
  int? roadNoOf(String roadId) => _roadNo[roadId];

  /// Graph lot number of [lotId], or null for a lot not in the graph.
  int? lotNoOf(String lotId) => _lotNo[lotId];

  /// Where [lotId] is entered from, or null when no road reaches it.
  LotAccess? accessOf(String lotId) {
    final i = _lotNo[lotId];
    if (i == null) return null;
    final p = lotPiece[i];
    if (p < 0) return null;
    final dirs = lotDirs[i];
    return LotAccess(roads[pieceRoad[p]].id, lotS[i],
        forward: dirs & forwardBit != 0, backward: dirs & backwardBit != 0);
  }

  /// The piece of road [road] (graph number) that arc [sM] falls on.
  int pieceAt(int road, double sM) {
    var lo = roadFirstPiece[road], hi = roadFirstPiece[road + 1] - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (pieceS0[mid] <= sM) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  double pieceLength(int piece) => pieceS1[piece] - pieceS0[piece];

  /// The point [sM] along road [road] (graph number).
  Vec2 pointAt(int road, double sM) => _pointOn(roadRecs[road], sM);

  /// The centreline of road [road] from arc [fromM] to [toM] — reversed
  /// when [toM] is the smaller — as points, both ends included.
  List<Vec2> polylineOf(int road, double fromM, double toM) {
    final rec = roadRecs[road];
    final lo = math.min(fromM, toM), hi = math.max(fromM, toM);
    final pts = <Vec2>[_pointOn(rec, lo)];
    for (var i = 0; i < rec.sampleCount; i++) {
      final s = rec.cum[i];
      if (s > lo + 1e-6 && s < hi - 1e-6) pts.add(rec.sampleAt(i));
    }
    pts.add(_pointOn(rec, hi));
    return fromM <= toM ? pts : pts.reversed.toList();
  }

  /// The node nearest [p] within [withinM], or null — what a click on a
  /// junction in the Junctions view resolves to.
  RoadNode? nodeNear(Vec2 p, {double withinM = 12}) {
    RoadNode? best;
    var bestD = withinM;
    for (final n in nodes) {
      final d = n.at.distanceTo(p);
      if (d <= bestD) {
        bestD = d;
        best = n;
      }
    }
    return best;
  }

  /// Whether [other] is this graph with nothing changed but junction plans
  /// or road names ([withOverrides], [refreshedFor]): the same nodes,
  /// pieces, edges and lots, numbered alike, so whatever is indexed by one
  /// is good for the other.
  bool sharesStructureWith(RoadGraph other) =>
      identical(pieceRoad, other.pieceRoad);

  /// The piece of road [road] (graph number) nearest [p]: a walk of the
  /// road's samples.
  int pieceNear(int road, Vec2 p) {
    final rec = roadRecs[road];
    var best = double.infinity;
    var bestS = 0.0;
    for (var seg = 1; seg < rec.sampleCount; seg++) {
      final (u, d) = _project(rec, seg, p.e, p.n);
      if (d < best) {
        best = d;
        bestS = rec.arcAt(seg, u);
      }
    }
    return pieceAt(road, bestS);
  }

  /// Where a building with footprint [polygon] that is not one of the
  /// layout's lots — one the colony's grid placed — is entered from, by the
  /// hand-drawn lot's rule: the nearest road within [manualReachM] of any
  /// part of it. Null when no road is that near.
  ///
  /// Slot 0 of [attachFootprintJoins]: the same rule a hand-drawn lot's
  /// access follows.
  PieceAccess? attachFootprint(List<Vec2> polygon, {Vec2? centroid}) {
    final slots = attachFootprintJoins(polygon, centroid: centroid);
    if (slots.isEmpty) return null;
    final s0 = slots.first;
    return PieceAccess(s0.piece, s0.s, s0.dirs);
  }

  /// The join slots (§2.2, §3.2) of a building with footprint [polygon] that
  /// is not one of the layout's lots — a grid cell: placed as a hand-drawn
  /// lot without a frontage (its effective frontage), slot 0 first. Empty
  /// when no road is within [manualReachM] of it.
  List<JoinSlot> attachFootprintJoins(List<Vec2> polygon, {Vec2? centroid}) {
    if (polygon.isEmpty) return const [];
    var c = centroid;
    if (c == null) {
      var e = 0.0, n = 0.0;
      for (final v in polygon) {
        e += v.e;
        n += v.n;
      }
      c = Vec2(e / polygon.length, n / polygon.length);
    }
    final hit = _nearestRoadTo(index, slotToRoad, roadRecs, roads, polygon, c);
    if (hit == null) return const [];
    final rec = roadRecs[hit.road];
    return _placer.slotsFor(polygon,
        legacy: (
          road: hit.road,
          s: rec.arcAt(hit.seg, hit.u),
          right: _rightOf(rec, hit.seg, hit.u, hit.probe),
        ));
  }

  /// The slot placer over this graph, for footprints placed after the build.
  /// Its lot look-up is an index of [_parcels] made on first use.
  late final SiteJoinPlacer _placer = () {
    BoxIndex<int>? lots;
    return SiteJoinPlacer(
      index: index,
      slotToRoad: slotToRoad,
      roads: roads,
      recs: roadRecs,
      roadFirstPiece: roadFirstPiece,
      pieceS0: pieceS0,
      pieceS1: pieceS1,
      pieceFrom: pieceFrom,
      pieceTo: pieceTo,
      nodes: nodes,
      windows: kerbWindows,
      parcels: _parcels,
      lotsNear: (box) {
        if (lots == null) {
          final built = BoxIndex<int>();
          for (var i = 0; i < _parcels.length; i++) {
            built.add(i, Box2.of(_parcels[i].polygon));
          }
          lots = built;
        }
        return lots!.nearIndices(box);
      },
      roadNoOf: roadNoOf,
      sidewalkM: _sidewalkM,
    );
  }();

  /// This graph brought up to date with [layout]'s roads and the player's
  /// [overrides] without a rebuild, where none is needed:
  ///
  /// - itself, when nothing it was built from has changed;
  /// - a copy sharing every structural array ([sharesStructureWith]) when
  ///   the only changes are ones routing never reads — a road's name — or
  ///   the overrides, whose junctions it re-plans ([withOverrides]);
  /// - null when a road was laid, removed, split, re-routed, reversed,
  ///   re-classed, re-dressed or raised: only [RoadGraph.of] will do.
  ///
  /// One walk of the roads comparing records. A light toggled in the
  /// Junctions view or a road renamed is a single click, and a rebuild of
  /// a twenty-mile city for it would be seconds — and would throw away the
  /// traffic pass in flight. The LOTS are the caller's to watch
  /// ([CityLayout.version]); this does not look at them.
  RoadGraph? refreshedFor(CityLayout layout,
      {Iterable<JunctionOverride> overrides = const []}) {
    var r = 0;
    List<RoadSpline>? newRoads;
    List<IndexedRoad>? newRecs;
    for (final (slot, rec) in layout.roadIndex.indexed) {
      // The build's choice of roads, in the build's order.
      if (rec.road.roadClass.isRail) continue;
      if (rec.sampleCount < 2 || rec.lengthM <= 1e-6) continue;
      if (r >= roads.length ||
          slot >= slotToRoad.length ||
          slotToRoad[slot] != r) {
        return null;
      }
      final old = roadRecs[r];
      if (!identical(rec, old)) {
        // An attribute swap keeps the samples; anything it swapped must
        // route as it did.
        if (!identical(rec.e, old.e) || !identical(rec.n, old.n)) return null;
        if (!identical(rec.road, old.road) &&
            !_routesAlike(rec.road, old.road)) {
          return null;
        }
        (newRoads ??= List.of(roads))[r] = rec.road;
        (newRecs ??= List.of(roadRecs))[r] = rec;
      }
      r++;
    }
    if (r != roads.length) return null;
    var g = this;
    if (newRoads != null) {
      g = _copy(
          roads: List.unmodifiable(newRoads),
          roadRecs: List.unmodifiable(newRecs!));
    }
    return g.withOverrides(overrides);
  }

  /// This graph under the player's junction [overrides] as they now stand:
  /// itself when they say what they said; else a copy that shares every
  /// structural array and differs only in the plans of the junctions within
  /// [JunctionOverride.matchM] of an override that came, went or changed,
  /// and in the times of the edges arriving at those — each worked out the
  /// way the build works it out, so the copy is exactly what
  /// [RoadGraph.of] would give.
  RoadGraph withOverrides(Iterable<JunctionOverride> overrides) {
    final list = [
      for (final o in overrides)
        if (!o.isEmpty) o
    ];
    final sig = overridesSignatureOf(list);
    if (sig == overridesSignature) return this;
    final before = {for (final o in this.overrides) _overrideSig(o)};
    final after = {for (final o in list) _overrideSig(o)};
    final changed = <Vec2>[
      for (final o in this.overrides)
        if (!after.contains(_overrideSig(o))) o.at,
      for (final o in list)
        if (!before.contains(_overrideSig(o))) o.at,
    ];
    final nN = nodes.length;
    final replan = Uint8List(nN);
    for (var n = 0; n < nN; n++) {
      final at = nodes[n].at;
      for (final p in changed) {
        if (p.distanceTo(at) <= JunctionOverride.matchM) {
          replan[n] = 1;
          break;
        }
      }
    }
    final newNodes = List<RoadNode>.of(nodes);
    for (var n = 0; n < nN; n++) {
      if (replan[n] == 0) continue;
      final node = nodes[n];
      newNodes[n] = node._withPlan(_planOf(
        node.legs,
        lifted: node._lifted,
        roundaboutPreferred: node._roundaboutPreferred,
        override: _nearestOverride(list, node.at),
      ));
    }
    final time = Float64List.fromList(edgeTime);
    for (var e = 0; e < time.length; e++) {
      final n = edgeTo[e];
      if (replan[n] == 0) continue;
      final drive = edgeLength[e] / roadSpeedMps[pieceRoad[edgePiece[e]]];
      time[e] = drive + newNodes[n].delayFor(edgeLeg[e]);
    }
    return _copy(
      nodes: List.unmodifiable(newNodes),
      edgeTime: time,
      overrides: List.unmodifiable(list),
      overridesSignature: sig,
    );
  }

  RoadGraph _copy({
    List<RoadSpline>? roads,
    List<IndexedRoad>? roadRecs,
    List<RoadNode>? nodes,
    Float64List? edgeTime,
    List<JunctionOverride>? overrides,
    String? overridesSignature,
  }) =>
      RoadGraph._(
        index: index,
        roads: roads ?? this.roads,
        roadRecs: roadRecs ?? this.roadRecs,
        roadNo: _roadNo,
        slotToRoad: slotToRoad,
        roadSpeedMps: roadSpeedMps,
        roadEmission: roadEmission,
        roadBonus: roadBonus,
        roadLanes: roadLanes,
        roadPaved: roadPaved,
        roadKey: roadKey,
        roadFirstPiece: roadFirstPiece,
        nodes: nodes ?? this.nodes,
        pieceRoad: pieceRoad,
        pieceS0: pieceS0,
        pieceS1: pieceS1,
        pieceFrom: pieceFrom,
        pieceTo: pieceTo,
        pieceFwdEdge: pieceFwdEdge,
        pieceBwdEdge: pieceBwdEdge,
        edgeFrom: edgeFrom,
        edgeTo: edgeTo,
        edgePiece: edgePiece,
        edgeForward: edgeForward,
        edgeLength: edgeLength,
        edgeTime: edgeTime ?? this.edgeTime,
        edgeLeg: edgeLeg,
        outStart: outStart,
        outEdges: outEdges,
        lotIds: lotIds,
        lotNo: _lotNo,
        lotPiece: lotPiece,
        lotS: lotS,
        lotDirs: lotDirs,
        lotE: lotE,
        lotN: lotN,
        lotJoinStart: lotJoinStart,
        joinPiece: joinPiece,
        joinS: joinS,
        joinDirs: joinDirs,
        joinRight: joinRight,
        joinFlags: joinFlags,
        joinRoomM: joinRoomM,
        joinKerbE: joinKerbE,
        joinKerbN: joinKerbN,
        joinNormE: joinNormE,
        joinNormN: joinNormN,
        joinCrossStart: joinCrossStart,
        joinCrossLot: joinCrossLot,
        kerbWindows: kerbWindows,
        parcels: _parcels,
        sidewalkM: _sidewalkM,
        sideStreetJoins: _sideStreetJoins,
        rootPiece: rootPiece,
        rootS: rootS,
        rootDirs: rootDirs,
        overrides: overrides ?? this.overrides,
        overridesSignature: overridesSignature ?? this.overridesSignature,
        stamp: _stamp,
      );

  /// The id a road was LAID under, before any junction split it: the id up
  /// to its first `x` (`r12x0x3` -> `r12`) — the layout's naming rule, so
  /// every piece of one drawn road shares it.
  static String baseRoadId(String id) {
    final i = id.indexOf('x');
    return i < 0 ? id : id.substring(0, i);
  }

  /// A hash of [s] that is the same on every run and every platform: a
  /// polynomial over its code units, kept to 30 bits so a web build's
  /// doubles hold every step exactly. Never [String.hashCode], which Dart
  /// does not promise to keep.
  static int stableKey(String s) {
    var h = 0;
    for (var i = 0; i < s.length; i++) {
      h = (h * 31 + s.codeUnitAt(i)) & 0x3fffffff;
    }
    return h;
  }

  /// One string for what a collection of overrides SAYS, whatever their
  /// order: two collections with one signature plan every junction alike.
  static String overridesSignatureOf(Iterable<JunctionOverride> overrides) {
    final parts = [
      for (final o in overrides)
        if (!o.isEmpty) _overrideSig(o)
    ]..sort();
    return parts.join(';');
  }

  static String _overrideSig(JunctionOverride o) =>
      '${o.at.e},${o.at.n},${o.lights},${o.stopHeadings?.join(' ')}';

  /// The override the build gives a node at [at]: the nearest within
  /// [JunctionOverride.matchM] — of two as near, the later.
  static JunctionOverride? _nearestOverride(
      List<JunctionOverride> list, Vec2 at) {
    JunctionOverride? best;
    var bestD = JunctionOverride.matchM;
    for (final o in list) {
      final d = o.at.distanceTo(at);
      if (d <= bestD) {
        bestD = d;
        best = o;
      }
    }
    return best;
  }

  /// The plan of a node of [legs]: `junctionPlanForNetwork` over the legs
  /// the tiles draw a junction of ([RoadClass.joinsJunctions]), its stop
  /// legs numbered back into [legs].
  ///
  /// Every leg is still a way in and out for routing; only the plan skips
  /// some. An alley meeting a street is a curb cut, a dirt track meets it
  /// with nothing at all — the tiles give neither a leg — and read as legs
  /// they made an all-way stop the town never drew: six seconds lost on
  /// both approaches of the street at every alley the generator runs down
  /// a block.
  static JunctionPlan _planOf(
    List<JunctionLeg> legs, {
    required bool lifted,
    required bool roundaboutPreferred,
    JunctionOverride? override,
  }) {
    final drawn = [
      for (var k = 0; k < legs.length; k++)
        if (legs[k].roadClass.joinsJunctions) k
    ];
    final all = drawn.length == legs.length;
    final plan = junctionPlanForNetwork(
      all ? legs : [for (final k in drawn) legs[k]],
      lifted: lifted,
      roundaboutPreferred: roundaboutPreferred,
      override: override,
    );
    if (all || plan.stopLegs.isEmpty) return plan;
    return JunctionPlan(
        plan.control, {for (final i in plan.stopLegs) drawn[i]});
  }

  /// Whether two records of one road route alike: the same in everything
  /// the build reads of a road — all of it but the name. The join slots read
  /// its bridges and its tapers ([KerbWindows]), so those count too.
  static bool _routesAlike(RoadSpline a, RoadSpline b) =>
      a.id == b.id &&
      a.roadClass == b.roadClass &&
      a.reversed == b.reversed &&
      a.decoration == b.decoration &&
      a.soundWalls == b.soundWalls &&
      a.collector == b.collector &&
      a.deck == b.deck &&
      a.startHalfWidthM == b.startHalfWidthM &&
      a.endHalfWidthM == b.endHalfWidthM &&
      _sameRanges(a.bridges, b.bridges);

  static bool _sameRanges(
      List<(double, double)> a, List<(double, double)> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].$1 != b[i].$1 || a[i].$2 != b[i].$2) return false;
    }
    return true;
  }

  /// A hand-drawn lot's road: the nearest segment of any graph road to the
  /// footprint [polygon] — reaching to its nearest point, not its centre
  /// [c]: a quarry's site is kilometres across and a road along its edge is
  /// still its road — within [manualReachM] of that road's edge.
  static ({int road, int seg, double u, Vec2 probe})? _nearestRoadTo(
    SegmentIndex idx,
    Int32List slotToRoad,
    List<IndexedRoad> recs,
    List<RoadSpline> roads,
    List<Vec2> polygon,
    Vec2 c,
  ) {
    final probes = <Vec2>[c, ...polygon];
    for (var k = 0; k < polygon.length; k++) {
      final a = polygon[k], b = polygon[(k + 1) % polygon.length];
      probes.add((a + b) * 0.5);
    }
    final near =
        idx.segmentsNear(Box2.of(polygon), manualReachM + maxHalfWidth);
    var best = double.infinity;
    var bestR = -1, bestSeg = 0;
    var bestU = 0.0;
    Vec2? bestProbe;
    for (final entry in near.entries) {
      if (entry.key >= slotToRoad.length) continue;
      final r = slotToRoad[entry.key];
      if (r < 0) continue;
      final rec = recs[r];
      // The index is the layout's own, and live: never project onto
      // samples that are not the graph's.
      if (!identical(idx.bySlot(entry.key)?.e, rec.e)) continue;
      final limit = manualReachM + roads[r].halfWidth;
      for (final seg in entry.value) {
        if (seg == 0) continue;
        for (final v in probes) {
          final (u, d) = _project(rec, seg, v.e, v.n);
          if (d <= limit && d < best) {
            best = d;
            bestR = r;
            bestSeg = seg;
            bestU = u;
            bestProbe = v;
          }
        }
      }
    }
    if (bestR < 0) return null;
    return (road: bestR, seg: bestSeg, u: bestU, probe: bestProbe!);
  }

  /// Build the graph of [layout]'s roads, with the player's junction
  /// [overrides] applied to the plans of the junctions they sit on.
  factory RoadGraph.of(
    CityLayout layout, {
    Iterable<JunctionOverride> overrides = const [],
  }) {
    final idx = layout.roadIndex;

    // ---- Roads: every road but rail, in index slot order (insertion
    // order), so two builds of one layout number everything alike.
    final roads = <RoadSpline>[];
    final recs = <IndexedRoad>[];
    final slots = <int>[];
    var maxSlot = -1;
    for (final (slot, rec) in idx.indexed) {
      if (slot > maxSlot) maxSlot = slot;
      if (rec.road.roadClass.isRail) continue;
      if (rec.sampleCount < 2 || rec.lengthM <= 1e-6) continue;
      roads.add(rec.road);
      recs.add(rec);
      slots.add(slot);
    }
    final nR = roads.length;
    final slotToRoad = Int32List(maxSlot + 1)..fillRange(0, maxSlot + 1, -1);
    final roadNo = <String, int>{};
    for (var r = 0; r < nR; r++) {
      slotToRoad[slots[r]] = r;
      roadNo[roads[r].id] = r;
    }
    // Each road's menu entry, looked up once per KIND of road (the look-up
    // is a scan of the menu, and a sprawl has tens of thousands of roads of
    // a dozen kinds), and what the traffic model reads of it kept per road,
    // so no pass looks anything up.
    final speed = Float64List(nR);
    final emission = Float64List(nR), bonus = Float64List(nR);
    final lanes = Int32List(nR);
    final paved = Uint8List(nR);
    final keys = Int32List(nR);
    final typeOf = <int, RoadType>{};
    final nDeco = RoadDecoration.values.length;
    for (var r = 0; r < nR; r++) {
      final road = roads[r];
      final kind = (road.roadClass.index * nDeco + road.decoration.index) * 2 +
          (road.soundWalls ? 1 : 0);
      final t = typeOf[kind] ??= RoadType.of(road);
      speed[r] = math.max(1.0, t.speedKmh / 3.6);
      emission[r] = t.noiseEmission;
      bonus[r] = RoadNoise.frontageBonusOf(t, road.decoration);
      lanes[r] = road.lanes?.laneCount ?? (road.oneWay ? 1 : 2);
      paved[r] = road.roadClass.paved ? 1 : 0;
      keys[r] = stableKey(baseRoadId(road.id));
    }

    // ---- Ends: 2r is road r's first sample, 2r + 1 its last, each at its
    // level as the layout reads it ([CityLayout.levelOf]): none for a
    // draped end, else its deck's height and whether the deck stands clear
    // of the ground there. Which ends meet is then the layout's own rule
    // ([CityLayout.levelsSeparated]) — the one that cut these roads into
    // junctions and snapped their ends. (A rule of its own — decks within
    // two metres, a deck end on the ground only within two metres of it —
    // left decks four metres apart, and a road sunk into a cutting, cut
    // into junctions the graph then refused to join: islands no car could
    // reach, on roads the connectivity walk called connected.)
    final nE = 2 * nR;
    final endE = Float64List(nE), endN = Float64List(nE);
    final endLevel = List<RoadLevel?>.filled(nE, null);
    for (var r = 0; r < nR; r++) {
      final rec = recs[r];
      final last = rec.sampleCount - 1;
      endE[2 * r] = rec.e[0];
      endN[2 * r] = rec.n[0];
      endE[2 * r + 1] = rec.e[last];
      endN[2 * r + 1] = rec.n[last];
      final deck = roads[r].deck;
      if (deck != null) {
        endLevel[2 * r] = CityLayout.levelOf(deck, 0, rec.lengthM);
        endLevel[2 * r + 1] =
            CityLayout.levelOf(deck, rec.lengthM, rec.lengthM);
      }
    }

    // ---- Cluster the ends, the renderer's way: each unclaimed end anchors
    // a node and takes every later unclaimed end within the tolerance of it
    // — and at its level.
    const tol = nodeMatchPlanM;
    const cell = tol * 1.0625;
    int cellKey(int x, int y) =>
        (x + 33554432) * 67108864 + (y + 33554432);
    final cx = Int32List(nE), cy = Int32List(nE);
    final buckets = <int, List<int>>{};
    for (var i = 0; i < nE; i++) {
      cx[i] = (endE[i] / cell).floor();
      cy[i] = (endN[i] / cell).floor();
      (buckets[cellKey(cx[i], cy[i])] ??= <int>[]).add(i);
    }
    final cluster = Int32List(nE)..fillRange(0, nE, -1);
    var nClusters = 0;
    for (var i = 0; i < nE; i++) {
      if (cluster[i] >= 0) continue;
      final c = nClusters++;
      cluster[i] = c;
      for (var dx = -1; dx <= 1; dx++) {
        for (var dy = -1; dy <= 1; dy++) {
          final bucket = buckets[cellKey(cx[i] + dx, cy[i] + dy)];
          if (bucket == null) continue;
          for (final j in bucket) {
            if (j <= i || cluster[j] >= 0) continue;
            final ex = endE[j] - endE[i], en = endN[j] - endN[i];
            if (math.sqrt(ex * ex + en * en) > tol) continue;
            if (CityLayout.levelsSeparated(endLevel[i], endLevel[j])) {
              continue;
            }
            cluster[j] = c;
          }
        }
      }
    }
    final parent = Int32List(nClusters);
    for (var c = 0; c < nClusters; c++) {
      parent[c] = c;
    }
    int find(int c) {
      while (parent[c] != c) {
        parent[c] = parent[parent[c]];
        c = parent[c];
      }
      return c;
    }

    void union(int a, int b) {
      final ra = find(a), rb = find(b);
      if (ra == rb) return;
      // The lower cluster wins, so node numbering follows end order.
      if (ra < rb) {
        parent[rb] = ra;
      } else {
        parent[ra] = rb;
      }
    }

    // ---- Dead ends lying against another road join it. A road the layout
    // did not cut where this one meets it — a ramp landing on a
    // carriageway's edge a lane out from its centre, a stub whose snap
    // fell a hair short — would otherwise be an island that the
    // connectivity walk calls connected. Joined at the other road's end if
    // that is where it lies, else part way along, as a node on that road.
    final size = Int32List(nClusters);
    for (var i = 0; i < nE; i++) {
      size[cluster[i]]++;
    }
    final virtuals = <int, List<(double, int)>>{};
    for (var i = 0; i < nE; i++) {
      if (size[cluster[i]] != 1) continue;
      final r = i >> 1;
      final own = roads[r];
      final pe = endE[i], pn = endN[i];
      final level = endLevel[i];
      final reach = own.halfWidth + maxHalfWidth + attachSlackM;
      var bestD = double.infinity;
      var bestR = -1;
      var bestS = 0.0;
      idx.visit(Box2(pe - reach, pn - reach, pe + reach, pn + reach), 0,
          (slot, rec, seg) {
        if (seg == 0 || slot >= slotToRoad.length) return;
        final ro = slotToRoad[slot];
        if (ro < 0 || ro == r || !identical(rec, recs[ro])) return;
        final other = roads[ro];
        final (u, d) = _project(rec, seg, pe, pn);
        if (d > own.halfWidth + other.halfWidth + attachSlackM || d >= bestD) {
          return;
        }
        final s = rec.arcAt(seg, u);
        final len = rec.lengthM;
        final nearEnd = s <= tol || s >= len - tol;
        // Nothing but a ramp meets a limited-access road part way along.
        if (!nearEnd &&
            other.roadClass.limitedAccess &&
            own.roadClass != RoadClass.ramp) {
          return;
        }
        // At its level there, by the rule the ends were clustered by: a
        // road the snap would have landed this end on is one it joins.
        if (CityLayout.levelsSeparated(
            level, CityLayout.levelOf(other.deck, s, len))) {
          return;
        }
        bestD = d;
        bestR = ro;
        bestS = s;
      });
      if (bestR < 0) continue;
      final len = recs[bestR].lengthM;
      if (bestS <= tol) {
        union(cluster[i], cluster[2 * bestR]);
      } else if (bestS >= len - tol) {
        union(cluster[i], cluster[2 * bestR + 1]);
      } else {
        (virtuals[bestR] ??= []).add((bestS, cluster[i]));
      }
    }
    // Two dead ends joining one road at one place are one junction.
    for (final list in virtuals.values) {
      list.sort((a, b) => a.$1.compareTo(b.$1));
      for (var k = 1; k < list.length; k++) {
        if (list[k].$1 - list[k - 1].$1 <= tol) {
          union(list[k].$2, list[k - 1].$2);
          list[k] = (list[k - 1].$1, list[k].$2);
        }
      }
    }

    // ---- Nodes: numbered in the order their first end appears.
    final nodeOfCluster = Int32List(nClusters)..fillRange(0, nClusters, -1);
    var nN = 0;
    final endNode = Int32List(nE);
    for (var i = 0; i < nE; i++) {
      final root = find(cluster[i]);
      if (nodeOfCluster[root] < 0) nodeOfCluster[root] = nN++;
      endNode[i] = nodeOfCluster[root];
    }
    final sumE = Float64List(nN), sumN = Float64List(nN);
    final count = Int32List(nN);
    final nodeGrade = Uint8List(nN)..fillRange(0, nN, 1);
    final nodeH = Float64List(nN)..fillRange(0, nN, double.nan);
    for (var i = 0; i < nE; i++) {
      final n = endNode[i];
      sumE[n] += endE[i];
      sumN[n] += endN[i];
      count[n]++;
      final level = endLevel[i];
      if (level == null) continue;
      if (level.offGround) nodeGrade[n] = 0;
      if (nodeH[n].isNaN) nodeH[n] = level.heightM;
    }

    // ---- Stations along each road — its two ends and any dead end joined
    // part way — then the legs they give their nodes and the pieces
    // between them.
    final legDrafts = List.generate(nN, (_) => <_LegDraft>[]);
    final pieceRoad = <int>[];
    final pieceS0 = <double>[], pieceS1 = <double>[];
    final pieceFrom = <int>[], pieceTo = <int>[];
    final pieceLegA = <int>[], pieceLegB = <int>[];
    final roadFirstPiece = Int32List(nR + 1);
    for (var r = 0; r < nR; r++) {
      roadFirstPiece[r] = pieceRoad.length;
      final road = roads[r];
      final rec = recs[r];
      final len = rec.lengthM;
      final stations = <(double, int)>[(0.0, endNode[2 * r])];
      final v = virtuals[r];
      if (v != null) {
        double? lastS;
        for (final (s, c) in v) {
          if (lastS != null && (s - lastS).abs() < 1e-9) continue;
          lastS = s;
          final n = nodeOfCluster[find(c)];
          stations.add((s, n));
          final q = _pointOn(rec, s);
          sumE[n] += q.e;
          sumN[n] += q.n;
          count[n]++;
        }
      }
      stations.add((len, endNode[2 * r + 1]));
      final oneWay = road.oneWay;
      final rev = road.reversed;
      final legFwd = List<int>.filled(stations.length, -1);
      final legBack = List<int>.filled(stations.length, -1);
      for (var k = 0; k < stations.length; k++) {
        final (s, n) = stations[k];
        final here = _pointOn(rec, s);
        if (k > 0) {
          final to = _pointOn(rec, math.max(stations[k - 1].$1, s - 10));
          legBack[k] = legDrafts[n].length;
          legDrafts[n].add(_LegDraft(
            road,
            // This is where the piece before ENDS: the road's first point
            // in travel order only on a one-way road running backwards.
            startsHere: oneWay && rev,
            heading: (to - here).heading,
          ));
        }
        if (k < stations.length - 1) {
          final to = _pointOn(rec, math.min(stations[k + 1].$1, s + 10));
          legFwd[k] = legDrafts[n].length;
          legDrafts[n].add(_LegDraft(
            road,
            startsHere: oneWay ? !rev : true,
            heading: (to - here).heading,
          ));
        }
      }
      for (var k = 0; k + 1 < stations.length; k++) {
        pieceRoad.add(r);
        pieceS0.add(stations[k].$1);
        pieceS1.add(stations[k + 1].$1);
        pieceFrom.add(stations[k].$2);
        pieceTo.add(stations[k + 1].$2);
        pieceLegA.add(legFwd[k]);
        pieceLegB.add(legBack[k + 1]);
      }
    }
    roadFirstPiece[nR] = pieceRoad.length;

    // ---- Plans: the warrant over each node's legs, with the player's
    // override where one sits on it.
    final overrideList = overrides.where((o) => !o.isEmpty).toList();
    final nodes = <RoadNode>[];
    for (var n = 0; n < nN; n++) {
      final at = Vec2(sumE[n] / count[n], sumN[n] / count[n]);
      final drafts = legDrafts[n];
      final legs = [
        for (final d in drafts)
          JunctionLeg(d.road.roadClass,
              startsHere: d.startsHere, heading: d.heading)
      ];
      // The tiles' rules, so a light the player sees is a light the traffic
      // waits at: read over the legs the tiles draw ([_planOf]), three
      // collector legs make a roundabout, and a junction the tool had a
      // hand in (a deck, a class only the tool lays) takes the leg-aware
      // warrant — see `junctionPlanForNetwork`.
      final drawn = [
        for (final d in drafts)
          if (d.road.roadClass.joinsJunctions) d
      ];
      final roundabout = drawn.where((d) => d.road.collector).length >= 3;
      final lifted = drawn.any((d) => d.road.deck != null);
      final plan = _planOf(
        legs,
        lifted: lifted,
        roundaboutPreferred: roundabout,
        override: _nearestOverride(overrideList, at),
      );
      nodes.add(RoadNode._(
        id: n,
        at: at,
        legs: List.unmodifiable(legs),
        legRoadIds: List.unmodifiable([for (final d in drafts) d.road.id]),
        plan: plan,
        atGrade: nodeGrade[n] == 1,
        heightM: nodeH[n].isNaN ? null : nodeH[n],
        roundaboutPreferred: roundabout,
        lifted: lifted,
      ));
    }

    // ---- Edges: both ways along a two-way piece; the travel direction
    // only along a one-way one. Each costs its driving time plus the delay
    // at the node it arrives at, along the leg it arrives by.
    final nP = pieceRoad.length;
    final pieceFwd = Int32List(nP)..fillRange(0, nP, -1);
    final pieceBwd = Int32List(nP)..fillRange(0, nP, -1);
    final eFrom = <int>[], eTo = <int>[], ePiece = <int>[];
    final eFwd = <int>[];
    final eLen = <double>[], eTime = <double>[];
    final eLeg = <int>[];
    for (var p = 0; p < nP; p++) {
      final r = pieceRoad[p];
      final road = roads[r];
      final len = math.max(0.1, pieceS1[p] - pieceS0[p]);
      final drive = len / speed[r];
      final fwdOk = !road.oneWay || !road.reversed;
      final bwdOk = !road.oneWay || road.reversed;
      if (fwdOk) {
        pieceFwd[p] = eFrom.length;
        eFrom.add(pieceFrom[p]);
        eTo.add(pieceTo[p]);
        ePiece.add(p);
        eFwd.add(1);
        eLen.add(len);
        eTime.add(drive + nodes[pieceTo[p]].delayFor(pieceLegB[p]));
        eLeg.add(pieceLegB[p]);
      }
      if (bwdOk) {
        pieceBwd[p] = eFrom.length;
        eFrom.add(pieceTo[p]);
        eTo.add(pieceFrom[p]);
        ePiece.add(p);
        eFwd.add(0);
        eLen.add(len);
        eTime.add(drive + nodes[pieceFrom[p]].delayFor(pieceLegA[p]));
        eLeg.add(pieceLegA[p]);
      }
    }
    final nEd = eFrom.length;
    final outStart = Int32List(nN + 1);
    for (var e = 0; e < nEd; e++) {
      outStart[eFrom[e] + 1]++;
    }
    for (var n = 0; n < nN; n++) {
      outStart[n + 1] += outStart[n];
    }
    final fill = Int32List.fromList(outStart.sublist(0, nN));
    final outEdges = Int32List(nEd);
    for (var e = 0; e < nEd; e++) {
      outEdges[fill[eFrom[e]]++] = e;
    }

    final pS0 = Float64List.fromList(pieceS0);
    final pS1 = Float64List.fromList(pieceS1);
    final pRoad = Int32List.fromList(pieceRoad);

    int pieceAtRoad(int r, double s) {
      var lo = roadFirstPiece[r], hi = roadFirstPiece[r + 1] - 1;
      while (lo < hi) {
        final mid = (lo + hi + 1) >> 1;
        if (pS0[mid] <= s) {
          lo = mid;
        } else {
          hi = mid - 1;
        }
      }
      return lo;
    }

    // ---- Kerb windows: where on each piece a cut may go (§3.2).
    final pFrom = Int32List.fromList(pieceFrom);
    final pTo = Int32List.fromList(pieceTo);
    final windows = KerbWindows.of(
      nodes: nodes,
      roads: roads,
      recs: recs,
      roadFirstPiece: roadFirstPiece,
      pieceS0: pS0,
      pieceS1: pS1,
      pieceFrom: pFrom,
      pieceTo: pTo,
    );

    // ---- Lots: each lot's join slots, slot 0 its access (§3.2). Today's
    // point — an auto lot on its own frontage road at its frontage midpoint,
    // a hand-drawn one on the nearest road within reach — is what a lot with
    // no legal cut keeps (a legacy slot), and a lot with no such point has no
    // slot at all.
    final parcels = layout.parcels;
    final nL = parcels.length;
    final lotIds = List<String>.filled(nL, '');
    final lotNo = <String, int>{};
    final lotPiece = Int32List(nL)..fillRange(0, nL, -1);
    final lotS = Float64List(nL);
    final lotDirs = Uint8List(nL);
    final lotE = Float64List(nL), lotN = Float64List(nL);
    final sidewalk = layout.settings.sidewalkM;
    for (var i = 0; i < nL; i++) {
      final p = parcels[i];
      lotIds[i] = p.id;
      lotNo[p.id] = i;
    }
    // Today's point of lot i, asked only of a lot that needs it.
    LegacyAccess? legacyOf(int i) {
      final p = parcels[i];
      final c = p.centroid;
      final rid = p.roadId;
      if (rid != null) {
        final r = roadNo[rid];
        if (r == null) return null;
        final rec = recs[r];
        final mid = p.frontageMidpoint ?? c;
        final hit = _nearestOnRoad(
            idx, slots[r], rec, mid, roads[r].halfWidth + sidewalk + 8);
        return (
          road: r,
          s: rec.arcAt(hit.seg, hit.u),
          right: hit.rightOfForward,
        );
      }
      // A hand-drawn lot: the nearest road within reach of any part of it.
      final hit = _nearestRoadTo(idx, slotToRoad, recs, roads, p.polygon, c);
      if (hit == null) return null;
      final rec = recs[hit.road];
      return (
        road: hit.road,
        s: rec.arcAt(hit.seg, hit.u),
        right: _rightOf(rec, hit.seg, hit.u, hit.probe),
      );
    }

    final placer = SiteJoinPlacer(
      index: idx,
      slotToRoad: slotToRoad,
      roads: roads,
      recs: recs,
      roadFirstPiece: roadFirstPiece,
      pieceS0: pS0,
      pieceS1: pS1,
      pieceFrom: pFrom,
      pieceTo: pTo,
      nodes: nodes,
      windows: windows,
      parcels: parcels,
      lotsNear: (box) => [
        for (final q in layout.parcelsNear(box))
          if (lotNo[q.id] case final int k) k,
      ],
      roadNoOf: (id) => roadNo[id],
      sidewalkM: sidewalk,
      legacyOfLot: legacyOf,
    );
    final lotJoinStart = Int32List(nL + 1);
    // Most lots have one slot, a corner lot two.
    final joins = JoinColumns(nL + (nL >> 1) + 16);
    for (var i = 0; i < nL; i++) {
      final p = parcels[i];
      final c = p.centroid;
      lotE[i] = c.e;
      lotN[i] = c.n;
      final k = lotJoinStart[i] = joins.count;
      final n = placer.addSlots(
        joins,
        p.polygon,
        frontage: p.frontage,
        roadId: p.roadId,
        sideStreet: p.sideStreet,
        ownLot: i,
      );
      if (n > 0) {
        lotPiece[i] = joins.piece[k];
        lotS[i] = joins.s[k];
        lotDirs[i] = joins.dirs[k];
      }
    }
    lotJoinStart[nL] = joins.count;
    final nJ = joins.count;

    // ---- The root: the nearest road point to the colony origin.
    var rootPiece = -1;
    var rootS = 0.0;
    var rootDirs = 0;
    if (nR > 0) {
      const origin = Vec2(0, 0);
      var radius = 64.0;
      var best = double.infinity;
      var bestR = -1, bestSeg = 0;
      var bestU = 0.0;
      while (true) {
        idx.visit(Box2.around(origin, radius), 0, (slot, rec, seg) {
          if (seg == 0 || slot >= slotToRoad.length) return;
          final r = slotToRoad[slot];
          if (r < 0 || !identical(rec, recs[r])) return;
          final (u, d) = _project(rec, seg, 0, 0);
          if (d < best) {
            best = d;
            bestR = r;
            bestSeg = seg;
            bestU = u;
          }
        });
        if ((bestR >= 0 && best <= radius) || radius >= 1e7) break;
        radius = math.min(1e7, radius * 2);
      }
      if (bestR >= 0) {
        final s = recs[bestR].arcAt(bestSeg, bestU);
        rootPiece = pieceAtRoad(bestR, s);
        rootS = s;
        final road = roads[bestR];
        rootDirs = road.oneWay
            ? (road.reversed ? backwardBit : forwardBit)
            : forwardBit | backwardBit;
      }
    }

    return RoadGraph._(
      index: idx,
      roads: List.unmodifiable(roads),
      roadRecs: List.unmodifiable(recs),
      roadNo: roadNo,
      slotToRoad: slotToRoad,
      roadSpeedMps: speed,
      roadEmission: emission,
      roadBonus: bonus,
      roadLanes: lanes,
      roadPaved: paved,
      roadKey: keys,
      roadFirstPiece: roadFirstPiece,
      nodes: List.unmodifiable(nodes),
      pieceRoad: pRoad,
      pieceS0: pS0,
      pieceS1: pS1,
      pieceFrom: pFrom,
      pieceTo: pTo,
      pieceFwdEdge: pieceFwd,
      pieceBwdEdge: pieceBwd,
      edgeFrom: Int32List.fromList(eFrom),
      edgeTo: Int32List.fromList(eTo),
      edgePiece: Int32List.fromList(ePiece),
      edgeForward: Uint8List.fromList(eFwd),
      edgeLength: Float64List.fromList(eLen),
      edgeTime: Float64List.fromList(eTime),
      edgeLeg: Int32List.fromList(eLeg),
      outStart: outStart,
      outEdges: outEdges,
      lotIds: List.unmodifiable(lotIds),
      lotNo: lotNo,
      lotPiece: lotPiece,
      lotS: lotS,
      lotDirs: lotDirs,
      lotE: lotE,
      lotN: lotN,
      lotJoinStart: lotJoinStart,
      joinPiece: Int32List.sublistView(joins.piece, 0, nJ),
      joinS: Float64List.sublistView(joins.s, 0, nJ),
      joinDirs: Uint8List.sublistView(joins.dirs, 0, nJ),
      joinRight: Uint8List.sublistView(joins.right, 0, nJ),
      joinFlags: Uint16List.sublistView(joins.flags, 0, nJ),
      joinRoomM: Float32List.sublistView(joins.roomM, 0, nJ),
      joinKerbE: Float64List.sublistView(joins.kerbE, 0, nJ),
      joinKerbN: Float64List.sublistView(joins.kerbN, 0, nJ),
      joinNormE: Float64List.sublistView(joins.normE, 0, nJ),
      joinNormN: Float64List.sublistView(joins.normN, 0, nJ),
      joinCrossStart: Int32List.sublistView(joins.crossStart, 0, nJ + 1),
      joinCrossLot: joins.crossLot.sublist(0, joins.crossCount),
      kerbWindows: windows,
      parcels: parcels,
      sidewalkM: sidewalk,
      rootPiece: rootPiece,
      rootS: rootS,
      rootDirs: rootDirs,
      overrides: List.unmodifiable(overrideList),
      overridesSignature: overridesSignatureOf(overrideList),
    );
  }

  /// Parameter along segment [seg] (samples seg-1 .. seg) of [rec] nearest
  /// (pe, pn), and the distance to it.
  static (double, double) _project(
      IndexedRoad rec, int seg, double pe, double pn) {
    final ae = rec.e[seg - 1], an = rec.n[seg - 1];
    final ex = rec.e[seg] - ae, en = rec.n[seg] - an;
    final len2 = ex * ex + en * en;
    final u = len2 <= 1e-12
        ? 0.0
        : (((pe - ae) * ex + (pn - an) * en) / len2).clamp(0.0, 1.0);
    final dx = pe - (ae + ex * u), dn = pn - (an + en * u);
    return (u, math.sqrt(dx * dx + dn * dn));
  }

  /// Whether [p] is on the RIGHT of segment [seg] of [rec] run first point
  /// to last — the kerb forward traffic drives along.
  static bool _rightOf(IndexedRoad rec, int seg, double u, Vec2 p) {
    final ae = rec.e[seg - 1], an = rec.n[seg - 1];
    final ex = rec.e[seg] - ae, en = rec.n[seg] - an;
    final qe = ae + ex * u, qn = an + en * u;
    // Vec2.perp is the LEFT normal, so a positive cross is the left side.
    return ex * (p.n - qn) - en * (p.e - qe) < 0;
  }

  /// The nearest point of road [rec] (index [slot]) to [p]: through the
  /// index within [reachM], else — a lot cut far from its road's line, on
  /// a curve sampled coarsely — every segment.
  static ({int seg, double u, bool rightOfForward}) _nearestOnRoad(
      SegmentIndex idx, int slot, IndexedRoad rec, Vec2 p, double reachM) {
    var best = double.infinity;
    var bestSeg = 1;
    var bestU = 0.0;
    idx.visit(Box2.around(p, reachM), 0, (s, r, seg) {
      if (s != slot || seg == 0) return;
      final (u, d) = _project(rec, seg, p.e, p.n);
      if (d < best) {
        best = d;
        bestSeg = seg;
        bestU = u;
      }
    });
    if (best.isInfinite) {
      for (var seg = 1; seg < rec.sampleCount; seg++) {
        final (u, d) = _project(rec, seg, p.e, p.n);
        if (d < best) {
          best = d;
          bestSeg = seg;
          bestU = u;
        }
      }
    }
    return (
      seg: bestSeg,
      u: bestU,
      rightOfForward: _rightOf(rec, bestSeg, bestU, p)
    );
  }

  static Vec2 _pointOn(IndexedRoad rec, double s) {
    final cum = rec.cum;
    final n = cum.length;
    if (s <= 0) return rec.sampleAt(0);
    if (s >= cum[n - 1]) return rec.sampleAt(n - 1);
    var lo = 1, hi = n - 1;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (cum[mid] < s) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final seg = cum[lo] - cum[lo - 1];
    final t = seg <= 1e-12 ? 0.0 : (s - cum[lo - 1]) / seg;
    return Vec2(rec.e[lo - 1] + (rec.e[lo] - rec.e[lo - 1]) * t,
        rec.n[lo - 1] + (rec.n[lo] - rec.n[lo - 1]) * t);
  }
}

/// A leg being collected for a node, before the node's plan exists.
class _LegDraft {
  _LegDraft(this.road, {required this.startsHere, required this.heading});
  final RoadSpline road;
  final bool startsHere;
  final double heading;
}
