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
/// draws through it. A road is a road: its class (and its dressing) says
/// how many lanes it has, its lanes say where the paint goes, and a
/// junction is decided from the legs meeting there
/// ([RoadMesher.junctionPlan]) — their classes, and where the road tool
/// had a hand, which of them are one-way roads leaving — wherever it is.
/// A road the tool lifted rides its deck ([RoadEnd.liftM], and the
/// carriageway's `liftAt`); `road_deck.dart` builds what the deck stands on.
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
import '../../../domain/colony/city/road_elevation.dart';
import '../../../domain/colony/city/road_junction.dart';
import '../../../domain/colony/city/sprawl_plan.dart';
import '../../../domain/scatter/mesh_builder.dart';
import '../../../domain/shared/vector3.dart';
import '../coord_convert.dart';
import 'city_texture_bakes.dart';
import 'oriented_box.dart';
import 'road_deck.dart';

/// One road END, for deriving junctions: where it is, the next point in
/// along the road (for the leg's direction), and what the road is.
class RoadEnd {
  const RoadEnd(this.at, this.next, this.halfWidthM, this.roadClass,
      {this.paved = true,
      this.collector = false,
      this.isStart = false,
      this.liftM = 0,
      bool? onDeck})
      : onDeck = onDeck ?? liftM != 0;
  final Vector3 at;
  final Vector3 next;
  final double halfWidthM;
  final RoadClass roadClass;
  final bool paved;

  /// A subdivision's collector: two of them crossing warrant a roundabout.
  final bool collector;

  /// This end is its road's FIRST point in the direction of travel (see
  /// `CityTileEnd.isStart`): a one-way road that starts here only ever
  /// LEAVES the junction, which is what the traffic-light warrant and the
  /// stop bars turn on.
  final bool isStart;

  /// The road's deck above the drape at this end: 0 on the ground. Ends at
  /// different heights are not one junction — an overpass's end is not a
  /// leg of the crossing under it (see [RoadMesher.liftsSeparated]).
  final double liftM;

  /// The road has a deck here — raised, sunk, or laid flush at a lift of
  /// exactly 0 — rather than lying on the drape: which side of
  /// [RoadMesher.liftsSeparated] the end answers to, and what a lift of 0
  /// alone cannot say. The tiles carry it from the cut
  /// (`CityTileEnd.onDeck`); unsaid, any lift at all is a deck.
  final bool onDeck;
}

/// One leg of a junction: the direction it leaves the node in, and what it is.
class RoadLeg {
  const RoadLeg(this.dir, this.halfWidthM, this.roadClass,
      {this.paved = true, this.startsHere = false, this.liftM = 0});

  /// Unit vector from the junction out along the road.
  final Vector3 dir;
  final double halfWidthM;
  final RoadClass roadClass;
  final bool paved;

  /// The road's first point in the direction of travel is at the junction
  /// ([RoadEnd.isStart]).
  final bool startsHere;

  /// The leg's deck above the drape where it meets the node ([RoadEnd.liftM]):
  /// at the level of the node's first leg ([RoadMesher.liftsSeparated]).
  final double liftM;

  bool get oneWay => roadClass.oneWay;

  /// Traffic on this leg only ever leaves the junction: a one-way road
  /// that starts here. Nothing arrives along it, so nothing stops on it —
  /// no bar, no sign, no signal (see [JunctionLeg.outgoing]).
  bool get outgoing => oneWay && startsHere;

  /// Traffic arrives at the junction along this leg.
  bool get inbound => !outgoing;
}

/// A junction, ready to draw: where, what meets there, and how it is
/// controlled.
class RoadJunction {
  const RoadJunction(this.at, this.legs, this.control,
      {this.liftM = 0, this.stopLegs, this.wholeBars = false});
  final Vector3 at;
  final List<RoadLeg> legs;
  final JunctionControl control;

  /// Radial lift of the node above the draped ground — a ramp terminal on a
  /// bridge approach, say, or a crossing of two roads the tool raised.
  final double liftM;

  /// Indices into [legs] that STOP at a [JunctionControl.stop] junction —
  /// the plan's [JunctionPlan.stopLegs]: every leg of an all-way stop, the
  /// minor road where it meets a bigger one, or whichever the player chose.
  /// Null stops every inbound leg.
  final Set<int>? stopLegs;

  /// Bars across the WHOLE width of each two-way leg that stops, rather
  /// than across the lanes arriving: how the generator's junctions have
  /// always been drawn, kept for the junctions its warrant still decides
  /// (see [RoadMesher.byClass]) so a town the road tool has not touched
  /// draws to the byte as it did. A one-way leg arriving is barred right
  /// across either way.
  final bool wholeBars;

  double get maxHalfWidthM =>
      legs.fold(0.0, (m, l) => math.max(m, l.halfWidthM));

  /// Whether leg [i] carries the junction's control: a stop bar and a sign
  /// at a stop, a stop bar and a signal at lights, a yield line at a
  /// roundabout. Never on an outgoing leg — nothing arrives along it.
  bool controls(int i) {
    if (!legs[i].inbound) return false;
    if (control == JunctionControl.stop) return stopLegs?.contains(i) ?? true;
    return true;
  }
}

/// A player's override of one junction (the Junctions view), as the
/// junction pass takes it: anchor-relative like the ends, the lights
/// forced on (true), off (false) or left to the warrant (null), and a point
/// out along each leg that stops, laid out from [at] (see
/// [JunctionOverride], which names a leg by its heading; these points are
/// that heading, carried in the frame's body-fixed metres).
class RoadOverride {
  const RoadOverride(this.at, {this.lights, this.stopPoints});
  final Vector3 at;
  final bool? lights;

  /// Null leaves the warrant's default stop legs; empty is the player's
  /// choice that NO leg stops — [JunctionOverride.stopHeadings] as `[]`,
  /// which is not the same thing as leaving it alone.
  final List<Vector3>? stopPoints;
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
  /// over any stretch [liftAt] carries more than [skipAboveM] up — a
  /// bridge, which has parapets of its own; a road the tool raised passes
  /// the structure clearance, so its walls ride the deck where it is at
  /// grade — and over the last stretch at either end. The walled variant
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
    double skipAboveM = 0.3,
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
        if ((liftAt?.call((s0 + s1) / 2) ?? 0) > skipAboveM) continue;
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
  /// width it was built at; the lane layout is scaled to fit. [layout]
  /// overrides the class's lanes for a road dressed otherwise at the same
  /// width — a decorated four-lane road's planted median (see
  /// [RoadClass.lanesFor]).
  ///
  /// [startHalfWidthM] and [endHalfWidthM] taper the road over [taperM]
  /// at either end into what it meets there — a lane drop, or the deck it
  /// comes off. Over the taper the edge moves in and any line outside the
  /// narrowed edge converges onto it, which is what a dropped lane's
  /// divider does; lines inside keep their place.
  ///
  /// With [arrows], a one-way layout gets an arrow down every lane (see
  /// [arrowSpacingM]); with [planting], a planted median is grassed over
  /// inside its kerbs, on the flat colour at [plantingU] of the ground
  /// palette — the builder [planting] draws with.
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
    LaneLayout? layout,
    bool arrows = false,
    MeshBuilder? planting,
    double plantingU = 0.5,
  }) {
    if (pts.length < 2) return;
    final st = _stations(pts, anchorBF);
    final lanes = layout ?? cls.lanes;
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
        case MedianStyle.planted:
          // A kerbed strip down the middle, and — given [planting] — its
          // grass inside the kerbs. The decoration's trees are the
          // caller's: pits the scatter system plants.
          _strip(m, st, -mh, mh, CityTextureBakes.roadConcrete, liftM + 0.02,
              liftAt: liftAt);
          if (planting != null && mh > 0.4) {
            _flatStrip(planting, st, -mh + 0.3, mh - 0.3, liftM + 0.05,
                plantingU,
                liftAt: liftAt);
          }
      }
    }
    if (arrows && lanes.oneWay) {
      _arrows(m, st, lanes, scale, hwAt, shoulder, liftM, liftAt);
    }
  }

  /// A strip from lateral [x0] to [x1] along every station in one flat
  /// colour of a palette: every vertex samples [u] at the swatch's middle,
  /// the way a ground patch does, so no filtering can bleed a neighbour in.
  static void _flatStrip(MeshBuilder m, List<_Station> st, double x0,
      double x1, double lift, double u,
      {double Function(double s)? liftAt}) {
    int? prevL, prevR;
    for (final k in st) {
      final h = lift + (liftAt?.call(k.s) ?? 0);
      final c = k.p + k.up * h;
      final l = m.vertex(_s(c + k.side * x0), k.up, u, 0.5);
      final r = m.vertex(_s(c + k.side * x1), k.up, u, 0.5);
      if (prevL != null && prevR != null) m.quad(prevL, prevR, r, l);
      prevL = l;
      prevR = r;
    }
  }

  /// Road between the arrows painted down a one-way road: about one a
  /// block, spread evenly so that a short road still gets one, midway.
  static const double arrowSpacingM = 50.0;

  /// An arrow down each lane of a one-way road every [arrowSpacingM],
  /// pointing the way the traffic runs: first point to last, the frame's
  /// travel order (a reversed road is flipped before it reaches here).
  /// Geometry on the solid white band, like every other painted line, not
  /// a band of its own — a new atlas band would move every band's U, the
  /// lot aprons' included.
  static void _arrows(
    MeshBuilder m,
    List<_Station> st,
    LaneLayout lanes,
    double scale,
    double Function(double s) hwAt,
    double shoulder,
    double lift,
    double Function(double s)? liftAt,
  ) {
    final total = st.last.s;
    if (total < 20) return;
    final count = math.max(1, (total / arrowSpacingM).floor());
    final u0 = bandU(CityTextureBakes.roadWhite, 0);
    final u1 = bandU(CityTextureBakes.roadWhite, 1);
    // A shaft 0.3 m wide and 2.8 long under a head 1.1 m across and 1.6
    // long: big enough to read from a car, and from the air.
    const shaftHalf = 0.15, headHalf = 0.55;
    const back = -2.2, neck = 0.6, tip = 2.2;
    for (var a = 0; a < count; a++) {
      final s = (a + 0.5) * total / count;
      final f = _frameAt(st, s);
      final h = lift + paintLiftM + (liftAt?.call(s) ?? 0);
      final edge = hwAt(s) - shoulder;
      for (final o0 in lanes.laneOffsets) {
        final o = o0 * scale;
        // A lane the taper has dropped by here gets no arrow.
        if (o.abs() + headHalf > edge) continue;
        final c = f.p + f.up * h + f.side * o;
        Vector3 at(double along, double across) =>
            c + f.along * along + f.side * across;
        final l0 = m.vertex(_s(at(back, -shaftHalf)), f.up, u0, 0);
        final r0 = m.vertex(_s(at(back, shaftHalf)), f.up, u1, 0);
        final r1 = m.vertex(_s(at(neck, shaftHalf)), f.up, u1, 0.5);
        final l1 = m.vertex(_s(at(neck, -shaftHalf)), f.up, u0, 0.5);
        m.quad(l0, r0, r1, l1);
        final hl = m.vertex(_s(at(neck, -headHalf)), f.up, u0, 0.5);
        final hr = m.vertex(_s(at(neck, headHalf)), f.up, u1, 0.5);
        final ht = m.vertex(_s(at(tip, 0)), f.up, (u0 + u1) / 2, 1);
        m.triangle(hl, hr, ht);
      }
    }
  }

  /// The frame at arc [s] along [st]: the point between the stations
  /// either side of it, with their up interpolated and the segment's own
  /// direction.
  static _Station _frameAt(List<_Station> st, double s) {
    for (var i = 1; i < st.length; i++) {
      final b = st[i];
      if (b.s < s && i < st.length - 1) continue;
      final a = st[i - 1];
      final span = b.s - a.s;
      final t = span > 1e-9 ? ((s - a.s) / span).clamp(0.0, 1.0) : 0.0;
      final up = (a.up * (1 - t) + b.up * t).normalized;
      final seg = b.p - a.p;
      final along = seg.length > 1e-6 ? seg.normalized : a.along;
      return _Station(
          a.p + seg * t, up, along, along.cross(up).normalized, s);
    }
    return st.first;
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
  ///
  /// Given [blocked] (see `RoadCorridors`), a pier that falls due in
  /// another road's carriageway moves on along the deck to the first
  /// station clear of it — at most a span on; a road running the length of
  /// the deck beneath it has no clear station, and there the pier stands.
  static void piers(
    MeshBuilder solid,
    List<Vector3> pts,
    Vector3 anchorBF,
    double halfWidth,
    double Function(double s) liftAt, {
    double spacingM = 38,
    PierBlocked? blocked,
  }) {
    var sincePier = spacingM;
    var prevS = 0.0;
    // Where the pier being moved on fell due.
    double? dueAt;
    const hd = 1.2;
    for (final k in _stations(pts, anchorBF)) {
      final lift = liftAt(k.s);
      sincePier += k.s - prevS;
      prevS = k.s;
      if (lift <= 0.3) {
        sincePier = spacingM;
        dueAt = null;
        continue;
      }
      // Stations are the polyline's own samples; a pier every few of them.
      if (sincePier < spacingM) continue;
      if (blocked != null) {
        final due = dueAt ??= k.s;
        if (k.s - due < spacingM &&
            blocked(k.p, k.along, k.up, halfWidth * 0.7, hd)) {
          continue;
        }
        dueAt = null;
      }
      sincePier = 0;
      final hw = halfWidth * 0.7;
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

  /// [pts] trimmed [pullStart] metres in from its first point and
  /// [pullEnd] from its last, the cut points interpolated — or null where
  /// that leaves no real run: each pull is held to 45% of the road, and
  /// under five metres left is none. What a pavement and its verge are
  /// laid along, stopping short of the crossing at either end.
  static List<Vector3>? _trimmed(
      List<Vector3> pts, double pullStart, double pullEnd) {
    var total = 0.0;
    for (var i = 1; i < pts.length; i++) {
      total += (pts[i] - pts[i - 1]).length;
    }
    // Keep a real run of pavement mid-block or draw none at all.
    pullStart = math.min(pullStart, total * 0.45);
    pullEnd = math.min(pullEnd, total * 0.45);
    if (total - pullStart - pullEnd < 5.0) return null;

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
    return kept.length < 2 ? null : kept;
  }

  /// Grass verges between the kerb and the walk, one strip each side: a
  /// decorated two-lane road's dressing. [widthM] of grass laid over the
  /// inner edge of the pavement, just clear of the kerb stones and a
  /// shade above the flags, on the flat colour at [u] of the ground
  /// palette; pulled back from the crossings exactly as the pavement is.
  ///
  /// With [treesOut], a street tree every [treeSpacingM] down the middle
  /// of each verge: a pit (anchor-relative, and a yaw from [seed]) for the
  /// scatter system to plant, like the pavement's own street trees.
  static void verges(
    MeshBuilder m,
    List<Vector3> pts,
    double halfWidth,
    Vector3 anchorBF, {
    required double widthM,
    required double u,
    double pullStart = 0,
    double pullEnd = 0,
    List<(Vector3, double)>? treesOut,
    double treeSpacingM = 12,
    int seed = 0,
  }) {
    final kept = _trimmed(pts, pullStart, pullEnd);
    if (kept == null) return;
    final inner = halfWidth + 0.12;
    final outer = inner + widthM;
    const lift = walkTopLiftM + 0.015;
    for (final s in const [-1.0, 1.0]) {
      int? pIn, pOut;
      for (var i = 0; i < kept.length; i++) {
        final p = kept[i];
        final up = (p + anchorBF).normalized;
        final ahead = i + 1 < kept.length ? kept[i + 1] - p : p - kept[i - 1];
        final along = ahead.length > 1e-6 ? ahead.normalized : Vector3.unitX;
        final side = along.cross(up).normalized;
        final iIn = m.vertex(_s(p + side * (inner * s) + up * lift), up, u, 0.5);
        final iOut =
            m.vertex(_s(p + side * (outer * s) + up * lift), up, u, 0.5);
        if (pIn != null) {
          // The sidewalk's winding: the s < 0 strip runs its edges the
          // other way round.
          if (s > 0) {
            m.quad(pIn, pOut!, iOut, iIn);
          } else {
            m.quad(pOut!, pIn, iIn, iOut);
          }
        }
        pIn = iIn;
        pOut = iOut;
      }
    }
    if (treesOut == null) return;
    var n = 0;
    for (final (p, along, _) in every(kept, treeSpacingM)) {
      final up = (p + anchorBF).normalized;
      final side = along.cross(up).normalized;
      for (final s in const [-1.0, 1.0]) {
        treesOut.add((
          p + side * ((inner + outer) / 2 * s) + up * walkTopLiftM,
          yawOf(seed, n++),
        ));
      }
    }
  }

  /// Points every [spacingM] along [pts], the first half a spacing in:
  /// each with the direction of the segment it falls on and its arc from
  /// the first point. Where a row of trees stands.
  static List<(Vector3, Vector3, double)> every(
      List<Vector3> pts, double spacingM) {
    final out = <(Vector3, Vector3, double)>[];
    var carry = spacingM * 0.5;
    var arc = 0.0;
    for (var i = 1; i < pts.length; i++) {
      final a = pts[i - 1];
      final seg = pts[i] - a;
      final len = seg.length;
      if (len < 1e-6) continue;
      final dir = seg * (1 / len);
      var s = carry;
      while (s < len) {
        out.add((a + dir * s, dir, arc + s));
        s += spacingM;
      }
      carry = s - len;
      arc += len;
    }
    return out;
  }

  /// A yaw for the [i]th pit a road with [seed] plants: an integer
  /// scramble, so every isolate turns the same tree the same way (see
  /// `city_tile_mesher.dart` on why nothing here seeds from `Object.hash`).
  static double yawOf(int seed, int i) {
    var h = (seed ^ (i * 0x27D4EB2F)) & 0x7FFFFFFF;
    h = (h ^ (h >> 15)) * 0x2C1B3C6D & 0x7FFFFFFF;
    h = (h ^ (h >> 12)) * 0x297A2D39 & 0x7FFFFFFF;
    h ^= h >> 15;
    return (h & 0xFFFF) / 65536.0 * 2 * math.pi;
  }

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
    final kept = _trimmed(pts, pullStart, pullEnd);
    if (kept == null) return;

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
  ///
  /// [offsetM] is how far out from the centreline a column stands: on the
  /// verge by default, and on a raised deck just inside its parapet, where
  /// there is no verge to stand on.
  static void lamps(
    MeshBuilder solid,
    MeshBuilder glow,
    List<Vector3> pts,
    Vector3 anchorBF,
    double halfWidthM,
    RoadClass cls, {
    double liftM = 0,
    double? offsetM,
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
      final offset = offsetM ?? halfWidthM + 1.2;
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

  /// Whether two road ends at one plan point, their decks [liftA] and
  /// [liftB] above the drape there, pass one over the other rather than
  /// meet: the layout's grade-separation rule (`CityLayout.levelsSeparated`)
  /// read in lifts, so the tiles draw the junctions the layout cut and the
  /// sim's road graph routes through.
  ///
  /// At one point the drape is shared, so a difference of lifts is the
  /// difference of the decks' heights; and a deck stands clear of the
  /// ground — on piers or in its tunnel — where its lift is past
  /// [RoadElevation.structureClearM] or below `-tunnelCoverM`, the survey's
  /// own line. [deckA] and [deckB] say which ends are on a deck
  /// ([RoadEnd.onDeck]); an end on none is a road on the ground, which has
  /// no level of its own. So: two roads on the ground meet; two decks pass
  /// [RoadElevation.gradeSeparationM] apart or more; a deck and a road on
  /// the ground pass where the deck is clear of the ground. (A 1.5 m
  /// tolerance of its own left two decks four metres apart, or a road sunk
  /// three metres into a cutting, cut into a junction nobody saw; and a
  /// deck told from the ground by a lift of 0 took one laid flush for the
  /// ground, and parted it from a deck three metres up that the layout
  /// joins it to.) The generator's roads carry no deck, so every end it
  /// lays meets every other exactly as it always has.
  static bool liftsSeparated(
      double liftA, bool deckA, double liftB, bool deckB) {
    if (!deckA && !deckB) return false;
    if (deckA && deckB) {
      return (liftA - liftB).abs() >= RoadElevation.gradeSeparationM;
    }
    final deck = deckA ? liftA : liftB;
    return deck > RoadElevation.structureClearM ||
        deck < -RoadElevation.tunnelCoverM;
  }

  /// Junctions from road ENDS: ends within [toleranceM] of each other —
  /// and at one level ([liftsSeparated] says they meet) — are one
  /// node, and the node's control and the legs that stop come from the
  /// legs meeting there ([junctionPlan]): the class-only warrant for the
  /// generator's roads, and where the road tool had a hand, their sizes
  /// and which of them are one-way roads leaving.
  ///
  /// Roads are split at their crossings, so an intersection is simply a
  /// place where three or more ends meet — the topology is there; this
  /// finds it. Legs split from one crossing land on (nearly) the same
  /// point; the tolerance covers the sampling step they were rebuilt from.
  /// An end the tool raised over the crossing, or sank under it, lands on
  /// the same point in plan and is no leg of it: its height is what tells
  /// an overpass from a crossing. A node deeper than
  /// [RoadElevation.tunnelCoverM] is in a tunnel and draws nothing.
  ///
  /// [overrides] are the player's, anchor-relative like the ends: the
  /// nearest within [JunctionOverride.matchM] of a node is that node's.
  /// Its stop points are read as headings in the node's own tangent
  /// frame — the frame its legs' headings are read in — with [anchorBF]
  /// saying which way is up there.
  ///
  /// Grouping is star-shaped and greedy: the lowest unused end seeds a
  /// node, every later unused end within the tolerance OF THE SEED joins
  /// it in index order, and each end joins exactly once. A dense tile has
  /// thousands of ends, so the ends are bucketed by cell first and a seed
  /// only measures the 27 cells around its own — the same groups, in the
  /// same order, without the all-pairs scan that made this the one
  /// indivisible build step to blow a frame.
  static List<RoadJunction> junctionsFromEnds(
    List<RoadEnd> ends, {
    double toleranceM = 8.0,
    List<RoadOverride> overrides = const [],
    Vector3 anchorBF = Vector3.zero,
  }) {
    // The cell is a shade wider than the tolerance so that two ends within
    // it can never land more than one cell apart, even where the division
    // rounds the wrong way on an exact-tolerance pair. A non-positive
    // tolerance still needs a real cell to bucket by; the distance test
    // below is what decides, so any cell at least as wide as the tolerance
    // gives the same answer.
    final cell = toleranceM > 0 ? toleranceM * 1.0625 : 1.0;
    final n = ends.length;
    final cx = List<int>.filled(n, 0),
        cy = List<int>.filled(n, 0),
        cz = List<int>.filled(n, 0);
    var minX = 0, minY = 0, minZ = 0, maxX = 0, maxY = 0, maxZ = 0;
    for (var i = 0; i < n; i++) {
      final p = ends[i].at;
      final x = (p.x / cell).floor(),
          y = (p.y / cell).floor(),
          z = (p.z / cell).floor();
      cx[i] = x;
      cy[i] = y;
      cz[i] = z;
      if (i == 0) {
        minX = maxX = x;
        minY = maxY = y;
        minZ = maxZ = z;
      } else {
        minX = math.min(minX, x);
        maxX = math.max(maxX, x);
        minY = math.min(minY, y);
        maxY = math.max(maxY, y);
        minZ = math.min(minZ, z);
        maxZ = math.max(maxZ, z);
      }
    }
    // One int per cell — cheaper to hash than a record, and exact: cells
    // are offset by the lowest one and strided by the extents, with a
    // cell of padding each side so a neighbour lookup off the edge of the
    // occupied box still gets its own key rather than wrapping onto a row
    // above. Keys wrap only where the ends span millions of cells an axis;
    // even then a shared bucket is only extra candidates for the distance
    // test, and the dedupe below keeps a candidate from joining twice.
    final nx = maxX - minX + 3, ny = maxY - minY + 3;
    int key(int x, int y, int z) =>
        (x - minX + 1) + nx * ((y - minY + 1) + ny * (z - minZ + 1));
    final cells = <int, List<int>>{};
    for (var i = 0; i < n; i++) {
      (cells[key(cx[i], cy[i], cz[i])] ??= <int>[]).add(i);
    }
    final out = <RoadJunction>[];
    final used = List<bool>.filled(n, false);
    final near = <int>[];
    for (var i = 0; i < n; i++) {
      if (used[i]) continue;
      final at = ends[i].at;
      final group = <RoadEnd>[ends[i]];
      used[i] = true;
      near.clear();
      for (var dx = -1; dx <= 1; dx++) {
        for (var dy = -1; dy <= 1; dy++) {
          for (var dz = -1; dz <= 1; dz++) {
            final bucket = cells[key(cx[i] + dx, cy[i] + dy, cz[i] + dz)];
            if (bucket == null) continue;
            for (final j in bucket) {
              if (j <= i || used[j]) continue;
              final q = ends[j].at;
              // Spelled out the way Vector3's subtraction and length compute
              // it, operand for operand, so a pair right on the tolerance
              // falls the same side it always did — minus the allocation.
              final ex = q.x - at.x, ey = q.y - at.y, ez = q.z - at.z;
              if (math.sqrt(ex * ex + ey * ey + ez * ez) > toleranceM) continue;
              // Not the seed's level: a road passing over the node or
              // under it, which is no leg of it.
              if (liftsSeparated(ends[j].liftM, ends[j].onDeck,
                  ends[i].liftM, ends[i].onDeck)) {
                continue;
              }
              near.add(j);
            }
          }
        }
      }
      // Members in index order, as the linear scan found them.
      near.sort();
      var last = -1;
      for (final j in near) {
        if (j == last) continue;
        last = j;
        used[j] = true;
        group.add(ends[j]);
      }
      // A node in its tunnel draws nothing: no plate, no bar, no mast.
      final lift = ends[i].liftM;
      if (lift < -RoadElevation.tunnelCoverM) continue;
      final legs = <RoadLeg>[];
      // Any leg on a deck at all is the tool's (see [byClass]) — one laid
      // flush included, as the graph counts it: a deck, not a lift.
      var lifted = false;
      for (final e in group) {
        final inward = e.next - e.at;
        if (inward.length < 1e-6) continue;
        legs.add(RoadLeg(inward.normalized, e.halfWidthM, e.roadClass,
            paved: e.paved, startsHere: e.isStart, liftM: e.liftM));
        lifted = lifted || e.onDeck;
      }
      // Where two collectors cross — all four legs collectors, or three at
      // a T — a subdivision builds a roundabout, not a four-way stop.
      final collectors = group.where((e) => e.collector).length;
      final override = overrides.isEmpty
          ? null
          : _overrideFor(at, legs, overrides, anchorBF);
      final headings = override?.$2;
      final jlegs = [
        for (var k = 0; k < legs.length; k++)
          JunctionLeg(legs[k].roadClass,
              startsHere: legs[k].startsHere, heading: headings?[k] ?? 0),
      ];
      final plan = junctionPlan(jlegs,
          lifted: lifted,
          roundaboutPreferred: collectors >= 3,
          override: override?.$1);
      if (plan.control == JunctionControl.none) continue;
      out.add(RoadJunction(at, legs, plan.control,
          liftM: lift,
          stopLegs:
              plan.control == JunctionControl.stop ? plan.stopLegs : null,
          wholeBars: byClass(jlegs, lifted: lifted)));
    }
    return out;
  }

  /// Whether [cls] is a road only the road tool lays — see [roadToolOnly],
  /// where the rule lives so the sim's road graph asks the same question.
  static bool toolOnly(RoadClass cls) => roadToolOnly(cls);

  /// Whether a junction of [legs] keeps the generator's class-only warrant
  /// — see [keepsClassWarrant].
  static bool byClass(List<JunctionLeg> legs, {bool lifted = false}) =>
      keepsClassWarrant(legs, lifted: lifted);

  /// The plan the tiles draw a junction of [legs] by — see
  /// [junctionPlanForNetwork], which the sim's road graph times the same
  /// junction by.
  static JunctionPlan junctionPlan(
    List<JunctionLeg> legs, {
    bool lifted = false,
    bool roundaboutPreferred = false,
    JunctionOverride? override,
  }) =>
      junctionPlanForNetwork(legs,
          lifted: lifted,
          roundaboutPreferred: roundaboutPreferred,
          override: override);

  /// The player's override of the node at [at] with [legs] — the nearest
  /// of [overrides] within [JunctionOverride.matchM] — as the plan takes
  /// it, with each leg's heading when it names stop legs (null when it
  /// does not: a heading is read only to match a stop point against).
  static (JunctionOverride, List<double>?)? _overrideFor(Vector3 at,
      List<RoadLeg> legs, List<RoadOverride> overrides, Vector3 anchorBF) {
    RoadOverride? best;
    var bestD = double.infinity;
    for (final o in overrides) {
      final d = (o.at - at).length;
      if (d <= JunctionOverride.matchM && d < bestD) {
        best = o;
        bestD = d;
      }
    }
    if (best == null) return null;
    // The stop points were laid out from the override's own point, which
    // may lie anywhere within the match of the node: read from the node, a
    // point 12 m out from an override 6 m off would swing by atan(6/12),
    // past the heading match on its own. Read in the NODE's frame all the
    // same, the one the legs' headings are read in — the frame turns with
    // the ground beneath it, and near a pole a few metres turn it round.
    final points = best.stopPoints;
    final from = best.at;
    final up = (at + anchorBF).normalized;
    final stops = points == null
        ? null
        : [for (final p in points) headingOf(p - from, up)];
    return (
      // Where it is has been matched here, in the tile's own metres; the
      // plan reads only what it says.
      JunctionOverride(
          at: const Vec2(0, 0), lights: best.lights, stopHeadings: stops),
      stops == null || stops.isEmpty
          ? null
          : [for (final l in legs) headingOf(l.dir, up)],
    );
  }

  /// The heading of [dir] in the tangent plane at [up]: radians from north
  /// toward east, [Vec2.heading]'s convention — what a stop-sign override
  /// names a leg by. East is the body's spin axis crossed with up, north
  /// is up crossed with east; at a pole, where that vanishes, east is +X.
  static double headingOf(Vector3 dir, Vector3 up) {
    var east = Vector3.unitZ.cross(up);
    if (east.lengthSquared < 1e-12) east = Vector3.unitY.cross(up);
    east = east.normalized;
    final north = up.cross(east);
    return math.atan2(dir.dot(east), dir.dot(north));
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
  /// [halfW] each side of a line [offset] metres to its [side] (the leg's
  /// centreline by default), on [band]. V runs ALONG the bar so a dashed
  /// band breaks across the road — a yield line.
  static void _bar(MeshBuilder m, Vector3 at, Vector3 up, Vector3 dir,
      Vector3 side, double from, double to, double halfW, int band,
      {double vScale = 0, double offset = 0}) {
    final lift = up * (plateLiftM + paintLiftM);
    final u0 = bandU(band, 0), u1 = bandU(band, 1);
    final c = offset == 0 ? at : at + side * offset;
    final near = c + dir * from;
    final far = c + dir * to;
    final v1 = vScale > 0 ? 2 * halfW * vScale : 0.5;
    final q = [
      m.vertex(_s(near - side * halfW + lift), up, u0, 0),
      m.vertex(_s(near + side * halfW + lift), up, u0, v1),
      m.vertex(_s(far + side * halfW + lift), up, u1, v1),
      m.vertex(_s(far - side * halfW + lift), up, u1, 0),
    ];
    m.quad(q[0], q[1], q[2], q[3]);
  }

  /// A bar across the lanes a [leg] ARRIVES in, [hw] its half width: the
  /// whole of a one-way road coming in, the inbound half of a two-way one.
  /// Traffic keeps right, so the traffic leaving along the leg is on its
  /// +[side] (to the right of the leg's direction, as a station's side
  /// is) and the traffic arriving on its -side; a bar across all of it
  /// would stop the drivers pulling away. With [whole], right across
  /// either way: a junction drawn as the generator's always were (see
  /// [RoadJunction.wholeBars]).
  static void _inboundBar(MeshBuilder m, Vector3 at, Vector3 up, RoadLeg leg,
      Vector3 side, double from, double to, double hw, int band,
      {double vScale = 0, bool whole = false}) {
    if (whole || leg.oneWay) {
      _bar(m, at, up, leg.dir, side, from, to, hw, band, vScale: vScale);
    } else {
      _bar(m, at, up, leg.dir, side, from, to, hw / 2, band,
          vScale: vScale, offset: -hw / 2);
    }
  }

  /// A stop or signal crossing: plate, zebras on a signalised one, and on
  /// every leg that stops (see [RoadJunction.controls]) a stop bar across
  /// its arriving lanes and a mast or a sign — none on a one-way road
  /// leaving, where nothing arrives to stop.
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

    for (var li = 0; li < j.legs.length; li++) {
      final leg = j.legs[li];
      if (!leg.paved) continue;
      final dir = leg.dir;
      final side = dir.cross(up).normalized;
      final hw = leg.halfWidthM * 0.92;
      final stops = j.controls(li);
      // A stop bar across the leg at the plate's edge: the mark that says a
      // driver yields here, and the reason the crossing reads as controlled
      // rather than as an accident of geometry.
      if (stops) {
        _inboundBar(m, at, up, leg, side, r * 0.92, r * 0.92 + 0.5, hw,
            CityTextureBakes.roadWhite,
            whole: j.wholeBars);
      }

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

      if (!stops) continue;
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
    // across the arriving lanes of every approach at the plate's edge —
    // none across a one-way road leaving the circle.
    for (var li = 0; li < j.legs.length; li++) {
      final leg = j.legs[li];
      if (!leg.paved || !j.controls(li)) continue;
      final dir = leg.dir;
      final side = dir.cross(up).normalized;
      _inboundBar(m, at, up, leg, side, r * 0.96, r * 0.96 + 0.45,
          leg.halfWidthM * 0.92, CityTextureBakes.roadDashedWhite,
          vScale: 1 / 1.2, whole: j.wholeBars);
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
