// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The site access plan contract (docs/plans/site-access.md §2.3): the enums,
/// the packed [SiteAccessChunk] and the cheap [SiteAccessPlan] view.
///
/// A chunk holds up to [kSitesPerChunk] sites. Every per-site family is CSR:
/// site k owns rows `xStart[k] .. xStart[k + 1] − 1` of family x, and every
/// index stored INSIDE a family (a node, a segment, a point, a via, a join,
/// a stall) is plan-local. Physically the chunk is five typed lists
/// (Float64List, Float32List, Int32List, Uint8List and an Int32List column
/// offset table) plus the `siteId` list, whose strings are the caller's own
/// instances: logical column `x` of type T is `backingT[offset[x] + row]`.
/// So a chunk retains at most 7 objects whatever its site count (§3.10).
///
/// **Immutable after build.** Nothing here writes a backing list after
/// [PlanBuilder] (site_plan_builder.dart) made it, and no backing list is
/// handed out: every read goes through an accessor. A changed site
/// publishes a NEW chunk; holders of the old one keep reading it unchanged.
///
/// Determinism (§3.9): no platform hash, no draw, no clock, no map
/// iteration, no trigonometry. [SiteAccessChunk.revisionOf] is `fnv1a32`
/// over quantised columns (V12).
library;

import 'dart:typed_data';

import '../hash32.dart';
import 'site_access_constants.dart';

// ---- Enums (append-only: indices are hashed and persisted) -----------------

/// What a site's plan is (§3.3).
enum SiteProgram { none, kerbOnly, homeDriveway, carPark, yard, installation }

/// Which way cars may use a join.
enum SiteJoinRole { both, inOnly, outOnly }

/// A join at the kerb (kerbside plans) or a kerb cut into the site.
enum SiteJoinKind { kerbside, cut }

/// What a segment is. `apron`: a home pad or a truck yard.
enum SiteSegmentKind { driveway, accessRoad, aisle, apron }

/// A segment's lanes. `sharedSingle`: one lane, used alternately both ways.
enum SiteLaneMode { twoWay, oneWayForward, oneWayBackward, sharedSingle }

/// A stall's angle to its segment. v1 emits `perpendicular`, and `inline` on
/// home pads: the stall lies ON its pad segment, nose along from→to.
enum StallAngle { perpendicular, angled60, angled45, parallel, inline }

/// A node's turnaround.
enum TurnaroundKind { none, hammerhead, circle }

/// What a point's height follows.
enum SiteHeightRef { pad, kerb, blend }

/// A pave's surface.
enum PaveSurface { asphalt, concrete, gravel }

/// A loading bay's kind (reserved, ask 9).
enum BayKind { dock, kerbBay }

/// `ptHJoin` of a point whose height follows no join.
const int kPtNoJoin = 255;

// ---- Physical layout ---------------------------------------------------------

/// Backing types.
const int _tF64 = 0, _tF32 = 1, _tI32 = 2, _tU8 = 3;

/// Revision quantisation: an integer as it is; metres (and coordinates) to
/// 1 cm; a unit vector ×1000; not hashed.
const int _qInt = 0, _qM = 1, _qUnit = 2, _qSkip = 3;

/// Families. [_fSite] has one row per site; [_fStart] S + 1 rows; the count
/// families as many rows as the site has; the CSR families ([_fSegVia],
/// [_fPaveRing], [_fPath]) one row more than their count family per site.
const int _fSite = 0,
    _fStart = 1,
    _fPt = 2,
    _fJoin = 3,
    _fNode = 4,
    _fSeg = 5,
    _fVia = 6,
    _fStall = 7,
    _fBay = 8,
    _fPave = 9,
    _fPavePt = 10,
    _fLamp = 11,
    _fPath = 12,
    _fPathPt = 13,
    _fFenceGap = 14,
    _fSegVia = 15,
    _fPaveRing = 16,
    _fPathStart = 17;

/// The count families, in the order of their start columns.
const List<int> _countFamilies = [
  _fPt, _fJoin, _fNode, _fSeg, _fVia, _fStall, _fBay, _fPave, _fPavePt, //
  _fLamp, _fPath, _fPathPt, _fFenceGap,
];

/// Column ids. The ORDER is the canonical hashing order (V12) and never
/// changes; new columns append.
abstract final class SiteCol {
  // site
  static const int rev = 0,
      flags = 1,
      graphStamp = 2,
      graphLot = 3,
      program = 4,
      frameE = 5,
      frameN = 6,
      frameUE = 7,
      frameUN = 8,
      envX0 = 9,
      envX1 = 10,
      envY0 = 11,
      envY1 = 12,
      envFrontInset = 13,
      gateX = 14,
      gateW = 15,
      truckTurnRadiusM = 16,
      entrancePt = 17,
      pavementPt = 18,
      entranceNode = 19;
  // family starts (S + 1 rows), in [_countFamilies] order
  static const int startBase = 20; // 20 .. 32
  // points
  static const int ptE = 33, ptN = 34, ptHRef = 35, ptHJoin = 36, ptHT = 37, ptDz = 38;
  // joins
  static const int joinSlot = 39,
      joinRight = 40,
      joinDirs = 41,
      joinRole = 42,
      joinKind = 43,
      joinRef = 44,
      joinPiece = 45,
      joinRoadNo = 46,
      joinRoadIdIdx = 47,
      joinKerbNode = 48,
      joinThroatSeg = 49,
      joinRoadS = 50,
      joinCutHalfM = 51;
  // nodes
  static const int nodePt = 52,
      nodeFlags = 53,
      nodeTurnKind = 54,
      nodeTurnR = 55,
      nodeTurnHx = 56,
      nodeTurnHn = 57;
  // segments
  static const int segFrom = 58,
      segTo = 59,
      segLenM = 60,
      segWidthM = 61,
      segSpeedMps = 62,
      segMaxVehLenM = 63,
      segKind = 64,
      segLaneMode = 65,
      segFlags = 66,
      segViaStart = 67,
      viaPt = 68;
  // stalls
  static const int stallSeg = 69,
      stallKey = 70,
      stallKeySorted = 71,
      stallKeyIdx = 72,
      stallS = 73,
      stallDirE = 74,
      stallDirN = 75,
      stallLenM = 76,
      stallWidthM = 77,
      stallE = 78,
      stallN = 79,
      stallSide = 80,
      stallAngle = 81,
      stallInDirs = 82,
      stallOutDirs = 83;
  // bays
  static const int bayE = 84,
      bayN = 85,
      bayDirE = 86,
      bayDirN = 87,
      bayLenM = 88,
      bayWidthM = 89,
      bayS = 90,
      baySeg = 91,
      baySide = 92,
      bayKind = 93;
  // paving, dressing, pedestrians
  static const int paveSurface = 94,
      paveClass = 95,
      paveStart = 96,
      pavePt = 97,
      lampPt = 98,
      pathStart = 99,
      pathPt = 100,
      fenceGapEdge = 101,
      fenceGapT0 = 102,
      fenceGapT1 = 103;

  static const int count = 104;
}

/// (family, type, quantisation) per column, in [SiteCol] order.
const List<int> _schema = [
  // site
  _fSite, _tI32, _qSkip, // rev
  _fSite, _tI32, _qInt, // flags
  _fSite, _tI32, _qSkip, // graphStamp
  _fSite, _tI32, _qSkip, // graphLot
  _fSite, _tU8, _qInt, // program
  _fSite, _tF64, _qM, // frameE
  _fSite, _tF64, _qM, // frameN
  _fSite, _tF32, _qUnit, // frameUE
  _fSite, _tF32, _qUnit, // frameUN
  _fSite, _tF32, _qM, // envX0
  _fSite, _tF32, _qM, // envX1
  _fSite, _tF32, _qM, // envY0
  _fSite, _tF32, _qM, // envY1
  _fSite, _tF32, _qM, // envFrontInset
  _fSite, _tF32, _qM, // gateX
  _fSite, _tF32, _qM, // gateW
  _fSite, _tF32, _qM, // truckTurnRadiusM
  _fSite, _tI32, _qInt, // entrancePt
  _fSite, _tI32, _qInt, // pavementPt
  _fSite, _tI32, _qInt, // entranceNode
  // starts (counts are hashed instead)
  _fStart, _tI32, _qSkip, _fStart, _tI32, _qSkip, _fStart, _tI32, _qSkip, //
  _fStart, _tI32, _qSkip, _fStart, _tI32, _qSkip, _fStart, _tI32, _qSkip, //
  _fStart, _tI32, _qSkip, _fStart, _tI32, _qSkip, _fStart, _tI32, _qSkip, //
  _fStart, _tI32, _qSkip, _fStart, _tI32, _qSkip, _fStart, _tI32, _qSkip, //
  _fStart, _tI32, _qSkip,
  // points
  _fPt, _tF64, _qM, _fPt, _tF64, _qM, _fPt, _tU8, _qInt, _fPt, _tU8, _qInt, //
  _fPt, _tF32, _qM, _fPt, _tF32, _qM,
  // joins
  _fJoin, _tU8, _qInt, // joinSlot
  _fJoin, _tU8, _qInt, // joinRight
  _fJoin, _tU8, _qInt, // joinDirs
  _fJoin, _tU8, _qInt, // joinRole
  _fJoin, _tU8, _qInt, // joinKind
  _fJoin, _tI32, _qSkip, // joinRef: resolved per graph
  _fJoin, _tI32, _qSkip, // joinPiece: resolved per graph
  _fJoin, _tI32, _qSkip, // joinRoadNo: diagnostic, per graph
  _fJoin, _tI32, _qSkip, // joinRoadIdIdx: reserved
  _fJoin, _tI32, _qInt, // joinKerbNode
  _fJoin, _tI32, _qInt, // joinThroatSeg
  _fJoin, _tF64, _qM, // joinRoadS
  _fJoin, _tF32, _qM, // joinCutHalfM
  // nodes
  _fNode, _tI32, _qInt, _fNode, _tU8, _qInt, _fNode, _tU8, _qInt, //
  _fNode, _tF32, _qM, _fNode, _tF32, _qUnit, _fNode, _tF32, _qUnit,
  // segments
  _fSeg, _tI32, _qInt, _fSeg, _tI32, _qInt, _fSeg, _tF64, _qM, //
  _fSeg, _tF32, _qM, _fSeg, _tF32, _qM, _fSeg, _tF32, _qM, //
  _fSeg, _tU8, _qInt, _fSeg, _tU8, _qInt, _fSeg, _tU8, _qInt, //
  _fSegVia, _tI32, _qInt, // segViaStart
  _fVia, _tI32, _qInt, // viaPt
  // stalls
  _fStall, _tI32, _qInt, // stallSeg
  _fStall, _tI32, _qInt, // stallKey
  _fStall, _tI32, _qInt, // stallKeySorted
  _fStall, _tI32, _qInt, // stallKeyIdx
  _fStall, _tF32, _qM, // stallS
  _fStall, _tF32, _qUnit, // stallDirE
  _fStall, _tF32, _qUnit, // stallDirN
  _fStall, _tF32, _qM, // stallLenM
  _fStall, _tF32, _qM, // stallWidthM
  _fStall, _tF64, _qM, // stallE
  _fStall, _tF64, _qM, // stallN
  _fStall, _tU8, _qInt, _fStall, _tU8, _qInt, _fStall, _tU8, _qInt, //
  _fStall, _tU8, _qInt,
  // bays
  _fBay, _tF64, _qM, _fBay, _tF64, _qM, _fBay, _tF32, _qUnit, //
  _fBay, _tF32, _qUnit, _fBay, _tF32, _qM, _fBay, _tF32, _qM, //
  _fBay, _tF32, _qM, _fBay, _tI32, _qInt, _fBay, _tU8, _qInt, //
  _fBay, _tU8, _qInt,
  // paving, dressing, pedestrians
  _fPave, _tU8, _qInt, _fPave, _tU8, _qInt, //
  _fPaveRing, _tI32, _qInt, // paveStart
  _fPavePt, _tI32, _qInt, // pavePt
  _fLamp, _tI32, _qInt, // lampPt
  _fPathStart, _tI32, _qInt, // pathStart
  _fPathPt, _tI32, _qInt, // pathPt
  _fFenceGap, _tI32, _qInt, _fFenceGap, _tF32, _qM, _fFenceGap, _tF32, _qM,
];

int _familyOf(int col) => _schema[col * 3];
int _typeOf(int col) => _schema[col * 3 + 1];
int _quantOf(int col) => _schema[col * 3 + 2];

/// The start column of count family [f].
int _startColOf(int f) => SiteCol.startBase + _countFamilies.indexOf(f);

/// The count family a CSR family extends by one row per site.
int _csrBaseFamily(int f) => switch (f) {
      _fSegVia => _fSeg,
      _fPaveRing => _fPave,
      _fPathStart => _fPath,
      _ => -1,
    };

/// Immutable packed columns for up to [kSitesPerChunk] sites (§2.3). See the
/// library comment for the layout. Built only by `PlanBuilder`.
class SiteAccessChunk {
  SiteAccessChunk.packed({
    required List<String> siteId,
    required Float64List f64,
    required Float32List f32,
    required Int32List i32,
    required Uint8List u8,
    required Int32List offsets,
  })  : _siteId = siteId,
        _f64 = f64,
        _f32 = f32,
        _i32 = i32,
        _u8 = u8,
        _off = offsets {
    if (siteId.length > kSitesPerChunk) {
      throw ArgumentError('a chunk holds at most $kSitesPerChunk sites');
    }
    if (offsets.length != SiteCol.count) {
      throw ArgumentError('offset table of ${offsets.length} columns');
    }
  }

  final List<String> _siteId;
  final Float64List _f64;
  final Float32List _f32;
  final Int32List _i32;
  final Uint8List _u8;
  final Int32List _off;

  /// Everything the chunk retains beyond itself: the five typed lists and
  /// the site id list (§3.10 heap bound; tests only).
  List<Object> get debugRetained => [_f64, _f32, _i32, _u8, _off, _siteId];

  /// Bytes of the five typed lists.
  int get byteLength =>
      _f64.lengthInBytes +
      _f32.lengthInBytes +
      _i32.lengthInBytes +
      _u8.lengthInBytes +
      _off.lengthInBytes;

  int get siteCount => _siteId.length;

  /// The site ids, as the caller's instances (no copies). Unmodifiable.
  List<String> get siteIds => _siteId;
  String siteId(int site) => _siteId[site];

  /// The view of site [site]. Allocates: sync and tests only.
  SiteAccessPlan plan(int site) => SiteAccessPlan._(this, site);

  /// The site whose id is [id], or −1. A linear scan: tests and sync only.
  int siteOf(String id) {
    for (var k = 0; k < _siteId.length; k++) {
      if (_siteId[k] == id) return k;
    }
    return -1;
  }

  // ---- typed reads ----------------------------------------------------------

  /// Column [col] at chunk-global row [row], by backing type.
  double f64(int col, int row) => _f64[_off[col] + row];
  double f32(int col, int row) => _f32[_off[col] + row];
  int i32(int col, int row) => _i32[_off[col] + row];
  int u8(int col, int row) => _u8[_off[col] + row];

  /// Chunk-global first row of count family [family] for [site].
  int _start(int family, int site) => _i32[_off[_startColOf(family)] + site];

  // ---- family starts (chunk-global rows) -----------------------------------

  int ptStart(int site) => _start(_fPt, site);
  int joinStart(int site) => _start(_fJoin, site);
  int nodeStart(int site) => _start(_fNode, site);
  int segStart(int site) => _start(_fSeg, site);
  int viaStart(int site) => _start(_fVia, site);
  int stallStart(int site) => _start(_fStall, site);
  int bayStart(int site) => _start(_fBay, site);
  int paveCountStart(int site) => _start(_fPave, site);
  int pavePtStart(int site) => _start(_fPavePt, site);
  int lampStart(int site) => _start(_fLamp, site);
  int pathCountStart(int site) => _start(_fPath, site);
  int pathPtStart(int site) => _start(_fPathPt, site);
  int fenceGapStart(int site) => _start(_fFenceGap, site);

  /// First chunk-global row of the CSR columns `segViaStart`, `paveStart`
  /// and `pathStart` for [site]: their count family's start plus [site]
  /// (each site owns count + 1 rows).
  int segViaRow(int site) => segStart(site) + site;
  int paveRingRow(int site) => paveCountStart(site) + site;
  int pathRow(int site) => pathCountStart(site) + site;

  int pointCountOf(int site) => ptStart(site + 1) - ptStart(site);
  int joinCountOf(int site) => joinStart(site + 1) - joinStart(site);
  int nodeCountOf(int site) => nodeStart(site + 1) - nodeStart(site);
  int segCountOf(int site) => segStart(site + 1) - segStart(site);
  int stallCountOf(int site) => stallStart(site + 1) - stallStart(site);
  int bayCountOf(int site) => bayStart(site + 1) - bayStart(site);

  // ---- site columns (row = site) -------------------------------------------

  int rev(int site) => i32(SiteCol.rev, site);
  int flags(int site) => i32(SiteCol.flags, site);
  int graphStamp(int site) => i32(SiteCol.graphStamp, site);
  int graphLot(int site) => i32(SiteCol.graphLot, site);
  SiteProgram program(int site) =>
      SiteProgram.values[u8(SiteCol.program, site)];
  double frameE(int site) => f64(SiteCol.frameE, site);
  double frameN(int site) => f64(SiteCol.frameN, site);
  double frameUE(int site) => f32(SiteCol.frameUE, site);
  double frameUN(int site) => f32(SiteCol.frameUN, site);
  double envX0(int site) => f32(SiteCol.envX0, site);
  double envX1(int site) => f32(SiteCol.envX1, site);
  double envY0(int site) => f32(SiteCol.envY0, site);
  double envY1(int site) => f32(SiteCol.envY1, site);
  double envFrontInset(int site) => f32(SiteCol.envFrontInset, site);
  double gateX(int site) => f32(SiteCol.gateX, site);
  double gateW(int site) => f32(SiteCol.gateW, site);
  double truckTurnRadiusM(int site) => f32(SiteCol.truckTurnRadiusM, site);

  /// Plan-local point / node indices.
  int entrancePt(int site) => i32(SiteCol.entrancePt, site);
  int pavementPt(int site) => i32(SiteCol.pavementPt, site);
  int entranceNode(int site) => i32(SiteCol.entranceNode, site);

  // ---- family columns (chunk-global rows) ----------------------------------

  double ptE(int row) => f64(SiteCol.ptE, row);
  double ptN(int row) => f64(SiteCol.ptN, row);
  SiteHeightRef ptHRef(int row) => SiteHeightRef.values[u8(SiteCol.ptHRef, row)];
  int ptHJoin(int row) => u8(SiteCol.ptHJoin, row);
  double ptHT(int row) => f32(SiteCol.ptHT, row);
  double ptDz(int row) => f32(SiteCol.ptDz, row);

  int joinSlot(int row) => u8(SiteCol.joinSlot, row);
  bool joinRight(int row) => u8(SiteCol.joinRight, row) == 1;
  int joinDirs(int row) => u8(SiteCol.joinDirs, row);
  SiteJoinRole joinRole(int row) => SiteJoinRole.values[u8(SiteCol.joinRole, row)];
  SiteJoinKind joinKind(int row) => SiteJoinKind.values[u8(SiteCol.joinKind, row)];
  int joinRef(int row) => i32(SiteCol.joinRef, row);
  int joinPiece(int row) => i32(SiteCol.joinPiece, row);
  int joinRoadNo(int row) => i32(SiteCol.joinRoadNo, row);
  int joinRoadIdIdx(int row) => i32(SiteCol.joinRoadIdIdx, row);
  int joinKerbNode(int row) => i32(SiteCol.joinKerbNode, row);
  int joinThroatSeg(int row) => i32(SiteCol.joinThroatSeg, row);
  double joinRoadS(int row) => f64(SiteCol.joinRoadS, row);
  double joinCutHalfM(int row) => f32(SiteCol.joinCutHalfM, row);

  int nodePt(int row) => i32(SiteCol.nodePt, row);
  int nodeFlags(int row) => u8(SiteCol.nodeFlags, row);
  TurnaroundKind nodeTurnKind(int row) =>
      TurnaroundKind.values[u8(SiteCol.nodeTurnKind, row)];
  double nodeTurnR(int row) => f32(SiteCol.nodeTurnR, row);
  double nodeTurnHx(int row) => f32(SiteCol.nodeTurnHx, row);
  double nodeTurnHn(int row) => f32(SiteCol.nodeTurnHn, row);

  int segFrom(int row) => i32(SiteCol.segFrom, row);
  int segTo(int row) => i32(SiteCol.segTo, row);
  double segLenM(int row) => f64(SiteCol.segLenM, row);
  double segWidthM(int row) => f32(SiteCol.segWidthM, row);
  double segSpeedMps(int row) => f32(SiteCol.segSpeedMps, row);
  double segMaxVehLenM(int row) => f32(SiteCol.segMaxVehLenM, row);
  SiteSegmentKind segKind(int row) =>
      SiteSegmentKind.values[u8(SiteCol.segKind, row)];
  SiteLaneMode segLaneMode(int row) =>
      SiteLaneMode.values[u8(SiteCol.segLaneMode, row)];
  int segFlags(int row) => u8(SiteCol.segFlags, row);

  /// Row is [segViaRow] + plan-local segment (0 .. segCount inclusive); the
  /// value is a plan-local via index.
  int segViaStart(int row) => i32(SiteCol.segViaStart, row);

  /// Row is [viaStart] + plan-local via; the value is a plan-local point.
  int viaPt(int row) => i32(SiteCol.viaPt, row);

  int stallSeg(int row) => i32(SiteCol.stallSeg, row);
  int stallKey(int row) => i32(SiteCol.stallKey, row);
  int stallKeySorted(int row) => i32(SiteCol.stallKeySorted, row);
  int stallKeyIdx(int row) => i32(SiteCol.stallKeyIdx, row);
  double stallS(int row) => f32(SiteCol.stallS, row);
  double stallDirE(int row) => f32(SiteCol.stallDirE, row);
  double stallDirN(int row) => f32(SiteCol.stallDirN, row);
  double stallLenM(int row) => f32(SiteCol.stallLenM, row);
  double stallWidthM(int row) => f32(SiteCol.stallWidthM, row);
  double stallE(int row) => f64(SiteCol.stallE, row);
  double stallN(int row) => f64(SiteCol.stallN, row);
  int stallSide(int row) => u8(SiteCol.stallSide, row);
  StallAngle stallAngle(int row) => StallAngle.values[u8(SiteCol.stallAngle, row)];
  int stallInDirs(int row) => u8(SiteCol.stallInDirs, row);
  int stallOutDirs(int row) => u8(SiteCol.stallOutDirs, row);

  double bayE(int row) => f64(SiteCol.bayE, row);
  double bayN(int row) => f64(SiteCol.bayN, row);
  double bayDirE(int row) => f32(SiteCol.bayDirE, row);
  double bayDirN(int row) => f32(SiteCol.bayDirN, row);
  double bayLenM(int row) => f32(SiteCol.bayLenM, row);
  double bayWidthM(int row) => f32(SiteCol.bayWidthM, row);
  double bayS(int row) => f32(SiteCol.bayS, row);
  int baySeg(int row) => i32(SiteCol.baySeg, row);
  int baySide(int row) => u8(SiteCol.baySide, row);
  BayKind bayKind(int row) => BayKind.values[u8(SiteCol.bayKind, row)];

  PaveSurface paveSurface(int row) =>
      PaveSurface.values[u8(SiteCol.paveSurface, row)];
  int paveClass(int row) => u8(SiteCol.paveClass, row);
  int paveStart(int row) => i32(SiteCol.paveStart, row);
  int pavePt(int row) => i32(SiteCol.pavePt, row);
  int lampPt(int row) => i32(SiteCol.lampPt, row);
  int pathStart(int row) => i32(SiteCol.pathStart, row);
  int pathPt(int row) => i32(SiteCol.pathPt, row);
  int fenceGapEdge(int row) => i32(SiteCol.fenceGapEdge, row);
  double fenceGapT0(int row) => f32(SiteCol.fenceGapT0, row);
  double fenceGapT1(int row) => f32(SiteCol.fenceGapT1, row);

  // ---- revision (V12) -------------------------------------------------------

  /// `rev` of [site] recomputed from its columns: `fnv1a32` over every
  /// hashed column in [SiteCol] order (coordinates and metres at 1 cm, unit
  /// vectors ×1000), preceded by the site's family counts; the site id, the
  /// graph resolution (`graphStamp`, `graphLot`, `joinRef`, `joinPiece`,
  /// `joinRoadNo`, `joinRoadIdIdx`) and `rev` itself excluded. Never 0.
  int revisionOf(int site) {
    var h = kFnvOffset32;
    for (final f in _countFamilies) {
      h = fnv1aU32(h, _start(f, site + 1) - _start(f, site));
    }
    for (var col = 0; col < SiteCol.count; col++) {
      final q = _quantOf(col);
      if (q == _qSkip) continue;
      final (row0, rows) = rowsOf(col, site);
      final base = _off[col];
      for (var r = row0; r < row0 + rows; r++) {
        switch (_typeOf(col)) {
          case _tF64:
            h = fnv1aU32(h, _quantised(_f64[base + r], q));
          case _tF32:
            h = fnv1aU32(h, _quantised(_f32[base + r], q));
          case _tI32:
            h = fnv1aU32(h, _i32[base + r]);
          default:
            h = fnv1aByte(h, _u8[base + r]);
        }
      }
    }
    return h == 0 ? 1 : h.toSigned(32);
  }

  /// The chunk-global first row and row count of column [col] for [site].
  (int, int) rowsOf(int col, int site) {
    final f = _familyOf(col);
    switch (f) {
      case _fSite:
        return (site, 1);
      case _fStart:
        return (site, 2);
      case _fSegVia:
      case _fPaveRing:
      case _fPathStart:
        final b = _csrBaseFamily(f);
        final s0 = _start(b, site);
        return (s0 + site, _start(b, site + 1) - s0 + 1);
      default:
        final s0 = _start(f, site);
        return (s0, _start(f, site + 1) - s0);
    }
  }

  static int _quantised(double x, int q) {
    if (!x.isFinite) return 0x7FFFFFFF;
    return (x * (q == _qUnit ? kRevUnitScale : kRevMetresScale)).round();
  }
}

/// Cheap view over one site's rows, with plan-local indices (§2.3).
/// Allocated only at sync time and in tests, never per frame.
class SiteAccessPlan {
  SiteAccessPlan._(this.chunk, this.site)
      : _pt = chunk.ptStart(site),
        _join = chunk.joinStart(site),
        _node = chunk.nodeStart(site),
        _seg = chunk.segStart(site),
        _via = chunk.viaStart(site),
        _stall = chunk.stallStart(site),
        _bay = chunk.bayStart(site),
        _pave = chunk.paveCountStart(site),
        _pavePt = chunk.pavePtStart(site),
        _lamp = chunk.lampStart(site),
        _path = chunk.pathCountStart(site),
        _pathPt = chunk.pathPtStart(site),
        _fence = chunk.fenceGapStart(site),
        pointCount = chunk.pointCountOf(site),
        joinCount = chunk.joinCountOf(site),
        nodeCount = chunk.nodeCountOf(site),
        segCount = chunk.segCountOf(site),
        viaCount = chunk.viaStart(site + 1) - chunk.viaStart(site),
        stallCount = chunk.stallCountOf(site),
        bayCount = chunk.bayCountOf(site),
        paveCount = chunk.paveCountStart(site + 1) - chunk.paveCountStart(site),
        lampCount = chunk.lampStart(site + 1) - chunk.lampStart(site),
        pathCount = chunk.pathCountStart(site + 1) - chunk.pathCountStart(site),
        fenceGapCount = chunk.fenceGapStart(site + 1) - chunk.fenceGapStart(site);

  final SiteAccessChunk chunk;
  final int site;

  final int _pt, _join, _node, _seg, _via, _stall, _bay, _pave, _pavePt, _lamp,
      _path, _pathPt, _fence;

  final int pointCount,
      joinCount,
      nodeCount,
      segCount,
      viaCount,
      stallCount,
      bayCount,
      paveCount,
      lampCount,
      pathCount,
      fenceGapCount;

  String get siteId => chunk.siteId(site);
  int get rev => chunk.rev(site);
  SiteProgram get program => chunk.program(site);

  /// `kPlan*` bits.
  int get flags => chunk.flags(site);
  int get graphStamp => chunk.graphStamp(site);
  int get graphLot => chunk.graphLot(site);

  /// Stalls are the capacity (ask 10).
  int get capacity => stallCount;

  bool get hasNetwork => flags & kPlanNetwork != 0;
  bool get admitsTrucks => flags & kPlanAdmitsTrucks != 0;

  // frame and envelope
  double get frameE => chunk.frameE(site);
  double get frameN => chunk.frameN(site);
  double get frameUE => chunk.frameUE(site);
  double get frameUN => chunk.frameUN(site);

  /// The frame's `v` (into the lot): `u` turned a quarter counter-clockwise.
  double get frameVE => -frameUN;
  double get frameVN => frameUE;
  double get envX0 => chunk.envX0(site);
  double get envX1 => chunk.envX1(site);
  double get envY0 => chunk.envY0(site);
  double get envY1 => chunk.envY1(site);
  double get envFrontInset => chunk.envFrontInset(site);
  double get gateX => chunk.gateX(site);
  double get gateW => chunk.gateW(site);
  double get truckTurnRadiusM => chunk.truckTurnRadiusM(site);
  int get entrancePt => chunk.entrancePt(site);
  int get pavementPt => chunk.pavementPt(site);
  int get entranceNode => chunk.entranceNode(site);

  // points
  double ptE(int p) => chunk.ptE(_pt + p);
  double ptN(int p) => chunk.ptN(_pt + p);
  SiteHeightRef ptHRef(int p) => chunk.ptHRef(_pt + p);
  int ptHJoin(int p) => chunk.ptHJoin(_pt + p);
  double ptHT(int p) => chunk.ptHT(_pt + p);
  double ptDz(int p) => chunk.ptDz(_pt + p);

  // joins (join 0 = slot 0)
  int joinSlot(int j) => chunk.joinSlot(_join + j);
  bool joinRight(int j) => chunk.joinRight(_join + j);
  int joinDirs(int j) => chunk.joinDirs(_join + j);
  SiteJoinRole joinRole(int j) => chunk.joinRole(_join + j);
  SiteJoinKind joinKind(int j) => chunk.joinKind(_join + j);
  int joinRef(int j) => chunk.joinRef(_join + j);
  int joinPiece(int j) => chunk.joinPiece(_join + j);
  int joinRoadNo(int j) => chunk.joinRoadNo(_join + j);
  int joinRoadIdIdx(int j) => chunk.joinRoadIdIdx(_join + j);
  int joinKerbNode(int j) => chunk.joinKerbNode(_join + j);
  int joinThroatSeg(int j) => chunk.joinThroatSeg(_join + j);
  double joinRoadS(int j) => chunk.joinRoadS(_join + j);
  double joinCutHalfM(int j) => chunk.joinCutHalfM(_join + j);
  bool joinIsCut(int j) => joinKind(j) == SiteJoinKind.cut;
  bool joinCanIn(int j) => joinRole(j) != SiteJoinRole.outOnly;
  bool joinCanOut(int j) => joinRole(j) != SiteJoinRole.inOnly;

  /// The kerb point of join [j] (its kerb node's point); NaN for a join with
  /// no kerb node.
  double joinKerbE(int j) {
    final k = joinKerbNode(j);
    return k < 0 ? double.nan : nodeE(k);
  }

  double joinKerbN(int j) {
    final k = joinKerbNode(j);
    return k < 0 ? double.nan : nodeN(k);
  }

  // nodes
  int nodePt(int n) => chunk.nodePt(_node + n);
  double nodeE(int n) => ptE(nodePt(n));
  double nodeN(int n) => ptN(nodePt(n));
  int nodeFlags(int n) => chunk.nodeFlags(_node + n);
  TurnaroundKind nodeTurnKind(int n) => chunk.nodeTurnKind(_node + n);
  double nodeTurnR(int n) => chunk.nodeTurnR(_node + n);
  double nodeTurnHx(int n) => chunk.nodeTurnHx(_node + n);
  double nodeTurnHn(int n) => chunk.nodeTurnHn(_node + n);

  // segments: polyline = nodePt[from], vias, nodePt[to]
  int segFrom(int k) => chunk.segFrom(_seg + k);
  int segTo(int k) => chunk.segTo(_seg + k);
  double segLenM(int k) => chunk.segLenM(_seg + k);
  double segWidthM(int k) => chunk.segWidthM(_seg + k);
  double segSpeedMps(int k) => chunk.segSpeedMps(_seg + k);
  double segMaxVehLenM(int k) => chunk.segMaxVehLenM(_seg + k);
  SiteSegmentKind segKind(int k) => chunk.segKind(_seg + k);
  SiteLaneMode segLaneMode(int k) => chunk.segLaneMode(_seg + k);
  int segFlags(int k) => chunk.segFlags(_seg + k);

  /// Vias of segment k are vias `segViaStart(k) .. segViaStart(k + 1) − 1`
  /// (`k` in 0 .. segCount).
  int segViaStart(int k) => chunk.segViaStart(_seg + site + k);
  int viaPt(int v) => chunk.viaPt(_via + v);
  int segViaCount(int k) => segViaStart(k + 1) - segViaStart(k);

  /// Points on segment k's polyline, ends included.
  int segPointCount(int k) => segViaCount(k) + 2;

  /// Plan-local point index of polyline point [i] of segment [k].
  int segPoint(int k, int i) {
    if (i == 0) return nodePt(segFrom(k));
    final nv = segViaCount(k);
    if (i <= nv) return viaPt(segViaStart(k) + i - 1);
    return nodePt(segTo(k));
  }

  // stalls: ordered by (seg, s, side); index = position
  int stallSeg(int i) => chunk.stallSeg(_stall + i);
  int stallKey(int i) => chunk.stallKey(_stall + i);
  int stallKeySorted(int i) => chunk.stallKeySorted(_stall + i);
  int stallKeyIdx(int i) => chunk.stallKeyIdx(_stall + i);
  double stallS(int i) => chunk.stallS(_stall + i);
  double stallDirE(int i) => chunk.stallDirE(_stall + i);
  double stallDirN(int i) => chunk.stallDirN(_stall + i);
  double stallLenM(int i) => chunk.stallLenM(_stall + i);
  double stallWidthM(int i) => chunk.stallWidthM(_stall + i);
  double stallE(int i) => chunk.stallE(_stall + i);
  double stallN(int i) => chunk.stallN(_stall + i);
  int stallSide(int i) => chunk.stallSide(_stall + i);
  StallAngle stallAngle(int i) => chunk.stallAngle(_stall + i);
  int stallInDirs(int i) => chunk.stallInDirs(_stall + i);
  int stallOutDirs(int i) => chunk.stallOutDirs(_stall + i);

  /// The stall whose key is [key] (either sign convention), or −1 when gone.
  /// A binary search of `stallKeySorted`.
  int stallIndexOfKey(int key) {
    final k = key.toSigned(32);
    var lo = 0, hi = stallCount - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final v = stallKeySorted(mid);
      if (v < k) {
        lo = mid + 1;
      } else if (v > k) {
        hi = mid - 1;
      } else {
        return stallKeyIdx(mid);
      }
    }
    return -1;
  }

  // bays
  double bayE(int b) => chunk.bayE(_bay + b);
  double bayN(int b) => chunk.bayN(_bay + b);
  double bayDirE(int b) => chunk.bayDirE(_bay + b);
  double bayDirN(int b) => chunk.bayDirN(_bay + b);
  double bayLenM(int b) => chunk.bayLenM(_bay + b);
  double bayWidthM(int b) => chunk.bayWidthM(_bay + b);
  double bayS(int b) => chunk.bayS(_bay + b);
  int baySeg(int b) => chunk.baySeg(_bay + b);
  int baySide(int b) => chunk.baySide(_bay + b);
  BayKind bayKind(int b) => chunk.bayKind(_bay + b);

  // paving, dressing, pedestrians
  PaveSurface paveSurface(int p) => chunk.paveSurface(_pave + p);
  int paveClass(int p) => chunk.paveClass(_pave + p);

  /// Ring of pave p: pave points `paveStart(p) .. paveStart(p + 1) − 1`.
  int paveStart(int p) => chunk.paveStart(_pave + site + p);

  /// Plan-local point of pave point [i].
  int pavePt(int i) => chunk.pavePt(_pavePt + i);
  int lampPt(int l) => chunk.lampPt(_lamp + l);

  /// Path q: path points `pathStart(q) .. pathStart(q + 1) − 1`.
  int pathStart(int q) => chunk.pathStart(_path + site + q);
  int pathPt(int i) => chunk.pathPt(_pathPt + i);
  int fenceGapEdge(int g) => chunk.fenceGapEdge(_fence + g);
  double fenceGapT0(int g) => chunk.fenceGapT0(_fence + g);
  double fenceGapT1(int g) => chunk.fenceGapT1(_fence + g);
}

/// Internal to the builder: layout facts it packs by.
abstract final class SiteChunkLayout {
  static int familyOf(int col) => _familyOf(col);
  static int typeOf(int col) => _typeOf(col);
  static int startColOf(int family) => _startColOf(family);
  static int csrBaseFamily(int family) => _csrBaseFamily(family);
  static List<int> get countFamilies => _countFamilies;
  static const int tF64 = _tF64, tF32 = _tF32, tI32 = _tI32, tU8 = _tU8;
  static const int fSite = _fSite,
      fStart = _fStart,
      fPt = _fPt,
      fJoin = _fJoin,
      fNode = _fNode,
      fSeg = _fSeg,
      fVia = _fVia,
      fStall = _fStall,
      fBay = _fBay,
      fPave = _fPave,
      fPavePt = _fPavePt,
      fLamp = _fLamp,
      fPath = _fPath,
      fPathPt = _fPathPt,
      fFenceGap = _fFenceGap,
      fSegVia = _fSegVia,
      fPaveRing = _fPaveRing,
      fPathStart = _fPathStart;
}
