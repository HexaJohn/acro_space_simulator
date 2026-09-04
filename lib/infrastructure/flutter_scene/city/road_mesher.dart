// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// ONE road pipeline for every road in the world.
///
/// The platted core and the sprawl used to draw their roads with two
/// different pieces of code: the core got lane texture, raised sidewalks
/// with curbs, lamps, junction plates, stop bars and signals; the suburbs
/// got a bare grey ribbon with one dashed line stretched across it however
/// wide it was, and streets that stopped thirty metres short of the county
/// highway with nothing where they met. From the air the two read as a
/// high-detail asset downtown and a placeholder everywhere else — which is
/// exactly what they were.
///
/// Everything here works on an anchor-relative polyline in metres and a
/// [RoadClass], and every caller — [CityNodes] for the core, the sprawl's
/// section and group builders for the suburbs, the viaduct for its deck —
/// draws through it. A road is a road: its class says how many lanes it
/// has, its lanes say where the paint goes, and a junction is decided by
/// [junctionControlFor] from the classes meeting there, wherever it is.
///
/// Geometry, not texture, carries the markings. The carriageway is an
/// asphalt ribbon the road's full width; each painted line is its own thin
/// strip a few centimetres above it, mapping one band of the road atlas
/// across itself. That is what makes an eight-lane expressway cost a road
/// class and nothing else.
library;

import 'dart:math' as math;

import '../../../domain/architecture/architecture_style.dart';
import '../../../domain/colony/city/parcel.dart';
import '../../../domain/colony/city/road_junction.dart';
import '../../../domain/colony/city/sprawl_plan.dart';
import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/shared/vector3.dart';
import '../coord_convert.dart';
import 'city_texture_bakes.dart';
import 'oriented_box.dart';

/// One road END, for deriving junctions: where it is, the next point in
/// along the road (for the leg's direction), and what the road is.
class RoadEnd {
  const RoadEnd(this.at, this.next, this.halfWidthM, this.roadClass,
      {this.paved = true, this.collector = false});
  final Vector3 at;
  final Vector3 next;
  final double halfWidthM;
  final RoadClass roadClass;
  final bool paved;

  /// A subdivision's collector: two of them crossing warrant a roundabout.
  final bool collector;
}

/// One leg of a junction: the direction it leaves the node in, and what it is.
class RoadLeg {
  const RoadLeg(this.dir, this.halfWidthM, this.roadClass, {this.paved = true});

  /// Unit vector from the junction out along the road.
  final Vector3 dir;
  final double halfWidthM;
  final RoadClass roadClass;
  final bool paved;
}

/// A junction, ready to draw: where, what meets there, and how it is
/// controlled.
class RoadJunction {
  const RoadJunction(this.at, this.legs, this.control, {this.liftM = 0});
  final Vector3 at;
  final List<RoadLeg> legs;
  final JunctionControl control;

  /// Radial lift of the node above the draped ground — a ramp terminal on a
  /// bridge approach, say.
  final double liftM;

  double get maxHalfWidthM =>
      legs.fold(0.0, (m, l) => math.max(m, l.halfWidthM));
}

/// A point on a polyline with its local frame.
class _Station {
  _Station(this.p, this.up, this.along, this.side, this.s);
  final Vector3 p;
  final Vector3 up;
  final Vector3 along;

  /// To the RIGHT of travel along the polyline.
  final Vector3 side;

  /// Arc length from the first point.
  final double s;
}

class RoadMesher {
  const RoadMesher._();

  /// The carriageway rides this far above the draped ground, clear of the
  /// terrain between its samples and the graded corridor's own error.
  static const double ribbonLiftM = 0.12;

  /// A curb's height; the sidewalk's top stands this much above the ribbon.
  static const double curbHeightM = 0.15;
  static const double walkTopLiftM = ribbonLiftM + curbHeightM;

  /// Paint sits a few centimetres over the asphalt — enough to win the depth
  /// test, not enough to read as a step.
  static const double paintLiftM = 0.03;

  /// A junction plate covers the ribbons meeting under it.
  static const double plateLiftM = 0.16;

  /// Width of a painted line.
  static const double lineWidthM = 0.15;

  /// Metres of road per repeat of the atlas along V.
  static const double tileM = CityTextureBakes.roadTileM;

  /// Whether painted lines, medians and barriers are drawn at all. The
  /// studio's isolate switch.
  static bool markings = true;

  // ---- Atlas -----------------------------------------------------------------

  /// U at fraction [t] across [band], inset from the band's edges so a mip
  /// level cannot bleed the neighbour in.
  static double bandU(int band, double t) {
    const inset = 0.03;
    return (band + inset + (1 - 2 * inset) * t) / CityTextureBakes.roadBands;
  }

  static int _bandOf(LaneLine line) => switch (line) {
        LaneLine.dashedWhite => CityTextureBakes.roadDashedWhite,
        LaneLine.solidWhite => CityTextureBakes.roadWhite,
        LaneLine.solidYellow => CityTextureBakes.roadYellow,
        LaneLine.dashedYellow => CityTextureBakes.roadDashedYellow,
      };

  // ---- Frames ------------------------------------------------------------------

  static List<_Station> _stations(List<Vector3> pts, Vector3 anchorBF) {
    final out = <_Station>[];
    var s = 0.0;
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i];
      // Local up is radial at the point itself, not at the anchor: a long
      // road curves with the body, and a single shared up would bury one end.
      final up = (p + anchorBF).normalized;
      final ahead = i + 1 < pts.length ? pts[i + 1] - p : p - pts[i - 1];
      final along = ahead.length > 1e-6 ? ahead.normalized : Vector3.unitX;
      final side = along.cross(up).normalized;
      if (i > 0) s += (p - pts[i - 1]).length;
      out.add(_Station(p, up, along, side, s));
    }
    return out;
  }

  /// A strip from lateral [x0] to [x1] (metres from the centreline, positive
  /// to the right of travel) along every station, [band] of the atlas
  /// mapped across it, [lift] above the ground plus [liftAt] of the arc.
  static void _strip(
    MeshBuilder m,
    List<_Station> st,
    double x0,
    double x1,
    int band,
    double lift, {
    double Function(double s)? liftAt,
    double vScale = 1 / tileM,
  }) =>
      _stripFn(m, st, (_) => x0, (_) => x1, band, lift,
          liftAt: liftAt, vScale: vScale);

  /// [_strip] with the lateral extents given per arc length, for a road
  /// that tapers.
  static void _stripFn(
    MeshBuilder m,
    List<_Station> st,
    double Function(double s) x0,
    double Function(double s) x1,
    int band,
    double lift, {
    double Function(double s)? liftAt,
    double vScale = 1 / tileM,
  }) {
    int? prevL, prevR;
    final u0 = bandU(band, 0), u1 = bandU(band, 1);
    for (final k in st) {
      final h = lift + (liftAt?.call(k.s) ?? 0);
      final c = k.p + k.up * h;
      final v = k.s * vScale;
      final l = m.vertex(_s(c + k.side * x0(k.s)), k.up, u0, v);
      final r = m.vertex(_s(c + k.side * x1(k.s)), k.up, u1, v);
      if (prevL != null && prevR != null) m.quad(prevL, prevR, r, l);
      prevL = l;
      prevR = r;
    }
  }

  /// Over how much road a lane drop or a width change is tapered.
  static const double taperM = 90.0;

  /// The half width at arc [s] of a road [hw] wide that starts at [hw0]
  /// and ends at [hw1] (null: its own width), tapering over [taperM].
  static double _taperedHalfWidth(
      double s, double total, double hw, double? hw0, double? hw1) {
    var w = hw;
    if (hw0 != null && s < taperM) w = hw0 + (hw - hw0) * (s / taperM);
    if (hw1 != null && s > total - taperM) {
      w = hw + (hw1 - hw) * ((s - (total - taperM)) / taperM);
    }
    return w;
  }

  // ---- Sound barriers ----------------------------------------------------------

  /// Height of a sound barrier, and how far its panels stand off the
  /// carriageway's edge.
  static const double soundWallHeightM = 4.6;
  static const double soundWallOffsetM = 0.9;

  /// How far short of either end of a piece the walls stop: every end is a
  /// junction, a merge a ramp has to get through, or a change of class.
  static const double soundWallEndGapM = 35.0;

  /// Sound barriers along both edges of [pts]: precast panels a road
  /// segment long, and with [posts] a steel post every few metres. Skipped
  /// over any stretch [liftAt] carries on a bridge, which has parapets of
  /// its own, and over the last stretch at either end. The walled variant
  /// of a highway, the one that runs past housing.
  static void soundWalls(
    MeshBuilder solid,
    List<Vector3> pts,
    Vector3 anchorBF,
    double halfWidthM, {
    double? startHalfWidthM,
    double? endHalfWidthM,
    double Function(double s)? liftAt,
    double liftM = ribbonLiftM,
    bool posts = false,
  }) {
    if (pts.length < 2) return;
    final st = _stations(pts, anchorBF);
    final total = st.last.s;
    if (total < soundWallEndGapM * 2 + 10) return;
    final panelU = (FacadeMaterial.precast + 0.5) / kFacadeMaterials;
    final postU = (FacadeMaterial.steel + 0.5) / kFacadeMaterials;
    double xAt(double s) =>
        _taperedHalfWidth(s, total, halfWidthM, startHalfWidthM, endHalfWidthM) +
        soundWallOffsetM;
    for (final sign in const [-1.0, 1.0]) {
      for (var i = 1; i < st.length; i++) {
        final a = st[i - 1], b = st[i];
        // The part of this segment between the end gaps.
        final s0 = math.max(a.s, soundWallEndGapM);
        final s1 = math.min(b.s, total - soundWallEndGapM);
        if (s1 - s0 < 1) continue;
        if ((liftAt?.call((s0 + s1) / 2) ?? 0) > 0.3) continue;
        final seg = b.p - a.p;
        final len = b.s - a.s;
        if (len < 1e-6) continue;
        Vector3 along(double s) => a.p + seg * ((s - a.s) / len);
        final up = ((a.up + b.up) * 0.5).normalized;
        final side = ((a.side + b.side) * 0.5).normalized;
        final lift = liftM + (liftAt?.call((s0 + s1) / 2) ?? 0);
        final p0 = along(s0) + side * (sign * xAt(s0)) + up * (lift + soundWallHeightM / 2);
        final p1 = along(s1) + side * (sign * xAt(s1)) + up * (lift + soundWallHeightM / 2);
        OrientedBox.span(solid, p0, p1, up, 0.24, soundWallHeightM, u: panelU);
        if (!posts) continue;
        // A post every six metres, a little taller and stouter than the
        // panels, on the road side of them.
        for (var sp = (s0 / 6).ceil() * 6.0; sp <= s1; sp += 6) {
          final foot = along(sp) + side * (sign * (xAt(sp) - 0.2)) + up * lift;
          OrientedBox.upright(solid, foot, a.along, up, 0.36, 0.36,
              soundWallHeightM + 0.3,
              u: postU);
        }
      }
    }
  }

  // ---- Carriageways --------------------------------------------------------------

  /// A plain ribbon [halfWidth] each side of the centreline, U running 0..1
  /// across it for a road that has its OWN texture — the alley's worn
  /// concrete, the dirt track's ruts — or one atlas [band] across it.
  static void ribbon(
    MeshBuilder m,
    List<Vector3> pts,
    Vector3 anchorBF,
    double halfWidth, {
    int? band,
    double liftM = ribbonLiftM,
    double Function(double s)? liftAt,
  }) {
    if (pts.length < 2) return;
    final st = _stations(pts, anchorBF);
    if (band != null) {
      _strip(m, st, -halfWidth, halfWidth, band, liftM, liftAt: liftAt);
      return;
    }
    int? prevL, prevR;
    for (final k in st) {
      final h = liftM + (liftAt?.call(k.s) ?? 0);
      final c = k.p + k.up * h;
      final v = k.s / (halfWidth * 2);
      final l = m.vertex(_s(c + k.side * -halfWidth), k.up, 0, v);
      final r = m.vertex(_s(c + k.side * halfWidth), k.up, 1, v);
      if (prevL != null && prevR != null) m.quad(prevL, prevR, r, l);
      prevL = l;
      prevR = r;
    }
  }

  /// A carriageway of [cls] along [pts]: the asphalt ribbon, and — with
  /// [paint] — every lane line, edge line and median its lane layout lists,
  /// plus a barrier where the layout has one ([solid] takes it).
  ///
  /// [halfWidthM] overrides the class's own width for a road drawn at the
  /// width it was built at; the lane layout is scaled to fit.
  ///
  /// [startHalfWidthM] and [endHalfWidthM] taper the road over [taperM]
  /// at either end into what it meets there — a lane drop, or the deck it
  /// comes off. Over the taper the edge moves in and any line outside the
  /// narrowed edge converges onto it, which is what a dropped lane's
  /// divider does; lines inside keep their place.
  static void carriageway(
    MeshBuilder m,
    List<Vector3> pts,
    Vector3 anchorBF,
    RoadClass cls, {
    double? halfWidthM,
    double? startHalfWidthM,
    double? endHalfWidthM,
    double liftM = ribbonLiftM,
    double Function(double s)? liftAt,
    bool paint = true,
    MeshBuilder? solid,
  }) {
    if (pts.length < 2) return;
    final st = _stations(pts, anchorBF);
    final lanes = cls.lanes;
    final hw = halfWidthM ?? cls.halfWidth;
    final total = st.last.s;
    final hw0 = startHalfWidthM, hw1 = endHalfWidthM;
    double hwAt(double s) => _taperedHalfWidth(s, total, hw, hw0, hw1);

    final tapered = hw0 != null || hw1 != null;
    _stripFn(m, st, (s) => -hwAt(s), hwAt, CityTextureBakes.roadAsphalt, liftM,
        liftAt: liftAt);
    if (lanes == null || !paint || !markings) return;
    // The layout at the drawn width: a road built narrower than its class
    // keeps its lane count and squeezes the lanes.
    final scale = hw / lanes.halfWidthM;
    final shoulder = lanes.shoulderM * scale;
    // A line's place at arc [s]: its own, unless the road has narrowed past
    // it, when it rides the narrowed edge.
    double lineAt(double o, double s) {
      if (!tapered) return o;
      final edge = hwAt(s) - shoulder;
      return o.abs() > edge ? edge * o.sign : o;
    }

    for (final line in lanes.lineOffsets) {
      final o = line.offset * scale;
      _stripFn(m, st, (s) => lineAt(o, s) - lineWidthM / 2,
          (s) => lineAt(o, s) + lineWidthM / 2, _bandOf(line.line),
          liftM + paintLiftM,
          liftAt: liftAt);
    }
    if (lanes.edgeLines && lanes.shoulderM > 0) {
      // The shoulders, a shade paler than the lanes, over the asphalt.
      for (final sign in const [1.0, -1.0]) {
        _stripFn(
            m,
            st,
            (s) => math.min((hwAt(s) - shoulder) * sign, hwAt(s) * sign),
            (s) => math.max((hwAt(s) - shoulder) * sign, hwAt(s) * sign),
            CityTextureBakes.roadShoulder,
            liftM + 0.01,
            liftAt: liftAt);
      }
    }
    if (lanes.divided) {
      final mh = lanes.medianM / 2 * scale;
      switch (lanes.median) {
        case MedianStyle.none:
          break;
        case MedianStyle.painted:
          _strip(m, st, -mh, mh, CityTextureBakes.roadHatch, liftM + paintLiftM,
              liftAt: liftAt);
        case MedianStyle.barrier:
          _strip(m, st, -mh, mh, CityTextureBakes.roadConcrete, liftM + 0.02,
              liftAt: liftAt);
          if (solid != null) _barrier(solid, st, liftM, liftAt);
      }
    }
  }

  /// A concrete Jersey barrier down the centreline: one box per segment,
  /// 0.6 m wide and 0.85 m tall.
  static void _barrier(MeshBuilder solid, List<_Station> st, double liftM,
      double Function(double s)? liftAt) {
    for (var i = 1; i < st.length; i++) {
      final a = st[i - 1], b = st[i];
      final ha = liftM + (liftAt?.call(a.s) ?? 0);
      final hb = liftM + (liftAt?.call(b.s) ?? 0);
      final up = ((a.up + b.up) * 0.5).normalized;
      OrientedBox.span(
        solid,
        a.p + a.up * (ha + 0.425),
        b.p + b.up * (hb + 0.425),
        up,
        0.6,
        0.85,
        u: (FacadeMaterial.precast + 0.5) / kFacadeMaterials,
      );
    }
  }

  // ---- Bridges -----------------------------------------------------------------------

  /// How high a bridge deck stands over what it crosses, and over how much
  /// road it rises to that height — the plan's numbers, so a ramp the plan
  /// lays to reach a deck reaches the deck the renderer draws.
  static const double bridgeHeightM = SprawlPlan.bridgeHeightM;
  static const double bridgeRampM = SprawlPlan.bridgeRampM;

  /// Deck lift at arc length [s] over the bridged [ranges].
  static double bridgeLiftAt(double s, List<(double, double)> ranges) =>
      SprawlPlan.bridgeLiftAt(s, ranges);

  /// Piers under the lifted stretches of [pts]: a column the deck's width
  /// every [spacingM], ground to soffit.
  static void piers(
    MeshBuilder solid,
    List<Vector3> pts,
    Vector3 anchorBF,
    double halfWidth,
    double Function(double s) liftAt, {
    double spacingM = 38,
  }) {
    var sincePier = spacingM;
    var prevS = 0.0;
    for (final k in _stations(pts, anchorBF)) {
      final lift = liftAt(k.s);
      sincePier += k.s - prevS;
      prevS = k.s;
      if (lift <= 0.3) {
        sincePier = spacingM;
        continue;
      }
      // Stations are the polyline's own samples; a pier every few of them.
      if (sincePier < spacingM) continue;
      sincePier = 0;
      final hw = halfWidth * 0.7;
      const hd = 1.2;
      final base = k.p - k.up * 1.0;
      final top = k.p + k.up * (lift - 1.2);
      final c = [
        base - k.side * hw - k.along * hd,
        base + k.side * hw - k.along * hd,
        base + k.side * hw + k.along * hd,
        base - k.side * hw + k.along * hd,
      ];
      final t = [for (final p in c) p + (top - base)];
      final n = [k.along * -1, k.side, k.along, k.side * -1];
      for (var f = 0; f < 4; f++) {
        final a = c[f], b = c[(f + 1) % 4];
        final ta = t[f], tb = t[(f + 1) % 4];
        final i0 = solid.vertex(_s(a), n[f], 0.5, 0);
        final i1 = solid.vertex(_s(b), n[f], 0.5, 0);
        final i2 = solid.vertex(_s(tb), n[f], 0.5, 1);
        final i3 = solid.vertex(_s(ta), n[f], 0.5, 1);
        solid.quad(i0, i1, i2, i3);
      }
    }
  }

  // ---- Sidewalks ----------------------------------------------------------------------

  /// Raised pavements with a real curb face, one strip each side.
  ///
  /// The walk rides [curbHeightM] above the carriageway ribbon, a vertical
  /// curb face closes the step, and both ends pull back so the strip stops
  /// at its crossing instead of bridging the intersecting street — the gap
  /// is where the curb cut and the zebra live. U samples the sidewalk tile
  /// across the walk (curb stones under 0.06, flags above); the curb face
  /// wraps the same curb band down its vertical.
  static void sidewalks(
    MeshBuilder m,
    List<Vector3> pts,
    double halfWidth,
    double pavementM,
    Vector3 anchorBF, {
    double pullStart = 0,
    double pullEnd = 0,
  }) {
    var total = 0.0;
    for (var i = 1; i < pts.length; i++) {
      total += (pts[i] - pts[i - 1]).length;
    }
    // Keep a real run of pavement mid-block or draw none at all.
    pullStart = math.min(pullStart, total * 0.45);
    pullEnd = math.min(pullEnd, total * 0.45);
    if (total - pullStart - pullEnd < 5.0) return;

    // Trim the centreline to the kept span, interpolating the cut points.
    final kept = <Vector3>[];
    final endAt = total - pullEnd;
    if (pullStart <= 0) kept.add(pts.first);
    var d = 0.0;
    for (var i = 1; i < pts.length; i++) {
      final seg = pts[i] - pts[i - 1];
      final len = seg.length;
      if (len < 1e-6) continue;
      final d0 = d;
      d += len;
      if (d0 < pullStart && d > pullStart) {
        kept.add(pts[i - 1] + seg * ((pullStart - d0) / len));
      }
      if (d > pullStart && d < endAt) {
        kept.add(pts[i]);
      } else if (d0 < endAt && d >= endAt) {
        kept.add(pts[i - 1] + seg * ((endAt - d0) / len));
        break;
      }
    }
    if (kept.length < 2) return;

    for (final s in const [-1.0, 1.0]) {
      int? pIn, pOut, pCurbT, pCurbB;
      var v = 0.0;
      for (var i = 0; i < kept.length; i++) {
        final p = kept[i];
        final up = (p + anchorBF).normalized;
        final ahead = i + 1 < kept.length ? kept[i + 1] - p : p - kept[i - 1];
        final along = ahead.length > 1e-6 ? ahead.normalized : Vector3.unitX;
        final side = along.cross(up).normalized;
        if (i > 0) v += (p - kept[i - 1]).length / 9.6; // four flags a tile
        final inner = p + side * (halfWidth * s);
        final outer = p + side * ((halfWidth + pavementM) * s);
        // The face looks at the carriageway.
        final curbN = side * -s;
        final iIn = m.vertex(_s(inner + up * walkTopLiftM), up, 0.03, v);
        final iOut = m.vertex(_s(outer + up * walkTopLiftM), up, 0.97, v);
        final iCt = m.vertex(_s(inner + up * walkTopLiftM), curbN, 0.03, v);
        final iCb = m.vertex(_s(inner + up * ribbonLiftM), curbN, 0.055, v);
        if (pIn != null) {
          // Winding follows the ribbon's convention; the s < 0 strip runs
          // its edges the other way round, so the order flips with it.
          if (s > 0) {
            m.quad(pIn, pOut!, iOut, iIn);
            m.quad(pCurbB!, pCurbT!, iCt, iCb);
          } else {
            m.quad(pOut!, pIn, iIn, iOut);
            m.quad(pCurbT!, pCurbB!, iCb, iCt);
          }
        }
        pIn = iIn;
        pOut = iOut;
        pCurbT = iCt;
        pCurbB = iCb;
      }
    }
  }

  // ---- Lamps -----------------------------------------------------------------------------

  /// Lamp columns down the verge, spaced by road width.
  ///
  /// Derived on the client from the road itself rather than shipped: the rule
  /// is deterministic, and a thousand lamp positions per colony is a lot of
  /// wire for something both ends can compute.
  static void lamps(
    MeshBuilder solid,
    MeshBuilder glow,
    List<Vector3> pts,
    Vector3 anchorBF,
    double halfWidthM,
    RoadClass cls, {
    double liftM = 0,
  }) {
    final scale = halfWidthM / 4.0; // street half-width is 4 m
    final spacing = 34.0 * math.sqrt(math.max(scale, 0.25));
    final height = 9.0 * math.sqrt(math.max(scale, 0.25));
    final both = cls != RoadClass.street;
    var travelled = 0.0;
    var next = spacing * 0.5;
    var flip = 1.0;

    for (var i = 1; i < pts.length; i++) {
      travelled += (pts[i] - pts[i - 1]).length;
      if (travelled < next) continue;
      next += spacing;
      final p = pts[i];
      final up = (p + anchorBF).normalized;
      final along = (pts[i] - pts[i - 1]).normalized;
      final side = along.cross(up).normalized;
      final offset = halfWidthM + 1.2;
      for (final s in both ? const [1.0, -1.0] : [flip]) {
        // On the raised walk when there is one — a column standing on the
        // old bare-drape height would float a curb's worth over the flags.
        final base = p + side * (offset * s) + up * (0.1 + liftM);
        column(solid, base, up, along, height);
        head(glow, base + up * height, up, along);
      }
      flip = -flip;
    }
  }

  /// A galvanised column: a mast, a lamp post, a sign post. Its faces map
  /// the facade atlas's steel band — a face that ran U from 0 to 1 spanned
  /// every band of the atlas and came out striped like a barber's pole.
  static void column(
      MeshBuilder m, Vector3 base, Vector3 up, Vector3 along, double h) {
    final side = along.cross(up).normalized;
    const r = 0.14;
    final u0 = (FacadeMaterial.steel + 0.15) / kFacadeMaterials;
    final u1 = (FacadeMaterial.steel + 0.85) / kFacadeMaterials;
    final corners = [
      base + side * -r + along * -r,
      base + side * r + along * -r,
      base + side * r + along * r,
      base + side * -r + along * r,
    ];
    for (var i = 0; i < 4; i++) {
      final a = corners[i], b = corners[(i + 1) % 4];
      final n = ((a + b) * 0.5 - base).normalized;
      final i0 = m.vertex(_s(a), n, u0, 1);
      final i1 = m.vertex(_s(b), n, u1, 1);
      final i2 = m.vertex(_s(b + up * h), n, u1, 0);
      final i3 = m.vertex(_s(a + up * h), n, u0, 0);
      m.quad(i0, i1, i2, i3);
    }
  }

  static void head(MeshBuilder m, Vector3 at, Vector3 up, Vector3 along) {
    final side = along.cross(up).normalized;
    const hw = 0.55, hd = 0.22;
    final a = at + side * -hw + along * -hd;
    final b = at + side * hw + along * -hd;
    final c = at + side * hw + along * hd;
    final d = at + side * -hw + along * hd;
    // Downward-facing lens: it is the lit surface, so it points at the road.
    final n = up * -1;
    final i0 = m.vertex(_s(a), n, 0, 0);
    final i1 = m.vertex(_s(b), n, 1, 0);
    final i2 = m.vertex(_s(c), n, 1, 1);
    final i3 = m.vertex(_s(d), n, 0, 1);
    m.quad(i0, i3, i2, i1);
  }

  // ---- Junctions -----------------------------------------------------------------------------

  /// Junctions from road ENDS: ends within [toleranceM] of each other are one
  /// node, and the node's control comes from the classes meeting there.
  ///
  /// Roads are split at their crossings, so an intersection is simply a
  /// place where three or more ends meet — the topology is there; this
  /// finds it. Legs split from one crossing land on (nearly) the same
  /// point; the tolerance covers the sampling step they were rebuilt from.
  static List<RoadJunction> junctionsFromEnds(List<RoadEnd> ends,
      {double toleranceM = 8.0}) {
    final out = <RoadJunction>[];
    final used = List<bool>.filled(ends.length, false);
    for (var i = 0; i < ends.length; i++) {
      if (used[i]) continue;
      final at = ends[i].at;
      final group = <RoadEnd>[ends[i]];
      used[i] = true;
      for (var j = i + 1; j < ends.length; j++) {
        if (used[j]) continue;
        if ((ends[j].at - at).length > toleranceM) continue;
        used[j] = true;
        group.add(ends[j]);
      }
      final legs = <RoadLeg>[];
      for (final e in group) {
        final inward = e.next - e.at;
        if (inward.length < 1e-6) continue;
        legs.add(RoadLeg(inward.normalized, e.halfWidthM, e.roadClass,
            paved: e.paved));
      }
      // Where two collectors cross — all four legs collectors, or three at
      // a T — a subdivision builds a roundabout, not a four-way stop.
      final collectors = group.where((e) => e.collector).length;
      final control = junctionControlFor(
          [for (final l in legs) l.roadClass],
          roundaboutPreferred: collectors >= 3);
      if (control == JunctionControl.none) continue;
      out.add(RoadJunction(at, legs, control));
    }
    return out;
  }

  /// Draw [junctions]: a plate, and — with [furniture] — the stop bars,
  /// zebras, signal masts, signs and islands each control calls for.
  ///
  /// Signal phase comes from [epoch]: deterministic, stateless, and the
  /// same on every client looking at the same tick.
  static void junctions(
    MeshBuilder m,
    MeshBuilder poles,
    MeshBuilder lights,
    List<RoadJunction> junctions,
    Vector3 anchorBF,
    double epoch, {
    bool furniture = true,
  }) {
    for (final j in junctions) {
      switch (j.control) {
        case JunctionControl.none:
        case JunctionControl.merge:
          break;
        case JunctionControl.stop:
        case JunctionControl.signals:
          _crossing(m, poles, lights, j, anchorBF, epoch, furniture);
        case JunctionControl.roundabout:
          _roundabout(m, poles, j, anchorBF, furniture);
      }
    }
  }

  /// The basis of a plate: two tangents in the ground plane at [up].
  static (Vector3, Vector3) _tangents(Vector3 up) {
    final seed = up.cross(Vector3.unitZ).lengthSquared > 1e-9
        ? up.cross(Vector3.unitZ)
        : up.cross(Vector3.unitX);
    final t1 = seed.normalized;
    return (t1, up.cross(t1));
  }

  /// A flat polygon of [sides] round [at], radius [r], on [band].
  static void _plate(MeshBuilder m, Vector3 at, Vector3 up, double r, int band,
      int sides) {
    final (t1, t2) = _tangents(up);
    final u = bandU(band, 0.5);
    final centre = m.vertex(_s(at), up, u, 0.5);
    final rim = <int>[];
    for (var k = 0; k < sides; k++) {
      final a = 2 * math.pi * k / sides;
      rim.add(m.vertex(
          _s(at + t1 * (math.cos(a) * r) + t2 * (math.sin(a) * r)), up, u, 0.5));
    }
    for (var k = 0; k < sides; k++) {
      m.triangle(centre, rim[k], rim[(k + 1) % sides]);
    }
  }

  /// A painted bar across a leg: [from] to [to] metres out along [dir],
  /// [halfW] each side, on [band]. V runs ALONG the bar so a dashed band
  /// breaks across the road — a yield line.
  static void _bar(MeshBuilder m, Vector3 at, Vector3 up, Vector3 dir,
      Vector3 side, double from, double to, double halfW, int band,
      {double vScale = 0}) {
    final lift = up * (plateLiftM + paintLiftM);
    final u0 = bandU(band, 0), u1 = bandU(band, 1);
    final near = at + dir * from;
    final far = at + dir * to;
    final v1 = vScale > 0 ? 2 * halfW * vScale : 0.5;
    final q = [
      m.vertex(_s(near - side * halfW + lift), up, u0, 0),
      m.vertex(_s(near + side * halfW + lift), up, u0, v1),
      m.vertex(_s(far + side * halfW + lift), up, u1, v1),
      m.vertex(_s(far - side * halfW + lift), up, u1, 0),
    ];
    m.quad(q[0], q[1], q[2], q[3]);
  }

  /// A stop or signal crossing: plate, stop bars, zebras on a signalised
  /// one, and a mast or a sign on every leg.
  static void _crossing(MeshBuilder m, MeshBuilder poles, MeshBuilder lights,
      RoadJunction j, Vector3 anchorBF, double epoch, bool furniture) {
    if (!j.legs.any((l) => l.paved)) return;
    final up = (j.at + anchorBF).normalized;
    final at = j.at + up * (plateLiftM + j.liftM);
    // An octagonal plate: round enough to serve any number of legs at any
    // angle, cheap enough to draw one per crossing.
    final r = j.maxHalfWidthM * 1.45;
    _plate(m, at, up, r, CityTextureBakes.roadAsphalt, 8);
    if (!furniture) return;
    final signals = j.control == JunctionControl.signals;
    final (t1, t2) = _tangents(up);

    for (final leg in j.legs) {
      if (!leg.paved) continue;
      final dir = leg.dir;
      final side = dir.cross(up).normalized;
      final hw = leg.halfWidthM * 0.92;
      // A stop bar across the leg at the plate's edge: the mark that says a
      // driver yields here, and the reason the crossing reads as controlled
      // rather than as an accident of geometry.
      _bar(m, at, up, dir, side, r * 0.92, r * 0.92 + 0.5, hw,
          CityTextureBakes.roadWhite);

      if (signals) {
        // Zebra OUTSIDE the stop bar: bars run along the direction of
        // travel, which is what makes a crossing read as a crossing rather
        // than as a ladder painted across the road.
        const stripes = 5;
        for (var k = 0; k < stripes; k++) {
          final o = (k / (stripes - 1) - 0.5) * 2 * hw * 0.82;
          final sw = hw * 0.11;
          final lift = up * (plateLiftM + paintLiftM);
          final a0 = at + dir * (r * 0.92 + 2.2) + side * o;
          final a1 = at + dir * (r * 0.92 + 5.0) + side * o;
          final u0 = bandU(CityTextureBakes.roadWhite, 0);
          final u1 = bandU(CityTextureBakes.roadWhite, 1);
          final z = [
            m.vertex(_s(a0 - side * sw + lift), up, u0, 0),
            m.vertex(_s(a0 + side * sw + lift), up, u1, 0),
            m.vertex(_s(a1 + side * sw + lift), up, u1, 0.3),
            m.vertex(_s(a1 - side * sw + lift), up, u0, 0.3),
          ];
          m.quad(z[0], z[1], z[2], z[3]);
        }
      }

      // Control. Signals on the arterial crossing, a sign on the local one
      // — the same rule a traffic engineer would apply, and it means the
      // two read differently from the cockpit.
      final corner = at + dir * (r * 0.98) + side * (hw + 1.6);
      if (signals) {
        column(poles, corner, up, dir, 4.6);
        // The heads CYCLE. Derived from the epoch rather than stored: it is
        // deterministic, costs no state, and opposing legs are out of phase
        // because their inbound directions differ by a quarter turn.
        final axis = (dir.dot(t1).abs() > dir.dot(t2).abs()) ? 0 : 1;
        final green = ((epoch / 12.0).floor() + axis).isEven;
        final top = corner + up * 4.6;
        head(lights, top + up * (green ? 0.0 : 0.55), up, dir);
      } else {
        // A sign: a small plate on a short post, facing the driver — the
        // plate in safety red off the facade atlas.
        column(poles, corner, up, dir, 2.2);
        final plate = corner + up * 2.2;
        const ps = 0.42;
        final su0 = (FacadeMaterial.safetyRed + 0.1) / kFacadeMaterials;
        final su1 = (FacadeMaterial.safetyRed + 0.9) / kFacadeMaterials;
        final pv = [
          poles.vertex(_s(plate - side * ps - up * ps), dir * -1, su0, 0),
          poles.vertex(_s(plate + side * ps - up * ps), dir * -1, su1, 0),
          poles.vertex(_s(plate + side * ps + up * ps), dir * -1, su1, 1),
          poles.vertex(_s(plate - side * ps + up * ps), dir * -1, su0, 1),
        ];
        poles.quad(pv[0], pv[1], pv[2], pv[3]);
      }
    }
  }

  /// A roundabout: a circular plate round a raised concrete island, a yield
  /// line on every approach, no signals.
  static void _roundabout(MeshBuilder m, MeshBuilder poles, RoadJunction j,
      Vector3 anchorBF, bool furniture) {
    final up = (j.at + anchorBF).normalized;
    final at = j.at + up * (plateLiftM + j.liftM);
    // Inscribed radius: room for one circulating lane round the island,
    // and never less than a mini-roundabout's.
    final r = math.max(14.0, j.maxHalfWidthM * 2 + 6);
    _plate(m, at, up, r, CityTextureBakes.roadAsphalt, 16);
    // The island: a concrete disc with a face, a curb's height up.
    final ri = r - 7.0;
    const islandH = 0.3;
    _plate(m, at + up * islandH, up, ri, CityTextureBakes.roadConcrete, 16);
    final (t1, t2) = _tangents(up);
    final u0 = bandU(CityTextureBakes.roadConcrete, 0);
    final u1 = bandU(CityTextureBakes.roadConcrete, 0.2);
    for (var k = 0; k < 16; k++) {
      final a0 = 2 * math.pi * k / 16, a1 = 2 * math.pi * (k + 1) / 16;
      final r0 = t1 * math.cos(a0) + t2 * math.sin(a0);
      final r1 = t1 * math.cos(a1) + t2 * math.sin(a1);
      final n = ((r0 + r1) * 0.5).normalized;
      final q = [
        m.vertex(_s(at + r0 * ri), n, u0, 0),
        m.vertex(_s(at + r1 * ri), n, u1, 0),
        m.vertex(_s(at + r1 * ri + up * islandH), n, u1, 0.1),
        m.vertex(_s(at + r0 * ri + up * islandH), n, u0, 0.1),
      ];
      m.quad(q[0], q[1], q[2], q[3]);
    }
    if (!furniture) return;
    // Circulating lane line round the island, and a broken yield line
    // across every approach at the plate's edge.
    for (final leg in j.legs) {
      if (!leg.paved) continue;
      final dir = leg.dir;
      final side = dir.cross(up).normalized;
      _bar(m, at, up, dir, side, r * 0.96, r * 0.96 + 0.45, leg.halfWidthM * 0.92,
          CityTextureBakes.roadDashedWhite,
          vScale: 1 / 1.2);
      // A keep-right sign on the splitter side of each approach.
      final post = at + dir * (r + 1.2) + side * (leg.halfWidthM + 1.2);
      column(poles, post, up, dir, 1.6);
    }
  }

  /// The turning circle at the end of a street that goes nowhere else.
  static void culDeSac(MeshBuilder m, Vector3 at, Vector3 anchorBF, double radius,
      {double liftM = ribbonLiftM}) {
    final up = (at + anchorBF).normalized;
    _plate(m, at + up * liftM, up, radius, CityTextureBakes.roadAsphalt, 12);
  }

  static Vector3 _s(Vector3 metres) => metres * kRenderScale;
}
