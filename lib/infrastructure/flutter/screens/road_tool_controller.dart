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
import '../../../domain/colony/city/road_junction.dart';
import '../../../domain/colony/city/road_snapper.dart';
import '../../../domain/colony/city/road_traffic_model.dart' show TripKind;

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
  adjust('Adjust');

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
    );
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

  /// The request for [controls] from the anchor to [end]: each end at the
  /// tool's elevation when it was placed, or at the deck it joins.
  RoadBuildRequest requestTo(CitySim city, List<Vec2> controls, RoadSnap end) {
    final a = anchor!;
    final endRoad = end.onRoad ? end.roadId : null;
    return RoadBuildRequest(
      controls: controls,
      type: _type,
      startElevationM: a.elevationM,
      endElevationM: elevationM,
      startHeightM: a.heightM,
      endHeightM: endRoad == null ? null : city.deckHeightAt(endRoad, end.point),
      snapStart: snap.roads,
      snapEnd: snap.roads,
    );
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
    final snapped =
        city.snapRoadRequest(requestTo(city, shape, s), groundAt: ground);
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
      anchor = _anchorOn(city, s);
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

  /// An anchor where [s] landed: on the deck of the road it joined, and
  /// carrying that road on where it landed on its end.
  RoadAnchor _anchorOn(CitySim city, RoadSnap s) {
    final id = s.onRoad ? s.roadId : null;
    Vec2? tangent;
    final t = s.roadTangent;
    if (s.kind == RoadSnapKind.roadEnd && t != null) {
      // Out of a road's first point is backwards along it; out of its last,
      // forwards.
      tangent = s.roadEndIsStart == true ? t * -1.0 : t;
    }
    return RoadAnchor(
      s.point,
      elevationM: elevationM,
      heightM: id == null ? null : city.deckHeightAt(id, s.point),
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
    final snapped =
        city.snapRoadRequest(requestTo(city, shape, end), groundAt: ground);
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
    final deck = r.quote.deck;
    anchor = RoadAnchor(
      line.last,
      elevationM: deck?.endOffsetM ?? 0,
      heightM: deck?.endM,
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
    blocked = null;
    changed();
  }

  /// Esc in the info views: drop the selection. False with none.
  bool escapeTraffic() {
    if (selectedRoadId == null) return false;
    selectRoad(null);
    return true;
  }

  /// The Junctions view's click at [p]: on a junction (within
  /// [JunctionOverride.matchM] of it) its lights go on or off; out along
  /// one of its legs, that leg's stop sign comes or goes. What the plan was
  /// comes from the road graph — the plan the tiles draw and the traffic
  /// waits at. Whether anything changed.
  bool toggleJunctionAt(CitySim city, Vec2 p, {double scale = 1}) {
    final node =
        city.roadGraph.nodeNear(p, withinM: math.max(20.0, 14 * scale));
    if (node == null || !node.isJunction) {
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
    if (d.length <= math.max(JunctionOverride.matchM, 4 * scale)) {
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

  /// Adjust Roads: drag an end of the selected road ([atStart]: its first
  /// control) to [to] and re-lay it. Dropped on a raised or sunk road, the
  /// end meets its deck. [ground] as for [clickAt]. The selection follows
  /// the road to its new id.
  ({String? roadId, RoadQuote quote})? moveSelectedEnd(
    CitySim city, {
    required bool atStart,
    required Vec2 to,
    double Function(Vec2)? ground,
  }) {
    final id = selectedRoadId;
    if (id == null) return null;
    final hit = city.layout.nearestRoadPoint(to, withinM: CitySim.roadSnapM);
    final toHeightM = hit == null || hit.roadId == id
        ? null
        : city.deckHeightAt(hit.roadId, hit.point);
    final r = city.moveRoadEnd(id,
        atStart: atStart, to: to, toHeightM: toHeightM, groundAt: ground);
    lastQuote = r.quote;
    final newId = r.roadId;
    if (newId == null) {
      blocked = r.quote.reason;
    } else {
      blocked = null;
      lastRoadId = newId;
      selectedRoadId = _pieceNear(city, newId, to) ?? selectedRoadId;
    }
    changed();
    return r;
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
