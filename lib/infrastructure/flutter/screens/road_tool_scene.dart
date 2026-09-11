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
import '../../../domain/colony/city/road_catalog.dart';
import '../../../domain/colony/city/road_graph.dart' show RoadGraph, RoadNode;
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
    // The edits are one object, re-composed in place as brushes land: its
    // identity says which list, its version what is on it.
    final version = edits?.version ?? 0;
    if (f != null) {
      ground.bind((identityHashCode(f), version),
          surfaceRadiusAt: f.surfaceRadiusAt,
          baseRadiusAt: f.baseGroundRadiusAt);
    }
    final radius = body.radius;
    bindCustom(
      bodyId: body.id.value,
      toBodyFixed: (p, h) => city.localToBodyFixed(p, bodyRadiusM: radius + h),
      height: ground.heightAt,
      exactHeight: ground.exactHeightAt,
      // No field, no raster to warm: the ground is the datum, and nothing
      // drawn on it is waiting for a better answer.
      warmAt: f == null ? null : ground.warmAt,
      groundKey: (_siteKey, _fieldKey, version),
    );
  }

  /// Draw on [bodyId] through [toBodyFixed] (a colony-local point and a
  /// height above the datum to body-fixed metres), over [height] (the
  /// hover's ground) and [exactHeight] (a commit's). What [bindGround]
  /// does for a real body; tests hand it a flat world.
  ///
  /// [warmAt] says whether [height] answers from ground it has cached, not
  /// from its pristine fallback (see [ColonyGroundSampler.warmAt]); null:
  /// always. [groundKey] names the ground: a drawing kept across refreshes
  /// is laid again when it changes — a brush landed, the town was graded.
  void bindCustom({
    required String bodyId,
    required Vector3 Function(Vec2 p, double heightM) toBodyFixed,
    required double Function(Vec2) height,
    double Function(Vec2)? exactHeight,
    bool Function(Vec2)? warmAt,
    Object? groundKey,
  }) {
    _bodyId = bodyId;
    _toBF = toBodyFixed;
    _height = height;
    _exact = exactHeight ?? height;
    _warmAt = warmAt;
    _groundKey = groundKey;
  }

  bool Function(Vec2)? _warmAt;
  Object? _groundKey;

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
      // The road the cursor would join, marked where it would join it — at
      // that road's level, which is the level the end is laid at
      // ([RoadToolEditing.joinLevelAt]): on a viaduct, up on its deck.
      final join = c.joinLevelAt(city, s, ground: _height);
      markers.add(OverlayMarker(
          atBF: _toBF(s.point, join?.heightM ?? _height(s.point)),
          argb: joinArgb,
          radiusM: r * 0.6));
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

  /// The Traffic tool's frame, by view — published only when it changed.
  ///
  /// The renderer rebuilds the whole overlay on every revision, and none of
  /// these views follows the cursor the way the road tool's ghost does: a
  /// Routes view moused over re-meshed its sixty-odd route lines thirty
  /// times a second for nothing. Each view hands back the lists it drew
  /// last time while nothing they were drawn from has moved, and a refresh
  /// that finds them already up says nothing.
  void showTraffic(CitySim city, RoadToolEditing c, {double pxM = 1}) {
    final o = overlay;
    List<OverlayLine> lines = const [];
    List<OverlayMarker> markers = const [];
    var ghost = false;
    switch (c.trafficView) {
      case TrafficInfoView.junctions:
        markers = _junctionMarkers(city, pxM);
      case TrafficInfoView.routes:
        lines = _routeLines(city, c, pxM);
      case TrafficInfoView.adjust:
        (lines, markers, ghost) = _adjustFrame(city, c, pxM);
    }
    if (!ghost &&
        o.ghostBF.isEmpty &&
        !o.showUnderground &&
        o.bodyId == _bodyId &&
        identical(o.lines, lines) &&
        identical(o.markers, markers)) {
      return;
    }
    o.bodyId = _bodyId;
    if (!ghost) _clearGhost();
    o.showUnderground = false;
    o.lines = lines;
    o.markers = markers;
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

  /// The Adjust view's frame: the road picked, outlined, with a circle at
  /// each end — or, while one end is dragged, the road as letting go would
  /// re-lay it ([RoadToolEditing.movePreview], priced by the rules the
  /// release lays by): its end on whatever it was dropped on, standing on
  /// its deck, red where it cannot be. The lines and markers to draw, and
  /// whether a ghost was laid.
  (List<OverlayLine>, List<OverlayMarker>, bool) _adjustFrame(
      CitySim city, RoadToolEditing c, double pxM) {
    final id = c.selectedRoadId;
    final road = id == null ? null : city.layout.roadById(id);
    final rec = id == null ? null : city.layout.roadIndex.byId(id);
    final d = drag;
    // A drag let go of, or dropped: nothing is priced any more.
    if (d == null) c.movePreview = null;
    if (road == null || rec == null) return (const [], const [], false);
    final r = _markerRadius(pxM) * 1.2;
    final m = c.movePreview;
    if (d != null && m != null && m.roadId == id && m.atStart == d.atStart) {
      final line =
          RoadSpline(id: 'adjust', controls: m.controls).sample(stepM: 4);
      final deck = m.quote.deck;
      // First point to last is the direction of travel, as Upgrade draws
      // it: a reversed one-way road runs back along its controls. Drawn in
      // control order, a reversed road's ghost pointed its arrows against
      // the traffic the re-lay keeps.
      _writeGhost(road.reversed ? line.reversed.toList() : line, deck,
          RoadType.of(road),
          m.quote.ok ? RoadGhostState.selected : RoadGhostState.refused,
          reversed: road.reversed);
      final first = m.controls.first, last = m.controls.last;
      return (
        const [],
        [
          for (final (p, h) in [(first, deck?.startM), (last, deck?.endM)])
            OverlayMarker(
                atBF: _toBF(p, h ?? _height(p)),
                argb: handleArgb,
                radiusM: r,
                kind: OverlayMarkerKind.ring),
        ],
        true,
      );
    }
    // The outline, kept per road and zoom: the view is redrawn per hover,
    // and nothing here follows the cursor.
    final key = (id, city.roadsRevision, _notch(pxM), _bodyId, _groundKey);
    final kept = _keptFor(_adjust, key);
    if (kept != null) return (kept.$1, kept.$2, false);
    final laid = <Vec2>[];
    final deck = road.deck;
    final drawn = (
      [_highlight(road, rec, pxM, laid)],
      [
        for (final (p, h) in [
          (road.controls.first, deck?.startM),
          (road.controls.last, deck?.endM),
        ])
          OverlayMarker(
              atBF: _toBF(p, h ?? _height(p)),
              argb: handleArgb,
              radiusM: r,
              kind: OverlayMarkerKind.ring),
      ],
    );
    final out = _keep(_adjust, key, drawn, laid);
    return (out.$1, out.$2, false);
  }

  // ---- Caches ----------------------------------------------------------------
  //
  // Every drawing that walks the network is kept against what it was drawn
  // from — the roads, the traffic pass, the zoom notch, and the GROUND
  // ([_groundKey], the edits' version with it: a town graded after the
  // drawing was laid gets it laid again). And a drawing laid partly on the
  // raster's pristine fallback is kept only while its points warm ([_Kept]).

  final _Kept<List<OverlayLine>> _tunnels = _Kept();

  /// Every tunnel already built, as translucent bands over where it runs —
  /// walked once per change to the network, not per mouse move.
  List<OverlayLine> _tunnelLines(CitySim city) {
    final key = (city.roadsRevision, _bodyId, _groundKey);
    final kept = _keptFor(_tunnels, key);
    if (kept != null) return kept;
    final out = <OverlayLine>[];
    final laid = <Vec2>[];
    for (final road in city.layout.roads) {
      final deck = road.deck;
      if (deck == null || deck.tunnels.isEmpty) continue;
      final rec = city.layout.roadIndex.byId(road.id);
      if (rec == null || rec.sampleCount < 2) continue;
      for (final (a, b) in deck.tunnels) {
        // Densified: a straight road is two points in the index, and the
        // band must lie on the ground over the tunnel, not on a chord.
        final pts = _densify(_roadLine(rec, a, b, stepM: 6), 6);
        if (pts.length < 2) continue;
        laid.addAll(pts);
        out.add(OverlayLine(
          pointsBF: [for (final p in pts) drape(p)],
          argb: tunnelArgb,
          widthM: road.roadClass.width,
          liftM: 0.4,
        ));
      }
    }
    return _keep(_tunnels, key, out, laid);
  }

  final _Kept<List<OverlayMarker>> _junctions = _Kept();

  /// How far from the cursor junctions are marked: a district, not a
  /// sprawl's every crossroads.
  static const double junctionReachM = 1600;

  /// The junctions of one graph, bucketed on a coarse grid, so the markers
  /// around the cursor are found without a walk of every node in a sprawl.
  RoadGraph? _gridGraph;
  Map<(int, int), List<RoadNode>> _grid = const {};
  static const double _gridCellM = 400;

  Map<(int, int), List<RoadNode>> _junctionGrid(RoadGraph g) {
    if (identical(g, _gridGraph)) return _grid;
    final grid = <(int, int), List<RoadNode>>{};
    for (final n in g.nodes) {
      if (!n.isJunction) continue;
      grid
          .putIfAbsent(((n.at.e / _gridCellM).floor(),
              (n.at.n / _gridCellM).floor()), () => [])
          .add(n);
    }
    _gridGraph = g;
    return _grid = grid;
  }

  /// A marker on every junction near the cursor — lights, or none — and a
  /// stop sign out along each leg that stops, laid out by [JunctionMarks]
  /// (the layout a click is read by). The plans are the road graph's, the
  /// rule the tiles draw by and the traffic waits by.
  List<OverlayMarker> _junctionMarkers(CitySim city, double pxM) {
    final graph = city.roadGraph;
    final cursor = hover ?? const Vec2(0, 0);
    // Rebuilt when the graph is replaced (a road, an override), the zoom
    // moves a notch, or the cursor leaves its cell — a cell about fifty
    // pixels across, so a sweep over a zoomed-out view rebuilds every few
    // dozen pixels rather than on every refresh.
    final cell =
        (50 * pxM).clamp(200.0, junctionReachM / 2).toDouble();
    final cx = (cursor.e / cell).floor(), cy = (cursor.n / cell).floor();
    final key = (
      identityHashCode(graph),
      city.roadsRevision,
      cx,
      cy,
      _notch(pxM),
      _bodyId,
      _groundKey,
    );
    final kept = _keptFor(_junctions, key);
    if (kept != null) return kept;
    final focus = Vec2((cx + 0.5) * cell, (cy + 0.5) * cell);
    final ring = JunctionMarks.ringRadiusM(pxM);
    final stopR = JunctionMarks.stopRadiusM(pxM);
    final stopOut = JunctionMarks.stopOutM(pxM);
    final grid = _junctionGrid(graph);
    const reach = junctionReachM;
    final x0 = ((focus.e - reach) / _gridCellM).floor();
    final x1 = ((focus.e + reach) / _gridCellM).floor();
    final y0 = ((focus.n - reach) / _gridCellM).floor();
    final y1 = ((focus.n + reach) / _gridCellM).floor();
    final out = <OverlayMarker>[];
    final laid = <Vec2>[];
    for (var x = x0; x <= x1; x++) {
      for (var y = y0; y <= y1; y++) {
        for (final node in grid[(x, y)] ?? const <RoadNode>[]) {
          if (node.at.distanceTo(focus) > reach) continue;
          final lights = node.plan.control == JunctionControl.signals;
          laid.add(node.at);
          out.add(OverlayMarker(
            atBF: drape(node.at, _nodeLift(node.heightM, node.at)),
            argb: lights ? lightsArgb : noLightsArgb,
            radiusM: ring,
            kind:
                lights ? OverlayMarkerKind.lights : OverlayMarkerKind.noLights,
          ));
          if (node.plan.control != JunctionControl.stop) continue;
          for (final i in node.plan.stopLegs) {
            final h = node.legs[i].heading;
            final at = node.at + Vec2(math.sin(h), math.cos(h)) * stopOut;
            laid.add(at);
            out.add(OverlayMarker(
              atBF: drape(at, _nodeLift(node.heightM, at)),
              argb: stopArgb,
              radiusM: stopR,
              kind: OverlayMarkerKind.stop,
            ));
          }
        }
      }
    }
    return _keep(_junctions, key, out, laid);
  }

  /// A raised node's height over the ground at [p]; 0 for one on the
  /// ground.
  double _nodeLift(double? heightM, Vec2 p) =>
      heightM == null ? 0 : math.max(0.0, heightM - _height(p));

  final _Kept<List<OverlayLine>> _routes = _Kept();
  int? _routesCount;

  /// The selected road, and the trips that use it, each drawn in its kind's
  /// colour. Asked of the traffic model once per selection, filter, change
  /// to the roads or pass of the traffic — never per mouse move.
  List<OverlayLine> _routeLines(CitySim city, RoadToolEditing c, double pxM) {
    final id = c.selectedRoadId;
    if (id == null) {
      c.routeCount = null;
      return const [];
    }
    final kinds = [for (final k in TripKind.values) c.routeKinds.contains(k)];
    // Keyed on the pass that published the routes, not just on there
    // having been one: a growing town's traffic is re-routed as its lots
    // fill, and a road kept selected showed its first pass's commuters
    // for good.
    final traffic = city.trafficReadout;
    final key = (
      id,
      kinds.join(),
      city.roadsRevision,
      identityHashCode(traffic),
      traffic.passes,
      _bodyId,
      _notch(pxM),
      _groundKey,
    );
    final kept = _keptFor(_routes, key);
    if (kept != null) {
      // The count goes with the lines: picking the road again (which
      // clears it) must not read "0 routes" over the routes drawn.
      c.routeCount = _routesCount;
      return kept;
    }
    final road = city.layout.roadById(id);
    final rec = city.layout.roadIndex.byId(id);
    final out = <OverlayLine>[];
    final laid = <Vec2>[];
    if (road != null && rec != null) out.add(_highlight(road, rec, pxM, laid));
    final routes = c.routeKinds.isEmpty
        ? const <TripRoute>[]
        : traffic.routesThrough(id, kinds: c.routeKinds);
    for (final t in routes) {
      final pts = _densify(t.polyline, 12);
      if (pts.length < 2) continue;
      laid.addAll(pts);
      out.add(OverlayLine(
        pointsBF: [for (final p in pts) drape(p)],
        argb: tripKindArgb(t.kind),
        widthM: math.max(2.0, 2.5 * pxM),
        liftM: 0.9,
      ));
    }
    c.routeCount = _routesCount = routes.length;
    return _keep(_routes, key, out, laid);
  }

  final _Kept<(List<OverlayLine>, List<OverlayMarker>)> _adjust = _Kept();

  /// [k]'s drawing, if it is still good for [key] — or null, to be drawn
  /// again.
  ///
  /// The hover raster fills a budget of cells a refresh, and a corner past
  /// it answers with the ground BEFORE any grading, uncached. A drawing
  /// that long — a route across town, every tunnel in the network — is
  /// mostly laid on that pristine ground the first time, and kept, it
  /// floated over the cuts and sank under the fills the town was graded
  /// into for as long as the roads stood. So one laid partly on the
  /// fallback is kept only while its points are warmed into the raster (a
  /// budget a refresh; see [warming]), and laid again once they all are.
  T? _keptFor<T>(_Kept<T> k, Object key) {
    if (k.key != key) return null;
    if (k.warming) {
      k.coldAt = _warmFrom(k.cold, k.coldAt);
      if (!k.warming) return null;
    }
    return k.value;
  }

  /// Keep [value], drawn for [key] over the points [laid].
  T _keep<T>(_Kept<T> k, Object key, T value, List<Vec2> laid) {
    k.key = key;
    k.value = value;
    final first = _firstCold(laid, 0);
    k.cold = first < laid.length ? laid : const [];
    k.coldAt = first;
    return value;
  }

  /// The first of [pts] from [from] on the raster did not answer from its
  /// cache, or their length when it answered for all (or there is none).
  int _firstCold(List<Vec2> pts, int from) {
    final warm = _warmAt;
    if (warm == null) return pts.length;
    for (var i = from; i < pts.length; i++) {
      if (!warm(pts[i])) return i;
    }
    return pts.length;
  }

  /// Warm [pts] into the raster from [from] on, as far as this refresh's
  /// fill budget goes; the first still cold after, or their length.
  int _warmFrom(List<Vec2> pts, int from) {
    final warm = _warmAt;
    if (warm == null) return pts.length;
    for (var i = from; i < pts.length; i++) {
      if (warm(pts[i])) continue;
      _height(pts[i]);
      if (!warm(pts[i])) return i;
    }
    return pts.length;
  }

  /// Whether something drawn still stands partly on ground the raster has
  /// not filled: the host refreshes again, mouse or no mouse, until not.
  bool get warming =>
      _ghostCold ||
      _tunnels.warming ||
      _junctions.warming ||
      _routes.warming ||
      _adjust.warming;

  /// Forget every cached drawing — the ground under them moved, or a test
  /// wants a fresh start.
  void invalidate() {
    _tunnels.forget();
    _junctions.forget();
    _routes.forget();
    _adjust.forget();
  }

  static int _notch(double pxM) =>
      (math.log(math.max(pxM, 0.05)) / math.log(1.5)).round();

  /// Drop everything the tool drew.
  void clear() {
    _ghostCold = false;
    overlay.clear();
  }

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
  /// its deck where it has one. The points it was laid on go to [laid].
  ///
  /// Densified like the ghost: the index holds a straight road as its two
  /// ends, and a band drawn between two points cuts through the hill
  /// between them, whatever ground the ends were laid on.
  OverlayLine _highlight(RoadSpline road, IndexedRoad rec, double pxM,
      [List<Vec2>? laid]) {
    final pts = _densify(_roadLine(rec, 0, rec.lengthM), 4);
    laid?.addAll(pts);
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
    // Laid partly on the raster's pristine fallback: the host draws it
    // again once more of the ground is in ([warming]), so a ghost the mouse
    // rests on ends up standing on the graded town, not the hill before it.
    _ghostCold = _firstCold(pts, 0) < pts.length;
  }

  /// Whether the ghost last laid stood partly on ground the raster had not
  /// filled.
  bool _ghostCold = false;

  void _clearGhost() {
    overlay.ghostBF = const [];
    overlay.ghostLiftsM = const [];
    overlay.ghostState = RoadGhostState.ok;
    overlay.ghostOneWay = false;
    _ghostCold = false;
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

/// A drawing kept across refreshes: what it was drawn for ([key]) and — if
/// the ground raster did not yet hold every point it was laid on — those
/// points ([cold], still cold from [coldAt] on), so it can be laid again
/// once they are warm (see `RoadToolScene._keptFor`).
class _Kept<T> {
  Object? key;
  T? value;
  List<Vec2> cold = const [];
  int coldAt = 0;

  bool get warming => coldAt < cold.length;

  void forget() {
    key = null;
    value = null;
    cold = const [];
    coldAt = 0;
  }
}
