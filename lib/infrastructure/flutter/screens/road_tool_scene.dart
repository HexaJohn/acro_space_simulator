// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The road tool's side of the flight view: the ground it drapes on, and
/// what it asks the renderer to draw.
///
/// The controller ([RoadToolEditing]) knows what the tool is doing in
/// colony-local metres; the renderer draws body-fixed geometry out of
/// [RoadOverlayState]. This is the step between: it holds the colony's
/// ground ([ColonyGroundSampler] over the body's edited terrain, cached
/// per edit version so a hover costs arithmetic, not field queries), lays
/// what the tool shows on that ground, and writes it into the overlay.
/// Everything that walks the network — the tunnels shown below ground, the
/// junction markers, a road's routes — is cached against what it was drawn
/// from, so a mouse move redraws the ghost and nothing else.
///
/// It also carries the view-side state the flight view's colony part needs
/// between events (the hover throttle, a drag in progress): that part is an
/// extension and can own no fields of its own.
library;

import 'dart:math' as math;
import 'dart:ui' show Offset;

import '../../../domain/colony/city/city_sim.dart';
import '../../../domain/colony/city/colony_ground.dart';
import '../../../domain/colony/city/parcel.dart';
import '../../../domain/colony/city/road_build.dart';
import '../../../domain/colony/city/road_catalog.dart';
import '../../../domain/colony/city/road_junction.dart';
import '../../../domain/colony/city/road_traffic_model.dart';
import '../../../domain/colony/city/spatial_index.dart';
import '../../../domain/shared/vector3.dart';
import '../../../domain/terrain/terrain_edits.dart';
import '../../../domain/terrain/terrain_field.dart';
import '../../../domain/universe/celestial_body.dart';
import '../../flutter_scene/city/road_overlay_state.dart';
import 'road_tool_controller.dart';

/// A handle picked in the Adjust view: one end of a road.
typedef RoadEndHandle = ({String roadId, bool atStart});

class RoadToolScene {
  RoadToolScene({RoadOverlayState? overlay})
      : overlay = overlay ?? RoadOverlayState.instance;

  /// Where it writes. The renderer's singleton, unless a test hands it its
  /// own.
  final RoadOverlayState overlay;

  // ---- Colours ---------------------------------------------------------------

  static const int guideArgb = 0xB3FFFFFF;
  static const int anchorArgb = 0xF2FFFFFF;
  static const int controlArgb = 0xF24FC3F7;
  static const int joinArgb = 0xF27FE0A0;
  static const int tunnelArgb = 0x8C5AA9E6;
  static const int highlightArgb = 0x8033D1FF;
  static const int handleArgb = 0xF2FFD54F;
  static const int lightsArgb = 0xF2FFFFFF;
  static const int noLightsArgb = 0xD99FB4CC;
  static const int stopArgb = 0xF2E53935;

  /// How far out along a leg its stop sign stands.
  static const double stopOutM = 12;

  // ---- Ground ----------------------------------------------------------------

  ColonyGroundSampler? _ground;
  Object? _siteKey;
  TerrainField? _field;
  Object? _fieldKey;
  String _bodyId = '';
  Vector3 Function(Vec2 p, double heightM) _toBF =
      (p, h) => Vector3(p.e, p.n, h);
  double Function(Vec2) _height = _flat;
  double Function(Vec2) _exact = _flat;

  static double _flat(Vec2 _) => 0;

  /// The body the overlay is drawn on.
  String get bodyId => _bodyId;

  /// Point the ground at [city] on [body], edited by [edits]. Cheap when
  /// nothing moved: the composed field is built once per edit list (never
  /// per sample — building one allocates the whole terrain profile), and
  /// the raster drops its cells only when a brush lands.
  void bindGround(CitySim city, CelestialBody body, TerrainEdits? edits) {
    final site = (city.id, city.cityLat, city.cityLon, body.id.value, body.radius);
    if (site != _siteKey || _ground == null) {
      _siteKey = site;
      _ground = ColonyGroundSampler(
        toDirection: (p) => city.localToBodyFixed(p, bodyRadiusM: body.radius),
        bodyRadiusM: body.radius,
      );
      _fieldKey = null;
    }
    final fieldKey = (body.id.value, identityHashCode(edits));
    if (fieldKey != _fieldKey) {
      _field = body.terrainFieldWith(edits);
      _fieldKey = fieldKey;
    }
    final ground = _ground!;
    final f = _field;
    if (f != null) {
      ground.bind((identityHashCode(f), edits?.version ?? 0),
          surfaceRadiusAt: f.surfaceRadiusAt,
          baseRadiusAt: f.baseGroundRadiusAt);
    }
    final radius = body.radius;
    bindCustom(
      bodyId: body.id.value,
      toBodyFixed: (p, h) => city.localToBodyFixed(p, bodyRadiusM: radius + h),
      height: ground.heightAt,
      exactHeight: ground.exactHeightAt,
    );
  }

  /// Draw on [bodyId] through [toBodyFixed] (a colony-local point and a
  /// height above the datum to body-fixed metres), over [height] (the
  /// hover's ground) and [exactHeight] (a commit's). What [bindGround]
  /// does for a real body; tests hand it a flat world.
  void bindCustom({
    required String bodyId,
    required Vector3 Function(Vec2 p, double heightM) toBodyFixed,
    required double Function(Vec2) height,
    double Function(Vec2)? exactHeight,
  }) {
    _bodyId = bodyId;
    _toBF = toBodyFixed;
    _height = height;
    _exact = exactHeight ?? height;
  }

  /// Start a frame's fill budget on the raster (once per refresh).
  void beginFrame() => _ground?.beginFrame();

  /// The ground under [p], metres above the datum — the hover's raster.
  double heightAt(Vec2 p) => _height(p);

  /// The ground under [p], exactly: one field query. For a commit.
  double exactHeightAt(Vec2 p) => _exact(p);

  /// [p] on the ground, [liftM] above it, body-fixed.
  Vector3 drape(Vec2 p, [double liftM = 0]) => _toBF(p, _height(p) + liftM);

  // ---- The hover throttle and the Adjust drag --------------------------------

  /// Where the cursor last was over the ground, and the metres one screen
  /// pixel spans there.
  Vec2? hover;
  double hoverPxM = 1;

  /// A hover arrived inside the throttle and is waiting to be drawn, and a
  /// frame callback is already booked to draw it.
  bool dirty = false;
  bool flushScheduled = false;

  /// At most one redraw per this many microseconds: 30 Hz.
  static const int refreshIntervalUs = 33000;
  final Stopwatch _clock = Stopwatch()..start();
  int _lastRefreshUs = -refreshIntervalUs;

  bool refreshDue() =>
      _clock.elapsedMicroseconds - _lastRefreshUs >= refreshIntervalUs;

  void markRefreshed() {
    dirty = false;
    _lastRefreshUs = _clock.elapsedMicroseconds;
  }

  /// The snap tolerance multiplier for the camera's distance: 1 at street
  /// scale (a metre a pixel or less), growing with it so a snap is always
  /// a handful of pixels away.
  double get snapScale => hoverPxM.clamp(1.0, 20.0).toDouble();

  /// The end being dragged in the Adjust view, where it is dragged to,
  /// where the press went down and how far the pointer has travelled.
  RoadEndHandle? drag;
  Vec2? dragTo;
  Offset? dragDownAt;
  double dragTravelPx = 0;

  /// Drop a drag in progress. Whether there was one.
  bool cancelDrag() {
    final had = drag != null;
    drag = null;
    dragTo = null;
    dragDownAt = null;
    dragTravelPx = 0;
    return had;
  }

  Object? _lastTool;

  /// Whether [tool] differs from the one last seen — a tool picked up.
  bool toolChanged(Object tool) {
    if (tool == _lastTool) return false;
    _lastTool = tool;
    return true;
  }

  // ---- The road tool ---------------------------------------------------------

  /// The road tool's frame: the stretch the next click builds, class-true
  /// on its deck (red when it cannot be built); the guidelines the cursor
  /// follows; the anchor, the curve's pull point and the road the cursor
  /// would join; and — while the tool is held below ground — every tunnel
  /// already built. [pxM] sizes the markers to the screen.
  void showRoadTool(CitySim city, RoadToolEditing c, {double pxM = 1}) {
    final o = overlay;
    o.bodyId = _bodyId;
    final p = c.preview;
    if (p != null) {
      _writeGhost(p.line, p.quote.deck, c.roadType,
          p.quote.ok ? RoadGhostState.ok : RoadGhostState.refused);
    } else {
      _clearGhost();
    }
    final lines = <OverlayLine>[];
    final guides = c.cursorSnap?.guides ?? const <List<Vec2>>[];
    for (final g in guides) {
      lines.add(OverlayLine(
        pointsBF: [for (final v in _densify(g, 16)) drape(v)],
        argb: guideArgb,
        widthM: math.max(1.0, 1.5 * pxM),
        liftM: 0.7,
        dashed: true,
      ));
    }
    o.showUnderground = c.elevationM < 0;
    if (o.showUnderground) lines.addAll(_tunnelLines(city));

    final markers = <OverlayMarker>[];
    final r = _markerRadius(pxM);
    final a = c.anchor;
    if (a != null) {
      markers.add(OverlayMarker(
        atBF: _toBF(a.point, a.heightM ?? (_height(a.point) + a.elevationM)),
        argb: anchorArgb,
        radiusM: r,
        kind: OverlayMarkerKind.ring,
      ));
    }
    final ctl = c.control;
    if (ctl != null) {
      markers.add(OverlayMarker(
          atBF: drape(ctl), argb: controlArgb, radiusM: r * 0.7));
    }
    final s = c.cursorSnap;
    if (s != null && s.onRoad) {
      // The road the cursor would join, marked where it would join it.
      markers.add(OverlayMarker(
          atBF: drape(s.point), argb: joinArgb, radiusM: r * 0.6));
    }
    o.lines = lines;
    o.markers = markers;
    o.changed();
  }

  /// The Upgrade tool's frame: the road under the cursor, drawn as the type
  /// it would become — outlined when it can, red when it cannot.
  void showUpgrade(CitySim city, RoadToolEditing c, {double pxM = 1}) {
    final o = overlay;
    o.bodyId = _bodyId;
    final id = c.upgradeRoadId;
    final q = c.upgradeQuote;
    final road = id == null ? null : city.layout.roadById(id);
    final rec = id == null ? null : city.layout.roadIndex.byId(id);
    if (road == null || rec == null || q == null) {
      _clearGhost();
    } else {
      // The ghost's first point to its last is the direction of travel —
      // a reversed one-way road runs back along its controls.
      final pts = _roadLine(rec, 0, rec.lengthM);
      _writeGhost(road.reversed ? pts.reversed.toList() : pts, road.deck,
          c.roadType, q.ok ? RoadGhostState.selected : RoadGhostState.refused,
          reversed: road.reversed);
    }
    o.lines = const [];
    o.markers = const [];
    o.showUnderground = false;
    o.changed();
  }

  // ---- The info views --------------------------------------------------------

  /// The Traffic tool's frame, by view.
  void showTraffic(CitySim city, RoadToolEditing c, {double pxM = 1}) {
    final o = overlay;
    o.bodyId = _bodyId;
    _clearGhost();
    o.showUnderground = false;
    switch (c.trafficView) {
      case TrafficInfoView.junctions:
        o.lines = const [];
        o.markers = _junctionMarkers(city, pxM);
      case TrafficInfoView.routes:
        o.lines = _routeLines(city, c, pxM);
        o.markers = const [];
      case TrafficInfoView.adjust:
        _writeAdjust(city, c, pxM);
    }
    o.changed();
  }

  /// The end of [roadId] within [withinM] of [p], or null.
  RoadEndHandle? handleAt(
      CitySim city, String? roadId, Vec2 p, double withinM) {
    if (roadId == null) return null;
    final road = city.layout.roadById(roadId);
    if (road == null || road.controls.length < 2) return null;
    final ds = road.controls.first.distanceTo(p);
    final de = road.controls.last.distanceTo(p);
    if (math.min(ds, de) > withinM) return null;
    return (roadId: roadId, atStart: ds <= de);
  }

  void _writeAdjust(CitySim city, RoadToolEditing c, double pxM) {
    final o = overlay;
    final id = c.selectedRoadId;
    final road = id == null ? null : city.layout.roadById(id);
    final rec = id == null ? null : city.layout.roadIndex.byId(id);
    if (road == null || rec == null) {
      o.lines = const [];
      o.markers = const [];
      return;
    }
    final r = _markerRadius(pxM) * 1.2;
    final d = drag;
    final to = dragTo;
    if (d != null && to != null && d.roadId == id) {
      // The road as it would be re-laid, following the drag.
      final moved = controlsWithMovedEnd(road.controls,
          atStart: d.atStart, to: to);
      final line = RoadSpline(id: 'adjust', controls: moved).sample(stepM: 4);
      _writeGhost(line, null, RoadType.of(road), RoadGhostState.selected);
      o.lines = const [];
      o.markers = [
        OverlayMarker(
            atBF: drape(to),
            argb: handleArgb,
            radiusM: r,
            kind: OverlayMarkerKind.ring),
        OverlayMarker(
            atBF: drape(d.atStart ? moved.last : moved.first),
            argb: handleArgb,
            radiusM: r,
            kind: OverlayMarkerKind.ring),
      ];
      return;
    }
    o.lines = [_highlight(road, rec, pxM)];
    o.markers = [
      for (final end in [road.controls.first, road.controls.last])
        OverlayMarker(
            atBF: drape(end),
            argb: handleArgb,
            radiusM: r,
            kind: OverlayMarkerKind.ring),
    ];
  }

  // ---- Caches ----------------------------------------------------------------

  Object? _tunnelKey;
  List<OverlayLine> _tunnels = const [];

  /// Every tunnel already built, as translucent bands over where it runs —
  /// walked once per change to the network, not per mouse move.
  List<OverlayLine> _tunnelLines(CitySim city) {
    final key = (city.roadsRevision, _bodyId, _siteKey, _fieldKey);
    if (key == _tunnelKey) return _tunnels;
    final out = <OverlayLine>[];
    for (final road in city.layout.roads) {
      final deck = road.deck;
      if (deck == null || deck.tunnels.isEmpty) continue;
      final rec = city.layout.roadIndex.byId(road.id);
      if (rec == null || rec.sampleCount < 2) continue;
      for (final (a, b) in deck.tunnels) {
        final pts = _roadLine(rec, a, b, stepM: 6);
        if (pts.length < 2) continue;
        out.add(OverlayLine(
          pointsBF: [for (final p in pts) drape(p)],
          argb: tunnelArgb,
          widthM: road.roadClass.width,
          liftM: 0.4,
        ));
      }
    }
    _tunnelKey = key;
    return _tunnels = out;
  }

  Object? _junctionKey;
  List<OverlayMarker> _junctions = const [];

  /// How far from the cursor junctions are marked: a district, not a
  /// sprawl's every crossroads.
  static const double junctionReachM = 1600;

  /// A marker on every junction near the cursor — lights, or none — and a
  /// stop sign out along each leg that stops. The plans are the road
  /// graph's, the rule the tiles draw by and the traffic waits by.
  List<OverlayMarker> _junctionMarkers(CitySim city, double pxM) {
    final graph = city.roadGraph;
    final focus = hover ?? const Vec2(0, 0);
    // Rebuilt when the graph is replaced (a road, an override) or the
    // cursor has wandered a block, or the zoom has moved a notch.
    final key = (
      identityHashCode(graph),
      city.roadsRevision,
      (focus.e / 200).round(),
      (focus.n / 200).round(),
      (math.log(math.max(pxM, 0.05)) / math.log(1.5)).round(),
      _bodyId,
    );
    if (key == _junctionKey) return _junctions;
    final r = _markerRadius(pxM) * 1.3;
    final out = <OverlayMarker>[];
    for (final node in graph.nodes) {
      if (!node.isJunction) continue;
      if (node.at.distanceTo(focus) > junctionReachM) continue;
      final lights = node.plan.control == JunctionControl.signals;
      out.add(OverlayMarker(
        atBF: drape(node.at, _nodeLift(node.heightM, node.at)),
        argb: lights ? lightsArgb : noLightsArgb,
        radiusM: r,
        kind: lights ? OverlayMarkerKind.lights : OverlayMarkerKind.noLights,
      ));
      if (node.plan.control != JunctionControl.stop) continue;
      for (final i in node.plan.stopLegs) {
        final h = node.legs[i].heading;
        final at = node.at + Vec2(math.sin(h), math.cos(h)) * stopOutM;
        out.add(OverlayMarker(
          atBF: drape(at, _nodeLift(node.heightM, at)),
          argb: stopArgb,
          radiusM: r * 0.55,
          kind: OverlayMarkerKind.stop,
        ));
      }
    }
    _junctionKey = key;
    return _junctions = out;
  }

  /// A raised node's height over the ground at [p]; 0 for one on the
  /// ground.
  double _nodeLift(double? heightM, Vec2 p) =>
      heightM == null ? 0 : math.max(0.0, heightM - _height(p));

  Object? _routesKey;
  List<OverlayLine> _routes = const [];

  /// The selected road, and the trips that use it, each drawn in its kind's
  /// colour. Asked of the traffic model once per selection, filter or
  /// change to the roads — never per mouse move.
  List<OverlayLine> _routeLines(CitySim city, RoadToolEditing c, double pxM) {
    final id = c.selectedRoadId;
    if (id == null) {
      c.routeCount = null;
      return const [];
    }
    final kinds = [for (final k in TripKind.values) c.routeKinds.contains(k)];
    final key = (
      id,
      kinds.join(),
      city.roadsRevision,
      city.roadTraffic.hasRun,
      _bodyId,
      (math.log(math.max(pxM, 0.05)) / math.log(1.5)).round(),
    );
    if (key == _routesKey) return _routes;
    final road = city.layout.roadById(id);
    final rec = city.layout.roadIndex.byId(id);
    final out = <OverlayLine>[];
    if (road != null && rec != null) out.add(_highlight(road, rec, pxM));
    final routes = c.routeKinds.isEmpty
        ? const <TripRoute>[]
        : city.roadTraffic.routesThrough(id, kinds: c.routeKinds);
    for (final t in routes) {
      final pts = _densify(t.polyline, 12);
      if (pts.length < 2) continue;
      out.add(OverlayLine(
        pointsBF: [for (final p in pts) drape(p)],
        argb: tripKindArgb(t.kind),
        widthM: math.max(2.0, 2.5 * pxM),
        liftM: 0.9,
      ));
    }
    c.routeCount = routes.length;
    _routesKey = key;
    return _routes = out;
  }

  /// Forget every cached drawing — the ground under them moved, or a test
  /// wants a fresh start.
  void invalidate() {
    _tunnelKey = null;
    _junctionKey = null;
    _routesKey = null;
  }

  /// Drop everything the tool drew.
  void clear() => overlay.clear();

  /// What the overlay holds, for the dev hook: a driver can tell a ghost
  /// that was drawn from one that was not without a screenshot.
  Map<String, Object?> overlayStatus() => {
        'revision': overlay.revision,
        'bodyId': overlay.bodyId,
        'ghostPoints': overlay.ghostBF.length,
        'ghostLifted': overlay.ghostLiftsM.isNotEmpty,
        'ghostState': overlay.ghostState.name,
        'ghostClass': overlay.ghostClassIndex,
        'lines': overlay.lines.length,
        'markers': overlay.markers.length,
        'showUnderground': overlay.showUnderground,
      };

  // ---- Drawing helpers -------------------------------------------------------

  /// Marker radius for [pxM] metres a pixel: about seven pixels across,
  /// never smaller than a lane.
  static double _markerRadius(double pxM) => math.max(3.0, 7 * pxM);

  /// [road]'s highlight: a translucent band a little wider than it, over
  /// its deck where it has one.
  OverlayLine _highlight(RoadSpline road, IndexedRoad rec, double pxM) {
    final pts = _roadLine(rec, 0, rec.lengthM);
    final deck = road.deck;
    final len = _length(pts);
    var s = 0.0;
    final lifts = <double>[];
    final bf = <Vector3>[];
    for (var i = 0; i < pts.length; i++) {
      if (i > 0) s += pts[i].distanceTo(pts[i - 1]);
      final g = _height(pts[i]);
      bf.add(_toBF(pts[i], g));
      lifts.add(deck == null ? 0 : math.max(0.0, deck.heightAt(s, len) - g));
    }
    return OverlayLine(
      pointsBF: bf,
      argb: highlightArgb,
      widthM: road.roadClass.width + math.max(2.0, 3 * pxM),
      liftM: 0.8,
      liftsM: deck == null ? null : lifts,
    );
  }

  /// The ghost: [line] on the ground, raised onto [deck] where it has one,
  /// drawn as [type].
  void _writeGhost(
      List<Vec2> line, RoadDeck? deck, RoadType type, RoadGhostState state,
      {bool reversed = false}) {
    final o = overlay;
    final pts = _densify(line, 4, maxPoints: 600);
    if (pts.length < 2) {
      _clearGhost();
      return;
    }
    final len = _length(pts);
    final bf = <Vector3>[];
    final lifts = <double>[];
    var s = 0.0;
    for (var i = 0; i < pts.length; i++) {
      if (i > 0) s += pts[i].distanceTo(pts[i - 1]);
      final g = _height(pts[i]);
      bf.add(_toBF(pts[i], g));
      if (deck != null) {
        // A reversed road's deck runs from its first CONTROL, which is the
        // ghost's last point.
        lifts.add(deck.heightAt(reversed ? len - s : s, len) - g);
      }
    }
    o.ghostBF = bf;
    o.ghostLiftsM = deck == null ? const [] : lifts;
    o.ghostClassIndex = type.roadClass.index;
    o.ghostHalfWidthM = type.roadClass.halfWidth;
    o.ghostState = state;
    o.ghostOneWay = type.oneWay;
  }

  void _clearGhost() {
    overlay.ghostBF = const [];
    overlay.ghostLiftsM = const [];
    overlay.ghostState = RoadGhostState.ok;
    overlay.ghostOneWay = false;
  }

  /// [rec]'s centreline between arcs [a] and [b], a point every [stepM] or
  /// so — its own samples thinned, its ends exact.
  static List<Vec2> _roadLine(IndexedRoad rec, double a, double b,
      {double stepM = 4}) {
    final lo = math.max(0.0, math.min(a, b));
    final hi = math.min(rec.lengthM, math.max(a, b));
    if (rec.sampleCount < 2 || hi - lo < 1e-6) return const [];
    final out = <Vec2>[_pointAt(rec, lo)];
    var last = lo;
    for (var i = 0; i < rec.sampleCount; i++) {
      final s = rec.cum[i];
      if (s <= lo + 1e-6 || s >= hi - 1e-6) continue;
      if (s - last < stepM) continue;
      out.add(rec.sampleAt(i));
      last = s;
    }
    out.add(_pointAt(rec, hi));
    return out;
  }

  static Vec2 _pointAt(IndexedRoad rec, double s) {
    for (var i = 1; i < rec.sampleCount; i++) {
      if (rec.cum[i] >= s) {
        final seg = rec.cum[i] - rec.cum[i - 1];
        final t = seg <= 1e-12 ? 0.0 : (s - rec.cum[i - 1]) / seg;
        final p = rec.sampleAt(i - 1);
        return p + (rec.sampleAt(i) - p) * t;
      }
    }
    return rec.sampleAt(rec.sampleCount - 1);
  }

  /// [pts] with every segment longer than [stepM] cut into equal pieces no
  /// longer than it — so a straight stretch drapes over the ground rather
  /// than cutting through a hill — at most [maxPoints] of them.
  static List<Vec2> _densify(List<Vec2> pts, double stepM,
      {int maxPoints = 400}) {
    if (pts.length < 2) return pts;
    final total = _length(pts);
    final step = math.max(stepM, total / maxPoints);
    final out = <Vec2>[pts.first];
    for (var i = 1; i < pts.length; i++) {
      final a = pts[i - 1], b = pts[i];
      final n = math.max(1, (a.distanceTo(b) / step).ceil());
      for (var k = 1; k <= n; k++) {
        out.add(a + (b - a) * (k / n));
      }
    }
    return out;
  }

  static double _length(List<Vec2> pts) {
    var sum = 0.0;
    for (var i = 1; i < pts.length; i++) {
      sum += pts[i].distanceTo(pts[i - 1]);
    }
    return sum;
  }

  /// A last look before the flight view goes: nothing of the tool may hang
  /// over the next world opened.
  static void clearOverlay() => RoadOverlayState.instance.clear();
}
