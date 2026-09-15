// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Synthetic site plans on REAL join slots (docs/plans/site-access.md §7.9,
/// slice R2a): what the Agent Traffic session builds T4a against before the
/// R2 generators exist.
///
/// Every template is laid out in the frame of its join slot — `v` the slot's
/// road normal into the lot, `u` turned a quarter clockwise from it (so `v` is
/// `u` turned counter-clockwise), `y = 0` the frontage line `k` metres behind
/// the kerb — and its kerb node sits EXACTLY on the slot's kerb point, so
/// V3's bit-for-bit check holds. Each passes V1–V13 against the starter kit's
/// road graph ([SyntheticSites.starterCity]).
///
/// A template is first a mutable [DraftSite] (a test may break it by hand),
/// then emitted through the real `PlanBuilder` ([SyntheticSites.emit]).
///
/// | Template | Where (starter kit) | Shape |
/// |---|---|---|
/// | [SyntheticTemplate.kerbside] | lot-r0x1-l9 slot 0 | `kerbOnly`: one kerbside join, no network |
/// | [SyntheticTemplate.home] | lot-r0x1-l4 slot 0 (1+1 street) | `homeDriveway`: 7 m `sharedSingle` 5.2 m throat K→H + 5.2 m pad H→P (collinear), cut half 4.0, 2 side-by-side `inline` stalls, pad end P with no turnaround |
/// | [SyntheticTemplate.homeTandem] | lot-r0x1-l5 slot 0 | as home with a 3.2 m drive and a 10.4 m pad: 2 `inline` stalls in tandem (outer S0 at s 0, deep S1 at s 5.2) |
/// | [SyntheticTemplate.strip] | lot-r0x1-l7 slot 0 | `carPark`: 6 m two-way throat (11.5 m), 42 m aisle, 12 + 12 perpendicular stalls, circle turnaround |
/// | [SyntheticTemplate.loop] | lot-r0x1-r0 (corner) slot 0 in + slot 2 (side street, joinRef ≤ −2) out | `carPark`: one-way through drive, 3 `angled60` stalls |
/// | [SyntheticTemplate.yard] | lot-r1x1-r5 slot 0 | `yard`: 7 m truck throat, branch to a 30 m aisle (8 stalls, circle) and a 36 m apron (2 bays, 12.5 m circle), `kPlanAdmitsTrucks` |
/// | [SyntheticTemplate.utility] | lot-m3 (aquifer pump) slot 0 | `installation`: 56 m throat K→F with vias at 24 and 48 m, yard circle Y (r 13), gate G on the fence line (hammerhead a), connector to an aisle loop with 20 stalls, 2 bays, `kPlanAdmitsTrucks` |
/// | FOOTPRINT ([SyntheticSites.footprintDraft]) | [SyntheticSites.footprintPolygon], `attachFootprintJoins` slot 0 | the strip car park on a site that is no graph lot: `graphLot` −1, `joinRef` −1 |
library;

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/colony/city/city_sim.dart';
import 'package:acro_space_simulator/domain/colony/city/parcel.dart';
import 'package:acro_space_simulator/domain/colony/city/road_graph.dart';
import 'package:acro_space_simulator/domain/colony/city/road_junction.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_constants.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_access_plan.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_join.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_builder.dart';
import 'package:acro_space_simulator/domain/colony/city/site_access/site_plan_validator.dart';
// Traffic is read here, never changed: V1 checks cuts against real lane graphs.
import 'package:acro_space_simulator/domain/colony/city/traffic/lane_graph_builder.dart';

import '../../traffic/traffic_fixture.dart';

/// The templates. Their names are the fixture site ids ([SyntheticSites.idOf]).
enum SyntheticTemplate { kerbside, home, homeTandem, strip, loop, yard, utility }

typedef XY = (double, double);

class DraftJoin {
  DraftJoin({
    required this.slot,
    required this.ref,
    required this.piece,
    required this.roadS,
    required this.right,
    required this.dirs,
    this.role = SiteJoinRole.both,
    this.kind = SiteJoinKind.cut,
    this.roadNo = -1,
    this.kerbNode = -1,
    this.throatSeg = -1,
    this.cutHalfM = 0,
  });

  int slot, ref, piece, dirs, roadNo, kerbNode, throatSeg;
  double roadS, cutHalfM;
  bool right;
  SiteJoinRole role;
  SiteJoinKind kind;
}

class DraftNode {
  DraftNode(this.e, this.n,
      {this.flags = 0,
      this.turn = TurnaroundKind.none,
      this.turnR = 0,
      this.turnHx = 0,
      this.turnHn = 0,
      this.ref = SiteHeightRef.pad});

  double e, n, turnR, turnHx, turnHn;
  int flags;
  TurnaroundKind turn;
  SiteHeightRef ref;
}

class DraftSeg {
  DraftSeg(this.from, this.to,
      {this.vias = const [],
      required this.kind,
      required this.mode,
      required this.widthM,
      this.speedMps,
      this.maxVehLenM = kSegMinVehLenM,
      this.flags = 0,
      this.lenM});

  int from, to, flags;
  List<XY> vias;
  SiteSegmentKind kind;
  SiteLaneMode mode;
  double widthM, maxVehLenM;
  double? speedMps, lenM;
}

class DraftStall {
  DraftStall({
    required this.seg,
    required this.s,
    required this.side,
    required this.angle,
    required this.inDirs,
    required this.outDirs,
    required this.e,
    required this.n,
    required this.dirE,
    required this.dirN,
    this.lenM = 5.2,
    this.widthM = 2.6,
    required this.row,
    required this.bay,
  });

  int seg, side, inDirs, outDirs, row, bay;
  double s, e, n, dirE, dirN, lenM, widthM;
  StallAngle angle;
}

class DraftBay {
  DraftBay({
    required this.seg,
    required this.s,
    required this.side,
    required this.e,
    required this.n,
    required this.dirE,
    required this.dirN,
    this.lenM = 15,
    this.widthM = 3.5,
  });

  int seg, side;
  double s, e, n, dirE, dirN, lenM, widthM;
}

/// One synthetic site, mutable until emitted.
class DraftSite {
  DraftSite({
    required this.siteId,
    required this.program,
    required this.graphLot,
    required this.oE,
    required this.oN,
    required this.uE,
    required this.uN,
  });

  String siteId;
  SiteProgram program;
  int flags = 0;
  int graphLot;

  /// The frame: origin on the frontage line, unit u; v = u turned CCW.
  double oE, oN, uE, uN;
  double vE() => -uN;
  double vN() => uE;
  double envX0 = 0, envX1 = 0, envY0 = 0, envY1 = 0, envFrontInset = 0;
  double gateX = 0, gateW = 0, truckTurnRadiusM = 0;

  final List<DraftJoin> joins = [];
  final List<DraftNode> nodes = [];
  final List<DraftSeg> segs = [];
  final List<DraftStall> stalls = [];
  final List<DraftBay> bays = [];
  final List<List<XY>> paves = [];
  final List<XY> lamps = [];
  final List<List<XY>> paths = [];
  XY entrance = (0, 0);
  int entranceNode = -1;
  XY pavement = (0, 0);
  int? revOverride;

  /// Frame (x, y) to world.
  XY w(double x, double y) =>
      (oE + uE * x + vE() * y, oN + uN * x + vN() * y);

  /// A frame direction to world.
  XY dir(double x, double y) => (uE * x + vE() * y, uN * x + vN() * y);

  int node(double x, double y,
      {int flags = 0,
      TurnaroundKind turn = TurnaroundKind.none,
      double turnR = 0,
      SiteHeightRef ref = SiteHeightRef.pad}) {
    final (e, n) = w(x, y);
    nodes.add(DraftNode(e, n, flags: flags, turn: turn, turnR: turnR, ref: ref));
    return nodes.length - 1;
  }

  /// An axis-aligned frame rectangle as a CCW world ring.
  List<XY> rect(double x0, double y0, double x1, double y1) =>
      [w(x0, y0), w(x1, y0), w(x1, y1), w(x0, y1)];

  /// A CCW regular octagon of radius [r] around frame (x, y).
  List<XY> octagon(double x, double y, double r) {
    const c = 0.70710678;
    const unit = [(1.0, 0.0), (c, c), (0.0, 1.0), (-c, c), (-1.0, 0.0), (-c, -c), (0.0, -1.0), (c, -c)];
    return [for (final (a, b) in unit) w(x + a * r, y + b * r)];
  }

  /// Swaps segments [a] and [b], every reference with them (tests).
  void swapSegments(int a, int b) {
    final t = segs[a];
    segs[a] = segs[b];
    segs[b] = t;
    int map(int k) => k == a ? b : (k == b ? a : k);
    for (final j in joins) {
      j.throatSeg = map(j.throatSeg);
    }
    for (final s in stalls) {
      s.seg = map(s.seg);
    }
    for (final y in bays) {
      y.seg = map(y.seg);
    }
  }
}

abstract final class SyntheticSites {
  /// The starter kit's lot each template stands on.
  static const Map<SyntheticTemplate, (String, int)> starterLots = {
    SyntheticTemplate.kerbside: ('lot-r0x1-l9', 0),
    SyntheticTemplate.home: ('lot-r0x1-l4', 0),
    SyntheticTemplate.homeTandem: ('lot-r0x1-l5', 0),
    SyntheticTemplate.strip: ('lot-r0x1-l7', 0),
    SyntheticTemplate.loop: ('lot-r0x1-r0', 0),
    SyntheticTemplate.yard: ('lot-r1x1-r5', 0),
    SyntheticTemplate.utility: ('lot-m3', 0),
  };

  /// A footprint off the plat, in the gap between the south-east lot rows,
  /// facing the east street.
  static const List<Vec2> footprintPolygon = [
    Vec2(42, -36), Vec2(58, -36), Vec2(58, -10), Vec2(42, -10), //
  ];

  /// The fixture site id of a template: its upper-case name, e.g. `HOME`,
  /// `HOME_TANDEM`.
  static String idOf(SyntheticTemplate t) => switch (t) {
        SyntheticTemplate.kerbside => 'KERBSIDE',
        SyntheticTemplate.home => 'HOME',
        SyntheticTemplate.homeTandem => 'HOME_TANDEM',
        SyntheticTemplate.strip => 'STRIP',
        SyntheticTemplate.loop => 'LOOP',
        SyntheticTemplate.yard => 'YARD',
        SyntheticTemplate.utility => 'UTILITY',
      };

  static const String footprintId = 'FOOTPRINT';

  /// The starter kit colony the fixtures stand in.
  static CitySim starterCity() => starterKit();

  /// Every template on its starter lot, then the footprint site, in
  /// [SyntheticTemplate] order.
  static List<DraftSite> starterDrafts(RoadGraph g) => [
        for (final t in SyntheticTemplate.values)
          draftAt(g, starterLots[t]!.$1, t),
        footprintDraft(g),
      ];

  /// Every starter fixture in one chunk, validated (debug) against [g].
  static SiteAccessChunk starterChunk(RoadGraph g) =>
      chunkOf(g, starterDrafts(g));

  /// Template [t] placed on graph lot [lotId] as one chunk.
  static SiteAccessChunk placeAt(RoadGraph g, String lotId, SyntheticTemplate t) =>
      chunkOf(g, [draftAt(g, lotId, t)]);

  /// [drafts] emitted into one chunk.
  static SiteAccessChunk chunkOf(RoadGraph g, List<DraftSite> drafts,
      {bool validate = true}) {
    final b = PlanBuilder(graph: g);
    for (final d in drafts) {
      emit(b, d);
    }
    return b.build(validate: validate);
  }

  /// Lane spans of lane graphs built from [g] under the override kinds of
  /// test A2: none, lights on, lights off, every leg stops, no leg stops.
  static List<SiteLaneSpans> laneSpansOf(RoadGraph g) {
    final junctions = [for (final n in g.nodes) if (n.legs.length >= 3) n];
    final kinds = <List<JunctionOverride>>[
      const [],
      [for (final n in junctions) JunctionOverride(at: n.at, lights: true)],
      [for (final n in junctions) JunctionOverride(at: n.at, lights: false)],
      [
        for (final n in junctions)
          JunctionOverride(at: n.at, stopHeadings: [for (final l in n.legs) l.heading])
      ],
      [
        for (final n in junctions)
          JunctionOverride(at: n.at, lights: false, stopHeadings: const [])
      ],
    ];
    return [
      for (final o in kinds)
        () {
          final lg = LaneGraphBuilder.build(g.withOverrides(o));
          return (
            laneS0: lg.edgeLaneS0,
            laneS1: lg.edgeLaneS1,
            travelArc: lg.travelArc,
          );
        }(),
    ];
  }

  /// Emits [d] into [b].
  static void emit(PlanBuilder b, DraftSite d) {
    b.beginSite(
      d.siteId,
      program: d.program,
      flags: d.flags,
      graphLot: d.graphLot,
      frameE: d.oE,
      frameN: d.oN,
      frameUE: d.uE,
      frameUN: d.uN,
      envX0: d.envX0,
      envX1: d.envX1,
      envY0: d.envY0,
      envY1: d.envY1,
      envFrontInset: d.envFrontInset,
      gateX: d.gateX,
      gateW: d.gateW,
      truckTurnRadiusM: d.truckTurnRadiusM,
    );
    for (final j in d.joins) {
      b.join(
        slot: j.slot,
        ref: j.ref,
        piece: j.piece,
        roadS: j.roadS,
        right: j.right,
        dirs: j.dirs,
        role: j.role,
        kind: j.kind,
        roadNo: j.roadNo,
        kerbNode: j.kerbNode,
        throatSeg: j.throatSeg,
        cutHalfM: j.cutHalfM,
      );
    }
    for (final n in d.nodes) {
      final pt = b.point(n.e, n.n, ref: n.ref);
      b.node(pt,
          flags: n.flags,
          turn: n.turn,
          turnR: n.turnR,
          turnHx: n.turnHx,
          turnHn: n.turnHn);
    }
    for (final s in d.segs) {
      b.segment(s.from, s.to,
          vias: [for (final (e, n) in s.vias) b.point(e, n)],
          kind: s.kind,
          mode: s.mode,
          widthM: s.widthM,
          speedMps: s.speedMps,
          maxVehLenM: s.maxVehLenM,
          flags: s.flags,
          lenM: s.lenM);
    }
    for (final s in d.stalls) {
      b.stall(
          seg: s.seg,
          s: s.s,
          side: s.side,
          angle: s.angle,
          inDirs: s.inDirs,
          outDirs: s.outDirs,
          e: s.e,
          n: s.n,
          dirE: s.dirE,
          dirN: s.dirN,
          lenM: s.lenM,
          widthM: s.widthM,
          row: s.row,
          bay: s.bay);
    }
    for (final y in d.bays) {
      b.bay(
          seg: y.seg,
          s: y.s,
          side: y.side,
          e: y.e,
          n: y.n,
          dirE: y.dirE,
          dirN: y.dirN,
          lenM: y.lenM,
          widthM: y.widthM);
    }
    for (final ring in d.paves) {
      b.pave([for (final (e, n) in ring) b.point(e, n)]);
    }
    for (final (e, n) in d.lamps) {
      b.lamp(b.point(e, n));
    }
    for (final path in d.paths) {
      b.path([for (final (e, n) in path) b.point(e, n)]);
    }
    b.entrance(b.point(d.entrance.$1, d.entrance.$2), node: d.entranceNode);
    b.pavement(b.point(d.pavement.$1, d.pavement.$2));
    if (d.revOverride != null) b.debugOverrideRev(d.revOverride!);
    b.endSite();
  }

  // ---- templates ---------------------------------------------------------------

  /// Template [t] on slot [starterLots]`[t].$2` of graph lot [lotId] (the
  /// loop also takes the lot's side-street slot 2).
  static DraftSite draftAt(RoadGraph g, String lotId, SyntheticTemplate t,
      {String? siteId}) {
    final lot = g.lotNoOf(lotId);
    if (lot == null) throw ArgumentError('no graph lot $lotId');
    final ref = g.joinRefOf(lot, starterLots[t]?.$2 ?? 0);
    final slot = g.joinOfRef(ref);
    if (slot == null) throw ArgumentError('$lotId has no slot 0');
    final id = siteId ?? idOf(t);
    return switch (t) {
      SyntheticTemplate.kerbside => _kerbside(g, id, lot, ref, slot),
      SyntheticTemplate.home => _home(g, id, lot, ref, slot, tandem: false),
      SyntheticTemplate.homeTandem => _home(g, id, lot, ref, slot, tandem: true),
      SyntheticTemplate.strip => _strip(g, id, lot, ref, slot),
      SyntheticTemplate.loop => _loop(g, id, lot, ref, slot),
      SyntheticTemplate.yard => _yard(g, id, lot, ref, slot),
      SyntheticTemplate.utility => _utility(g, id, lot, ref, slot),
    };
  }

  /// The strip car park on slot 0 of a footprint that is no graph lot.
  static DraftSite footprintDraft(RoadGraph g,
      {List<Vec2> polygon = footprintPolygon, String siteId = footprintId}) {
    final slots = g.attachFootprintJoins(polygon);
    if (slots.isEmpty || slots.first.flags & kJoinCut == 0) {
      throw StateError('the footprint has no cut slot 0');
    }
    return _strip(g, siteId, -1, kJoinRefNone, slots.first);
  }

  /// A site in [slot]'s frame, frontage [k] m behind the kerb, with its join
  /// 0 copied from the slot.
  static DraftSite _site(RoadGraph g, String id, int lot, int ref, JoinSlot slot,
      SiteProgram program, double k,
      {SiteJoinKind kind = SiteJoinKind.cut,
      SiteJoinRole role = SiteJoinRole.both,
      double cutHalfM = 0}) {
    final vE = slot.normE, vN = slot.normN;
    final uE = vN, uN = -vE;
    final d = DraftSite(
      siteId: id,
      program: program,
      graphLot: lot,
      oE: slot.kerbE + vE * k,
      oN: slot.kerbN + vN * k,
      uE: uE,
      uN: uN,
    );
    d.joins.add(DraftJoin(
      slot: 0,
      ref: ref,
      piece: slot.piece,
      roadS: slot.s,
      right: slot.right,
      dirs: slot.dirs,
      role: role,
      kind: kind,
      roadNo: g.pieceRoad[slot.piece],
      cutHalfM: cutHalfM,
    ));
    if (program != SiteProgram.kerbOnly) d.flags |= kPlanNetwork;
    d.pavement = (slot.kerbE + vE * 1.5, slot.kerbN + vN * 1.5);
    return d;
  }

  /// A kerb node exactly on [slot]'s kerb point.
  static int _kerbNode(DraftSite d, JoinSlot slot) {
    d.nodes.add(DraftNode(slot.kerbE, slot.kerbN,
        flags: kNodeKerb, ref: SiteHeightRef.kerb));
    return d.nodes.length - 1;
  }

  static DraftSite _kerbside(
      RoadGraph g, String id, int lot, int ref, JoinSlot slot) {
    final d = _site(g, id, lot, ref, slot, SiteProgram.kerbOnly, 3,
        kind: SiteJoinKind.kerbside);
    d
      ..envX0 = 1.5
      ..envX1 = 22.5
      ..envY0 = 4
      ..envY1 = 29
      ..entrance = d.w(8, 4);
    return d;
  }

  /// §3.4: K(0, −3) → H(0, 4) → P(0, 4 + 5.2 r), stalls inline, nose +v.
  static DraftSite _home(RoadGraph g, String id, int lot, int ref, JoinSlot slot,
      {required bool tandem}) {
    const k = 3.0, yT = 4.0;
    final w = tandem ? 3.2 : 5.2;
    final rows = tandem ? 2 : 1;
    final d = _site(g, id, lot, ref, slot, SiteProgram.homeDriveway, k,
        cutHalfM: kHomeCutHalfM);
    final kn = _kerbNode(d, slot);
    final h = d.node(0, yT);
    final pEnd = d.node(0, yT + 5.2 * rows, flags: kNodeDeadEnd);
    d.segs
      ..add(DraftSeg(kn, h,
          kind: SiteSegmentKind.driveway,
          mode: SiteLaneMode.sharedSingle,
          widthM: w,
          flags: kSegThroat | kSegCrossesPavement))
      ..add(DraftSeg(h, pEnd,
          kind: SiteSegmentKind.apron,
          mode: SiteLaneMode.sharedSingle,
          widthM: w));
    d.joins[0]
      ..kerbNode = kn
      ..throatSeg = 0;
    final (dE, dN) = d.dir(0, 1);
    void stall(double x, double y, double s, int side, int bay) {
      final (e, n) = d.w(x, y);
      d.stalls.add(DraftStall(
          seg: 1,
          s: s,
          side: side,
          angle: StallAngle.inline,
          inDirs: kSiteDirFwd,
          outDirs: kSiteDirBwd,
          e: e,
          n: n,
          dirE: dE,
          dirN: dN,
          row: 0,
          bay: bay));
    }

    if (tandem) {
      stall(0, yT + 2.6, 0, 0, 0);
      stall(0, yT + 7.8, 5.2, 0, 1);
    } else {
      stall(1.3, yT + 2.6, 0, 0, 0);
      stall(-1.3, yT + 2.6, 0, 1, 0);
    }
    final xEnv = w / 2 + 1;
    d
      ..envX0 = xEnv
      ..envX1 = xEnv + 9.5
      ..envY0 = yT
      ..envY1 = 29
      ..entrance = d.w(xEnv + 4, yT)
      ..entranceNode = h;
    d.paves.add(d.rect(-w / 2, -k, w / 2, yT + 5.2 * rows));
    d.paths.add([d.w(xEnv + 4, -1.5), d.w(xEnv + 4, yT)]);
    return d;
  }

  /// A car park: throat K(0, −3) → J(0, 8.5), aisle J → E(42, 8.5) with 12
  /// perpendicular stalls each side and a circle at E.
  static DraftSite _strip(RoadGraph g, String id, int lot, int ref, JoinSlot slot) {
    const k = 3.0, yA = 8.5, aisle = 42.0;
    final d = _site(g, id, lot, ref, slot, SiteProgram.carPark, k,
        cutHalfM: 3 + kCutFlareM);
    final kn = _kerbNode(d, slot);
    final j = d.node(0, yA);
    final e = d.node(aisle, yA,
        flags: kNodeDeadEnd, turn: TurnaroundKind.circle, turnR: 6.5);
    d.segs
      ..add(DraftSeg(kn, j,
          kind: SiteSegmentKind.driveway,
          mode: SiteLaneMode.twoWay,
          widthM: 6,
          flags: kSegThroat | kSegCrossesPavement))
      ..add(DraftSeg(j, e,
          vias: [d.w(aisle / 2, yA)],
          kind: SiteSegmentKind.aisle,
          mode: SiteLaneMode.twoWay,
          widthM: 6));
    d.joins[0]
      ..kerbNode = kn
      ..throatSeg = 0;
    for (var i = 0; i < 12; i++) {
      final s = 4.5 + 2.6 * i;
      final inDirs = (s - kStallRunupHalfWidthM >= kStallRunupM ? kSiteDirFwd : 0) |
          (aisle - s - kStallRunupHalfWidthM >= kStallRunupM ? kSiteDirBwd : 0);
      for (final side in const [0, 1]) {
        final y = side == 0 ? yA - 3 - 2.6 : yA + 3 + 2.6;
        final (ce, cn) = d.w(s, y);
        final (de, dn) = d.dir(0, side == 0 ? -1 : 1);
        d.stalls.add(DraftStall(
            seg: 1,
            s: s,
            side: side,
            angle: StallAngle.perpendicular,
            inDirs: inDirs,
            outDirs: kSiteDirFwd | kSiteDirBwd,
            e: ce,
            n: cn,
            dirE: de,
            dirN: dn,
            row: side,
            bay: i));
      }
    }
    d
      ..envX0 = -4
      ..envX1 = 40
      ..envY0 = 18.7
      ..envY1 = 31.7
      ..entrance = d.w(20, 18.7)
      ..entranceNode = j;
    d.paves
      ..add(d.rect(-3, -k, 3, 0.3))
      ..add(d.rect(-3, 0.3, aisle + 6.5, 16.7));
    d.lamps
      ..add(d.w(12.5, 16.7))
      ..add(d.w(37.5, 16.7));
    return d;
  }

  /// A corner lot's through drive: in at slot 0, out at the side-street slot
  /// 2, one-way, three angled stalls on the leg toward the side street.
  static DraftSite _loop(RoadGraph g, String id, int lot, int ref, JoinSlot slot) {
    final ref2 = g.joinRefOf(lot, kJoinSlotSideStreet);
    final side = g.joinOfRef(ref2);
    if (side == null) throw ArgumentError('lot $lot has no side-street slot');
    const k = 3.0, w = 3.5, throat = 7.0;
    final cut = w / 2 + kCutFlareM;
    final d = _site(g, id, lot, ref, slot, SiteProgram.carPark, k,
        role: SiteJoinRole.inOnly, cutHalfM: cut);
    d.joins.add(DraftJoin(
      slot: kJoinSlotSideStreet,
      ref: ref2,
      piece: side.piece,
      roadS: side.s,
      right: side.right,
      dirs: side.dirs,
      role: SiteJoinRole.outOnly,
      roadNo: g.pieceRoad[side.piece],
      cutHalfM: cut,
    ));
    final k1 = _kerbNode(d, slot);
    final k2 = _kerbNode(d, side);
    final (n1e, n1n) = (slot.normE, slot.normN);
    final (n2e, n2n) = (side.normE, side.normN);
    final (ae, an) = (slot.kerbE + n1e * throat, slot.kerbN + n1n * throat);
    final (be, bn) = (side.kerbE + n2e * throat, side.kerbN + n2n * throat);
    // C = A + n1·t = B + n2·r.
    final det = -n1e * n2n + n2e * n1n;
    final de = be - ae, dn = bn - an;
    final t = (de * -n2n + n2e * dn) / det;
    final r = (n1e * dn - n1n * de) / det;
    if (t < 1 || r < 16) throw StateError('corner geometry t $t r $r');
    final (ce, cn) = (ae + n1e * t, an + n1n * t);
    d.nodes
      ..add(DraftNode(ae, an))
      ..add(DraftNode(be, bn))
      ..add(DraftNode(ce, cn));
    const a = 2, b = 3, c = 4;
    d.segs
      ..add(DraftSeg(k1, a,
          kind: SiteSegmentKind.driveway,
          mode: SiteLaneMode.oneWayForward,
          widthM: w,
          flags: kSegThroat | kSegCrossesPavement))
      ..add(DraftSeg(k2, b,
          kind: SiteSegmentKind.driveway,
          mode: SiteLaneMode.oneWayBackward,
          widthM: w,
          flags: kSegThroat | kSegCrossesPavement))
      ..add(DraftSeg(a, c,
          kind: SiteSegmentKind.aisle, mode: SiteLaneMode.oneWayForward, widthM: w))
      ..add(DraftSeg(c, b,
          kind: SiteSegmentKind.aisle, mode: SiteLaneMode.oneWayForward, widthM: w));
    d.joins[0]
      ..kerbNode = k1
      ..throatSeg = 0;
    d.joins[1]
      ..kerbNode = k2
      ..throatSeg = 1;
    // Stalls on C → B, nose 60° off travel toward its right.
    final he = -n2e, hn = -n2n; // travel along C → B
    final re = hn, rn = -he; // right of travel
    const sin60 = 0.8660254;
    final ne = he * 0.5 + re * sin60, nn = hn * 0.5 + rn * sin60;
    final reach = w / 2 / sin60 + 2.6;
    for (var i = 0; i < 3; i++) {
      final s = 7.0 + 3.0 * i;
      final pe = ce + he * s, pn = cn + hn * s;
      d.stalls.add(DraftStall(
          seg: 3,
          s: s,
          side: 0,
          angle: StallAngle.angled60,
          inDirs: kSiteDirFwd,
          outDirs: kSiteDirFwd,
          e: pe + ne * reach,
          n: pn + nn * reach,
          dirE: ne,
          dirN: nn,
          row: 0,
          bay: i));
    }
    List<XY> strip(double ae, double an, double be, double bn) {
      final l = math.sqrt((be - ae) * (be - ae) + (bn - an) * (bn - an));
      final ue = (be - ae) / l, un = (bn - an) / l;
      final pe = -un * w / 2, pn = ue * w / 2;
      return [
        (ae - pe, an - pn), (be - pe, bn - pn), (be + pe, bn + pn), (ae + pe, an + pn), //
      ];
    }

    d.paves
      ..add(strip(slot.kerbE, slot.kerbN, ae, an))
      ..add(strip(side.kerbE, side.kerbN, be, bn))
      ..add(strip(ae, an, ce, cn))
      ..add(strip(ce, cn, be, bn));
    // The envelope beyond the stalls: 8..16 m right of C → B, from 5 to 16 m
    // along it, as a frame box.
    var x0 = double.infinity, x1 = double.negativeInfinity;
    var y0 = double.infinity, y1 = double.negativeInfinity;
    for (final (lat, s) in const [(8.0, 5.0), (16.0, 5.0), (8.0, 16.0), (16.0, 16.0)]) {
      final pe = ce + he * s + re * lat, pn = cn + hn * s + rn * lat;
      final x = (pe - d.oE) * d.uE + (pn - d.oN) * d.uN;
      final y = (pe - d.oE) * d.vE() + (pn - d.oN) * d.vN();
      x0 = math.min(x0, x);
      x1 = math.max(x1, x);
      y0 = math.min(y0, y);
      y1 = math.max(y1, y);
    }
    d
      ..envX0 = x0
      ..envX1 = x1
      ..envY0 = y0
      ..envY1 = y1
      ..entrance = d.w((x0 + x1) / 2, y0)
      ..entranceNode = c;
    return d;
  }

  /// §3.6: throat K(0, −3) → J(0, 4) (7 m, trucks), aisle J → E(−30, 4) with
  /// 8 stalls and a circle, apron J → Y(0, 40) with 2 bays and a 12.5 m circle.
  static DraftSite _yard(RoadGraph g, String id, int lot, int ref, JoinSlot slot) {
    const k = 3.0;
    final d = _site(g, id, lot, ref, slot, SiteProgram.yard, k,
        cutHalfM: 3.5 + kCutFlareM);
    d
      ..flags |= kPlanAdmitsTrucks
      ..truckTurnRadiusM = kTruckTurnMinM;
    final kn = _kerbNode(d, slot);
    final j = d.node(0, 4, flags: kNodeBranch);
    final e = d.node(-30, 4,
        flags: kNodeDeadEnd, turn: TurnaroundKind.circle, turnR: 6);
    final y = d.node(0, 40,
        flags: kNodeDeadEnd, turn: TurnaroundKind.circle, turnR: kTruckTurnMinM);
    d.segs
      ..add(DraftSeg(kn, j,
          kind: SiteSegmentKind.driveway,
          mode: SiteLaneMode.twoWay,
          widthM: 7,
          maxVehLenM: kTruckMinVehLenM,
          flags: kSegThroat | kSegCrossesPavement | kSegTruck))
      ..add(DraftSeg(j, e,
          vias: [d.w(-15, 4)],
          kind: SiteSegmentKind.aisle,
          mode: SiteLaneMode.twoWay,
          widthM: 6))
      ..add(DraftSeg(j, y,
          vias: [d.w(0, 22)],
          kind: SiteSegmentKind.apron,
          mode: SiteLaneMode.twoWay,
          widthM: 7,
          maxVehLenM: kTruckMinVehLenM,
          flags: kSegTruck));
    d.joins[0]
      ..kerbNode = kn
      ..throatSeg = 0;
    final (ve, vn) = d.dir(0, 1);
    for (var i = 0; i < 8; i++) {
      final s = 5.3 + 2.6 * i;
      final inDirs = (s - kStallRunupHalfWidthM >= kStallRunupM ? kSiteDirFwd : 0) |
          (30 - s - kStallRunupHalfWidthM >= kStallRunupM ? kSiteDirBwd : 0);
      final (ce, cn) = d.w(-s, 4 + 3 + 2.6);
      d.stalls.add(DraftStall(
          seg: 1,
          s: s,
          side: 0,
          angle: StallAngle.perpendicular,
          inDirs: inDirs,
          outDirs: kSiteDirFwd | kSiteDirBwd,
          e: ce,
          n: cn,
          dirE: ve,
          dirN: vn,
          row: 0,
          bay: i));
    }
    final (ue, un) = d.dir(1, 0);
    for (final (s, yb) in const [(8.0, 12.0), (12.0, 16.0)]) {
      final (be, bn) = d.w(11, yb);
      d.bays.add(DraftBay(
          seg: 2, s: s, side: 0, e: be, n: bn, dirE: ue, dirN: un));
    }
    d
      ..envX0 = 20
      ..envX1 = 50
      ..envY0 = 2
      ..envY1 = 40
      ..entrance = d.w(20, 20)
      ..entranceNode = j;
    d.paves
      ..add(d.rect(-3.5, -k, 3.5, 4))
      ..add(d.rect(-30, 1, -3.5, 12.2))
      ..add(d.rect(-3.5, 4, 18.5, 27.5))
      ..add(d.octagon(0, 40, kTruckTurnMinM));
    return d;
  }

  /// §3.7: the starter installation, k = 56.
  static DraftSite _utility(
      RoadGraph g, String id, int lot, int ref, JoinSlot slot) {
    const k = 56.0, dF = 46.0;
    final d = _site(g, id, lot, ref, slot, SiteProgram.installation, k,
        cutHalfM: 3.5 + kCutFlareM);
    d
      ..flags |= kPlanAdmitsTrucks
      ..truckTurnRadiusM = 13
      ..gateX = 0
      ..gateW = 9
      ..envFrontInset = dF
      ..envX0 = -60
      ..envX1 = 80
      ..envY0 = dF
      ..envY1 = 140;
    final kn = _kerbNode(d, slot); // 0
    final f = d.node(0, 0); // 1
    final y = d.node(0, 15,
        flags: kNodeBranch, turn: TurnaroundKind.circle, turnR: 13); // 2
    final gate = d.node(0, dF,
        flags: kNodeGate | kNodeDeadEnd,
        turn: TurnaroundKind.hammerhead,
        turnR: kHammerheadApronM); // 3
    final c = d.node(18, 15, flags: kNodeBranch); // 4
    final p1 = d.node(18, 25); // 5
    final p2 = d.node(56, 25); // 6
    final p3 = d.node(56, 5); // 7
    final p4 = d.node(18, 5); // 8
    final (hx, hn) = d.dir(0, 1);
    d.nodes[gate]
      ..turnHx = hx
      ..turnHn = hn;
    DraftSeg aisle(int a, int b, {List<XY> vias = const []}) => DraftSeg(a, b,
        vias: vias,
        kind: SiteSegmentKind.aisle,
        mode: SiteLaneMode.twoWay,
        widthM: 6);
    DraftSeg road(int a, int b, {int flags = 0, List<XY> vias = const []}) =>
        DraftSeg(a, b,
            vias: vias,
            kind: SiteSegmentKind.accessRoad,
            mode: SiteLaneMode.twoWay,
            widthM: 7,
            maxVehLenM: kTruckMinVehLenM,
            flags: flags | kSegTruck);
    d.segs
      ..add(road(kn, f,
          flags: kSegThroat | kSegCrossesPavement,
          vias: [d.w(0, 24 - k), d.w(0, 48 - k)])) // 0
      ..add(aisle(p4, c)) // 1
      ..add(aisle(p3, p4, vias: [d.w(37, 5)])) // 2
      ..add(aisle(y, c)) // 3
      ..add(aisle(c, p1)) // 4
      ..add(aisle(p1, p2, vias: [d.w(37, 25)])) // 5
      ..add(aisle(p2, p3)) // 6
      ..add(road(f, y)) // 7
      ..add(road(y, gate, vias: [d.w(0, 30.5)])); // 8
    d.joins[0]
      ..kerbNode = kn
      ..throatSeg = 0;
    // Stalls inside the ring: top aisle P1 → P2, bottom aisle P3 → P4.
    for (var i = 0; i < 10; i++) {
      final s = 7.3 + 2.6 * i;
      final top = d.w(18 + s, 25 - 3 - 2.6);
      final (te, tn) = d.dir(0, -1);
      d.stalls.add(DraftStall(
          seg: 5,
          s: s,
          side: 0,
          angle: StallAngle.perpendicular,
          inDirs: kSiteDirFwd | kSiteDirBwd,
          outDirs: kSiteDirFwd | kSiteDirBwd,
          e: top.$1,
          n: top.$2,
          dirE: te,
          dirN: tn,
          row: 1,
          bay: i));
      final bottom = d.w(56 - s, 5 + 3 + 2.6);
      final (be, bn) = d.dir(0, 1);
      d.stalls.add(DraftStall(
          seg: 2,
          s: s,
          side: 0,
          angle: StallAngle.perpendicular,
          inDirs: kSiteDirFwd | kSiteDirBwd,
          outDirs: kSiteDirFwd | kSiteDirBwd,
          e: bottom.$1,
          n: bottom.$2,
          dirE: be,
          dirN: bn,
          row: 0,
          bay: i));
    }
    final (ve, vn) = d.dir(0, 1);
    for (final (side, x) in const [(0, 5.75), (1, -5.75)]) {
      final (be, bn) = d.w(x, 15 + 13 + 7.5);
      d.bays.add(
          DraftBay(seg: 8, s: 13, side: side, e: be, n: bn, dirE: ve, dirN: vn));
    }
    d
      ..entrance = d.w(0, dF)
      ..entranceNode = gate;
    d.paves
      ..add(d.rect(-3.5, -k, 3.5, 0))
      ..add(d.rect(-3.5, 0, 3.5, dF))
      ..add(d.octagon(0, 15, 13))
      ..add(d.rect(0, 12, 18, 18))
      ..add(d.rect(15, 2, 59, 28));
    d.lamps
      ..add(d.w(9, 20))
      ..add(d.w(37, 15));
    return d;
  }
}
