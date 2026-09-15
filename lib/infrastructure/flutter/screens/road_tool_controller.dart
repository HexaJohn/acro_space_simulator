// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The road tool: what it holds between clicks, and what a click with it
/// does.
///
/// A city builder's road tool lays a road a stretch at a time. The first
/// click on the ground sets where it starts — the ANCHOR — and every click
/// after that builds the stretch from the anchor to where it lands and
/// carries on from there, so a chain of clicks lays a street with no
/// "build" button between them. The modes differ only in the shape of each
/// stretch ([RoadCurves]): STRAIGHT; CURVED, where the second click sets the
/// point the curve is pulled toward; FREEFORM, where each stretch leaves on
/// the heading the last one ended on. UPGRADE instead turns the road
/// clicked into the type held, and a right-click reverses a one-way road.
///
/// Every stretch is priced and charged through `CitySim.buildRoad`, and the
/// hover preview is the same quote on the same snapped line
/// (`CitySim.snapRoadRequest`), so the figure the player reads is the
/// figure the treasury pays. The state lives here, on the controller the
/// flight view owns, rather than in the view: a test can drive a whole
/// chain of clicks against a colony with no widget in sight.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ChangeNotifier;

import '../../../domain/colony/city/city_sim.dart';
import '../../../domain/colony/city/parcel.dart';
import '../../../domain/colony/city/road_build.dart';
import '../../../domain/colony/city/road_catalog.dart';
import '../../../domain/colony/city/road_curves.dart';
import '../../../domain/colony/city/road_elevation.dart';
import '../../../domain/colony/city/road_graph.dart' show RoadGraph, RoadNode;
import '../../../domain/colony/city/road_junction.dart';
import '../../../domain/colony/city/road_snapper.dart';
import '../../../domain/colony/city/road_traffic_model.dart' show TripKind;
import '../../../domain/colony/city/spatial_index.dart' show Box2;

/// How the road tool lays a stretch.
enum RoadToolMode {
  straight('Straight'),
  curved('Curved'),
  freeform('Freeform'),
  upgrade('Upgrade');

  const RoadToolMode(this.label);
  final String label;
}

/// The road info views the Traffic tool opens.
enum TrafficInfoView {
  /// Click a road: the trips that use it, by why they travel.
  routes('Routes'),

  /// Every junction's lights and stop signs, switchable.
  junctions('Junctions'),

  /// Drag a road's end circles to re-lay it; rename it.
  adjust('Adjust'),

  /// Every lane coloured by how fast the agents drive it against its limit;
  /// click a car to inspect it. Agent traffic's view: V and the HUD's Flow
  /// chip open it (traffic_lane_speed_overlay.dart).
  laneSpeed('Lane speed');

  const TrafficInfoView(this.label);
  final String label;
}

/// What the Traffic Routes view calls each kind of trip.
String tripKindLabel(TripKind k) => switch (k) {
      TripKind.commuter => 'Residents',
      TripKind.shopper => 'Shoppers',
      TripKind.goods => 'Goods',
      TripKind.service => 'Services',
    };

/// The colour each kind of trip is drawn in, 0xAARRGGBB — the palette the
/// zoning view already taught: green homes, blue shops, amber industry.
int tripKindArgb(TripKind k) => switch (k) {
      TripKind.commuter => 0xD97FE0A0,
      TripKind.shopper => 0xD94FC3F7,
      TripKind.goods => 0xD9E3A857,
      TripKind.service => 0xD9FF6E6E,
    };

/// Where the next stretch starts.
class RoadAnchor {
  const RoadAnchor(
    this.point, {
    this.elevationM = 0,
    this.heightM,
    this.tangent,
    this.roadId,
  });

  /// Colony-local metres.
  final Vec2 point;

  /// The tool's elevation when the anchor was placed: metres above the
  /// ground under it. What the next stretch starts at, unless [heightM]
  /// says otherwise.
  final double elevationM;

  /// Absolute deck height above the body datum, where the anchor is the end
  /// of a raised or sunk road — joined, or just built. The next stretch
  /// meets that deck where it is, whatever the ground under it does.
  final double? heightM;

  /// The heading a freeform stretch leaves on (unit), or null for none.
  final Vec2? tangent;

  /// The road the anchor lies on, if any.
  final String? roadId;
}

/// The stretch the next click would build, priced.
class RoadPreview {
  const RoadPreview({
    required this.snap,
    required this.request,
    required this.quote,
    this.placesControl = false,
  });

  /// Where the cursor landed.
  final RoadSnap snap;

  /// The request as it would be built — ends already snapped onto the
  /// roads they join, so its controls are the line the quote was measured
  /// on (a deck's pier and tunnel ranges run from its first point).
  final RoadBuildRequest request;
  final RoadQuote quote;

  /// The next click sets the curve's pull point rather than building.
  final bool placesControl;

  List<Vec2> get line => request.controls;
}

/// An Adjust Roads drag, priced: where the dragged end lands and the road
/// as it would be re-laid there — by the rules `CitySim.moveRoadEnd` lays
/// and charges by, so the ghost the player drags is the road the release
/// lays, and the figure beside it is the bill.
class RoadMovePreview {
  const RoadMovePreview({
    required this.roadId,
    required this.atStart,
    required this.end,
    required this.controls,
    required this.quote,
    this.toHeightM,
    this.joinRoadId,
  });

  /// The road being re-laid, and which of its ends moves ([atStart]: its
  /// first control).
  final String roadId;
  final bool atStart;

  /// Where the moved end lands: on the road it was dropped on, else where
  /// it was dropped.
  final Vec2 end;

  /// That end's height above the body datum where it meets another road's
  /// level; null keeps it as high above the ground as it stood.
  final double? toHeightM;

  /// The road it lands on, if any.
  final String? joinRoadId;

  /// The re-laid road's controls, first to last.
  final List<Vec2> controls;

  /// The road as re-laid — its deck, whether it can be — at the price of
  /// what it adds ([RoadQuote.cost]).
  final RoadQuote quote;
}

/// Where the Junctions view draws a junction and its stop signs, sized to
/// the screen — ONE layout, read by the drawing and by the click, so a
/// click lands on what it was drawn over.
///
/// A junction's disc is a handful of pixels across at any zoom, so it
/// grows as the camera pulls back. The stop signs used to stand a fixed
/// 12 m out along their legs: from a district's zoom that is inside the
/// disc, and a click on one switched the junction's lights instead. They
/// stand past its rim now, and a click is the junction's only on its disc.
abstract final class JunctionMarks {
  /// The junction's disc, metres, at [pxM] metres a pixel.
  static double ringRadiusM(double pxM) => _base(pxM) * 1.3;

  /// A stop sign's disc.
  static double stopRadiusM(double pxM) => _base(pxM) * 0.55;

  /// How far out along its leg a stop sign stands: clear of the junction's
  /// disc, and never nearer than 12 m, where the stop bar is.
  static double stopOutM(double pxM) =>
      math.max(12.0, ringRadiusM(pxM) + stopRadiusM(pxM));

  /// How far from a junction a click may still be on one of its stop
  /// signs.
  static double reachM(double pxM) =>
      math.max(20.0, stopOutM(pxM) + stopRadiusM(pxM));

  /// About seven pixels across, never smaller than a lane.
  static double _base(double pxM) => math.max(3.0, 7 * pxM);
}

/// The road tool's state and its click semantics, mixed into the editor's
/// controller.
///
/// Hover work ([previewTo], [upgradeHover]) notifies nobody: it runs on
/// every mouse move, and a rebuild per move is the stall this tool exists
/// to avoid. Everything a click changes notifies.
mixin RoadToolEditing on ChangeNotifier {
  // ---- What the host controller supplies ----------------------------------

  /// Last thing refused, shown in the toolbar.
  String? get blocked;
  set blocked(String? reason);

  /// Free build: the ground does not gate a road's grade.
  bool get ignoreTerrain;

  /// Lot frontage and depth the new road's blocks are cut at.
  double get frontageM;
  double get lotDepthM;

  /// The ground under a colony-local point, metres above the body datum —
  /// what [commitSpline] prices against. Null: flat ground at the datum.
  double Function(Vec2)? get groundAt;

  /// Publish a change to the toolbar and the view.
  void changed();

  // ---- The tool's state -----------------------------------------------------

  /// The type a player starts with: the plain two-lane street.
  static final RoadType defaultRoadType = RoadType.byId('two-lane')!;

  RoadToolMode mode = RoadToolMode.straight;

  RoadType _type = defaultRoadType;

  /// The road menu's open tab.
  RoadGroup roadGroup = RoadGroup.small;

  /// The tool's elevation: metres above the ground where each end is
  /// placed, negative below it. PAGE UP / PAGE DOWN move it.
  double elevationM = 0;

  /// What PAGE UP / PAGE DOWN move it by (3, 6 or 12 m).
  double elevationStepM = RoadElevation.defaultStepM;

  /// The snapping menu.
  RoadSnapOptions snap = const RoadSnapOptions();

  RoadAnchor? anchor;

  /// The Curved mode's pull point, once placed.
  Vec2? control;

  /// The last hover's stretch, or null.
  RoadPreview? preview;

  /// Where the last hover landed, anchor or no anchor — so the view can
  /// show what a first click would snap to.
  RoadSnap? cursorSnap;

  /// The Upgrade tool's hover: the road under the cursor and what turning
  /// it into [roadType] would cost.
  String? upgradeRoadId;
  RoadQuote? upgradeQuote;

  /// The last build, upgrade or re-lay tried, and the road it made.
  RoadQuote? lastQuote;
  String? lastRoadId;

  /// Steepest grade of the stretch being previewed, percent: the deck's
  /// for a raised or sunk road, the ground's while the grade gate is on.
  double? previewGradePct;

  /// Control points of a road built in one go ([commitSpline]) — the
  /// controller API the tests and headless callers drive. The click tool
  /// never adds to it.
  final List<Vec2> pending = [];

  // ---- The info views -------------------------------------------------------

  TrafficInfoView trafficView = TrafficInfoView.routes;

  /// The trip kinds the Routes view draws.
  final Set<TripKind> routeKinds = {...TripKind.values};

  /// The road picked in Routes or Adjust.
  String? selectedRoadId;

  /// How many routes the Routes view drew for [selectedRoadId] — written by
  /// the view, which is where they are counted, and read by the toolbar.
  int? routeCount;

  /// The Adjust drag in progress, priced ([previewMoveEnd]); null when no
  /// end is being dragged.
  RoadMovePreview? movePreview;

  // ---- Type and elevation ---------------------------------------------------

  RoadType get roadType => _type;

  /// Hold [t]. The elevation is clamped to what its class may do: a gravel
  /// road cannot go under, an elevated class is at its own height.
  set roadType(RoadType t) {
    _type = t;
    roadGroup = t.group;
    elevationM = clampElevation(elevationM, t.roadClass);
  }

  /// The toolbar's pick: [t] held, or — while it is still locked — the
  /// reason it cannot be.
  void pickRoadType(RoadType t, {bool unlocked = true}) {
    if (!unlocked) {
      blocked = RoadQuote.refused(t, RoadRefusal.locked).reason;
    } else {
      roadType = t;
      blocked = null;
    }
    upgradeQuote = null;
    changed();
  }

  /// The class the tool lays. Kept for callers from before the road menu:
  /// set, it holds that class's plain entry (walled, when [soundWalls] was
  /// on and the class takes walls).
  RoadClass get roadClass => _type.roadClass;
  set roadClass(RoadClass cls) => roadType = RoadType.forClass(cls,
      soundWalls: soundWalls && cls.canHaveSoundWalls);

  /// The walled variant of the held type, where the menu has one.
  bool get soundWalls => _type.soundWalls;
  set soundWalls(bool on) => roadType = RoadType.forClass(_type.roadClass,
      decoration: _type.decoration, soundWalls: on);

  static double clampElevation(double e, RoadClass cls) => e
      .clamp(RoadElevation.minOffsetFor(cls), RoadElevation.maxOffsetFor(cls))
      .toDouble();

  /// PAGE UP (+1) / PAGE DOWN (-1): one step up or down, onto a multiple of
  /// the step, clamped to the class. A step that cannot be taken says why.
  void stepElevation(int direction) {
    final cls = _type.roadClass;
    final next =
        RoadElevation.step(elevationM, direction, elevationStepM, cls);
    if ((next - elevationM).abs() < 1e-9) {
      final RoadRefusal why;
      if (direction < 0) {
        why = cls.canTunnel ? RoadRefusal.tooDeep : RoadRefusal.noTunnel;
      } else {
        why = cls.canElevate ? RoadRefusal.tooHigh : RoadRefusal.noElevation;
      }
      blocked = RoadQuote.refused(_type, why).reason;
    } else {
      blocked = null;
    }
    elevationM = next;
    changed();
  }

  void setElevationStep(double stepM) {
    if (!RoadElevation.stepChoicesM.contains(stepM)) return;
    elevationStepM = stepM;
    changed();
  }

  void setMode(RoadToolMode m) {
    if (m == mode) return;
    mode = m;
    control = null;
    preview = null;
    upgradeRoadId = null;
    upgradeQuote = null;
    blocked = null;
    // Upgrade acts on roads already built; a half-laid chain means nothing
    // to it. The drawing modes keep the chain: a street can turn from
    // straight to curved mid-way.
    if (m == RoadToolMode.upgrade) anchor = null;
    changed();
  }

  void setSnap(RoadSnapOptions options) {
    snap = options;
    changed();
  }

  // ---- Snapping and shape ---------------------------------------------------

  /// The snapper as the tool is set: its menu, the plat's lot settings
  /// (so the zoning grid is the grid lots are cut on), the new road's width.
  /// [scale] widens every tolerance as the camera pulls back.
  RoadSnapper snapperFor(CitySim city, {double scale = 1}) {
    final plat = city.layout.settings;
    return RoadSnapper(
      city.layout,
      options: snap,
      frontageM: frontageM,
      lotDepthM: lotDepthM,
      cornerClearM: plat.cornerClearM,
      sidewalkM: plat.sidewalkM,
      newHalfWidthM: _type.roadClass.halfWidth,
      scale: scale,
      // An end laid on the ground or above it can neither see a tunnel nor
      // meet one: it passes over, as Adjust's drop does ([_dropSnap]).
      passesOver: elevationM < -RoadElevation.nodeMatchM
          ? null
          : (road, s, lengthM, atStart) =>
              inHiddenTunnel(road, s, lengthM, atStart: atStart),
    );
  }

  /// Whether [road] at arc [s] of its [lengthM] (as indexed) is in its
  /// tunnel: out of sight from the ground, and met only by an end below it.
  /// [atStart] names an END (true: its first), which is in its tunnel when
  /// it was laid deeper than the tunnel cover below its ground, as the
  /// renderer judges a node. A stretch is read on the deck's own measure
  /// ([RoadDeck.rangeArc]) and half a metre wide: the survey's ranges can
  /// end a hair short of the length the index measures.
  ///
  /// The one rule both of the tool's snaps pass over a tunnel by — the
  /// drawing snap ([snapperFor]) and Adjust's drop ([_dropSnap]).
  static bool inHiddenTunnel(RoadSpline road, double s, double lengthM,
      {bool? atStart}) {
    final deck = road.deck;
    if (deck == null) return false;
    if (atStart != null &&
        (atStart ? deck.startOffsetM : deck.endOffsetM) <
            -RoadElevation.tunnelCoverM) {
      return true;
    }
    final r = deck.rangeArc(s, lengthM);
    for (final (a, b) in deck.tunnels) {
      if (r >= a - 0.5 && r <= b + 0.5) return true;
    }
    return false;
  }

  /// Where [cursor] lands. The angle and grid snaps measure from the
  /// anchor along the heading the chain carries — or, once a curve's pull
  /// point is set, from that point along the heading the curve arrives on.
  RoadSnap snapCursor(CitySim city, Vec2 cursor, {double scale = 1}) {
    final a = anchor;
    var from = a?.point;
    var fromTangent = a?.tangent;
    final c = control;
    if (a != null && c != null && mode == RoadToolMode.curved) {
      from = c;
      final d = c - a.point;
      fromTangent = d.length > 1e-6 ? d.normalized : null;
    }
    return snapperFor(city, scale: scale)
        .snap(cursor, from: from, fromTangent: fromTangent);
  }

  /// The stretch from the anchor to [end] in the current mode, as a dense
  /// polyline (straight: its two ends). Null without an anchor, or in
  /// Upgrade.
  List<Vec2>? shapeTo(Vec2 end) {
    final a = anchor;
    if (a == null) return null;
    switch (mode) {
      case RoadToolMode.straight:
        return RoadCurves.straight(a.point, end);
      case RoadToolMode.curved:
        final c = control;
        // Before the pull point is set, the stretch shown is the straight
        // line the second click will bend.
        return c == null
            ? RoadCurves.straight(a.point, end)
            : RoadCurves.quadratic(a.point, c, end);
      case RoadToolMode.freeform:
        final t = a.tangent;
        // The first stretch of a chain has no heading to carry — unless it
        // leaves the end of a road, which it then carries on.
        return t == null
            ? RoadCurves.straight(a.point, end)
            : RoadCurves.tangentArc(a.point, t, end);
      case RoadToolMode.upgrade:
        return null;
    }
  }

  /// The request for [controls] from the anchor to [end]: the start where
  /// the anchor put it; the end at the tool's elevation — or, landed on a
  /// road, at that road's level there ([joinLevelAt], judged over
  /// [ground]: the hover's raster, or a click's exact field; null is flat
  /// ground at the datum).
  RoadBuildRequest requestTo(CitySim city, List<Vec2> controls, RoadSnap end,
      {double Function(Vec2)? ground}) {
    final a = anchor!;
    final join = joinLevelAt(city, end, ground: ground);
    return RoadBuildRequest(
      controls: controls,
      type: _type,
      startElevationM: a.elevationM,
      endElevationM: join?.elevationM ?? elevationM,
      startHeightM: a.heightM,
      endHeightM: join?.heightM,
      snapStart: snap.roads,
      snapEnd: snap.roads,
    );
  }

  /// The level an end placed at [s] takes where [s] landed on a road —
  /// that road's own level there, as in every city builder — or null off
  /// any road, where the end stands at the tool's elevation.
  ///
  /// On a road laid on the ground, or a deck graded into the ground there,
  /// the end is laid on the ground too: elevation 0, no height. Held at the
  /// tool's +12 m instead, it stood in the air over the street it had
  /// snapped to — the layout passed it over as grade-separated, the snap
  /// refused it, and the join marker promised a junction that was never
  /// built. On a deck clear of the ground, the end meets the deck at its
  /// height.
  ///
  /// A road's END is judged as the road graph joins ends: a deck end within
  /// two metres of the ground it was laid on is at grade
  /// ([RoadDeck.endAtGrade]) — so the ground end of a ramp hands on no
  /// height, which would have had the next stretch surveyed as a deck from
  /// end to end: piers over every dip, a tunnel under every rise. A point
  /// ALONG a deck is judged over [ground] by the same two metres
  /// ([RoadElevation.nodeMatchM]), the offset the layout gives the ends of
  /// the pieces it cuts the deck into there.
  ({double elevationM, double? heightM})? joinLevelAt(CitySim city, RoadSnap s,
      {double Function(Vec2)? ground}) {
    final id = s.onRoad ? s.roadId : null;
    if (id == null) return null;
    const ({double elevationM, double? heightM}) onGround =
        (elevationM: 0.0, heightM: null);
    final deck = city.layout.roadById(id)?.deck;
    if (deck == null) return onGround;
    if (s.kind == RoadSnapKind.roadEnd) {
      final first = s.roadEndIsStart ?? false;
      if (first ? deck.startAtGrade : deck.endAtGrade) return onGround;
      return first
          ? (elevationM: deck.startOffsetM, heightM: deck.startM)
          : (elevationM: deck.endOffsetM, heightM: deck.endM);
    }
    final h = city.deckHeightAt(id, s.point);
    if (h == null) return onGround;
    final offset = h - (ground?.call(s.point) ?? 0);
    if (offset.abs() < RoadElevation.nodeMatchM) return onGround;
    return (elevationM: offset, heightM: h);
  }

  // ---- Hover ----------------------------------------------------------------

  /// Snap [cursor] and price the stretch the next click would build — the
  /// hover preview. [ground] is the ground it is surveyed over (the view's
  /// cheap raster); [scale] widens the snap tolerances. Stores the result
  /// in [preview] and [cursorSnap] and notifies nobody.
  RoadPreview? previewTo(
    CitySim city,
    Vec2 cursor, {
    double Function(Vec2)? ground,
    double scale = 1,
  }) {
    if (mode == RoadToolMode.upgrade) {
      cursorSnap = null;
      return _noPreview();
    }
    final s = snapCursor(city, cursor, scale: scale);
    cursorSnap = s;
    if (anchor == null) return _noPreview();
    final shape = shapeTo(s.point)!;
    // The cursor on the anchor itself: nothing to show yet.
    if (RoadCurves.length(shape) < 1) return _noPreview();
    final snapped = city.snapRoadRequest(
        requestTo(city, shape, s, ground: ground),
        groundAt: ground);
    final q =
        city.quoteRoad(snapped, groundAt: ground, gradeGate: !ignoreTerrain);
    previewGradePct = q.deck != null || !ignoreTerrain ? q.gradePct : null;
    return preview = RoadPreview(
      snap: s,
      request: snapped,
      quote: q,
      placesControl: mode == RoadToolMode.curved && control == null,
    );
  }

  RoadPreview? _noPreview() {
    preview = null;
    previewGradePct = null;
    return null;
  }

  /// The Upgrade tool's hover: the road under [p] and the price of turning
  /// it into the held type. Notifies nobody.
  RoadQuote? upgradeHover(
    CitySim city,
    Vec2 p, {
    double Function(Vec2)? ground,
    double scale = 1,
  }) {
    final id = roadAt(city, p, scale: scale);
    upgradeRoadId = id;
    return upgradeQuote =
        id == null ? null : city.quoteUpgrade(id, _type, groundAt: ground);
  }

  // ---- Clicks ---------------------------------------------------------------

  /// A primary click at [cursor] (colony-local, not yet snapped). [ground]
  /// is what a build is priced and laid on — the exact field, not the
  /// hover raster; [scale] as for [snapCursor].
  void clickAt(
    CitySim city,
    Vec2 cursor, {
    double Function(Vec2)? ground,
    double scale = 1,
  }) {
    blocked = null;
    if (mode == RoadToolMode.upgrade) {
      upgradeAt(city, cursor, ground: ground, scale: scale);
      return;
    }
    final s = snapCursor(city, cursor, scale: scale);
    final a = anchor;
    if (a == null) {
      anchor = _anchorOn(city, s, ground: ground);
      preview = null;
      changed();
      return;
    }
    if (mode == RoadToolMode.curved && control == null) {
      if (s.point.distanceTo(a.point) < 1) return;
      control = s.point;
      preview = null;
      changed();
      return;
    }
    _build(city, shapeTo(s.point)!, s, ground: ground);
  }

  /// An anchor where [s] landed: at the level of the road it landed on
  /// ([joinLevelAt]) — else at the tool's elevation — and carrying that
  /// road on where it landed on its end.
  RoadAnchor _anchorOn(CitySim city, RoadSnap s,
      {double Function(Vec2)? ground}) {
    final id = s.onRoad ? s.roadId : null;
    Vec2? tangent;
    final t = s.roadTangent;
    if (s.kind == RoadSnapKind.roadEnd && t != null) {
      // Out of a road's first point is backwards along it; out of its last,
      // forwards.
      tangent = s.roadEndIsStart == true ? t * -1.0 : t;
    }
    final join = joinLevelAt(city, s, ground: ground);
    return RoadAnchor(
      s.point,
      elevationM: join?.elevationM ?? elevationM,
      heightM: join?.heightM,
      tangent: tangent,
      roadId: id,
    );
  }

  /// Build [shape] from the anchor to [end]. Built: the chain carries on
  /// from its end — at its deck, on its heading. Refused: the anchor stays
  /// where it was and the toolbar says why.
  bool _build(CitySim city, List<Vec2> shape, RoadSnap end,
      {double Function(Vec2)? ground}) {
    _applyLotSettings(city);
    final snapped = city.snapRoadRequest(
        requestTo(city, shape, end, ground: ground),
        groundAt: ground);
    final r =
        city.buildRoad(snapped, groundAt: ground, gradeGate: !ignoreTerrain);
    lastQuote = r.quote;
    preview = null;
    if (r.roadId == null) {
      blocked = r.quote.reason;
      changed();
      return false;
    }
    lastRoadId = r.roadId;
    final line = snapped.controls;
    // The chain carries the deck on only where its end is off the ground.
    // A ramp brought back down ends AT GRADE, and the next stretch is laid
    // on the ground from there: handed the ramp's end height instead, it
    // was surveyed as a deck from end to end — and so was every stretch
    // after it — piers over every dip, a tunnel under every rise, the
    // structure price for all of it.
    final deck = r.quote.deck;
    final raised = deck != null && !deck.endAtGrade ? deck : null;
    anchor = RoadAnchor(
      line.last,
      elevationM: raised?.endOffsetM ?? 0,
      heightM: raised?.endM,
      tangent: RoadCurves.endTangent(line),
      roadId: r.roadId,
    );
    control = null;
    changed();
    return true;
  }

  /// The lot settings onto the plat — only when they moved: setting them
  /// re-cuts every lot in the colony.
  void _applyLotSettings(CitySim city) {
    final s = city.layout.settings;
    if (s.frontageM == frontageM && s.depthM == lotDepthM) return;
    city.layout.settings = s.copyWith(frontageM: frontageM, depthM: lotDepthM);
  }

  /// A right-click. In Upgrade: reverse the one-way road under [cursor].
  /// While drawing: one step back — the curve's pull point, else the chain.
  /// Whether it did anything.
  bool rightClickAt(CitySim city, Vec2? cursor, {double scale = 1}) {
    if (mode == RoadToolMode.upgrade) {
      return cursor != null && reverseAt(city, cursor, scale: scale);
    }
    if (control != null) {
      control = null;
      preview = null;
      changed();
      return true;
    }
    if (anchor != null) {
      endChain();
      return true;
    }
    return false;
  }

  /// Stop drawing: the next click starts a new road.
  void endChain() {
    anchor = null;
    control = null;
    preview = null;
    previewGradePct = null;
    blocked = null;
    changed();
  }

  /// Esc: end the chain. False when nothing was being drawn.
  bool escape() {
    if (anchor == null && control == null && pending.isEmpty) return false;
    pending.clear();
    endChain();
    return true;
  }

  /// Everything the road tool holds between clicks, dropped — another tool
  /// was picked up.
  void resetRoadTool() {
    anchor = null;
    control = null;
    preview = null;
    cursorSnap = null;
    upgradeRoadId = null;
    upgradeQuote = null;
    previewGradePct = null;
    selectedRoadId = null;
    routeCount = null;
    movePreview = null;
  }

  // ---- Upgrade --------------------------------------------------------------

  /// The road under [p] — the nearest within 12 m (wider when the camera
  /// is far) — or null.
  String? roadAt(CitySim city, Vec2 p, {double scale = 1}) =>
      city.layout.nearestRoadPoint(p, withinM: 12 * scale)?.roadId;

  /// Turn the road under [p] into the held type (a downgrade too).
  RoadQuote? upgradeAt(
    CitySim city,
    Vec2 p, {
    double Function(Vec2)? ground,
    double scale = 1,
  }) {
    final id = roadAt(city, p, scale: scale);
    if (id == null) {
      blocked = 'Click a road to make it a ${_type.label}';
      changed();
      return null;
    }
    final q = city.upgradeRoad(id, _type, groundAt: ground);
    lastQuote = q;
    lastRoadId = id;
    blocked = q.ok ? null : q.reason;
    // Re-quoted on the next hover: the road is not what it was.
    upgradeRoadId = null;
    upgradeQuote = null;
    changed();
    return q;
  }

  /// Reverse the one-way road under [p]. A two-way road says why not.
  bool reverseAt(CitySim city, Vec2 p, {double scale = 1}) {
    final id = roadAt(city, p, scale: scale);
    if (id == null) return false;
    final ok = city.reverseRoad(id);
    blocked = ok ? null : city.blocked;
    upgradeRoadId = null;
    upgradeQuote = null;
    changed();
    return ok;
  }

  // ---- Building in one go ---------------------------------------------------

  /// Add a control point to [pending].
  void addSplinePoint(Vec2 p) {
    // Skip points a hand-drag dumps almost on top of each other: they make
    // the curve cusp and buy nothing.
    if (pending.isNotEmpty && pending.last.distanceTo(p) < 8) return;
    pending.add(p);
    changed();
  }

  /// Throw [pending] away.
  void cancelSpline() {
    pending.clear();
    previewGradePct = null;
    changed();
  }

  /// Build [pending] as one road of the held type at the tool's elevation,
  /// through the same priced path as a click: junctions split, lots re-cut,
  /// buildings carried across, the treasury charged. Refused, the points
  /// are KEPT — the player re-routes or drops a tier rather than redrawing
  /// from nothing — and the toolbar says why.
  void commitSpline(CitySim city) {
    if (pending.length < 2) {
      pending.clear();
      changed();
      return;
    }
    _applyLotSettings(city);
    final r = city.buildRoad(
      RoadBuildRequest(
        controls: List.of(pending),
        type: _type,
        startElevationM: elevationM,
        endElevationM: elevationM,
        snapStart: snap.roads,
        snapEnd: snap.roads,
      ),
      groundAt: groundAt,
      gradeGate: !ignoreTerrain,
    );
    lastQuote = r.quote;
    if (r.roadId == null) {
      blocked = r.quote.reason;
      changed();
      return;
    }
    lastRoadId = r.roadId;
    pending.clear();
    previewGradePct = null;
    blocked = null;
    changed();
  }

  // ---- Info views -----------------------------------------------------------

  void setTrafficView(TrafficInfoView v) {
    if (v == trafficView) return;
    trafficView = v;
    selectedRoadId = null;
    routeCount = null;
    movePreview = null;
    blocked = null;
    changed();
  }

  void toggleRouteKind(TripKind k) {
    if (!routeKinds.remove(k)) routeKinds.add(k);
    changed();
  }

  void selectRoad(String? id) {
    if (id == selectedRoadId) return;
    selectedRoadId = id;
    routeCount = null;
    movePreview = null;
    blocked = null;
    changed();
  }

  /// Esc in the info views: drop the selection. False with none.
  bool escapeTraffic() {
    if (selectedRoadId == null) return false;
    selectRoad(null);
    return true;
  }

  /// The Junctions view's click at [p], the view at [pxM] metres a pixel:
  /// on a junction's disc its lights go on or off; out along one of its
  /// legs — where its stop sign is drawn — that leg's stop sign comes or
  /// goes. Both are read by [JunctionMarks], the layout the markers are
  /// drawn by. What the plan was comes from the road graph — the plan the
  /// tiles draw and the traffic waits at. Whether anything changed.
  bool toggleJunctionAt(CitySim city, Vec2 p, {double pxM = 1}) {
    final node = _junctionNear(city.roadGraph, p, JunctionMarks.reachM(pxM));
    if (node == null) {
      blocked = 'Click a junction — a place where three roads or more meet';
      changed();
      return false;
    }
    final plan = node.plan;
    final signalled = plan.control == JunctionControl.signals ||
        plan.control == JunctionControl.stop;
    final current = city.junctionOverrideNear(node.at) ??
        JunctionOverride(at: node.at);
    final d = p - node.at;
    if (d.length <= JunctionMarks.ringRadiusM(pxM)) {
      if (!signalled) {
        blocked = plan.control == JunctionControl.roundabout
            ? 'A roundabout runs without lights'
            : 'This junction merges; it takes no lights';
        changed();
        return false;
      }
      city.setJunctionOverride(current.copyWith(lights: !plan.lights));
      blocked = null;
      changed();
      return true;
    }
    // A leg: the one whose heading the click lies along.
    final heading = d.heading;
    var best = -1;
    var bestAngle = double.infinity;
    for (var i = 0; i < node.legs.length; i++) {
      final a = _angleBetween(heading, node.legs[i].heading);
      if (a < bestAngle) {
        bestAngle = a;
        best = i;
      }
    }
    if (best < 0 || bestAngle > 40 * math.pi / 180) return false;
    if (plan.lights) {
      blocked = 'Switch the lights off to give this junction stop signs';
      changed();
      return false;
    }
    if (plan.control != JunctionControl.stop) return false;
    if (!node.legs[best].inbound) {
      blocked = 'Nothing arrives along a one-way road leaving the junction';
      changed();
      return false;
    }
    final had = plan.stopLegs.contains(best);
    final stops = [
      for (final i in plan.stopLegs)
        if (i != best) node.legs[i].heading,
      if (!had) node.legs[best].heading,
    ];
    city.setJunctionOverride(current.copyWith(stopHeadings: stops));
    blocked = null;
    changed();
    return true;
  }

  static double _angleBetween(double a, double b) {
    const tau = 2 * math.pi;
    var d = (a - b) % tau;
    if (d < 0) d += tau;
    return d > math.pi ? tau - d : d;
  }

  /// The junction nearest [p] within [withinM]. Only junctions: the reach
  /// is wide enough to take a click on a stop sign far out along a leg,
  /// and a bend or a dead end nearer the click must not win it.
  static RoadNode? _junctionNear(RoadGraph g, Vec2 p, double withinM) {
    RoadNode? best;
    var bestD = withinM;
    for (final n in g.nodes) {
      if (!n.isJunction) continue;
      final d = n.at.distanceTo(p);
      if (d <= bestD) {
        bestD = d;
        best = n;
      }
    }
    return best;
  }

  // ---- Adjust Roads ---------------------------------------------------------

  static double _flatGround(Vec2 _) => 0;

  /// Where Adjust Roads would re-lay [roadId] with its end [atStart] (its
  /// first control) dropped at [to], and what that would cost — null for a
  /// road that is gone. The drag's preview ([previewMoveEnd]) and the
  /// release ([moveSelectedEnd]) both come through here, so the road drawn
  /// under the pointer is the road laid when it lets go:
  ///
  /// * Dropped near another road, the end lands ON it — its nearest end
  ///   within [RoadSnapper.endSnapM], else its nearest point within
  ///   [CitySim.roadSnapM], as the road tool snaps — and takes its level
  ///   there ([joinLevelAt]). A raised road's end dropped on a street comes
  ///   down to meet it, where it used to hang over it at its old offset,
  ///   passed over as grade-separated. A road on the ground dropped on one
  ///   stays on the ground — and never lands on a tunnel, which the view
  ///   does not show and only an end underground can meet ([_dropSnap]).
  /// * From there the line, the deck and the price are
  ///   `CitySim.planMoveRoadEnd`'s — the very plan `CitySim.moveRoadEnd`
  ///   lays and charges, so the preview is the bill by construction: the
  ///   end left alone keeps its height, the moved one stands at the level
  ///   it met or as high above the ground as it stood, a road on the ground
  ///   stays on it; charged the road as re-laid less the road it replaces,
  ///   both surveyed over [ground] (null: flat at the datum).
  RoadMovePreview? planMoveEnd(
    CitySim city,
    String roadId, {
    required bool atStart,
    required Vec2 to,
    double Function(Vec2)? ground,
  }) {
    final road = city.layout.roadById(roadId);
    if (road == null || road.controls.length < 2) return null;
    final g = ground ?? _flatGround;
    final deck = road.deck;
    final hit = _dropSnap(city, to, roadId,
        underground: _endUnderground(deck, atStart: atStart));
    double? toHeightM;
    if (hit != null) {
      final join = joinLevelAt(city, hit, ground: g);
      // At grade there: a raised or sunk road comes to the ground; one on
      // the ground needs no height (an absolute one would make it a deck
      // from end to end, standing on piers over the first dip).
      toHeightM = join?.heightM ?? (deck == null ? null : g(hit.point));
    }
    final end = hit?.point ?? to;
    final plan = city.planMoveRoadEnd(roadId,
        atStart: atStart, to: end, toHeightM: toHeightM, groundAt: ground);
    if (plan == null) return null;
    return RoadMovePreview(
      roadId: roadId,
      atStart: atStart,
      end: end,
      toHeightM: toHeightM,
      joinRoadId: hit?.roadId,
      controls: plan.controls,
      quote: plan.quote,
    );
  }

  /// Whether a road with [deck] has its end [atStart] below the ground it
  /// was laid on — a sunk road, which may meet another in its tunnel.
  static bool _endUnderground(RoadDeck? deck, {required bool atStart}) =>
      deck != null &&
      (atStart ? deck.startOffsetM : deck.endOffsetM) <
          -RoadElevation.nodeMatchM;

  /// The Adjust drag's hover: [planMoveEnd] for the selected road, kept in
  /// [movePreview] for the ghost and the toolbar. Notifies nobody — it
  /// runs on every move of the drag.
  RoadMovePreview? previewMoveEnd(
    CitySim city, {
    required bool atStart,
    required Vec2 to,
    double Function(Vec2)? ground,
  }) {
    final id = selectedRoadId;
    return movePreview = id == null
        ? null
        : planMoveEnd(city, id, atStart: atStart, to: to, ground: ground);
  }

  /// Adjust Roads: drag an end of the selected road ([atStart]: its first
  /// control) to [to] and re-lay it — where [planMoveEnd] says, at the
  /// level it says: dropped on a road, the end meets it. [ground] as for
  /// [clickAt]. The selection follows the road to its new id.
  ({String? roadId, RoadQuote quote})? moveSelectedEnd(
    CitySim city, {
    required bool atStart,
    required Vec2 to,
    double Function(Vec2)? ground,
  }) {
    final id = selectedRoadId;
    if (id == null) return null;
    movePreview = null;
    final plan = planMoveEnd(city, id, atStart: atStart, to: to, ground: ground);
    final end = plan?.end ?? to;
    final r = city.moveRoadEnd(id,
        atStart: atStart,
        to: end,
        toHeightM: plan?.toHeightM,
        groundAt: ground);
    lastQuote = r.quote;
    final newId = r.roadId;
    if (newId == null) {
      blocked = r.quote.reason;
    } else {
      blocked = null;
      lastRoadId = newId;
      selectedRoadId = _pieceNear(city, newId, end) ?? selectedRoadId;
    }
    changed();
    return r;
  }

  /// The road an end dropped at [p] lands on: another road's end within
  /// [RoadSnapper.endSnapM], else the nearest point along one within
  /// [CitySim.roadSnapM] — never [excludeId], the road being re-laid.
  /// Blind to level, as the road tool's snapper is: the end then takes the
  /// level of what it landed on ([joinLevelAt]) — with one exception. A
  /// road's TUNNEL is out of sight in this view and is met only from
  /// underground: unless the end is itself below the ground ([underground])
  /// it never lands on a stretch in a tunnel, and passes over it on the
  /// ground. It used to land on one all the same, a street's end dropped
  /// over a tunnel it could not see diving 12 m to meet it — re-laid as a
  /// ramp, cut into the ground in slabs over the rises it had followed.
  static RoadSnap? _dropSnap(CitySim city, Vec2 p, String excludeId,
      {bool underground = false}) {
    final index = city.layout.roadIndex;
    // Whether [road]'s stretch at arc [s] is in a tunnel this end cannot
    // meet ([inHiddenTunnel]).
    bool hidden(RoadSpline road, double s, double lengthM, {bool? start}) =>
        !underground && inHiddenTunnel(road, s, lengthM, atStart: start);

    RoadSnap? best;
    var bestD = RoadSnapper.endSnapM;
    final seen = <int>{};
    index.visit(Box2.around(p, bestD), 0, (slot, rec, _) {
      if (rec.road.id == excludeId ||
          rec.sampleCount == 0 ||
          !seen.add(slot)) {
        return;
      }
      for (final first in const [true, false]) {
        if (hidden(rec.road, first ? 0 : rec.lengthM, rec.lengthM,
            start: first)) {
          continue;
        }
        final q = rec.sampleAt(first ? 0 : rec.sampleCount - 1);
        final d = p.distanceTo(q);
        if (d < bestD) {
          bestD = d;
          best = RoadSnap(q, RoadSnapKind.roadEnd,
              roadId: rec.road.id, roadEndIsStart: first);
        }
      }
    });
    if (best != null) return best;
    bestD = CitySim.roadSnapM;
    index.visit(Box2.around(p, bestD), 0, (slot, rec, seg) {
      if (seg == 0 || rec.road.id == excludeId) return;
      final (q, d) = rec.nearestOnSegment(p, seg);
      if (d >= bestD) return;
      final s = rec.cum[seg - 1] + rec.sampleAt(seg - 1).distanceTo(q);
      if (hidden(rec.road, s, rec.lengthM)) return;
      bestD = d;
      best = RoadSnap(q, RoadSnapKind.roadPoint, roadId: rec.road.id);
    });
    return best;
  }

  /// The piece of the road [baseId] (itself, or `<baseId>x<i>` where a
  /// junction cut it) whose end is nearest [p].
  static String? _pieceNear(CitySim city, String baseId, Vec2 p) {
    if (city.layout.roadById(baseId) != null) return baseId;
    String? best;
    var bestD = double.infinity;
    for (final r in city.layout.roads) {
      if (!r.id.startsWith('${baseId}x') || r.controls.isEmpty) continue;
      final d = math.min(
          r.controls.first.distanceTo(p), r.controls.last.distanceTo(p));
      if (d < bestD) {
        bestD = d;
        best = r.id;
      }
    }
    return best;
  }

  /// Name the selected road — every piece of it. Blank restores the
  /// generated name.
  bool renameSelected(CitySim city, String name) {
    final id = selectedRoadId;
    if (id == null) return false;
    final trimmed = name.trim();
    final ok = city.renameRoad(id, trimmed.isEmpty ? null : trimmed);
    changed();
    return ok;
  }

  // ---- Diagnostics ----------------------------------------------------------

  /// The tool's state for the dev hook: what a driver script judges a run
  /// by without a screenshot.
  Map<String, Object?> roadToolStatus() => {
        'mode': mode.name,
        'type': _type.id,
        'elevationM': elevationM,
        'stepM': elevationStepM,
        'snap': [
          if (snap.roads) 'roads',
          if (snap.angles) 'angles',
          if (snap.zoningGrid) 'grid',
          if (snap.guidelines) 'guides',
        ],
        'anchor': switch (anchor) {
          null => null,
          final a => {
              'e': a.point.e,
              'n': a.point.n,
              'elevationM': a.elevationM,
              'heightM': a.heightM,
              'roadId': a.roadId,
            },
        },
        'control': switch (control) {
          null => null,
          final c => [c.e, c.n],
        },
        'preview': switch (preview) {
          null => null,
          final p => quoteJson(p.quote),
        },
        'upgrade': switch (upgradeQuote) {
          null => null,
          final q => {'roadId': upgradeRoadId, ...quoteJson(q)},
        },
        'lastQuote': switch (lastQuote) {
          null => null,
          final q => quoteJson(q),
        },
        'lastRoadId': lastRoadId,
        'blocked': blocked,
        'trafficView': trafficView.name,
        'selectedRoadId': selectedRoadId,
        'routeCount': routeCount,
      };

  static Map<String, Object?> quoteJson(RoadQuote q) => {
        'type': q.type.id,
        'ok': q.ok,
        'reason': q.ok ? null : q.reason,
        'lengthM': q.lengthM,
        'cost': q.cost,
        'upkeepPerWeek': q.upkeepPerWeek,
        'structureM': q.structureM,
        'bridgeM': q.bridgeM,
        'tunnelM': q.tunnelM,
        'gradePct': q.gradePct,
        'gradeLimitPct': q.gradeLimitPct,
        'deck': q.deck == null
            ? null
            : {'startM': q.deck!.startM, 'endM': q.deck!.endM},
      };

  /// The dev hook's settings, applied by name — the SAME calls the toolbar
  /// makes. `mode`, `type` (a [RoadType.id]), `step` (3/6/12), `elev` (a
  /// height in metres, or `up`/`down` — one PAGE UP / PAGE DOWN), `snap`
  /// (the options that are ON: `roads,angles,grid,guides`; empty for none),
  /// `view` (a [TrafficInfoView]). The pointer and the keys go through the
  /// view, which owns them.
  void applyToolParams(Map<String, String> p, {bool Function(RoadType)? unlocked}) {
    final m = p['mode'];
    if (m != null) {
      for (final v in RoadToolMode.values) {
        if (v.name == m) setMode(v);
      }
    }
    final t = p['type'];
    if (t != null) {
      final type = RoadType.byId(t);
      if (type == null) {
        blocked = 'No road type "$t"';
      } else {
        pickRoadType(type, unlocked: unlocked?.call(type) ?? true);
      }
    }
    final step = double.tryParse(p['step'] ?? '');
    if (step != null) setElevationStep(step);
    final e = p['elev'];
    if (e == 'up') {
      stepElevation(1);
    } else if (e == 'down') {
      stepElevation(-1);
    } else if (e != null) {
      final v = double.tryParse(e);
      if (v != null) {
        elevationM = clampElevation(v, _type.roadClass);
        changed();
      }
    }
    final s = p['snap'];
    if (s != null) {
      final on = s.split(',').map((x) => x.trim()).toSet();
      setSnap(RoadSnapOptions(
        roads: on.contains('roads'),
        angles: on.contains('angles'),
        zoningGrid: on.contains('grid'),
        guidelines: on.contains('guides'),
      ));
    }
    final view = p['view'];
    if (view != null) {
      for (final v in TrafficInfoView.values) {
        if (v.name == view) setTrafficView(v);
      }
    }
  }
}

/// A road's short name for a menu cell: 'Two-Lane', 'Four-Lane + Trees',
/// 'Highway + Walls'. The full name is the tooltip's.
String roadTypeShortLabel(RoadType t) {
  final base = switch (t.roadClass) {
    RoadClass.path => 'Gravel',
    RoadClass.street => 'Two-Lane',
    RoadClass.streetOneWay => 'One-Way',
    RoadClass.avenue => 'Four-Lane',
    RoadClass.boulevard => 'Six-Lane',
    RoadClass.ramp => 'Ramp',
    RoadClass.motorway => 'Highway',
    RoadClass.alley => 'Alley',
    RoadClass.trunk => 'Trunk',
    RoadClass.highway => 'Urban Hwy',
    RoadClass.expressway4 => '4-Lane Expwy',
    RoadClass.expressway6 => '6-Lane Expwy',
    RoadClass.expressway8 => '8-Lane Expwy',
    RoadClass.elevated => 'Elevated Hwy',
    RoadClass.rail => 'Railway',
    RoadClass.transit => 'Elevated Rail',
  };
  final dress = switch (t.decoration) {
    RoadDecoration.none => '',
    RoadDecoration.grass => ' + Grass',
    RoadDecoration.trees => ' + Trees',
  };
  return '$base$dress${t.soundWalls ? ' + Walls' : ''}';
}

/// A road type as its menu tooltip reads: lanes and direction, speed, what
/// it costs to build and to keep per cell, and what it does to the lots
/// along it.
String roadTypeTooltip(RoadType t, {bool locked = false}) {
  final cls = t.roadClass;
  final lanes = t.oneWay ? cls.lanesEachWay : cls.lanesEachWay * 2;
  final noise = t.noiseEmission < 0.2
      ? 'low'
      : t.noiseEmission < 0.5
          ? 'medium'
          : 'high';
  final lines = [
    t.label,
    '$lanes lane${lanes == 1 ? '' : 's'}, '
        '${t.oneWay ? 'one-way' : 'two-way'}, ${t.speedKmh.round()} km/h',
    '${formatMoney(t.costPerCell)} per cell to build, '
        '§${t.upkeepPerCellWeek.toStringAsFixed(2)} per cell per week to keep',
    'Zoning: ${t.zonable ? 'yes' : 'no'}   Parking: '
        '${t.hasParking ? 'yes' : 'no'}   Noise: $noise',
    if (!t.canTunnel) 'Cannot go underground',
    if (locked) 'Opens at ${t.unlockPop} population',
  ];
  return lines.join('\n');
}
