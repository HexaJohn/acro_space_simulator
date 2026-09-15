// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Car parks and yards (docs/plans/site-access.md §3.5, §3.6).
///
/// Everything is axis-aligned in the site frame (x along the frontage, y into
/// the lot). A car park is a throat from slot 0's kerb point straight along
/// the frame's `v` (so V5's "within 10° of the road normal" is the slot's
/// skew, checked up front), then a block of `m` modules:
///
/// - **F1 front:** aisles along x, the block at the frontage, the envelope
///   behind it. The throat meets the first aisle in a T at `J`.
/// - **F2 rear:** aisles along x, the block at the back, the throat a side
///   drive to the front-most aisle, the envelope in front beside the drive.
/// - **F3 side:** aisles along y, the throat continuing straight into the
///   first aisle, the modules toward the side with more room.
///
/// `m = 1` blocks end in V7(b) T ends (F1/F2 arms longer than 8.6 m; shorter
/// arms are cut to an L); `m ≥ 2` blocks are joined by cross aisles (F1/F2 at
/// both ends, F3 at the rear, whose other aisles' front ends are T ends).
/// Every candidate is scored by §3.5's formula and the best with a stall wins
/// (scores within 1 % tie, broken by `SiteContext.tieBreak(family)`).
///
/// A yard (§3.6, as built) is a 7 m truck spine carrying side stall rows,
/// then an apron turning across its end to a 12.5 m circle, with two
/// 3.5 × 15 m loading bays facing the envelope's rear face (see `_yard`).
///
/// Generation is branch and bound: a candidate whose best possible score
/// (stalls up to the cap, the lot's free area less its block, its drive)
/// cannot reach the 1 % tie band of the best so far is dropped before its
/// envelope search, or while its stalls pack past the cap. The winner is the
/// exhaustive enumeration's ([carParkCandidatesOf] lists every candidate).
///
/// Reads only the [SiteContext] (frame, profile, slot 0, spec, seed) and the
/// §3.5/§3.6 constants. Determinism (§3.9): no platform hash, draw, clock, map
/// iteration or trigonometry; stall keys come from lattice integers (row index
/// from the block's own origin, bay index from the aisle segment's start).
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../parcel.dart';
import 'site_access_constants.dart';
import 'site_access_plan.dart';
import 'site_envelope.dart';
import 'site_frame.dart';
import 'site_plan_builder.dart';
import 'site_plan_generator.dart';
import 'site_program.dart';

/// §3.5's families, plus the §3.6 yard spine. The name seeds the tie-break.
enum CarParkFamily { front, rear, side, yard }

/// Margin kept inside cos 10° when the throat is laid along the frame's `v`:
/// the validator measures the road normal from the road polyline, the slot
/// from its own sample. (Private: `site_access_constants.dart` is core's.)
const double _kSkewMarginCos = 2e-3;

/// A stall is kept this far inside a bound the validator tests on Float32
/// rows (the T end's stall-free tail).
const double _kF32SlackM = 1e-3;

/// Bay-index base of the aisle segment that ends at `J` (left of the throat
/// on a ring's first aisle), so its lattice never meets the segment leaving
/// `J`'s.
const int _kBayBaseBeforeJ = 4096;

/// The yard's loading bays sit this far apart edge to edge, centred on the
/// apron segment.
const double _kYardBayGapM = 1.0;

/// One scored §3.5 candidate, kept or rejected (tests and the audit read
/// these; generation keeps only the winner).
class CarParkCandidate {
  CarParkCandidate._(this.family, this.modules, this.singleLast, this._plan,
      this.stallCount, this.envelope, this.score, this.driveLengthM,
      this.rejection);

  final CarParkFamily family;

  /// `m`, and whether the module nearest the building is single-loaded (a
  /// yard: whether its spine carries a stall row on the far side only).
  final int modules;
  final bool singleLast;

  final _Draft? _plan;

  /// Stalls packed (0 when rejected before packing).
  final int stallCount;

  /// The free rectangle the envelope rule found (null when none).
  final SiteRect? envelope;

  /// §3.5's score; null when rejected.
  final double? score;

  /// Σ segment lengths.
  final double driveLengthM;

  /// Why the candidate was rejected; null when it is valid.
  final String? rejection;

  bool get valid => rejection == null;

  @override
  String toString() => '${family.name} m$modules ${singleLast ? 'single' : 'double'}: '
      '$stallCount stalls, env $envelope, score $score'
      '${rejection == null ? '' : ' REJECTED $rejection'}';
}

/// A finished car park or yard plan (§3.5, §3.6), ready to write.
class CarParkPlan implements SiteGeneratedPlan {
  CarParkPlan._(this.program, this.winner, this.envelope);

  @override
  final SiteProgram program;

  /// The candidate that won.
  final CarParkCandidate winner;

  /// The envelope, frame metres.
  final SiteEnvelope envelope;

  CarParkFamily get family => winner.family;
  int get stallCount => winner.stallCount;
  int get bayCount => winner._plan!.bays.length ~/ _Draft.bayStride;
  bool get admitsTrucks => winner._plan!.trucks;

  @override
  void emit(PlanBuilder b, SiteContext ctx, int dispatchFlags) =>
      winner._plan!.emit(b, ctx, program, dispatchFlags, envelope);
}

/// §3.5: the best car park on [ctx] (families F1–F3, `m` modules, the
/// score), or null when no candidate has a stall and meets the minimums
/// (throat width, envelope ≥ 8 × 8 m and `A_min`).
CarParkPlan? carParkPlanOf(SiteContext ctx) {
  final s = _Site.of(ctx, truck: false);
  if (s == null) return null;
  final best = _best(ctx, _carParkCandidates(s, prune: true));
  return best == null
      ? null
      : CarParkPlan._(SiteProgram.carPark, best,
          SiteEnvelope(best.envelope!.x0, best.envelope!.y0,
              best.envelope!.x1, best.envelope!.y1));
}

/// §3.6: a car park plus a truck apron (circle 12.5 m, two 3.5 × 15 m bays,
/// `kPlanAdmitsTrucks`) on [ctx], its `program` `yard`.
///
/// Where the apron does not fit (or slot 0's room gives no 7 m throat), the
/// car park alone: a plan whose `program` is `carPark` (trucks not admitted);
/// the dispatcher counts `yardNoFit` and writes it with `kPlanFallback`. Null
/// EXACTLY when neither a yard nor a car park fits: this function owns the
/// car park attempt.
CarParkPlan? yardPlanOf(SiteContext ctx) {
  final s = _Site.of(ctx, truck: true);
  if (s != null) {
    final best = _best(ctx, _yardCandidates(s, prune: true));
    if (best != null) {
      return CarParkPlan._(SiteProgram.yard, best,
          SiteEnvelope(best.envelope!.x0, best.envelope!.y0,
              best.envelope!.x1, best.envelope!.y1));
    }
  }
  return carParkPlanOf(ctx);
}

/// Every §3.5 car park candidate of [ctx], in enumeration order, kept or
/// rejected (tests pin the §3.5 worked example with it). Empty when the slot
/// or frame admits no car park at all.
List<CarParkCandidate> carParkCandidatesOf(SiteContext ctx) {
  final s = _Site.of(ctx, truck: false);
  return s == null ? const [] : _carParkCandidates(s);
}

/// Every §3.6 yard candidate of [ctx] (empty when slot 0 has no 7 m throat).
List<CarParkCandidate> yardCandidatesOf(SiteContext ctx) {
  final s = _Site.of(ctx, truck: true);
  return s == null ? const [] : _yardCandidates(s);
}

// ---- selection ---------------------------------------------------------------

CarParkCandidate? _best(SiteContext ctx, List<CarParkCandidate> all) {
  var top = double.negativeInfinity;
  for (final c in all) {
    if (c.valid && c.score! > top) top = c.score!;
  }
  if (top == double.negativeInfinity) return null;
  final floor = top - kScoreTieFraction * top.abs();
  CarParkCandidate? pick;
  var pickKey = 0;
  for (final c in all) {
    if (!c.valid || c.score! < floor) continue;
    final key = ctx.tieBreak(c.family.name);
    if (pick == null ||
        key > pickKey ||
        (key == pickKey && c.score! > pick.score!)) {
      pick = c;
      pickKey = key;
    }
  }
  return pick;
}

List<CarParkCandidate> _carParkCandidates(_Site s, {bool prune = false}) {
  s.prune = prune;
  final out = <CarParkCandidate>[];
  for (final fam in const [
    CarParkFamily.front,
    CarParkFamily.rear,
    CarParkFamily.side,
  ]) {
    for (var m = 1; m <= kMaxModules; m++) {
      var fitted = false;
      for (final single in const [false, true]) {
        final c = fam == CarParkFamily.side
            ? _alongY(s, m, single)
            : _alongX(s, fam, m, single);
        out.add(c);
        if (c.rejection != _kNoBlock) fitted = true;
      }
      if (!fitted) break;
    }
  }
  return out;
}

List<CarParkCandidate> _yardCandidates(_Site s, {bool prune = false}) {
  s.prune = prune;
  final out = <CarParkCandidate>[];
  final ys = _yardApronYs(s);
  for (final bothSides in const [false, true]) {
    if (ys.isEmpty) {
      out.add(_rejected(CarParkFamily.yard, 1, !bothSides, _kNoBlock));
      continue;
    }
    for (final yA in ys) {
      out.add(_yard(s, yA, bothSides));
    }
  }
  return out;
}

const String _kNoBlock = 'block does not fit';
const String _kDominated = 'dominated by a better candidate';

CarParkCandidate _rejected(
        CarParkFamily fam, int m, bool single, String why,
        {_Draft? plan, SiteRect? env, int stalls = 0, double drive = 0}) =>
    CarParkCandidate._(fam, m, single, plan, stalls, env, null, drive, why);

// ---- the site ----------------------------------------------------------------

/// One site's packing inputs, derived once per generator call.
class _Site {
  _Site._(this.ctx, this.frame, this.throatW, this.throatMode, this.truck,
      this.xJ, this.k, this.yT, this.lotLo, this.lotHi, this.depths, this.cap,
      this.aMin, this.maxStalls);

  /// [truck]: the yard spine (a 7 m two-way throat, room ≥ 4.5); else a car
  /// park throat (§3.3: 6 m two-way, or 3.0–5.5 m `sharedSingle` with at
  /// most 8 stalls).
  static _Site? of(SiteContext ctx, {required bool truck}) {
    final f = ctx.frame;
    final spec = ctx.spec;
    if (f == null || spec == null || ctx.slotCount == 0) return null;
    final slot = ctx.slot0;
    if (slot.flags & kJoinCut == 0) return null;
    final programW = truck ? kYardThroatWidthM : kCarParkThroatWidthM;
    final tw = math.min(programW, 2 * (slot.roomM - kCutFlareM));
    SiteLaneMode mode;
    var maxStalls = kMaxPlanStalls;
    if (truck) {
      if (tw < kYardThroatWidthM - kGenEpsM) return null;
      mode = SiteLaneMode.twoWay;
    } else if (tw >= kCarParkThroatMinTwoWayM - kGenEpsM) {
      mode = SiteLaneMode.twoWay;
    } else if (tw >= kCarParkSharedSingleThroatM - kGenEpsM) {
      mode = SiteLaneMode.sharedSingle;
      maxStalls = kCarParkSharedSingleMaxStalls;
    } else {
      return null;
    }
    // The throat runs along v: V5 needs v within 10° of the road normal.
    if (slot.normE * f.v.e + slot.normN * f.v.n < kCos10 + _kSkewMarginCos) {
      return null;
    }
    final kl = f.toLocal(Vec2(slot.kerbE, slot.kerbN));
    final k = -kl.n;
    var lo = double.infinity, hi = double.negativeInfinity;
    for (final p in ctx.parcel.polygon) {
      final x = f.toLocal(p).e;
      if (x < lo) lo = x;
      if (x > hi) hi = x;
    }
    if (!(hi > lo)) return null;
    final columns = math.max(1, ((hi - lo) / kDepthProfileStepM).ceil());
    final depths = Float64List(columns);
    for (var c = 0; c < columns; c++) {
      depths[c] = f.profile.depthAt(lo + (c + 0.5) * kDepthProfileStepM);
    }
    final program = truck ? SiteProgram.yard : SiteProgram.carPark;
    final cap = math.max(capacityScoreCap(spec),
        capacityTarget(program, spec).toDouble());
    return _Site._(ctx, f, tw, mode, truck, kl.e, k,
        math.max(0.0, kThroatMinM - k), lo, hi, depths, cap,
        minEnvelopeArea(spec), maxStalls);
  }

  final SiteContext ctx;
  final SiteFrame frame;
  final double throatW;
  final SiteLaneMode throatMode;
  final bool truck;

  /// Slot 0's kerb point in the frame: x_J, and k (kerb to frontage).
  final double xJ, k;

  /// `max(0, 7 − k)`: the nearest frame y the throat may end at.
  final double yT;

  /// The polygon's frame x extent: the depth profile's column grid.
  final double lotLo, lotHi;
  final Float64List depths;

  /// §3.5's score cap and the §3.3 minimum envelope.
  final double cap;
  final double aMin;
  final int maxStalls;

  DepthProfile get profile => frame.profile;
  double get widthM => frame.widthM;

  /// Branch and bound over the candidates (generation only; the candidate
  /// lists tests read are not pruned): the best valid score so far.
  bool prune = false;
  double best = double.negativeInfinity;

  /// Whether a candidate whose score cannot exceed [upperBound] can no longer
  /// win or tie (§3.5's 1 % band only rises with the best score).
  bool dominated(double upperBound) =>
      prune &&
      best > double.negativeInfinity &&
      upperBound < best - kScoreTieFraction * best.abs() - kGenEpsM;

  /// §3.5's score at most for a block of [blockArea] m², a drive of [drive]
  /// m and at most [atMost] stalls, before anything is drawn.
  double boundOf(double blockArea, double drive, double bias, int atMost) =>
      kScoreStall * math.min(atMost.toDouble(), cap) +
      kScoreEnvelopeArea * envelopeBound(blockArea) -
      kScoreDriveLength * drive +
      bias;

  /// The free area an envelope could have at most, less [blockArea].
  double envelopeBound(double blockArea) => math.max(0.0,
      (widthM - 2 * kSideSetbackM) * profile.maxDepthM - blockArea);

  /// The throat corridor half width, `throatW/2 + 1`.
  double get corridorHalf => throatW / 2 + kThroatCorridorClearM;

  int columnOf(double x) {
    final c = ((x - lotLo) / kDepthProfileStepM).floor();
    return c < 0 || c >= depths.length ? -1 : c;
  }

  /// The run of columns around [x] whose depth reaches [need], inset by the
  /// profile margin at both ends; null when [x]'s own column does not.
  (double, double)? runAt(double x, double need) {
    final c = columnOf(x);
    if (c < 0 || depths[c] < need - kGenEpsM) return null;
    var a = c, z = c;
    while (a > 0 && depths[a - 1] >= need - kGenEpsM) {
      a--;
    }
    while (z + 1 < depths.length && depths[z + 1] >= need - kGenEpsM) {
      z++;
    }
    final left = lotLo + a * kDepthProfileStepM;
    final right = math.min(lotLo + (z + 1) * kDepthProfileStepM, lotHi);
    return (left + kDepthProfileMarginM, right - kDepthProfileMarginM);
  }

  /// The shallowest column depth over `[x0, x1]`; 0 where any lies outside.
  double depthOverRange(double x0, double x1) {
    if (x0 < lotLo - kGenEpsM || x1 > lotHi + kGenEpsM) return 0;
    final a = columnOf(math.max(x0, lotLo) + 1e-9);
    final z = columnOf(math.min(x1, lotHi) - 1e-9);
    if (a < 0 || z < 0) return 0;
    var d = double.infinity;
    for (var c = a; c <= z; c++) {
      if (depths[c] < d) d = depths[c];
    }
    return d;
  }

  /// §6.1 step 2 exactly as `largestFreeRect` computes it (the same column
  /// grid from [xMin], the same fronts, histogram and tie rule, `yMin` the
  /// profile margin), with the grid's profile reads cached across every
  /// candidate of this site that asks for the same `[xMin, xMax]`.
  SiteRect? freeRect(
      List<SiteRect> blocked, double clearanceM, double xMin, double xMax) {
    const step = kDepthProfileStepM;
    const yMin = kDepthProfileMarginM;
    final lo = math.max(0.0, xMin);
    final hi = math.min(widthM, xMax);
    if (!(hi - lo >= step)) return null;
    final n = ((hi - lo) / step).floor();
    if (lo != _gridLo || hi != _gridHi) {
      _gridLo = lo;
      _gridHi = hi;
      _gridFar = Float64List(n);
      _heights = Float64List(n);
      _stack = Int32List(n + 1);
      for (var c = 0; c < n; c++) {
        final xa = lo + c * step, xb = xa + step;
        _gridFar[c] = math.min(
            profile.depthAt(xa + 1e-9), profile.depthAt(xb - 1e-9));
      }
    }
    final nb = blocked.length;
    final gx0 = Float64List(nb), gy0 = Float64List(nb);
    final gx1 = Float64List(nb), gy1 = Float64List(nb);
    final fronts = <double>[yMin];
    for (var i = 0; i < nb; i++) {
      final b = blocked[i];
      gx0[i] = b.x0 - clearanceM;
      gy0[i] = b.y0 - clearanceM;
      gx1[i] = b.x1 + clearanceM;
      gy1[i] = b.y1 + clearanceM;
      if (gy1[i] > yMin) fronts.add(gy1[i]);
    }
    fronts.sort();
    final heights = _heights, stack = _stack;
    SiteRect? best;
    var bestArea = 0.0;
    double? lastFront;
    for (final y0 in fronts) {
      if (lastFront != null && (y0 - lastFront).abs() <= kGenEpsM) continue;
      lastFront = y0;
      for (var c = 0; c < n; c++) {
        final xa = lo + c * step, xb = xa + step;
        var far = _gridFar[c];
        for (var i = 0; i < nb; i++) {
          if (gx1[i] <= xa || gx0[i] >= xb) continue;
          if (gy1[i] <= y0) continue;
          if (gy0[i] <= y0) {
            far = y0;
          } else if (gy0[i] < far) {
            far = gy0[i];
          }
        }
        heights[c] = math.max(0.0, far - y0);
      }
      var sp = 0;
      for (var c = 0; c <= n; c++) {
        final h = c == n ? -1.0 : heights[c];
        while (sp > 0 && heights[stack[sp - 1]] >= h) {
          final top = stack[--sp];
          final height = heights[top];
          final left = sp == 0 ? 0 : stack[sp - 1] + 1;
          final area = height * (c - left) * step;
          if (area > bestArea + 1e-9 && height > 0) {
            bestArea = area;
            best = SiteRect(lo + left * step, y0, lo + c * step, y0 + height);
          }
        }
        if (c < n) stack[sp++] = c;
      }
    }
    return best;
  }

  double _gridLo = double.nan, _gridHi = double.nan;
  Float64List _gridFar = Float64List(0);
  Float64List _heights = Float64List(0);
  Int32List _stack = Int32List(0);

  /// The side of x_J with more room (+1: larger x), ties by the seed.
  int get sideDir {
    final right = widthM - xJ, left = xJ;
    if ((right - left).abs() <= kGenEpsM) {
      return ctx.tieBreak('car-park-side') & 1 == 0 ? 1 : -1;
    }
    return right > left ? 1 : -1;
  }
}

// ---- the draft plan, frame metres ---------------------------------------------

/// A plan under construction, in frame metres. Node 0 is the kerb node `K`,
/// segment 0 the throat, pave 0 the throat's pave.
class _Draft {
  _Draft(this.site);

  final _Site site;
  bool trucks = false;

  // Nodes: x, y, flags, turn kind, turn radius, turn direction (frame).
  final List<double> nodes = [];
  final List<int> nodeInts = [];
  static const int nodeStride = 5; // x, y, r, dx, dy
  static const int nodeIntStride = 2; // flags, turn

  // Segments: from, to, kind, mode, flags / width, maxVeh.
  final List<int> segInts = [];
  final List<double> segDoubles = [];
  static const int segIntStride = 5;
  static const int segDoubleStride = 2;

  // Stalls: seg, side, row, bay, inDirs, outDirs / s, x, y, dx, dy.
  final List<int> stallInts = [];
  final List<double> stallDoubles = [];
  static const int stallIntStride = 6;
  static const int stallDoubleStride = 5;

  // Bays: seg, side / s, x, y, dx, dy.
  final List<double> bays = [];
  final List<int> bayInts = [];
  static const int bayStride = 5;

  final List<SiteRect> paves = [];

  /// The bound [preCheck] set up, and whether packing stopped because the
  /// stalls already packed past the score cap make the candidate lose.
  double boundBlockArea = 0;
  double boundBias = 0;
  bool abandoned = false;

  /// Bounding rectangles of packed stall runs (the §3.5 walk strip).
  final List<SiteRect> rows = [];
  final List<double> lamps = [];

  int get nodeCount => nodes.length ~/ nodeStride;
  int get segCount => segInts.length ~/ segIntStride;
  int get stallCount => stallInts.length ~/ stallIntStride;

  double nx(int n) => nodes[n * nodeStride];
  double ny(int n) => nodes[n * nodeStride + 1];

  int node(double x, double y,
      {int flags = 0,
      TurnaroundKind turn = TurnaroundKind.none,
      double r = 0,
      double dx = 0,
      double dy = 0}) {
    nodes.addAll([x, y, r, dx, dy]);
    nodeInts.addAll([flags, turn.index]);
    return nodeCount - 1;
  }

  int seg(int from, int to, SiteSegmentKind kind, SiteLaneMode mode,
      double widthM,
      {int flags = 0, double maxVehLenM = kSegMinVehLenM}) {
    segInts.addAll([from, to, kind.index, mode.index, flags]);
    segDoubles.addAll([widthM, maxVehLenM]);
    return segCount - 1;
  }

  double segLen(int k) {
    final a = segInts[k * segIntStride], b = segInts[k * segIntStride + 1];
    final dx = nx(b) - nx(a), dy = ny(b) - ny(a);
    return math.sqrt(dx * dx + dy * dy);
  }

  double get driveLengthM {
    var sum = 0.0;
    for (var k = 0; k < segCount; k++) {
      sum += segLen(k);
    }
    return sum;
  }

  /// Packs one perpendicular stall row beside segment [seg] (§3.5): from the
  /// segment start (frame [ax], [ay]) along the unit axis ([tx], [ty]), on the
  /// side of unit [ox], [oy], rectangles' extents along the segment inside
  /// `[lo, hi]` (segment metres), left-packed from [lo]. Bay `i` is the `i`th
  /// lattice place from [lo] (a dropped place keeps its number). A place is
  /// dropped when it has no run-up bit (V9) or fails `containsRect`.
  void pack({
    required int seg,
    required double ax,
    required double ay,
    required double tx,
    required double ty,
    required double ox,
    required double oy,
    required double len,
    required double lo,
    required double hi,
    required int row,
    int bayBase = 0,
    double halfAisleM = kAisleTwoWayWidthM / 2,
  }) {
    if (abandoned) return;
    const hw = kStallWidthM / 2;
    const hl = kStallLengthM / 2;
    var x0 = double.infinity, y0 = double.infinity;
    var x1 = double.negativeInfinity, y1 = double.negativeInfinity;
    // One exact test of the whole row band: a rectangle inside it is inside
    // the lot too, so only a band that fails tests its stalls one by one.
    final off = halfAisleM + hl;
    final bandLo = lo, bandHi = hi;
    var bandInside = false;
    if (bandHi > bandLo) {
      final ax0 = ax + tx * bandLo + ox * halfAisleM;
      final ay0 = ay + ty * bandLo + oy * halfAisleM;
      final ax1 = ax + tx * bandHi + ox * (halfAisleM + kStallLengthM);
      final ay1 = ay + ty * bandHi + oy * (halfAisleM + kStallLengthM);
      bandInside = site.profile.containsRect(SiteRect(math.min(ax0, ax1),
          math.min(ay0, ay1), math.max(ax0, ax1), math.max(ay0, ay1)));
    }
    for (var i = 0;; i++) {
      final sc = lo + hw + kStallWidthM * i;
      if (sc + hw > hi + 1e-9) break;
      if (stallCount >= site.maxStalls) break;
      if (sc < -1e-9) continue;
      var inDirs = 0;
      if (sc - kStallRunupHalfWidthM >= kStallRunupM - kGenEpsM) {
        inDirs |= kSiteDirFwd;
      }
      if (len - sc - kStallRunupHalfWidthM >= kStallRunupM - kGenEpsM) {
        inDirs |= kSiteDirBwd;
      }
      if (inDirs == 0) continue;
      final cx = ax + tx * sc + ox * off, cy = ay + ty * sc + oy * off;
      final ex = tx.abs() * hw + ox.abs() * hl;
      final ey = ty.abs() * hw + oy.abs() * hl;
      final rect = SiteRect(cx - ex, cy - ey, cx + ex, cy + ey);
      if (!bandInside && !site.profile.containsRect(rect)) continue;
      final side = ty * ox - tx * oy > 0 ? 0 : 1; // right of travel: side 0
      stallInts
        ..add(seg)
        ..add(side)
        ..add(row)
        ..add(bayBase + i)
        ..add(inDirs)
        ..add(kSiteDirFwd | kSiteDirBwd);
      stallDoubles
        ..add(sc)
        ..add(cx)
        ..add(cy)
        ..add(ox)
        ..add(oy);
      // Past the cap every stall costs score: stop once it cannot win.
      if (site.prune &&
          stallCount > site.cap &&
          stallCount % 8 == 0 &&
          site.dominated(upperBound(boundBlockArea, boundBias,
              stalls: stallCount))) {
        abandoned = true;
      }
      x0 = math.min(x0, rect.x0);
      y0 = math.min(y0, rect.y0);
      x1 = math.max(x1, rect.x1);
      y1 = math.max(y1, rect.y1);
      if (abandoned) break;
    }
    if (x1 > x0) rows.add(SiteRect(x0, y0, x1, y1));
  }

  void bay(int seg, int side, double s, double x, double y, double dx,
      double dy) {
    bays.addAll([s, x, y, dx, dy]);
    bayInts.addAll([seg, side]);
  }

  void lampsX(double x0, double x1, double y) {
    for (final (lx, ly) in lampsAlong(x0, x1, y)) {
      lamps.addAll([lx, ly]);
    }
  }

  void lampsY(double x, double y0, double y1) {
    for (var y = y0 + kLampStartM; y <= y1 + kGenEpsM; y += kLampPitchM) {
      lamps.addAll([x, y]);
    }
  }

  /// §3.5's score at most, for exactly [stalls] packed (or, before packing,
  /// at most [atMost]) and a block of [blockArea] m² the envelope cannot
  /// overlap.
  double upperBound(double blockArea, double bias,
      {int? stalls, int? atMost}) {
    final double stallTerm;
    if (stalls != null) {
      stallTerm = kScoreStall * math.min(stalls.toDouble(), site.cap) -
          kScoreOverflow * math.max(0.0, stalls - site.cap);
    } else {
      // The best any count up to atMost can score is at min(atMost, cap).
      stallTerm = kScoreStall * math.min((atMost ?? 1 << 20).toDouble(), site.cap);
    }
    return stallTerm +
        kScoreEnvelopeArea * site.envelopeBound(blockArea) -
        kScoreDriveLength * driveLengthM +
        bias;
  }

  /// Before packing: the block pave [block] inside the lot, and the
  /// candidate not dominated. Returns the rejection, or null to go on.
  CarParkCandidate? preCheck(CarParkFamily fam, int m, bool single,
      SiteRect block, double bias, int maxStalls) {
    if (!site.profile.containsRect(block)) {
      return _rejected(fam, m, single, 'block pave leaves the lot');
    }
    boundBlockArea = block.width * block.depth;
    boundBias = bias;
    if (site.dominated(upperBound(boundBlockArea, bias, atMost: maxStalls))) {
      return _rejected(fam, m, single, _kDominated, plan: this);
    }
    return null;
  }

  /// Flags branch nodes (site degree ≥ 3).
  void flagBranches() {
    final degree = Int32List(nodeCount);
    for (var k = 0; k < segCount; k++) {
      degree[segInts[k * segIntStride]]++;
      degree[segInts[k * segIntStride + 1]]++;
    }
    for (var n = 0; n < nodeCount; n++) {
      if (degree[n] >= 3) nodeInts[n * nodeIntStride] |= kNodeBranch;
    }
  }

  /// Scores the draft: the envelope rule, the door's entrance node, §3.5's
  /// score. [bias] is the family's.
  CarParkCandidate finish(CarParkFamily fam, int m, bool single,
      {double bias = 0,
      double envXMin = double.negativeInfinity,
      double envXMax = double.infinity,
      bool Function(SiteRect env)? envFaces}) {
    final s = site;
    final n = stallCount;
    final drive = driveLengthM;
    if (abandoned) {
      return _rejected(fam, m, single, _kDominated,
          plan: this, stalls: n, drive: drive);
    }
    if (n == 0) {
      return _rejected(fam, m, single, 'no stall', plan: this, drive: drive);
    }
    var biggest = 0.0;
    for (var q = 1; q < paves.length; q++) {
      biggest = math.max(biggest, paves[q].width * paves[q].depth);
    }
    if (s.dominated(upperBound(biggest, bias, stalls: n))) {
      return _rejected(fam, m, single, _kDominated,
          plan: this, stalls: n, drive: drive);
    }
    flagBranches();
    // The stall rows' union, grown by the walk strip beyond the 1 m every
    // pave keeps (one rectangle keeps the free-rectangle search cheap).
    var rx0 = double.infinity, ry0 = double.infinity;
    var rx1 = double.negativeInfinity, ry1 = double.negativeInfinity;
    for (final r in rows) {
      rx0 = math.min(rx0, r.x0);
      ry0 = math.min(ry0, r.y0);
      rx1 = math.max(rx1, r.x1);
      ry1 = math.max(ry1, r.y1);
    }
    const walk = kWalkStripM - kEnvelopeClearLotM;
    final blocked = <SiteRect>[
      ...paves,
      if (rows.isNotEmpty)
        SiteRect(rx0 - walk, ry0 - walk, rx1 + walk, ry1 + walk),
    ];
    final env = s.freeRect(blocked, kEnvelopeClearLotM,
        math.max(kSideSetbackM, envXMin),
        math.min(s.widthM - kSideSetbackM, envXMax));
    if (env == null) {
      return _rejected(fam, m, single, 'no envelope',
          plan: this, stalls: n, drive: drive);
    }
    if (env.width < kEnvelopeMinSideM - kGenEpsM ||
        env.depth < kEnvelopeMinSideM - kGenEpsM) {
      return _rejected(fam, m, single, 'envelope under 8 x 8 m',
          plan: this, env: env, stalls: n, drive: drive);
    }
    if (envFaces != null && !envFaces(env)) {
      return _rejected(fam, m, single, 'the bays face no envelope',
          plan: this, env: env, stalls: n, drive: drive);
    }
    final area = env.width * env.depth;
    if (area < s.aMin - kGenEpsM) {
      return _rejected(fam, m, single, 'envelope under A_min ${s.aMin}',
          plan: this, env: env, stalls: n, drive: drive);
    }
    if (entranceNode(env) < 0) {
      return _rejected(fam, m, single, 'door beyond V11 reach',
          plan: this, env: env, stalls: n, drive: drive);
    }
    final score = kScoreStall * math.min(n.toDouble(), s.cap) -
        kScoreOverflow * math.max(0.0, n - s.cap) +
        kScoreEnvelopeArea * area -
        kScoreDriveLength * drive +
        bias;
    if (score > s.best) s.best = score;
    return CarParkCandidate._(
        fam, m, single, this, n, env, score, drive, null);
  }

  /// The network node nearest the envelope's door (never the kerb node), or
  /// −1 when none lies within V11's reach.
  int entranceNode(SiteRect env) {
    final dx = (env.x0 + env.x1) / 2, dy = env.y0;
    var best = -1;
    var bestD = double.infinity;
    for (var i = 1; i < nodeCount; i++) {
      final ex = nx(i) - dx, ey = ny(i) - dy;
      final d = ex * ex + ey * ey;
      if (d < bestD) {
        bestD = d;
        best = i;
      }
    }
    final reach = kEntranceMaxM - 1e-3;
    return bestD <= reach * reach ? best : -1;
  }

  // ---- emission ----------------------------------------------------------------

  void emit(PlanBuilder b, SiteContext ctx, SiteProgram program, int flags,
      SiteEnvelope envelope) {
    final f = ctx.frame!;
    final slot = ctx.slot0;
    final ue = f.u.e, un = f.u.n, ve = f.v.e, vn = f.v.n;
    ctx.beginSite(
        b,
        program,
        flags | kPlanNetwork | (trucks ? kPlanAdmitsTrucks : 0),
        envelope,
        truckTurnRadiusM: trucks ? kYardCircleRadiusM : 0);
    final j = ctx.addJoin(b, 0,
        cutHalfM: site.throatW / 2 + kCutFlareM);
    // Nodes, K first (exactly slot 0's kerb point, V3).
    ctx.kerbNode(b, slot, j);
    for (var i = 1; i < nodeCount; i++) {
      final o = i * nodeStride, oi = i * nodeIntStride;
      final dx = nodes[o + 3], dy = nodes[o + 4];
      b.node(ctx.localPoint(b, nodes[o], nodes[o + 1]),
          flags: nodeInts[oi],
          turn: TurnaroundKind.values[nodeInts[oi + 1]],
          turnR: nodes[o + 2],
          turnHx: ue * dx + ve * dy,
          turnHn: un * dx + vn * dy);
    }
    // Segments: the throat, then aisles by the (y, x) of their start, then
    // aprons (V10).
    final order = <int>[0];
    final aisles = <int>[];
    final aprons = <int>[];
    for (var k = 1; k < segCount; k++) {
      final kind = segInts[k * segIntStride + 2];
      (kind == SiteSegmentKind.aisle.index ? aisles : aprons).add(k);
    }
    aisles.sort((a, c) {
      final na = segInts[a * segIntStride], nc = segInts[c * segIntStride];
      final dy = ny(na) - ny(nc);
      if (dy.abs() > kGenEpsM) return dy < 0 ? -1 : 1;
      final dx = nx(na) - nx(nc);
      if (dx.abs() > kGenEpsM) return dx < 0 ? -1 : 1;
      return a - c;
    });
    order
      ..addAll(aisles)
      ..addAll(aprons);
    final segAt = Int32List(segCount);
    for (var i = 0; i < order.length; i++) {
      final k = order[i];
      segAt[k] = i;
      final o = k * segIntStride;
      final from = segInts[o], to = segInts[o + 1];
      final len = segLen(k);
      final gaps = (len / kViaMaxGapM).ceil();
      final vias = <int>[];
      for (var g = 1; g < gaps; g++) {
        final t = g / gaps;
        vias.add(ctx.localPoint(b, nx(from) + (nx(to) - nx(from)) * t,
            ny(from) + (ny(to) - ny(from)) * t));
      }
      b.segment(from, to,
          vias: vias,
          kind: SiteSegmentKind.values[segInts[o + 2]],
          mode: SiteLaneMode.values[segInts[o + 3]],
          widthM: segDoubles[k * segDoubleStride],
          maxVehLenM: segDoubles[k * segDoubleStride + 1],
          flags: segInts[o + 4]);
    }
    b.setJoinNetwork(j, kerbNode: 0, throatSeg: 0);
    // Stalls (the builder orders and keys them).
    for (var i = 0; i < stallCount; i++) {
      final o = i * stallIntStride, d = i * stallDoubleStride;
      final w = f.toWorld(Vec2(stallDoubles[d + 1], stallDoubles[d + 2]));
      final dx = stallDoubles[d + 3], dy = stallDoubles[d + 4];
      b.stall(
        seg: segAt[stallInts[o]],
        s: stallDoubles[d],
        side: stallInts[o + 1],
        angle: StallAngle.perpendicular,
        inDirs: stallInts[o + 4],
        outDirs: stallInts[o + 5],
        e: w.e,
        n: w.n,
        dirE: ue * dx + ve * dy,
        dirN: un * dx + vn * dy,
        lenM: kStallLengthM,
        widthM: kStallWidthM,
        row: stallInts[o + 2],
        bay: stallInts[o + 3],
      );
    }
    for (var i = 0; i < bays.length ~/ bayStride; i++) {
      final d = i * bayStride;
      final w = f.toWorld(Vec2(bays[d + 1], bays[d + 2]));
      final dx = bays[d + 3], dy = bays[d + 4];
      b.bay(
        seg: segAt[bayInts[2 * i]],
        s: bays[d],
        side: bayInts[2 * i + 1],
        e: w.e,
        n: w.n,
        dirE: ue * dx + ve * dy,
        dirN: un * dx + vn * dy,
        lenM: kLoadingBayLengthM,
        widthM: kLoadingBayWidthM,
      );
    }
    // Paves: the throat's kerb corners blend from the kerb (§6.3).
    for (var q = 0; q < paves.length; q++) {
      final r = paves[q];
      final kerbEdge = q == 0;
      int corner(double x, double y, bool atKerb) => atKerb
          ? ctx.localPoint(b, x, y,
              ref: SiteHeightRef.blend, hJoin: j, hT: 1)
          : ctx.localPoint(b, x, y);
      b.pave([
        corner(r.x0, r.y0, kerbEdge),
        corner(r.x1, r.y0, kerbEdge),
        corner(r.x1, r.y1, false),
        corner(r.x0, r.y1, false),
      ]);
    }
    for (var l = 0; l < lamps.length ~/ 2; l++) {
      b.lamp(ctx.localPoint(b, lamps[2 * l], lamps[2 * l + 1]));
    }
    final env = envelope.rect;
    final (dx, dy) = envelopeDoor(envelope);
    final door = ctx.localPoint(b, dx, dy);
    final pavement = ctx.localPoint(b, dx, 0);
    ctx.finishPedestrians(b, door, pavement,
        entranceNode: entranceNode(env));
    b.endSite();
  }
}

/// The throat `K → (x_J, y)` and its pave; null when its on-parcel stretch
/// leaves the lot.
_Draft _throat(_Site s, double y) {
  final p = _Draft(s);
  final flags = kSegThroat |
      (s.ctx.crossesPavement(s.ctx.slot0) ? kSegCrossesPavement : 0) |
      (s.truck ? kSegTruck : 0);
  final k = p.node(s.xJ, -s.k, flags: kNodeKerb);
  final far = p.node(s.xJ, y);
  p.seg(k, far, SiteSegmentKind.driveway, s.throatMode, s.throatW,
      flags: flags,
      maxVehLenM: s.truck ? kTruckMinVehLenM : kSegMinVehLenM);
  return p;
}

/// The throat's pave from the kerb to [y1], its on-parcel stretch checked.
bool _throatPave(_Draft p, double y1) {
  final s = p.site;
  final hw = s.throatW / 2;
  if (y1 > kContainsInsetM + kGenEpsM &&
      !s.profile.containsRect(
          SiteRect(s.xJ - hw, kContainsInsetM, s.xJ + hw, y1))) {
    return false;
  }
  p.paves.add(SiteRect(s.xJ - hw, -s.k, s.xJ + hw, y1));
  return true;
}

// ---- module layout -----------------------------------------------------------

/// A block of [m] modules laid along a q axis from 0: modules 0..m−2 double
/// (row, aisle, row), the last single (aisle, then its row) when [single].
/// [firstCentred]: module 0's aisle sits at q = 0 (F3: the throat continues
/// into it), so the block starts at −8.2 (double) or −3 (single).
class _Modules {
  _Modules(int m, bool single, {bool firstCentred = false}) {
    var q = 0.0;
    for (var i = 0; i < m; i++) {
      final isSingle = single && i == m - 1;
      if (firstCentred && i == 0) {
        if (isSingle) {
          aisles.add(0);
          addRow(kAisleTwoWayWidthM / 2, kAisleTwoWayWidthM / 2 + kStallLengthM,
              0, 1);
          start = -kAisleTwoWayWidthM / 2;
          q = kAisleTwoWayWidthM / 2 + kStallLengthM;
        } else {
          final h = kModuleDoubleM / 2;
          addRow(-h, -h + kStallLengthM, 0, -1);
          aisles.add(0);
          addRow(h - kStallLengthM, h, 0, 1);
          start = -h;
          q = h;
        }
        if (i < m - 1) boundaries.add(q);
        continue;
      }
      final a = aisles.length;
      if (isSingle) {
        aisles.add(q + kAisleTwoWayWidthM / 2);
        addRow(q + kAisleTwoWayWidthM, q + kModuleSingleM, a, 1);
        q += kModuleSingleM;
      } else {
        addRow(q, q + kStallLengthM, a, -1);
        aisles.add(q + kStallLengthM + kAisleTwoWayWidthM / 2);
        addRow(q + kStallLengthM + kAisleTwoWayWidthM, q + kModuleDoubleM, a, 1);
        q += kModuleDoubleM;
      }
      if (i < m - 1) boundaries.add(q);
    }
    end = q;
  }

  final List<double> aisles = [];

  /// Rows: q0, q1 (stride 2), their aisle and side (+1: larger q).
  final List<double> rowQ = [];
  final List<int> rowAisle = [];
  final List<int> rowSide = [];

  /// Module boundaries strictly inside the block (back-to-back row lines).
  final List<double> boundaries = [];
  double start = 0;
  double end = 0;

  int get rowCount => rowAisle.length;

  void addRow(double q0, double q1, int aisle, int side) {
    rowQ.addAll([q0, q1]);
    rowAisle.add(aisle);
    rowSide.add(side);
  }
}

// ---- F1 / F2: aisles along x -------------------------------------------------

CarParkCandidate _alongX(_Site s, CarParkFamily fam, int m, bool single) {
  final rear = fam == CarParkFamily.rear;
  final bias =
      rear && s.widthM < kScoreRearBiasMaxWidthM ? kScoreRearBias : 0.0;
  final mod = _Modules(m, single);
  final depth = mod.end;
  // Frame y of a q, and of the block ends.
  late final double base;
  late final double yRear;
  double yOf(double q) => rear ? yRear - q : base + q;
  double blockY0, blockY1;
  (double, double)? run;
  if (!rear) {
    const y0 = kDepthProfileMarginM;
    base = y0 + math.max(0.0, s.yT - (y0 + mod.aisles.first));
    blockY0 = base;
    blockY1 = base + depth;
    run = s.runAt(s.xJ, blockY1);
  } else {
    final c = s.columnOf(s.xJ);
    yRear = c < 0 ? 0 : s.depths[c];
    blockY0 = yRear - depth;
    blockY1 = yRear;
    if (blockY0 < kDepthProfileMarginM - kGenEpsM) {
      return _rejected(fam, m, single, _kNoBlock);
    }
    run = s.runAt(s.xJ, yRear);
  }
  if (run == null) return _rejected(fam, m, single, _kNoBlock);
  final (xL, xR) = run;
  // Aisles in ascending frame y; the throat meets the first (nearest the
  // frontage).
  final aisleY = [for (final q in mod.aisles) yOf(q)];
  final byY = List<int>.generate(aisleY.length, (i) => i)
    ..sort((a, b) => aisleY[a].compareTo(aisleY[b]));
  final jA = byY.first;
  final yJ = aisleY[jA];
  if (yJ < s.yT - kGenEpsM) return _rejected(fam, m, single, _kNoBlock);
  {
    // The bound before any allocation: the block, its drive and its rows.
    final throatM = yJ + s.k;
    double drive, bx0, bx1;
    if (m == 1) {
      final armL = s.xJ - xL, armR = xR - s.xJ;
      final hasL = armL > kArmHammerheadMinM + kGenEpsM;
      final hasR = armR > kArmHammerheadMinM + kGenEpsM;
      drive = throatM + (hasL ? armL : 0) + (hasR ? armR : 0);
      bx0 = hasL ? xL : s.xJ - s.throatW / 2;
      bx1 = hasR ? xR : s.xJ + s.throatW / 2;
    } else {
      drive = throatM +
          (xR - xL - kCrossAisleWidthM) * m +
          2 * (aisleY[byY.last] - yJ);
      bx0 = xL;
      bx1 = xR;
    }
    if (s.dominated(s.boundOf((bx1 - bx0) * (blockY1 - blockY0), drive, bias,
        mod.rowCount * (((bx1 - bx0) / kStallWidthM).floor() + 1)))) {
      return _rejected(fam, m, single, _kDominated);
    }
  }
  final p = _throat(s, yJ);
  const ha = kAisleTwoWayWidthM / 2;
  if (!_throatPave(p, yJ - ha)) {
    return _rejected(fam, m, single, 'throat leaves the lot');
  }
  const j = 1;
  final c = s.corridorHalf;
  final aisleFlags = s.truck ? kSegTruck : 0;
  final veh = s.truck ? kTruckMinVehLenM : kSegMinVehLenM;
  int aisle(int a, int b) => p.seg(a, b, SiteSegmentKind.aisle,
      SiteLaneMode.twoWay, kAisleTwoWayWidthM,
      flags: aisleFlags, maxVehLenM: veh);

  double rowY1(int r) => rear ? yRear - mod.rowQ[2 * r] : base + mod.rowQ[2 * r + 1];
  bool inFront(int r) => rowY1(r) <= yJ - ha + kGenEpsM;
  double rowO(int r) => (rear ? -mod.rowSide[r] : mod.rowSide[r]).toDouble();

  double paveX0, paveX1;
  if (m == 1) {
    final armL = s.xJ - xL, armR = xR - s.xJ;
    final hasR = armR > kArmHammerheadMinM + kGenEpsM;
    final hasL = armL > kArmHammerheadMinM + kGenEpsM;
    if (!hasR && !hasL) return _rejected(fam, m, single, 'both arms cut');
    final segR = hasR
        ? aisle(j, p.node(xR, yJ,
            flags: kNodeDeadEnd,
            turn: TurnaroundKind.hammerhead,
            r: kTEndClearM,
            dx: 1))
        : -1;
    final segL = hasL
        ? aisle(j, p.node(xL, yJ,
            flags: kNodeDeadEnd,
            turn: TurnaroundKind.hammerhead,
            r: kTEndClearM,
            dx: -1))
        : -1;
    paveX0 = hasL ? xL : s.xJ - s.throatW / 2;
    paveX1 = hasR ? xR : s.xJ + s.throatW / 2;
    final pre = p.preCheck(fam, m, single,
        SiteRect(paveX0, blockY0, paveX1, blockY1), bias,
        mod.rowCount * (((paveX1 - paveX0) / kStallWidthM).floor() + 1));
    if (pre != null) return pre;
    for (var r = 0; r < mod.rowCount; r++) {
      final front = inFront(r);
      final oy = rowO(r);
      if (hasR) {
        p.pack(
            seg: segR, ax: s.xJ, ay: yJ, tx: 1, ty: 0, ox: 0, oy: oy,
            len: armR,
            lo: front ? math.max(-kStallWidthM / 2, c) : -kStallWidthM / 2,
            hi: armR - kTEndClearM - _kF32SlackM,
            row: r);
      }
      if (hasL) {
        p.pack(
            seg: segL, ax: s.xJ, ay: yJ, tx: -1, ty: 0, ox: 0, oy: oy,
            len: armL,
            // Both arms: this one stops where the other's first stall starts.
            lo: math.max(hasR ? kStallWidthM / 2 : -kStallWidthM / 2,
                front ? c : double.negativeInfinity),
            hi: armL - kTEndClearM - _kF32SlackM,
            row: r);
      }
    }
  } else {
    final xW = xL + kCrossAisleWidthM / 2, xE = xR - kCrossAisleWidthM / 2;
    if (s.xJ - xW < kSegMinLenM || xE - s.xJ < kSegMinLenM) {
      return _rejected(fam, m, single, 'throat meets a cross aisle');
    }
    final west = <int>[], east = <int>[];
    for (final a in byY) {
      west.add(p.node(xW, aisleY[a]));
      east.add(p.node(xE, aisleY[a]));
    }
    final segBefore = aisle(west[0], j);
    final segAfter = aisle(j, east[0]);
    final aisleSeg = <int>[-1];
    for (var i = 1; i < byY.length; i++) {
      aisleSeg.add(aisle(west[i], east[i]));
    }
    for (var i = 0; i + 1 < byY.length; i++) {
      aisle(west[i], west[i + 1]);
      aisle(east[i], east[i + 1]);
    }
    paveX0 = xL;
    paveX1 = xR;
    final pre = p.preCheck(fam, m, single,
        SiteRect(paveX0, blockY0, paveX1, blockY1), bias,
        mod.rowCount * (((paveX1 - paveX0) / kStallWidthM).floor() + 1));
    if (pre != null) return pre;
    const cross = kCrossAisleWidthM / 2;
    for (var r = 0; r < mod.rowCount; r++) {
      final rank = byY.indexOf(mod.rowAisle[r]);
      final oy = rowO(r);
      final y = aisleY[mod.rowAisle[r]];
      if (rank == 0) {
        final front = inFront(r);
        final dJ = s.xJ - xW;
        p.pack(
            seg: segBefore, ax: xW, ay: y, tx: 1, ty: 0, ox: 0, oy: oy,
            len: dJ,
            lo: cross,
            // Clear of the east cross aisle too when J stands close to it.
            hi: math.min(xE - cross - xW,
                front
                    ? math.min(dJ - kStallWidthM / 2, dJ - c)
                    : dJ - kStallWidthM / 2),
            row: r,
            bayBase: _kBayBaseBeforeJ);
        final lenA = xE - s.xJ;
        p.pack(
            seg: segAfter, ax: s.xJ, ay: y, tx: 1, ty: 0, ox: 0, oy: oy,
            len: lenA,
            // Clear of the west cross aisle too when J stands close to it.
            lo: math.max(math.max(-kStallWidthM / 2, cross - dJ),
                front ? c : double.negativeInfinity),
            hi: lenA - cross,
            row: r);
      } else {
        final len = xE - xW;
        p.pack(
            seg: aisleSeg[rank], ax: xW, ay: y, tx: 1, ty: 0, ox: 0, oy: oy,
            len: len, lo: cross, hi: len - cross, row: r);
      }
    }
  }
  p.paves.add(SiteRect(paveX0, blockY0, paveX1, blockY1));
  // Lamps along the back-to-back lines, or the block's building-side edge.
  if (mod.boundaries.isEmpty) {
    p.lampsX(paveX0, paveX1, rear ? blockY0 : blockY1);
  } else {
    for (final q in mod.boundaries) {
      p.lampsX(paveX0, paveX1, yOf(q));
    }
  }
  return p.finish(fam, m, single, bias: bias);
}

// ---- F3: aisles along y ------------------------------------------------------

CarParkCandidate _alongY(_Site s, int m, bool single) {
  const fam = CarParkFamily.side;
  final dir = s.sideDir;
  final mod = _Modules(m, single, firstCentred: true);
  double xOf(double t) => s.xJ + dir * t;
  final xa = xOf(mod.start), xb = xOf(mod.end);
  final bx0 = math.min(xa, xb), bx1 = math.max(xa, xb);
  final yRear = s.depthOverRange(bx0, bx1);
  const y0 = kDepthProfileMarginM;
  final yT = s.yT;
  final yC = yRear - kCrossAisleWidthM / 2;
  if (m == 1
      ? yRear - yT < kTEndAisleMinM + kStallWidthM
      : (yC - yT < kSegMinLenM + kStallWidthM ||
          yC - y0 < kTEndAisleMinM + kStallWidthM)) {
    return _rejected(fam, m, single, _kNoBlock);
  }
  {
    // The bound before any allocation.
    final aisles = mod.aisles.length;
    final drive = yT +
        s.k +
        (m == 1
            ? yRear - yT
            : (yC - yT) +
                (aisles - 1) * (yC - y0) +
                (mod.aisles.last - mod.aisles.first).abs());
    final by0 = m == 1 ? math.max(yT, y0) : y0;
    if (s.dominated(s.boundOf((bx1 - bx0) * (yRear - by0), drive,
        kScoreSideBias,
        mod.rowCount * (((yRear - y0) / kStallWidthM).floor() + 1)))) {
      return _rejected(fam, m, single, _kDominated);
    }
  }
  final p = _throat(s, yT);
  if (!_throatPave(p, yT)) {
    return _rejected(fam, m, single, 'throat leaves the lot');
  }
  const t = 1;
  final aisleFlags = s.truck ? kSegTruck : 0;
  final veh = s.truck ? kTruckMinVehLenM : kSegMinVehLenM;
  int aisle(int a, int b) => p.seg(a, b, SiteSegmentKind.aisle,
      SiteLaneMode.twoWay, kAisleTwoWayWidthM,
      flags: aisleFlags, maxVehLenM: veh);
  // Stall rectangles start at least at the profile margin and at y_T.
  final loFirst = math.max(0.0, y0 - yT);
  final segOf = <int>[];
  final startY = <double>[];
  final lenOf = <double>[];
  final loOf = <double>[];
  if (m == 1) {
    final len = yRear - yT;
    segOf.add(aisle(t, p.node(s.xJ, yRear,
        flags: kNodeDeadEnd,
        turn: TurnaroundKind.hammerhead,
        r: kTEndClearM,
        dy: 1)));
    startY.add(yT);
    lenOf.add(len);
    loOf.add(loFirst);
  } else {
    final rear = <int>[];
    for (var i = 0; i < mod.aisles.length; i++) {
      rear.add(p.node(xOf(mod.aisles[i]), yC));
    }
    segOf.add(aisle(t, rear[0]));
    startY.add(yT);
    lenOf.add(yC - yT);
    loOf.add(loFirst);
    for (var i = 1; i < mod.aisles.length; i++) {
      final front = p.node(xOf(mod.aisles[i]), y0,
          flags: kNodeDeadEnd,
          turn: TurnaroundKind.hammerhead,
          r: kTEndClearM,
          dy: -1);
      segOf.add(aisle(front, rear[i]));
      startY.add(y0);
      lenOf.add(yC - y0);
      loOf.add(kTEndClearM + _kF32SlackM);
    }
    for (var i = 0; i + 1 < rear.length; i++) {
      aisle(rear[i], rear[i + 1]);
    }
  }
  final block = SiteRect(bx0, math.max(m == 1 ? yT : y0, y0), bx1, yRear);
  final pre = p.preCheck(fam, m, single, block, kScoreSideBias,
      mod.rowCount * (((yRear - y0) / kStallWidthM).floor() + 1));
  if (pre != null) return pre;
  for (var r = 0; r < mod.rowCount; r++) {
    final a = mod.rowAisle[r];
    final len = lenOf[a];
    p.pack(
        seg: segOf[a],
        ax: xOf(mod.aisles[a]),
        ay: startY[a],
        tx: 0,
        ty: 1,
        ox: (dir * mod.rowSide[r]).toDouble(),
        oy: 0,
        len: len,
        lo: loOf[a],
        hi: len - (m == 1 ? kTEndClearM : kCrossAisleWidthM / 2) - _kF32SlackM,
        row: r);
  }
  p.paves.add(block);
  final lampY0 = block.y0;
  if (mod.boundaries.isEmpty) {
    p.lampsY(xOf(mod.end), lampY0, yRear);
  } else {
    for (final q in mod.boundaries) {
      p.lampsY(xOf(q), lampY0, yRear);
    }
  }
  return p.finish(fam, m, single, bias: kScoreSideBias);
}

// ---- §3.6 yard: a truck spine with stalls, the apron across its end ----------

/// The shortest stall aisle that gives a place a run-up bit (§3.5 V9).
const double _kYardMinAisleM =
    kStallWidthM / 2 + kStallRunupHalfWidthM + kStallRunupM;

/// From the apron segment's line, how far toward the frontage its bays reach
/// (half the 7 m apron lane, then the 15 m bay).
const double _kYardBayBandM = kYardThroatWidthM / 2 + kLoadingBayLengthM;

/// The apron's frame t-range across the spine: the spine's far edge to the
/// circle node at the apron segment's end.
const double _kYardApronT0 = -kYardThroatWidthM / 2;
const double _kYardApronT1 = kYardApronWidthM;

/// The frame y of the apron segment for each yard candidate: the shallowest
/// that leaves an 8 m envelope in front of the bays, the one whose spine
/// holds the capacity target, and the deepest. Ascending, distinct; empty
/// when none fits.
List<double> _yardApronYs(_Site s) {
  final dir = s.sideDir;
  final xa = s.xJ + dir * _kYardApronT0, xb = s.xJ + dir * _kYardApronT1;
  final yRear = s.depthOverRange(math.min(xa, xb), math.max(xa, xb));
  final lo = math.max(
      s.yT + _kYardMinAisleM,
      kDepthProfileMarginM +
          kEnvelopeMinSideM +
          kEnvelopeClearLotM +
          _kYardBayBandM);
  final hi = yRear - kYardThroatWidthM / 2;
  if (hi < lo - kGenEpsM) return const [];
  final want = (s.yT + kStallWidthM * s.cap.ceil()).clamp(lo, hi);
  final out = <double>[lo];
  if (want - out.last > kGenEpsM) out.add(want);
  if (hi - out.last > kGenEpsM) out.add(hi);
  return out;
}

/// §3.6 as built. The throat `K → T` (7 m, trucks) runs on as the stall
/// aisle `T → A` along `v` (6 m, trucks), with a stall row on the far side
/// (away from the envelope) and, when [bothSides], a row on the near side
/// that stops short of the bays. At `A` the apron segment turns along `±u`
/// toward the side with more room, 18 m to the circle node `Y` (12.5 m); its
/// two 3.5 × 15 m bays hang toward the frontage, noses on `−v`, so the
/// envelope stands in front of them: the apron is beside its rear face.
CarParkCandidate _yard(_Site s, double yA, bool bothSides) {
  const fam = CarParkFamily.yard;
  final single = !bothSides;
  final dir = s.sideDir;
  double xOf(double t) => s.xJ + dir * t;
  SiteRect band(double t0, double t1, double y0, double y1) => SiteRect(
      math.min(xOf(t0), xOf(t1)), y0, math.max(xOf(t0), xOf(t1)), y1);
  final yRear = s.depthOverRange(
      band(_kYardApronT0, _kYardApronT1, 0, 1).x0,
      band(_kYardApronT0, _kYardApronT1, 0, 1).x1);
  if (yA + kYardThroatWidthM / 2 > yRear + kGenEpsM) {
    return _rejected(fam, 1, single, _kNoBlock);
  }
  final yT = s.yT;
  final bayY0 = yA - _kYardBayBandM;
  final p = _throat(s, yT)..trucks = true;
  if (!_throatPave(p, yT)) {
    return _rejected(fam, 1, single, 'throat leaves the lot');
  }
  const t = 1;
  final a = p.node(s.xJ, yA);
  final y = p.node(xOf(_kYardApronT1), yA,
      flags: kNodeDeadEnd, turn: TurnaroundKind.circle, r: kYardCircleRadiusM);
  final spine = p.seg(t, a, SiteSegmentKind.aisle, SiteLaneMode.twoWay,
      kAisleTwoWayWidthM,
      flags: kSegTruck, maxVehLenM: kTruckMinVehLenM);
  final apron = p.seg(a, y, SiteSegmentKind.apron, SiteLaneMode.twoWay,
      kYardThroatWidthM,
      flags: kSegTruck, maxVehLenM: kTruckMinVehLenM);
  const y0 = kDepthProfileMarginM;
  final rowY0 = math.max(yT, y0);
  final len = yA - yT;
  final lo = math.max(0.0, y0 - yT);
  const ha = kAisleTwoWayWidthM / 2;
  final apronRect = band(_kYardApronT0, _kYardApronT1, bayY0,
      yA + kYardThroatWidthM / 2);
  final spineRect = band(-ha, ha, rowY0, yA);
  if (!s.profile.containsRect(apronRect) || !s.profile.containsRect(spineRect)) {
    return _rejected(fam, 1, single, 'yard pave leaves the lot');
  }
  p.boundBlockArea = apronRect.width * apronRect.depth;
  if (s.dominated(p.upperBound(p.boundBlockArea, 0,
      atMost: 2 * ((len / kStallWidthM).floor() + 1)))) {
    return _rejected(fam, 1, single, _kDominated, plan: p);
  }
  p.paves
    ..add(spineRect)
    ..add(apronRect);
  // Rows: the far side up to A, the near side up to the bays.
  for (final (side, top) in [
    (-1, yA),
    if (bothSides) (1, bayY0),
  ]) {
    if (top - rowY0 < kStallWidthM) continue;
    final rows = side < 0
        ? band(-ha - kStallLengthM, -ha, rowY0, top)
        : band(ha, ha + kStallLengthM, rowY0, top);
    if (!s.profile.containsRect(rows)) continue;
    p.paves.add(rows);
    p.pack(
        seg: spine,
        ax: s.xJ,
        ay: yT,
        tx: 0,
        ty: 1,
        ox: (dir * side).toDouble(),
        oy: 0,
        len: len,
        lo: lo,
        hi: top - yT,
        row: side < 0 ? 0 : 1);
  }
  // Two bays on the apron segment, centred, noses toward the frontage.
  final bayY = yA - kYardThroatWidthM / 2 - kLoadingBayLengthM / 2;
  final pitch = kLoadingBayWidthM + _kYardBayGapM;
  final mid = kYardApronWidthM / 2;
  var bx0 = double.infinity, bx1 = double.negativeInfinity;
  for (var i = 0; i < kYardBays; i++) {
    final sb = mid + (i - (kYardBays - 1) / 2) * pitch;
    // Travel along dir·u: its right is −v when dir > 0.
    p.bay(apron, dir > 0 ? 0 : 1, sb, xOf(sb), bayY, 0, -1);
    bx0 = math.min(bx0, xOf(sb) - kLoadingBayWidthM / 2);
    bx1 = math.max(bx1, xOf(sb) + kLoadingBayWidthM / 2);
  }
  p.lampsY(xOf(-ha - kStallLengthM), rowY0, yA);
  // The envelope stands in front of the bays, on the apron's side of the
  // spine, its rear face against them.
  return p.finish(fam, 1, single,
      envXMin: dir > 0 ? xOf(ha) : double.negativeInfinity,
      envXMax: dir < 0 ? xOf(ha) : double.infinity,
      envFaces: (env) =>
          env.x0 < bx1 - kGenEpsM &&
          env.x1 > bx0 + kGenEpsM &&
          env.y1 >= bayY0 - kEnvelopeClearLotM - kDepthProfileStepM - kGenEpsM &&
          env.y1 <= bayY0 + kGenEpsM);
}
