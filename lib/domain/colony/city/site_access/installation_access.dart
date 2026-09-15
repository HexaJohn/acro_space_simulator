// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Installations: access road, gate, forecourt, yard and staff car park
/// (docs/plans/site-access.md §3.7).
///
/// ```
///   y ▲   envelope = the largest lot rectangle in y ≥ Df; G on the fence y = Df
///  Df ├──────────────G──────────────   G: kNodeGate, dead end, hammerhead (a)
///     │      ▭ ▭     ║     ▭ ▭          loading bays beside Y→G
///     │             (Y)══════C═╗       connector along ±u to the first aisle
///     │        circle r 13     ║ aisles along y, stalls at |x − x_G| ≥ 21
///   0 ├──────────────T─────────────── frontage line (T on it when k ≥ 12)
///     │              ║ throat K→T along the ROAD normal, vias every 24 m
///  -k └──────────────K kerb node (slot 0's kerb point exactly, V3)
/// ```
///
/// All positions are computed in the site frame (x along the frontage, y into
/// the lot) and written in world metres. The generator computes the whole
/// plan first ([installationPlanOf]) and writes it only in
/// [InstallationPlan.emit], so a site that does not fit writes nothing.
///
/// As built (R2 installation track), recorded in §3.7:
/// - The throat reaches frame depth `T.y = max(0, 12 − k)` along the road
///   normal `n`, so its length is `(k + T.y)/(n·v)` (exactly `max(12, k)` when
///   `n = v`). The spine always continues along `v` from `T`: within 3° that is
///   the §3.7 straight run, beyond it `T` is the bend node. A slot whose
///   normal is more than 60° off `v` gets no plan ([_kMinThroatCos]).
/// - The staff car park is this file's own F3-form packer (aisles along `y`,
///   the connector at `Y` or `B`, cross aisles at both block ends for two or
///   more aisles, T-end hammerheads for one), scored by the §3.5 terms, not a
///   call into `car_park_packer.dart` (another track's file, whose F3 needs a
///   throat, not a connector).
/// - A dogleg (`kJoinOffFrontage`) follows R1's corridor polyline `K → T → Q
///   → F` exactly; one whose bend `T` does not lie in front of the frontage
///   line gets no plan.
/// - The envelope is the largest lot rectangle behind the fence line that
///   spans the gate gap ([_envelopeOf]); the car park band starts behind a
///   skewed throat ([_farYBeyond]).
///
/// Determinism (§3.9): no platform hash, draw, clock, map iteration or
/// trigonometry; ties go to the smaller candidate, the side tie to the seed.
library;

import 'dart:math' as math;

import '../parcel.dart';
import 'site_access_constants.dart';
import 'site_access_plan.dart';
import 'site_envelope.dart';
import 'site_frame.dart';
import 'site_plan_builder.dart';
import 'site_plan_generator.dart';
import 'site_program.dart';

/// The slot normal must lie within 60° of the frame's `v` (`n·v ≥ 0.5`):
/// beyond it the throat's frame depth would stretch without bound. Not a
/// §3.7 number; private to this generator.
const double _kMinThroatCos = 0.5;

/// tan 22.5°: the yard circle's pave is the octagon circumscribing it.
const double _kTan22_5 = 0.41421356;

/// The staff car park's first aisle leaves this much of the band (the
/// `[0.3, …]` profile margin) plus half an aisle in front of it.
const double _kBandFrontM = kDepthProfileMarginM;

/// A plan movement deflects at most 150° (§2.5); a dogleg bend sharper than
/// this (with a margin) gets no plan.
const double _kBendDotMin = kCos150 + 0.01;

/// One loading bay of §3.7 step 5, frame metres.
class InstallationBay {
  const InstallationBay(this.x0, this.x1, this.y0, this.y1);
  final double x0, x1, y0, y1;
  double get cx => (x0 + x1) / 2;
  double get cy => (y0 + y1) / 2;
}

/// One stall of the staff car park, in the car park's own lattice.
class _Stall {
  const _Stall(this.aisle, this.far, this.bay, this.y, this.inDirs);

  /// The aisle it opens onto, whether on its far row (away from the spine),
  /// its index along the row, its centre y, its entry bits.
  final int aisle;
  final bool far;
  final int bay;
  final double y;
  final int inDirs;
}

/// The staff car park of §3.7 step 6: `k` aisles along `y` on side [sigma]
/// of the spine.
class InstallationCarPark {
  InstallationCarPark._({
    required this.sigma,
    required this.aisles,
    required this.connectorY,
    required this.aisleY0,
    required this.aisleY1,
    required this.paveY0,
    required this.depthM,
    required List<_Stall> stalls,
  }) : _stalls = stalls;

  /// +1: at larger frame x than the spine; −1: smaller.
  final int sigma;

  /// Aisle count k (1..kMaxModules).
  final int aisles;

  /// The connector's y (`Y.y` or `B.y`): node `C` on aisle 0.
  final double connectorY;

  /// The aisles' end nodes' y, and the block pave's near edge.
  final double aisleY0, aisleY1, paveY0;

  /// `carParkDepth`: the block pave's far edge y.
  final double depthM;

  final List<_Stall> _stalls;

  int get stallCount => _stalls.length;

  /// Whether `C` is aisle 0's near end node (no aisle stretch before it).
  bool get connectorAtEnd => (connectorY - aisleY0).abs() <= kGenEpsM;

  /// Distance of aisle [i]'s centre from the spine.
  static double offsetOf(int i) => kStaffAisleOffsetM + kModuleDoubleM * i;
}

/// A fitted §3.7 installation plan, ready to write.
class InstallationPlan implements SiteGeneratedPlan {
  InstallationPlan._({
    required this.throatLengthM,
    required this.frontY,
    required this.dogleg,
    required this.gateX,
    required this.spineY,
    required this.yard,
    required this.branchY,
    required this.bays,
    required this.carPark,
    required this.forecourtDepthM,
    required this.envelope,
  });

  /// `|K→T|` along the road normal.
  final double throatLengthM;

  /// `T.y` in the frame (the frame depth of the throat's far node); for a
  /// dogleg, the frame y of the bend `T` (in front of the frontage).
  final double frontY;

  /// The dogleg's `Q` and `F` in the frame (`F` on `y = 0`), or null.
  final (Vec2?, Vec2)? dogleg;

  /// `x_G`, and the spine origin's frame y (`yS`).
  final double gateX, spineY;

  /// Whether the yard circle `Y` fits; `branchY` is `Y.y` or `B.y`.
  final bool yard;
  final double branchY;

  /// The loading bays that remain (none, or 2..4).
  final List<InstallationBay> bays;

  /// The staff car park, or null when none fits.
  final InstallationCarPark? carPark;

  /// `Df`: the fence line and gate `G`'s y.
  final double forecourtDepthM;

  final SiteEnvelope envelope;

  bool get admitsTrucks => bays.isNotEmpty;

  @override
  SiteProgram get program => SiteProgram.installation;

  @override
  void emit(PlanBuilder b, SiteContext ctx, int dispatchFlags) {
    final frame = ctx.frame!;
    final slot = ctx.slot0;
    final n = Vec2(slot.normE, slot.normN);
    final kerb = Vec2(slot.kerbE, slot.kerbN);
    final v = frame.v;
    Vec2 w(double x, double y) => frame.toWorld(Vec2(x, y));

    ctx.beginSite(
        b,
        program,
        dispatchFlags | kPlanNetwork | (admitsTrucks ? kPlanAdmitsTrucks : 0),
        envelope,
        truckTurnRadiusM: admitsTrucks ? kInstallationTruckTurnM : 0);
    final j = ctx.addJoin(b, 0,
        cutHalfM: kInstallationThroatWidthM / 2 + kCutFlareM);

    // ---- nodes ---------------------------------------------------------------
    // World position by plan node index (nodes are numbered in call order).
    final pos = <Vec2>[];
    int nodeAt(Vec2 world,
        {int flags = 0,
        TurnaroundKind turn = TurnaroundKind.none,
        double turnR = 0,
        Vec2? arm}) {
      final node = b.node(b.point(world.e, world.n),
          flags: flags,
          turn: turn,
          turnR: turnR,
          turnHx: arm?.e ?? 0,
          turnHn: arm?.n ?? 0);
      assert(node == pos.length);
      pos.add(world);
      return node;
    }

    final kNode = ctx.kerbNode(b, slot, j);
    assert(kNode == pos.length);
    pos.add(kerb);
    final tWorld = kerb + n * throatLengthM;
    final tNode = nodeAt(tWorld);
    // The access road after the throat, in path order: world points.
    final roadPath = <Vec2>[tWorld];
    final roadNodes = <int>[tNode];
    final dl = dogleg;
    if (dl != null) {
      final (q, f) = dl;
      if (q != null) {
        roadPath.add(w(q.e, q.n));
        roadNodes.add(nodeAt(roadPath.last));
      }
      roadPath.add(w(f.e, f.n));
      roadNodes.add(nodeAt(roadPath.last));
    }
    final branchWorld = w(gateX, branchY);
    final branchNode = nodeAt(branchWorld,
        flags: carPark != null ? kNodeBranch : 0,
        turn: yard ? TurnaroundKind.circle : TurnaroundKind.none,
        turnR: yard ? kInstallationCircleRadiusM : 0);
    roadPath.add(branchWorld);
    roadNodes.add(branchNode);
    final gateWorld = w(gateX, forecourtDepthM);
    final gNode = nodeAt(gateWorld,
        flags: kNodeGate | kNodeDeadEnd,
        turn: TurnaroundKind.hammerhead,
        turnR: kHammerheadApronM,
        arm: v);
    roadPath.add(gateWorld);
    roadNodes.add(gNode);

    // The car park's nodes and its aisle segments (sorted below).
    final aisleSegs = <_SegSpec>[];
    int? cNode;
    final aisleNodesLo = <int>[], aisleNodesHi = <int>[];
    final cp = carPark;
    if (cp != null) {
      double xOf(double d) => gateX + cp.sigma * d;
      final k = cp.aisles;
      final along = v;
      for (var i = 0; i < k; i++) {
        final x = xOf(InstallationCarPark.offsetOf(i));
        final corner = k >= 2 && (i == 0 || i == k - 1);
        final lo = i == 0 && cp.connectorAtEnd
            ? nodeAt(w(x, cp.aisleY0), flags: kNodeBranch)
            : nodeAt(w(x, cp.aisleY0),
                flags: k == 1 ? kNodeDeadEnd : (corner ? 0 : kNodeBranch),
                turn: k == 1 ? TurnaroundKind.hammerhead : TurnaroundKind.none,
                turnR: k == 1 ? kTEndClearM : 0,
                arm: k == 1 ? along * -1 : null);
        final hi = nodeAt(w(x, cp.aisleY1),
            flags: k == 1 ? kNodeDeadEnd : (corner ? 0 : kNodeBranch),
            turn: k == 1 ? TurnaroundKind.hammerhead : TurnaroundKind.none,
            turnR: k == 1 ? kTEndClearM : 0,
            arm: k == 1 ? along : null);
        aisleNodesLo.add(lo);
        aisleNodesHi.add(hi);
      }
      final x0 = xOf(InstallationCarPark.offsetOf(0));
      if (cp.connectorAtEnd) {
        cNode = aisleNodesLo[0];
        aisleSegs.add(_SegSpec.aisle(
            cNode, aisleNodesHi[0], 0, cp.connectorY, cp.aisleY1, x0));
      } else {
        cNode = nodeAt(w(x0, cp.connectorY), flags: kNodeBranch);
        aisleSegs
          ..add(_SegSpec.aisle(
              aisleNodesLo[0], cNode, 0, cp.aisleY0, cp.connectorY, x0))
          ..add(_SegSpec.aisle(
              cNode, aisleNodesHi[0], 0, cp.connectorY, cp.aisleY1, x0));
      }
      for (var i = 1; i < k; i++) {
        final x = xOf(InstallationCarPark.offsetOf(i));
        aisleSegs.add(_SegSpec.aisle(
            aisleNodesLo[i], aisleNodesHi[i], i, cp.aisleY0, cp.aisleY1, x));
      }
      for (var i = 0; i + 1 < k; i++) {
        final x = xOf(InstallationCarPark.offsetOf(i));
        aisleSegs
          ..add(_SegSpec.cross(
              aisleNodesLo[i], aisleNodesLo[i + 1], cp.aisleY0, x))
          ..add(_SegSpec.cross(
              aisleNodesHi[i], aisleNodesHi[i + 1], cp.aisleY1, x));
      }
      // V10: aisles by the (y, x) of their start.
      aisleSegs.sort((a, c) {
        final dy = a.startY.compareTo(c.startY);
        return dy != 0 ? dy : a.startX.compareTo(c.startX);
      });
    }

    // ---- segments (V10 order: throat, aisles, access road, connector) -------
    final throat = b.segment(kNode, tNode,
        vias: _vias(b, kerb, tWorld),
        kind: SiteSegmentKind.accessRoad,
        mode: SiteLaneMode.twoWay,
        widthM: kInstallationThroatWidthM,
        maxVehLenM: kTruckMinVehLenM,
        flags: kSegThroat |
            kSegTruck |
            (ctx.crossesPavement(slot) ? kSegCrossesPavement : 0));
    b.setJoinNetwork(j, kerbNode: kNode, throatSeg: throat);
    final aisleIndex = <int>[];
    for (final s in aisleSegs) {
      aisleIndex.add(b.segment(s.from, s.to,
          vias: _vias(b, pos[s.from], pos[s.to]),
          kind: SiteSegmentKind.aisle,
          mode: SiteLaneMode.twoWay,
          widthM: kAisleTwoWayWidthM));
    }
    var spineSeg = -1;
    for (var i = 1; i < roadPath.length; i++) {
      final seg = b.segment(roadNodes[i - 1], roadNodes[i],
          vias: _vias(b, roadPath[i - 1], roadPath[i]),
          kind: SiteSegmentKind.accessRoad,
          mode: SiteLaneMode.twoWay,
          widthM: kInstallationThroatWidthM,
          maxVehLenM: kTruckMinVehLenM,
          flags: kSegTruck);
      if (i == roadPath.length - 1) spineSeg = seg;
    }
    if (cp != null) {
      b.segment(branchNode, cNode!,
          vias: _vias(b, branchWorld, pos[cNode]),
          kind: SiteSegmentKind.driveway,
          mode: SiteLaneMode.twoWay,
          widthM: kConnectorWidthM);
    }

    // ---- stalls --------------------------------------------------------------
    if (cp != null) {
      final u = frame.u;
      for (final st in cp._stalls) {
        // Its segment: the aisle stretch holding its centre.
        var seg = -1;
        var s = 0.0;
        for (var q = 0; q < aisleSegs.length; q++) {
          final spec = aisleSegs[q];
          if (spec.cross || spec.aisle != st.aisle) continue;
          if (st.y < spec.startY - kGenEpsM || st.y > spec.endY + kGenEpsM) {
            continue;
          }
          seg = aisleIndex[q];
          s = st.y - spec.startY;
          break;
        }
        final d = InstallationCarPark.offsetOf(st.aisle) +
            (st.far ? 1 : -1) *
                (kAisleTwoWayWidthM / 2 + kStallLengthM / 2);
        final centre = w(gateX + cp.sigma * d, st.y);
        final noseSign = (st.far ? 1 : -1) * cp.sigma;
        b.stall(
          seg: seg,
          s: s,
          side: noseSign > 0 ? 0 : 1,
          angle: StallAngle.perpendicular,
          inDirs: st.inDirs,
          outDirs: kSiteDirFwd | kSiteDirBwd,
          e: centre.e,
          n: centre.n,
          dirE: u.e * noseSign,
          dirN: u.n * noseSign,
          lenM: kStallLengthM,
          widthM: kStallWidthM,
          row: 2 * st.aisle + (st.far ? 1 : 0),
          bay: st.bay,
        );
      }
    }

    // ---- loading bays (on Y→G, bayS 13, nose +v) ------------------------------
    for (final bay in bays) {
      final c = w(bay.cx, bay.cy);
      b.bay(
        seg: spineSeg,
        s: kInstallationCircleRadiusM,
        side: bay.cx > gateX ? 0 : 1,
        e: c.e,
        n: c.n,
        dirE: v.e,
        dirN: v.n,
        lenM: kLoadingBayLengthM,
        widthM: kLoadingBayWidthM,
      );
    }

    // ---- paving ----------------------------------------------------------------
    const hw = kInstallationThroatWidthM / 2;
    // The throat: the stretch in front of the frontage line (kerb corners
    // blend from the kerb) and the stretch inside the lot, as separate rings,
    // so each lies in the corridor or in the parcel whole.
    final c = n.dot(v);
    final kFront = -ctx.kerbLocal(slot).n;
    final cross = dogleg == null && kFront > 0
        ? math.min(throatLengthM, kFront / c)
        : throatLengthM;
    b.pave(_ring(b, kerb, kerb + n * cross, hw, kerbJoin: j));
    if (cross < throatLengthM - kGenEpsM) {
      b.pave(_ring(b, kerb + n * cross, tWorld, hw));
    }
    for (var i = 1; i < roadPath.length; i++) {
      b.pave(_ring(b, roadPath[i - 1], roadPath[i], hw));
    }
    if (yard) {
      final r = kInstallationCircleRadiusM;
      final t = r * _kTan22_5;
      b.pave([
        for (final (x, y) in [
          (r, -t), (r, t), (t, r), (-t, r), //
          (-r, t), (-r, -t), (-t, -r), (t, -r),
        ])
          ctx.localPoint(b, gateX + x, branchY + y),
      ]);
    }
    if (bays.isNotEmpty) {
      var x0 = gateX - hw, x1 = gateX + hw;
      for (final bay in bays) {
        x0 = math.min(x0, bay.x0);
        x1 = math.max(x1, bay.x1);
      }
      b.pave(_localRect(ctx, b, x0, bays.first.y0, x1, bays.first.y1));
    }
    if (cp != null) {
      final dC = InstallationCarPark.offsetOf(0);
      final cy = cp.connectorY;
      final half = kConnectorWidthM / 2;
      final xa = cp.sigma > 0 ? gateX : gateX - dC;
      final xb = cp.sigma > 0 ? gateX + dC : gateX;
      b.pave(_localRect(ctx, b, xa, cy - half, xb, cy + half));
      final (bx0, bx1) = _blockX(gateX, cp);
      b.pave(_localRect(ctx, b, bx0, cp.paveY0, bx1, cp.depthM));
      // Lamps along each aisle's far back line.
      for (var i = 0; i < cp.aisles; i++) {
        final d = InstallationCarPark.offsetOf(i) +
            kAisleTwoWayWidthM / 2 +
            kStallLengthM;
        for (final (y, _) in lampsAlong(cp.paveY0, cp.depthM, 0)) {
          b.lamp(ctx.localPoint(b, gateX + cp.sigma * d, y));
        }
      }
    }

    // ---- door, pavement point, footpath ---------------------------------------
    final door = b.point(gateWorld.e, gateWorld.n);
    final pavement = b.point(kerb.e + n.e * kPavementPointInsetM,
        kerb.n + n.n * kPavementPointInsetM,
        ref: SiteHeightRef.kerb, hJoin: j);
    ctx.finishPedestrians(b, door, pavement, entranceNode: gNode);
    b.endSite();
  }

  /// A counter-clockwise rectangle ring from [a] to [c] of half width [hw];
  /// with [kerbJoin], the two corners at [a] blend from that join's kerb.
  static List<int> _ring(PlanBuilder b, Vec2 a, Vec2 c, double hw,
      {int? kerbJoin}) {
    final d = (c - a).normalized;
    final p = d.perp * hw;
    int pt(Vec2 x, {bool kerb = false}) => kerb && kerbJoin != null
        ? b.point(x.e, x.n,
            ref: SiteHeightRef.blend, hJoin: kerbJoin, hT: 1)
        : b.point(x.e, x.n);
    return [
      pt(a - p, kerb: true),
      pt(c - p),
      pt(c + p),
      pt(a + p, kerb: true),
    ];
  }

  static List<int> _localRect(SiteContext ctx, PlanBuilder b, double x0,
          double y0, double x1, double y1) =>
      [
        ctx.localPoint(b, x0, y0),
        ctx.localPoint(b, x1, y0),
        ctx.localPoint(b, x1, y1),
        ctx.localPoint(b, x0, y1),
      ];

  /// Via points every [kViaMaxGapM] from [a] toward [c] (V5, V8).
  static List<int> _vias(PlanBuilder b, Vec2 a, Vec2 c) {
    final len = a.distanceTo(c);
    if (len <= kViaMaxGapM) return const [];
    final d = (c - a) * (1 / len);
    return [
      for (var at = kViaMaxGapM; at < len - kGenEpsM; at += kViaMaxGapM)
        b.point(a.e + d.e * at, a.n + d.n * at),
    ];
  }
}

/// The frame x-range of [cp]'s block pave.
(double, double) _blockX(double gateX, InstallationCarPark cp) {
  final near = kStaffCarParkBandM;
  final far = InstallationCarPark.offsetOf(cp.aisles - 1) +
      kAisleTwoWayWidthM / 2 +
      kStallLengthM;
  return cp.sigma > 0
      ? (gateX + near, gateX + far)
      : (gateX - far, gateX - near);
}

/// An aisle segment of the staff car park before it is numbered: its end
/// nodes, the aisle it runs along (−1 for a cross aisle), and its start's
/// frame (y, x) and end y, which V10 orders aisles by.
class _SegSpec {
  _SegSpec.aisle(this.from, this.to, this.aisle, this.startY, this.endY,
      this.startX)
      : cross = false;
  _SegSpec.cross(this.from, this.to, double y, this.startX)
      : cross = true,
        aisle = -1,
        startY = y,
        endY = y;

  final int from, to;
  final bool cross;
  final int aisle;
  final double startY, endY, startX;
}

/// §3.7 on [ctx], or null when nothing fits (the dispatcher then writes
/// `kerbOnly` with `kPlanFallback`).
InstallationPlan? installationPlanOf(SiteContext ctx) {
  final frame = ctx.frame;
  final spec = ctx.spec;
  if (frame == null || spec == null || ctx.slotCount == 0) return null;
  final slot = ctx.slot0;
  if (slot.flags & kJoinCut == 0) return null;
  // §3.3: throatW = min(7, 2·(room − flare)) must reach 7.
  final throatW = math.min(
      kInstallationThroatWidthM, 2 * (slot.roomM - kCutFlareM));
  if (throatW < kInstallationThroatWidthM - kGenEpsM) return null;

  final wLot = frame.widthM;
  final depth = ctx.depthM;
  final profile = frame.profile;
  final v = frame.v;
  final n = Vec2(slot.normE, slot.normN);
  final c = n.dot(v);
  if (c < _kMinThroatCos) return null;
  final kerbL = ctx.kerbLocal(slot);
  final k = -kerbL.n;
  final nu = n.dot(frame.u); // the normal's frame x per metre

  // ---- 1–3: throat, dogleg, spine origin -------------------------------------
  late final double throatM, frontY, gateX, spineY;
  (Vec2?, Vec2)? dogleg;
  if (slot.flags & kJoinOffFrontage != 0) {
    throatM = kInstallationThroatMinM;
    final tX = kerbL.e + nu * throatM;
    final tY = kerbL.n + c * throatM;
    if (tY > -kSegMinLenM) return null; // the bend must lie before the lot
    final xc = wLot >= 2 * kDoglegSideClearM
        ? (kerbL.e < kDoglegSideClearM
            ? kDoglegSideClearM
            : (kerbL.e > wLot - kDoglegSideClearM
                ? wLot - kDoglegSideClearM
                : kerbL.e))
        : wLot / 2;
    final q = (xc - tX).abs() >= kSegMinLenM ? Vec2(xc, tY) : null;
    final f = Vec2(xc, 0);
    // K→F at most 120 m, and no bend a car cannot take.
    final pts = [kerbL, Vec2(tX, tY), ?q, f];
    var len = 0.0;
    for (var i = 1; i < pts.length; i++) {
      len += pts[i].distanceTo(pts[i - 1]);
    }
    if (len > kDoglegMaxM + kGenEpsM) return null;
    pts.add(Vec2(xc, 1)); // the spine leaves F along +v
    for (var i = 1; i + 1 < pts.length; i++) {
      final a = (pts[i] - pts[i - 1]).normalized;
      final b = (pts[i + 1] - pts[i]).normalized;
      if (a.dot(b) < _kBendDotMin) return null;
    }
    dogleg = (q, f);
    frontY = tY;
    gateX = xc;
    spineY = 0;
  } else {
    frontY = math.max(0.0, kInstallationThroatMinM - k);
    throatM = (k + frontY) / c;
    gateX = kerbL.e + nu * throatM;
    spineY = frontY;
    if (throatM < kInstallationThroatMinM - kGenEpsM) return null;
    // The throat's stretch inside the lot lies in the lot.
    if (frontY > kContainsInsetM) {
      final tStart = k > 0 ? k / c : 0.0;
      final xs = [
        for (final t in [tStart, throatM])
          for (final lat in [-throatW / 2, throatW / 2])
            kerbL.e + nu * t + c * lat,
      ];
      final x0 = xs.reduce(math.min), x1 = xs.reduce(math.max);
      if (!profile.containsRect(SiteRect(x0, kContainsInsetM, x1, frontY))) {
        return null;
      }
    }
  }
  if (spineY > kInstallationThroatMinM + kGenEpsM) return null;
  final dMax = math.max(kForecourtMinM, kForecourtDepthFraction * depth);

  // ---- 4: yard circle or branch node -----------------------------------------
  const r = kInstallationCircleRadiusM;
  final yardY = spineY + kInstallationCircleGapM + r;
  final yard = profile.containsRect(SiteRect(gateX - r,
      yardY - r, gateX + r, yardY + r));
  final branchY = yard ? yardY : spineY + kInstallationBranchNoYardM;

  // ---- 5: loading bays -------------------------------------------------------
  var bays = <InstallationBay>[];
  if (yard) {
    final y0 = yardY + r, y1 = yardY + r + kLoadingBayLengthM;
    for (final side in const [1.0, -1.0]) {
      for (final (a, bb) in const [
        (kInstallationBayInnerX0M, kInstallationBayInnerX1M),
        (kInstallationBayOuterX0M, kInstallationBayOuterX1M),
      ]) {
        final xa = gateX + side * a, xb = gateX + side * bb;
        final bay = InstallationBay(
            math.min(xa, xb), math.max(xa, xb), y0, y1);
        if (bays.length < kInstallationMaxBays &&
            profile.containsRect(SiteRect(bay.x0, y0, bay.x1, y1))) {
          bays.add(bay);
        }
      }
    }
    if (bays.length < kInstallationMinBays) bays = [];
  }
  final bayNeed = yardY + r + kLoadingBayLengthM + kForecourtBayRearClearM;

  // ---- 6: staff car park -----------------------------------------------------
  final target = capacityTarget(SiteProgram.installation, spec);
  // The throat's frame footprint K→T (a dogleg's legs lie before the lot and
  // its spine leaves F along v, so only a straight throat can lean into the
  // car park's band).
  final throat = dogleg == null
      ? (kerbL, Vec2(gateX, frontY), Vec2(nu, c))
      : null;
  final carPark = _staffCarPark(ctx, gateX, branchY, dMax, target,
      bayNeed: bays.isNotEmpty ? bayNeed : 0, throat: throat);

  // ---- 7: forecourt depth, without clamp -------------------------------------
  final need = math.max(
      kForecourtMinM,
      math.max((carPark?.depthM ?? 0.0) + kForecourtCarParkClearM,
          bays.isNotEmpty ? bayNeed : 0.0));
  final df = math.min(need, dMax);
  if (bays.isNotEmpty && bayNeed > df + kGenEpsM) bays = [];

  // ---- 8–9: gate, spine and envelope fit -------------------------------------
  if (df - branchY < kHammerheadApronM - kGenEpsM) return null;
  if (depth - df < kEnvelopeMinSideM - kGenEpsM) return null;
  const hw = kInstallationThroatWidthM / 2;
  if (!profile.containsRect(SiteRect(gateX - hw,
      math.max(spineY, kContainsInsetM), gateX + hw, df))) {
    return null;
  }
  final envelope = _envelopeOf(profile, wLot, df, gateX);
  if (envelope == null) return null;
  return InstallationPlan._(
    throatLengthM: throatM,
    frontY: frontY,
    dogleg: dogleg,
    gateX: gateX,
    spineY: spineY,
    yard: yard,
    branchY: branchY,
    bays: bays,
    carPark: carPark,
    forecourtDepthM: df,
    envelope: envelope,
  );
}

/// §3.7 step 9 with §6.1 steps 2–3 on an odd lot (§3.8): the largest frame
/// rectangle inside [profile] with its front on the fence line `y = Df`
/// ([df]) that holds the whole gate gap `gateX ± gateW/2`; null when there is
/// none with both sides at least [kEnvelopeMinSideM].
///
/// As `largestFreeRect` (§6.1 step 2), over 0.5 m columns from 0.3 m inside
/// each lot line (a corner ON the boundary is neither in nor out of
/// `containsRect`), each column's free depth the shallower of its two edges;
/// but the rectangle must span the gate's columns (the fence gap, the gate
/// node and the envelope's front edge coincide, §6.2), so the unconstrained
/// largest one — often a strip beside the gate on an L or a triangle — is not
/// the answer. The sweep takes every candidate height (the running minimum
/// outward from the gate on either side), tallest first; the largest area
/// wins, ties to the taller.
/// A result whose column-edge corners fail the exact `containsRect` (a back
/// edge steeper than the 0.3 m margin covers over half a column) has its back
/// edge pulled in by bisection until it passes. Nothing of the plan lies past
/// `Df` (the car park ends 6 m before it, the bays 3 m, the gate apron on
/// it), so no pave blocks it.
SiteEnvelope? _envelopeOf(
    DepthProfile profile, double wLot, double df, double gateX) {
  const gateW = kInstallationThroatWidthM + kGateExtraWidthM;
  const step = kDepthProfileStepM;
  const lo = kDepthProfileMarginM;
  final n = ((wLot - 2 * lo) / step + 1e-9).floor();
  if (n <= 0) return null;
  // The gate's columns [cL, cR]: x0 = lo + cL·step ≤ gateX − gateW/2 and
  // x1 = lo + (cR + 1)·step ≥ gateX + gateW/2.
  final cL = ((gateX - gateW / 2 - lo) / step + 1e-9).floor();
  final cR = ((gateX + gateW / 2 - lo) / step - 1e-9).ceil() - 1;
  if (cL < 0 || cR >= n || cR < cL) return null;
  double heightOf(int c) {
    final xa = lo + c * step, xb = xa + step;
    final far =
        math.min(profile.depthAt(xa + 1e-9), profile.depthAt(xb - 1e-9));
    return math.max(0.0, far - df);
  }

  var core = double.infinity;
  for (var c = cL; c <= cR; c++) {
    core = math.min(core, heightOf(c));
  }
  if (core < kEnvelopeMinSideM - kGenEpsM) return null;
  // Running minimum outward: left[i] over [cL − i, cR], right[j] over
  // [cL, cR + j]; both non-increasing.
  final left = <double>[core];
  for (var c = cL - 1; c >= 0; c--) {
    left.add(math.min(left.last, heightOf(c)));
  }
  final right = <double>[core];
  for (var c = cR + 1; c < n; c++) {
    right.add(math.min(right.last, heightOf(c)));
  }
  final heights = [...left, ...right]..sort((a, b) => b.compareTo(a));
  var bestArea = 0.0;
  SiteRect? best;
  var li = 0, ri = 0;
  for (final h in heights) {
    if (h < kEnvelopeMinSideM - kGenEpsM) break;
    while (li + 1 < left.length && left[li + 1] >= h) {
      li++;
    }
    while (ri + 1 < right.length && right[ri + 1] >= h) {
      ri++;
    }
    final x0 = lo + (cL - li) * step, x1 = lo + (cR + ri + 1) * step;
    final area = (x1 - x0) * h;
    if (area > bestArea + 1e-9) {
      bestArea = area;
      best = SiteRect(x0, df, x1, df + h);
    }
  }
  final r = best;
  if (r == null || r.width < kEnvelopeMinSideM - kGenEpsM) return null;
  var y1 = r.y1;
  if (!profile.containsRect(SiteRect(r.x0, df, r.x1, y1))) {
    var ok = df + kEnvelopeMinSideM, bad = y1;
    if (!profile.containsRect(SiteRect(r.x0, df, r.x1, ok))) return null;
    for (var i = 0; i < 24 && bad - ok > kGenEpsM; i++) {
      final mid = (ok + bad) / 2;
      if (profile.containsRect(SiteRect(r.x0, df, r.x1, mid))) {
        ok = mid;
      } else {
        bad = mid;
      }
    }
    y1 = ok;
  }
  return SiteEnvelope(r.x0, df, r.x1, y1,
      frontInset: df, gateX: gateX, gateW: gateW);
}

/// §3.7 step 6: the best staff car park on the roomier side of the spine at
/// [gateX], its connector at [branchY], inside the band `y ∈ [0.3, Dmax − 6]`,
/// for [target] stalls; null when no aisle with a stall fits.
///
/// Candidates: `k = 1..8` aisles, each with its far edge `y` on a 2.6 m
/// lattice from the shallowest that holds the connector and a stall, stopped
/// at the first that reaches [target]. The candidate holding the most stalls
/// up to [target] wins; among those, the best score (§3.5 terms): `10·min(n,
/// C) − 2·max(0, n − C) − 0.5·(aisle and connector length) + 0.02·envelope
/// area`, the envelope's front at `Df`. (The target comes first: on a
/// 780 m-wide field the area term prices each metre of forecourt at 15.6
/// points and would otherwise stop the car park short of its 12 stalls.)
/// Ties go to the smaller `k`, then the shallower block.
InstallationCarPark? _staffCarPark(SiteContext ctx, double gateX,
    double branchY, double dMax, int target,
    {required double bayNeed, (Vec2, Vec2, Vec2)? throat}) {
  final frame = ctx.frame!;
  final profile = frame.profile;
  final wLot = frame.widthM;
  final depth = ctx.depthM;
  final roomPlus = wLot - kDepthProfileMarginM - gateX;
  final roomMinus = gateX - kDepthProfileMarginM;
  final int sigma;
  if ((roomPlus - roomMinus).abs() <= kGenEpsM) {
    sigma = ctx.tieBreak('installation-car-park-side') & 1 == 0 ? 1 : -1;
  } else {
    sigma = roomPlus > roomMinus ? 1 : -1;
  }
  final room = sigma > 0 ? roomPlus : roomMinus;
  final bandTop = dMax - kForecourtCarParkClearM;
  const halfAisle = kAisleTwoWayWidthM / 2;
  // The band's front: 0.3 m, or behind the throat where a skewed throat
  // leans into the block's x range (§3.7 as built: the block pave never
  // overlaps the throat's).
  var bandFront = _kBandFrontM;
  if (throat != null) {
    final (a, t, d) = throat;
    bandFront = math.max(bandFront,
        _farYBeyond(a, t, d, kInstallationThroatWidthM / 2, gateX, sigma));
  }
  final firstRowY = bandFront + halfAisle; // aisle end nodes, near side
  // C strictly inside aisle 0 only when both its stretches are T-end long.
  final connectorAtEnd = branchY - firstRowY < kTEndAisleMinM - kGenEpsM;
  final aisleY0 = connectorAtEnd ? branchY : firstRowY;
  final paveY0 = aisleY0 - halfAisle;
  if (paveY0 < bandFront - kGenEpsM) return null;
  final dC = InstallationCarPark.offsetOf(0);
  final cx0 = sigma > 0 ? gateX : gateX - dC;
  final cx1 = sigma > 0 ? gateX + dC : gateX;
  if (!profile.containsRect(SiteRect(cx0, branchY - kConnectorWidthM / 2, cx1,
      branchY + kConnectorWidthM / 2))) {
    return null;
  }

  InstallationCarPark? best;
  var bestScore = double.negativeInfinity;
  var bestReach = 0;
  for (var k = 1; k <= kMaxModules; k++) {
    final far = InstallationCarPark.offsetOf(k - 1) + halfAisle + kStallLengthM;
    if (far > room + kGenEpsM) break;
    // The far aisle end: T-end room past C, and a stall between the ends.
    final minHi = math.max(branchY + kTEndAisleMinM + halfAisle,
        aisleY0 + kTEndClearM + kStallWidthM + kTEndClearM + halfAisle);
    for (var yHi = minHi; yHi <= bandTop + kGenEpsM; yHi += kStallWidthM) {
      final block = InstallationCarPark._(
        sigma: sigma,
        aisles: k,
        connectorY: branchY,
        aisleY0: aisleY0,
        aisleY1: yHi - halfAisle,
        paveY0: paveY0,
        depthM: yHi,
        stalls: const [],
      );
      final (bx0, bx1) = _blockX(gateX, block);
      if (!profile.containsRect(SiteRect(bx0, paveY0, bx1, yHi))) break;
      final stalls = _stallsOf(block);
      if (stalls.isEmpty) continue;
      final nS = stalls.length;
      final aisleLen = k * (block.aisleY1 - aisleY0) +
          2 * (k - 1) * kModuleDoubleM +
          dC;
      final dfHere = math.min(
          math.max(kForecourtMinM,
              math.max(yHi + kForecourtCarParkClearM, bayNeed)),
          dMax);
      final score = kScoreStall * math.min(nS, target) -
          kScoreOverflow * math.max(0, nS - target) -
          kScoreDriveLength * aisleLen +
          kScoreEnvelopeArea * wLot * (depth - dfHere);
      final reach = math.min(nS, target);
      if (reach > bestReach || (reach == bestReach && score > bestScore + 1e-9)) {
        bestReach = reach;
        bestScore = score;
        best = InstallationCarPark._(
          sigma: sigma,
          aisles: k,
          connectorY: branchY,
          aisleY0: aisleY0,
          aisleY1: block.aisleY1,
          paveY0: paveY0,
          depthM: yHi,
          stalls: stalls,
        );
      }
      if (nS >= target) break;
    }
  }
  return best;
}

/// The largest frame y of the throat rectangle from [a] to [t] (unit
/// direction [d], half width [hw]) on the car park's side [sigma] at or past
/// the block's near edge `x_G ± kStaffCarParkBandM`; −∞ where none of it
/// reaches there. The rectangle is clipped to that half-plane (one
/// Sutherland–Hodgman pass); its highest remaining vertex is the answer.
double _farYBeyond(
    Vec2 a, Vec2 t, Vec2 d, double hw, double gateX, int sigma) {
  final p = Vec2(-d.n, d.e) * hw;
  final ring = [a - p, t - p, t + p, a + p];
  double side(Vec2 q) => sigma * (q.e - gateX) - kStaffCarParkBandM;
  var far = double.negativeInfinity;
  for (var i = 0; i < ring.length; i++) {
    final q0 = ring[i], q1 = ring[(i + 1) % ring.length];
    final s0 = side(q0), s1 = side(q1);
    if (s0 >= 0) far = math.max(far, q0.n);
    if ((s0 < 0) != (s1 < 0)) {
      final f = s0 / (s0 - s1);
      far = math.max(far, q0.n + (q1.n - q0.n) * f);
    }
  }
  return far;
}

/// The stalls of [cp]'s rows: every aisle's far row, and its near row from
/// the second aisle on (aisle 0's near row would stand in the spine's
/// exclusion); centres on a 2.6 m lattice clear of the last 3 m of every
/// aisle (V7 b, and the cross aisles), each with the run-up bits V9 allows.
List<_Stall> _stallsOf(InstallationCarPark cp) {
  final out = <_Stall>[];
  final y0 = cp.aisleY0 + kTEndClearM;
  final y1 = cp.aisleY1 - kTEndClearM;
  const half = kStallWidthM / 2;
  for (var i = 0; i < cp.aisles; i++) {
    for (final far in i == 0 ? const [true] : const [false, true]) {
      var bay = 0;
      for (var yc = y0 + half; yc + half <= y1 + kGenEpsM; yc += kStallWidthM) {
        // The aisle stretch holding it: aisle 0 splits at C.
        var from = cp.aisleY0, to = cp.aisleY1;
        if (i == 0 && !cp.connectorAtEnd) {
          if (yc <= cp.connectorY + kGenEpsM) {
            to = cp.connectorY;
          } else {
            from = cp.connectorY;
          }
        }
        final s = yc - from, len = to - from;
        var bits = 0;
        if (s - kStallRunupHalfWidthM >= kStallRunupM - kGenEpsM) {
          bits |= kSiteDirFwd;
        }
        if (len - s - kStallRunupHalfWidthM >= kStallRunupM - kGenEpsM) {
          bits |= kSiteDirBwd;
        }
        if (bits != 0) out.add(_Stall(i, far, bay, yc, bits));
        bay++;
      }
    }
  }
  return out;
}
