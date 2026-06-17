import 'dart:math' as math;

import 'package:flutter/gestures.dart'
    show
        PointerScrollEvent,
        PointerDeviceKind,
        kPrimaryButton,
        kMiddleMouseButton,
        kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../domain/colony/building.dart';

/// Which warning badge floats over a building.
enum _BadgeKind { noRoad, worker }

/// Default per-tile traffic: uniform full load (so the legacy `commuters`-only
/// look is preserved when a caller doesn't supply real per-tile data).
double _noTraffic(int key) => 1.0;

/// Holds the city map camera (orbit + zoom + pan) OUTSIDE the CityMapView's
/// State so it survives the widget being rebuilt/reparented (e.g. toggling the
/// side drawer, which moves the map between a Row and a ListView). The parent
/// owns one of these; CityMapView reads + mutates it.
class CityCamController {
  double azimuth = math.pi / 4; // 3/4 view
  double elevation = math.pi / 5; // tilt down
  double zoom = 1.0; // multiplier on the auto-fit scale
  double panX = 0, panY = 0; // screen-px pan offset (two-finger drag)
}

/// Default building kind: none (generic box art).
String _noKind(Building b) => '';

/// Default footprint: 1×1 (single-tile building).
(int, int) _unitFoot(int key) => (1, 1);

/// Default architecture style: open (0).
int _openStyle(int key) => 0;

/// Default growth: fully built / fully utilised.
double _fullGrowth(int key) => 1.0;

/// A 3/4-perspective city map: the colony grid rendered as a tilted ground plane
/// with buildings drawn as lit 3D boxes (the same orbit-a-target view the flight
/// sim uses, scaled to a tabletop). Drag to orbit, tap a tile to place/remove.
///
/// Coordinate convention matches the flight camera: world X/Y is the ground
/// plane, +Z is up; the camera basis is forward=(cE·sA,cE·cA,−sE), right, up,
/// and we project orthographically onto right/up (a clean tabletop look).
class CityMapView extends StatefulWidget {
  final int grid; // cells per side
  final double cell; // metres per cell
  final Map<int, Building> cells; // y*grid + x -> building
  final Map<int, Color> zoneTint; // cells painted as a zone -> ground tint
  final Set<int> roads; // y*grid + x cells that hold a road
  final Set<int> rubble; // cells with disaster rubble (debris piles)
  final Map<int, double> fires; // burning building tiles -> intensity 0..1
  final Set<int> crystal; // cells overgrown by spore/crystal/vines (block build)
  final Map<int, int> scatter; // cell -> natural-cover kind index (trees/rocks…)
  final Set<int> support; // structural-support tiles (truss / platform / frame)
  final int colonyMode; // 0 open/surface, 1 floating(domed), 2 orbital
  final int liquidColor; // ARGB tint of the surface liquid (ocean/lava)
  final bool liquidMolten; // lava/molten — glows + is lethal
  final Map<int, double> elevation; // cell -> terrain height (m); non-flat cities
  final Set<int> liquidTiles; // cells below sea/lava level (water surface)
  final Set<int> roadSealed; // road tiles built while hostile -> tube, not asphalt
  final Set<int> hubs; // cells that are the network hub (city centre)
  final bool Function(int key) connected; // is this cell wired to the hub?
  final bool Function(int key) occupied; // false = abandoned/inactive -> grey
  final Color Function(Building) colorOf;
  final double Function(Building) heightOf; // building height (m)
  final String Function(Building) kindOf; // building type id (custom art)
  final (int, int) Function(int key) footOf; // footprint (w,h) cells, anchor key
  final int Function(int key) styleOf; // architecture style index (open/domed/orbital)
  // Grown-zone build/utilisation 0..1 (<0.3 = under construction). Utils = 1.
  final double Function(int key) growthOf;
  final void Function(int x, int y) onTapCell;
  final void Function(int x, int y)? onPaintCell; // drag-paint (continuous)
  final bool paintMode; // true: single-finger drag paints; false: drag orbits
  final double commuters; // 0..1 global traffic density (workforce/pop)
  final double Function(int key) trafficAt; // 0..1 per-tile road load
  final Set<int> transitStops; // cells with a transit stop
  final double corpseDensity; // 0..1 unprocessed-corpse backlog (stationary)
  final double garbageDensity; // 0..1 garbage backlog (black litter on ground)
  final double sewageDensity; // 0..1 sewage backlog (dark-green pools)
  final Set<int> wasteTiles; // cells (near buildings) litter may appear on
  final bool Function(int key) understaffed; // true -> red worker icon
  final Color groundTint; // surface colour of the host planet
  final int disaster; // _Disaster.index (0 = none); drives a weather overlay
  final double weatherFade; // 0..1 ramp so effects fade in/out, not pop
  final double nuclearWinter; // 0..1 sky darkening
  final double radiation; // 0..1 (green haze tint)
  final double daylight; // 1 = noon, 0 = night (drives tint + building lights)
  final bool flag; // a planted flag flies over the landing site (hub)
  final double stormX; // moving-storm epicentre, cell coords (<0 = none)
  final double stormY;
  final int? landerPad; // spaceport anchor the lander is parked on (occupied)
  // Craft visiting spaceports — relief missions + scheduled deliveries. Each
  // lands on its pad [tile], animated by [phase] (0..1). [relief] tints it.
  final List<({int tile, double phase, bool relief, double altM, double downrange})>
      landedCraft;
  final int? beaconCell; // grid cell holding the alien-beacon monolith
  final CityCamController? controller; // external camera (survives rebuilds)
  final bool panMode; // single-finger drag pans instead of orbiting
  final int? rectStart; // rect-select anchor cell (for the preview box)
  final int? rectEnd; // rect-select opposite corner (hovered/dragged cell)
  final void Function(int? key)? onHoverCell; // cursor moved over this cell
  final Set<int> hoverCells; // cells to highlight under the cursor (placement)
  final bool hoverDestructive; // true = bulldoze; highlight RED to warn

  const CityMapView({
    super.key,
    required this.grid,
    required this.cell,
    required this.cells,
    required this.zoneTint,
    required this.roads,
    this.rubble = const {},
    this.fires = const {},
    this.crystal = const {},
    this.scatter = const {},
    this.support = const {},
    this.colonyMode = 0,
    this.liquidColor = 0xFF285AA0,
    this.liquidMolten = false,
    this.elevation = const {},
    this.liquidTiles = const {},
    this.roadSealed = const {},
    required this.hubs,
    required this.connected,
    required this.occupied,
    required this.colorOf,
    required this.heightOf,
    this.kindOf = _noKind,
    this.footOf = _unitFoot,
    this.styleOf = _openStyle,
    this.growthOf = _fullGrowth,
    required this.onTapCell,
    this.onPaintCell,
    this.paintMode = false,
    this.commuters = 0,
    this.trafficAt = _noTraffic,
    this.transitStops = const {},
    this.corpseDensity = 0,
    this.garbageDensity = 0,
    this.sewageDensity = 0,
    this.wasteTiles = const {},
    required this.understaffed,
    this.groundTint = const Color(0xFF14241A),
    this.disaster = 0,
    this.weatherFade = 1,
    this.nuclearWinter = 0,
    this.radiation = 0,
    this.daylight = 1,
    this.flag = false,
    this.stormX = -1,
    this.stormY = -1,
    this.landerPad,
    this.landedCraft = const [],
    this.beaconCell,
    this.controller,
    this.panMode = false,
    this.rectStart,
    this.rectEnd,
    this.onHoverCell,
    this.hoverCells = const {},
    this.hoverDestructive = false,
  });

  @override
  State<CityMapView> createState() => _CityMapViewState();
}

class _CityMapViewState extends State<CityMapView>
    with SingleTickerProviderStateMixin {
  // The camera lives in an external controller when one is supplied (so it
  // survives the widget being rebuilt by the drawer toggle); otherwise a local
  // one is used. All reads/writes go through _cam.
  late final CityCamController _localCam = CityCamController();
  CityCamController get _cam => widget.controller ?? _localCam;
  double get _azimuth => _cam.azimuth;
  set _azimuth(double v) => _cam.azimuth = v;
  double get _elevation => _cam.elevation;
  set _elevation(double v) => _cam.elevation = v;
  double get _zoom => _cam.zoom;
  set _zoom(double v) => _cam.zoom = v;

  static const double _minZoom = 0.4;
  static const double _maxZoom = 24.0; // deeper zoom-in than the old 6×
  double _zoomStart = 1.0;
  Offset? _dragStart;
  Offset _panStart = Offset.zero;
  // Which mouse button started the current gesture (0 = touch / unknown). On
  // desktop: LMB (primary) places/paints, MMB orbits, RMB pans — so the camera
  // is always reachable without a tool toggle and MMB never lays tiles.
  int _btn = 0;
  double _azStart = 0, _elStart = 0;
  late final Ticker _ticker;
  double _phase = 0; // commute animation phase (0..1, loops)
  bool _painting = false; // a paint-drag is in progress
  (int, int)? _lastPainted; // last cell painted this drag (dedupe)
  // Number of fingers currently down + whether THIS gesture was ever multi-touch.
  // A pinch-zoom must never place tiles, so placement (tap + paint) is gated on a
  // gesture that stayed single-touch start to finish.
  int _activePointers = 0;
  bool _multiTouchGesture = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((d) {
      // ~6 s loop; repaint when there's traffic, a disaster, or env overlays.
      final p = (d.inMilliseconds / 6000) % 1.0;
      final animate = widget.commuters > 0 ||
          widget.disaster != 0 ||
          widget.nuclearWinter > 0.02 ||
          widget.radiation > 0.05 ||
          widget.corpseDensity > 0.02;
      if (animate && p != _phase) setState(() => _phase = p);
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      final size = Size(c.maxWidth, c.maxHeight);
      final cam = _Cam(_azimuth, _elevation, widget.grid, widget.cell, size,
          _zoom, _cam.panX, _cam.panY);
      // Terrain height of a cell (metres), for elevation-aware cursor picking.
      double zAt(int x, int y) => widget.elevation[y * widget.grid + x] ?? 0;
      return Listener(
        // Capture which mouse button is pressed so the scale handlers can route
        // LMB -> place, MMB -> orbit, RMB -> pan. Touch reports buttons == 0.
        // Also count fingers: a second finger marks the gesture multi-touch (a
        // pinch), which disables placement so zooming never lays tiles.
        onPointerDown: (e) {
          _btn = e.buttons;
          _activePointers++;
          if (_activePointers >= 2) {
            _multiTouchGesture = true;
            _painting = false; // cancel any paint that the first finger started
          }
        },
        onPointerUp: (e) {
          _activePointers = (_activePointers - 1).clamp(0, 10);
          // Only clear the pinch taint once EVERY finger is up. Fingers never
          // release simultaneously, so a pinch dropping to one finger must stay
          // tainted — otherwise the lingering finger places a tile on release.
          if (_activePointers == 0) _multiTouchGesture = false;
          // Finger lifted -> no "cursor on screen", so drop the hover highlight.
          if (e.kind != PointerDeviceKind.mouse) widget.onHoverCell?.call(null);
        },
        onPointerCancel: (e) {
          _activePointers = (_activePointers - 1).clamp(0, 10);
          if (_activePointers == 0) _multiTouchGesture = false;
        },
        // Mouse-wheel zoom (toward the cursor isn't needed; centre is fine).
        onPointerSignal: (sig) {
          if (sig is PointerScrollEvent) {
            setState(() => _zoom =
                (_zoom * (sig.scrollDelta.dy < 0 ? 1.12 : 0.89))
                    .clamp(_minZoom, _maxZoom));
          }
        },
        child: MouseRegion(
          // Only a REAL mouse hovers a cell. Touch/stylus has no "cursor when the
          // finger is up", so we never show the hover highlight for those — and a
          // stray touch-hover event clears it. (Touch placement uses tap/drag.)
          onHover: widget.onHoverCell == null
              ? null
              : (e) {
                  if (e.kind != PointerDeviceKind.mouse) {
                    widget.onHoverCell!(null);
                    return;
                  }
                  final c = cam.pick(e.localPosition, widget.grid, zAt);
                  widget.onHoverCell!(
                      c == null ? null : c.$2 * widget.grid + c.$1);
                },
          onExit:
              widget.onHoverCell == null ? null : (_) => widget.onHoverCell!(null),
          child: GestureDetector(
          onTapUp: (d) {
            // A tap that was part of a pinch (multi-touch) must not place a tile.
            if (_multiTouchGesture) return;
            final cell = cam.pick(d.localPosition, widget.grid, zAt);
            if (cell != null) widget.onTapCell(cell.$1, cell.$2);
          },
          onScaleStart: (d) {
            _dragStart = d.localFocalPoint;
            _panStart = Offset(_cam.panX, _cam.panY);
            _azStart = _azimuth;
            _elStart = _elevation;
            _zoomStart = _zoom;
            // Taint this gesture if it already has 2+ fingers. NEVER clear the
            // taint here — a pinch that drops to one finger restarts the scale
            // gesture with one finger down, and clearing it would let that
            // lingering finger place a tile. The taint clears only when every
            // finger is fully up (the pointer-up/cancel handlers).
            if (d.pointerCount >= 2 || _activePointers >= 2) {
              _multiTouchGesture = true;
            }
            // Don't paint yet — wait for the first single-finger move. Painting on
            // touch-down would lay a tile before a second finger (pinch) can
            // cancel it. The move handler starts the paint when it's safe.
            _painting = false;
            _lastPainted = null;
          },
          onScaleUpdate: (d) {
            if (_dragStart == null) return;
            final dd = d.localFocalPoint - _dragStart!;
            // Two (or more) fingers: pinch-zoom AND pan together. Pan follows the
            // focal point so the map slides under your fingers.
            if (d.pointerCount >= 2) {
              _painting = false;
              setState(() {
                _zoom = (_zoomStart * d.scale).clamp(_minZoom, _maxZoom);
                _cam.panX = _panStart.dx + dd.dx;
                _cam.panY = _panStart.dy + dd.dy;
              });
              return;
            }
            // MMB always orbits; RMB always pans — regardless of tool/camera mode.
            if (_btn == kMiddleMouseButton) {
              setState(() {
                _azimuth = _azStart + dd.dx * 0.008;
                _elevation =
                    (_elStart + dd.dy * 0.006).clamp(0.12, math.pi / 2 - 0.05);
              });
              return;
            }
            if (_btn == kSecondaryMouseButton) {
              setState(() {
                _cam.panX = _panStart.dx + dd.dx;
                _cam.panY = _panStart.dy + dd.dy;
              });
              return;
            }
            // Begin painting on the FIRST single-finger move (deferred from
            // touch-down so a pinch never lays a tile). Only when: paint mode, a
            // primary/touch input, exactly one finger, and not a pinch gesture.
            final placeBtn = _btn == 0 || _btn == kPrimaryButton;
            if (!_painting &&
                placeBtn &&
                widget.paintMode &&
                widget.onPaintCell != null &&
                !_multiTouchGesture &&
                d.pointerCount == 1) {
              _painting = true;
              // A paint-drag is underway -> drop the hover preview highlight; the
              // painted cells themselves show the result.
              widget.onHoverCell?.call(null);
            }
            // Paint mode (LMB/touch): a drag paints each new cell it crosses.
            if (_painting && widget.onPaintCell != null) {
              final c = cam.pick(d.localFocalPoint, widget.grid, zAt);
              if (c != null && c != _lastPainted) {
                _lastPainted = c;
                widget.onPaintCell!(c.$1, c.$2);
              }
              return;
            }
            // Plain LMB/touch drag: pan or orbit depending on the camera mode.
            setState(() {
              if (widget.panMode) {
                _cam.panX = _panStart.dx + dd.dx;
                _cam.panY = _panStart.dy + dd.dy;
              } else {
                _azimuth = _azStart + dd.dx * 0.008; // drag right -> orbit right
                _elevation =
                    (_elStart + dd.dy * 0.006).clamp(0.12, math.pi / 2 - 0.05);
              }
            });
          },
          onScaleEnd: (_) {
            _dragStart = null;
            _painting = false;
            _lastPainted = null;
            _btn = 0;
            // Clear the multi-touch flag only once all fingers are up, so a
            // lingering finger after a pinch can't immediately start placing.
            if (_activePointers <= 0) _multiTouchGesture = false;
          },
          child: ClipRect(
            child: CustomPaint(
          size: size,
          painter: _CityPainter(
            cam: cam,
            grid: widget.grid,
            cell: widget.cell,
            cells: widget.cells,
            zoneTint: widget.zoneTint,
            roads: widget.roads,
            rubble: widget.rubble,
            fires: widget.fires,
            crystal: widget.crystal,
            scatter: widget.scatter,
            support: widget.support,
            colonyMode: widget.colonyMode,
            liquidColor: widget.liquidColor,
            liquidMolten: widget.liquidMolten,
            elevation: widget.elevation,
            liquidTiles: widget.liquidTiles,
            roadSealed: widget.roadSealed,
            hubs: widget.hubs,
            connected: widget.connected,
            occupied: widget.occupied,
            colorOf: widget.colorOf,
            heightOf: widget.heightOf,
            kindOf: widget.kindOf,
            footOf: widget.footOf,
            styleOf: widget.styleOf,
            growthOf: widget.growthOf,
            commuters: widget.commuters,
            trafficAt: widget.trafficAt,
            transitStops: widget.transitStops,
            corpseDensity: widget.corpseDensity,
            garbageDensity: widget.garbageDensity,
            sewageDensity: widget.sewageDensity,
            wasteTiles: widget.wasteTiles,
            understaffed: widget.understaffed,
            groundTint: widget.groundTint,
            disaster: widget.disaster,
            weatherFade: widget.weatherFade,
            nuclearWinter: widget.nuclearWinter,
            radiation: widget.radiation,
            daylight: widget.daylight,
            flag: widget.flag,
            stormX: widget.stormX,
            stormY: widget.stormY,
            landerPad: widget.landerPad,
            landedCraft: widget.landedCraft,
            beaconCell: widget.beaconCell,
            rectStart: widget.rectStart,
            rectEnd: widget.rectEnd,
            hoverCells: widget.hoverCells,
            hoverDestructive: widget.hoverDestructive,
            phase: _phase,
          ),
        ),
        ),
        ),
      ),
    );
    });
  }
}

/// Orthographic 3/4 camera centred on the grid, auto-scaled to fit the viewport.
class _Cam {
  final double az, el;
  final Size size;
  final double scale; // px per metre
  final Offset centre;
  late final List<double> _fwd;
  late final List<double> _right;
  late final List<double> _up;
  late final double _cx, _cy; // grid centre (metres)

  _Cam(this.az, this.el, int grid, double cell, this.size,
      [double zoom = 1.0, double panX = 0, double panY = 0])
      : scale = _fitScale(grid, cell, el, size) * zoom,
        // Pan shifts the projection centre directly in screen px.
        centre = Offset(size.width / 2 + panX, size.height * 0.56 + panY) {
    final ce = math.cos(el), se = math.sin(el);
    final ca = math.cos(az), sa = math.sin(az);
    _fwd = [ce * sa, ce * ca, -se];
    _right = [ca, -sa, 0];
    // up = right x fwd
    _up = [
      _right[1] * _fwd[2] - _right[2] * _fwd[1],
      _right[2] * _fwd[0] - _right[0] * _fwd[2],
      _right[0] * _fwd[1] - _right[1] * _fwd[0],
    ];
    _cx = grid * cell / 2;
    _cy = grid * cell / 2;
  }

  static double _fitScale(int grid, double cell, double el, Size size) {
    final span = grid * cell * 1.5;
    final byW = size.width / span;
    final byH = size.height / (span * math.sin(el).clamp(0.3, 1.0)) * 0.9;
    return math.min(byW, byH).clamp(0.1, 1e6);
  }

  /// Project a world point (x,y on ground, z up; metres) to screen px.
  Offset project(double x, double y, double z) {
    final dx = x - _cx, dy = y - _cy, dz = z;
    final sx = dx * _right[0] + dy * _right[1] + dz * _right[2];
    final sy = dx * _up[0] + dy * _up[1] + dz * _up[2];
    return Offset(centre.dx + sx * scale, centre.dy - sy * scale);
  }

  /// Depth along the view axis (bigger = farther) for back-to-front ordering.
  double depth(double x, double y, double z) =>
      (x - _cx) * _fwd[0] + (y - _cy) * _fwd[1] + z * _fwd[2];

  /// Nearest grid cell to a screen point (project each cell centre, pick closest
  /// within a tile-sized radius). [zAt] gives a cell's terrain elevation (metres)
  /// so raised tiles are hit-tested at their true on-screen position, not at
  /// z=0 (which would highlight a neighbour on sloped ground).
  (int, int)? pick(Offset p, int grid, [double Function(int, int)? zAt]) {
    var best = -1, bestX = 0, bestY = 0;
    var bestD = double.infinity;
    final cell = (_cx * 2) / grid;
    for (var y = 0; y < grid; y++) {
      for (var x = 0; x < grid; x++) {
        final c = project(
            (x + 0.5) * cell, (y + 0.5) * cell, zAt == null ? 0 : zAt(x, y));
        final d = (c - p).distanceSquared;
        if (d < bestD) {
          bestD = d;
          best = 1;
          bestX = x;
          bestY = y;
        }
      }
    }
    if (best < 0) return null;
    // Accept only if reasonably close (half a tile in px).
    if (bestD > (cell * scale) * (cell * scale)) return null;
    return (bestX, bestY);
  }
}

class _CityPainter extends CustomPainter {
  final _Cam cam;
  final int grid;
  final double cell;
  final Map<int, Building> cells;
  final Map<int, Color> zoneTint;
  final Set<int> roads;
  final Set<int> rubble;
  final Map<int, double> fires;
  final Set<int> crystal;
  final Map<int, int> scatter;
  final Set<int> support;
  final int colonyMode;
  final int liquidColor;
  final bool liquidMolten;
  final Map<int, double> elevation;
  final Set<int> liquidTiles;
  final Set<int> roadSealed;
  final Set<int> hubs;
  final bool Function(int key) connected;
  final bool Function(int key) occupied;
  final Color Function(Building) colorOf;
  final double Function(Building) heightOf;
  final String Function(Building) kindOf;
  final (int, int) Function(int key) footOf;
  final int Function(int key) styleOf;
  final double Function(int key) growthOf;
  final double commuters;
  final double Function(int key) trafficAt;
  final Set<int> transitStops;
  final double corpseDensity;
  final double garbageDensity;
  final double sewageDensity;
  final Set<int> wasteTiles;
  final bool Function(int key) understaffed;
  final Color groundTint;
  final int disaster;
  final double weatherFade;
  final double nuclearWinter;
  final double radiation;
  final double daylight;
  final bool flag;
  final double stormX;
  final double stormY;
  final int? landerPad;
  final List<({int tile, double phase, bool relief, double altM, double downrange})>
      landedCraft;
  final int? beaconCell;
  final int? rectStart;
  final int? rectEnd;
  final Set<int> hoverCells;
  final bool hoverDestructive;
  final double phase;

  _CityPainter({
    required this.cam,
    required this.grid,
    required this.cell,
    required this.cells,
    required this.zoneTint,
    required this.roads,
    this.rubble = const {},
    this.fires = const {},
    this.crystal = const {},
    this.scatter = const {},
    this.support = const {},
    this.colonyMode = 0,
    this.liquidColor = 0xFF285AA0,
    this.liquidMolten = false,
    this.elevation = const {},
    this.liquidTiles = const {},
    this.roadSealed = const {},
    required this.hubs,
    required this.connected,
    required this.occupied,
    required this.colorOf,
    required this.heightOf,
    this.kindOf = _noKind,
    this.footOf = _unitFoot,
    this.styleOf = _openStyle,
    this.growthOf = _fullGrowth,
    this.commuters = 0,
    this.trafficAt = _noTraffic,
    this.transitStops = const {},
    this.corpseDensity = 0,
    this.garbageDensity = 0,
    this.sewageDensity = 0,
    this.wasteTiles = const {},
    required this.understaffed,
    this.groundTint = const Color(0xFF14241A),
    this.disaster = 0,
    this.weatherFade = 1,
    this.nuclearWinter = 0,
    this.radiation = 0,
    this.daylight = 1,
    this.flag = false,
    this.stormX = -1,
    this.stormY = -1,
    this.landerPad,
    this.landedCraft = const [],
    this.beaconCell,
    this.rectStart,
    this.rectEnd,
    this.hoverCells = const {},
    this.hoverDestructive = false,
    this.phase = 0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Backdrop for non-surface colonies: a cloud sea (floating) or a starfield
    // (orbital), filling behind the deck.
    if (colonyMode != 0) _drawColonyBackdrop(canvas, size);

    _drawTerrain(canvas);

    // Zone tints: flat coloured ground tiles where a zone is painted (drawn
    // under the grown building box so the painted zone reads even before it
    // grows / when disconnected).
    for (final e in zoneTint.entries) {
      _drawZoneTile(canvas, e.key % grid, e.key ~/ grid, e.value);
    }

    // Structural-support tiles (truss / platform / lift-frame) under buildings.
    for (final k in support) {
      _drawSupport(canvas, k % grid, k ~/ grid);
    }
    // Natural ground cover (trees/rocks/etc) on open tiles — surface colonies
    // only (a station/cloud deck has no terrain). Drawn under roads + buildings.
    if (colonyMode == 0) {
      for (final e in scatter.entries) {
        _drawScatter(canvas, e.key % grid, e.key ~/ grid, e.value);
      }
    }

    // Roads: flat asphalt tiles on the ground (drawn before buildings).
    for (final k in roads) {
      _drawRoadTile(canvas, k % grid, k ~/ grid);
    }
    // Driveways: a plain grey stub linking each connected building to its
    // nearest road tile. Buildings don't sit ON the road (no lane lines) — the
    // driveway is the link, so a building tucked against a road corner still
    // reads as served without the road merging into it.
    for (final k in cells.keys) {
      if (connected(k)) _drawDriveway(canvas, k % grid, k ~/ grid);
    }
    // Rubble: debris piles where a disaster flattened a building.
    for (final k in rubble) {
      _drawRubble(canvas, k % grid, k ~/ grid);
    }
    // Overgrowth: spore/vine/crystal cover spread by bio events.
    for (final k in crystal) {
      _drawCrystal(canvas, k % grid, k ~/ grid);
    }
    // Hub marker: a bright pad so the city-centre is obvious.
    for (final k in hubs) {
      _drawHubPad(canvas, k % grid, k ~/ grid);
    }
    // Transit stops on the road network.
    for (final k in transitStops) {
      _drawTransitStop(canvas, k % grid, k ~/ grid);
    }
    // Commuters: animated dots flowing along the road arms (traffic). On
    // stations the tubes carry pods through their glowing core instead.
    if (commuters > 0 && colonyMode == 0) {
      for (final k in roads) {
        _drawCommuters(canvas, k % grid, k ~/ grid);
      }
    }
    // Corpses: stationary dark bodies littering the roads when the deathcare
    // backlog is high (build morgues/crematoria to clear them).
    if (corpseDensity > 0.02) {
      for (final k in roads) {
        _drawCorpses(canvas, k % grid, k ~/ grid);
      }
    }
    // Waste litter on the ground: black garbage bags + dark-green sewage pools.
    // Drawn ONLY on tiles around waste-producing buildings (not empty streets),
    // density scaling with the unprocessed backlog (drawn like corpses).
    if (garbageDensity > 0.02 || sewageDensity > 0.02) {
      for (final k in wasteTiles) {
        _drawWaste(canvas, k % grid, k ~/ grid);
      }
    }

    // Unified depth-sorted pass for everything TALL (buildings, lander cones,
    // the flag) so they overdraw each other correctly by depth — the lander cone
    // no longer always sits on top / clips against nearby boxes. Each item is a
    // (depthCentre, draw) pair; we sort back-to-front then paint.
    final items = <({double depth, void Function() draw})>[];
    double depthAt(int gx, int gy, int fw, int fh) =>
        cam.depth((gx + fw / 2) * cell, (gy + fh / 2) * cell, 0);

    for (final e in cells.entries) {
      final gx = e.key % grid, gy = e.key ~/ grid;
      final live = connected(e.key) && occupied(e.key);
      final fw = footOf(e.key).$1, fh = footOf(e.key).$2;
      final kind = kindOf(e.value);
      final growth = growthOf(e.key);
      final style = styleOf(e.key); // 0 open, 1 domed, 2 orbital
      items.add((
        depth: depthAt(gx, gy, fw, fh),
        draw: () {
          if (kind == 'solar' || kind == 'solar-big') {
            _drawSolar(canvas, gx, gy, fw, fh, live);
          } else if (kind == 'farm' ||
              kind == 'farm-big' ||
              kind == 'hydroponics') {
            _drawFarm(canvas, gx, gy, fw, fh, e.value, live);
          } else if (kind == 'mine' && fw >= 3) {
            _drawQuarry(canvas, gx, gy, fw, fh, e.value, live);
          } else if (kind == 'spaceport' && growth >= 0.3) {
            _drawSpaceport(canvas, gx, gy, fw, fh, e.value, live);
          } else if (growth < 0.3 && live) {
            // Scaffolding only for a building genuinely under construction AND
            // still alive. An abandoned/cut-off building (not live) whose
            // occupancy decayed must render as a full-height greyed ruin, not
            // shrink into scaffold.
            _drawConstruction(canvas, gx, gy, fw, fh, e.value, growth);
          } else if (style == 2) {
            // Orbital: a rounded cylindrical hull module instead of a box.
            _drawModule(canvas, gx, gy, fw, fh, e.value, live, growth);
          } else if (style == 1) {
            // Domed (sealed, inhospitable world): a faceted pentagon-sphere hab
            // instead of a cube.
            _drawPentaSphere(canvas, gx, gy, fw, fh, e.value, live);
          } else {
            // Height ramps ONLY through the construction phase (growth 0..0.3),
            // then the building is at full size. Occupancy/abandonment must NOT
            // change its structure — an emptied or abandoned building is a
            // standing (greyed) ruin, it doesn't deflate. So once built it's
            // always full height regardless of the live occupancy value.
            const cf = 0.3; // construction fraction (matches _constructFrac)
            // A live building grows through construction then holds full size; a
            // non-live (abandoned/cut-off) one is a full-height ruin (never
            // deflates as its occupancy decays).
            final hScale = !live
                ? 1.0
                : (growth >= cf
                    ? 1.0
                    : (0.4 + (growth / cf) * 0.6).clamp(0.4, 1.0));
            _drawBox(canvas, gx, gy, fw, fh, e.value, live, heightScale: hScale);
          }
        },
      ));
    }
    // The lander cone(s) — at the hub (landing site) and on the parked spaceport
    // pad — join the same depth pass, plus the planted flag.
    for (final k in hubs) {
      final gx = k % grid, gy = k ~/ grid;
      items.add((depth: depthAt(gx, gy, 1, 1), draw: () {
        _drawLanderCone(canvas, gx, gy);
        if (flag) _drawFlag(canvas, gx, gy);
      }));
    }
    final pad = landerPad;
    if (pad != null) {
      final gx = pad % grid, gy = pad ~/ grid;
      items.add((depth: depthAt(gx, gy, 1, 1), draw: () {
        _drawLanderCone(canvas, gx, gy);
      }));
    }
    // Visiting craft: relief + delivery shuttles. A craft on its pad uses the
    // pad animation; a delivery still IN FLIGHT (altM > ~5 m) is drawn climbing /
    // descending above the map at its altitude + downrange offset.
    for (final c in landedCraft) {
      final gx = c.tile % grid, gy = c.tile ~/ grid;
      if (c.altM > 5) {
        items.add((depth: -1e9, draw: () {
          _drawFlyingCraft(canvas, gx, gy, c.altM, c.downrange, c.relief);
        }));
      } else {
        items.add((depth: depthAt(gx, gy, 1, 1) - 1, draw: () {
          _drawReliefCraft(canvas, gx, gy, c.phase, relief: c.relief);
        }));
      }
    }
    items.sort((a, b) => b.depth.compareTo(a.depth)); // far -> near
    for (final it in items) {
      it.draw();
    }
    // Alien-beacon monolith: a tall dark slab standing on its grid tile.
    final beacon = beaconCell;
    if (beacon != null) {
      _drawMonolith(canvas, beacon % grid, beacon ~/ grid);
    }

    // Fires: animated flames overlaid on each burning building tile.
    if (fires.isNotEmpty) _drawFires(canvas);

    // Night: a cool blue darkening that deepens as the sun sets. Drawn over the
    // ground + buildings but UNDER the window-lights (added next) so the lit
    // windows pop against the dusk.
    final night = (1 - daylight).clamp(0.0, 1.0);
    if (night > 0.03) {
      canvas.drawRect(
          Offset.zero & size,
          Paint()
            ..color = const Color(0xFF0A1020).withValues(alpha: night * 0.6));
      // Window-lights: each occupied building glows with a warm dot at night.
      for (final e in cells.entries) {
        if (!(connected(e.key) && occupied(e.key))) continue;
        _drawWindowLights(canvas, e.key % grid, e.key ~/ grid, e.value, night);
      }
    }

    // Full-screen environment overlays: nuclear winter darkens, radiation tints
    // green, and the active disaster draws its weather effect.
    if (nuclearWinter > 0.02) {
      canvas.drawRect(Offset.zero & size,
          Paint()..color = const Color(0xFF12161C).withValues(alpha: nuclearWinter * 0.6));
    }
    if (radiation > 0.05) {
      canvas.drawRect(Offset.zero & size,
          Paint()..color = const Color(0xFF6FFF00).withValues(alpha: radiation * 0.12));
    }
    if (disaster != 0) _drawWeather(canvas, size);

    // Rect-select preview: outline the rectangle from the anchor tile to the
    // cursor/dragged tile so you can see what a Rect fill will cover.
    if (rectStart != null && rectEnd != null) {
      _drawRectPreview(canvas, rectStart!, rectEnd!);
    }

    // Placement highlight: tint the tile(s) under the cursor so it's clear a
    // placement tool is active + where (a multi-tile building shows its whole
    // footprint).
    // Bulldoze (destructive) tints the cursor RED to warn; otherwise white.
    final fillC = hoverDestructive ? const Color(0x55FF3B30) : const Color(0x40FFFFFF);
    final strokeC = hoverDestructive ? const Color(0xEEFF3B30) : const Color(0xCCFFFFFF);
    for (final k in hoverCells) {
      final gx = k % grid, gy = k ~/ grid;
      final hz = 0.14 + _z(gx, gy); // drape on the terrain tile
      _fillRect(canvas, gx + 0.04, gy + 0.04, gx + 0.96, gy + 0.96, hz,
          Paint()..color = fillC);
      _strokeRect(canvas, gx + 0.04, gy + 0.04, gx + 0.96, gy + 0.96, hz,
          strokeC, 1.5);
    }
  }

  /// Highlight the rectangle spanning two corner cells (rect-select preview): a
  /// translucent fill + bright outline on the ground plane.
  void _drawRectPreview(Canvas canvas, int a, int b) {
    final ax = a % grid, ay = a ~/ grid;
    final bx = b % grid, by = b ~/ grid;
    final ix0 = math.min(ax, bx), ix1 = math.max(ax, bx) + 1;
    final iy0 = math.min(ay, by), iy1 = math.max(ay, by) + 1;
    final x0 = ix0.toDouble(), x1 = ix1.toDouble();
    final y0 = iy0.toDouble(), y1 = iy1.toDouble();
    // Drape the outline corners on the terrain (corner heights), so the preview
    // hugs the slope instead of floating at a fixed level.
    final pts = [
      cam.project(x0 * cell, y0 * cell, 0.12 + _cornerZ(ix0, iy0)),
      cam.project(x1 * cell, y0 * cell, 0.12 + _cornerZ(ix1, iy0)),
      cam.project(x1 * cell, y1 * cell, 0.12 + _cornerZ(ix1, iy1)),
      cam.project(x0 * cell, y1 * cell, 0.12 + _cornerZ(ix0, iy1)),
    ];
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (var i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    path.close();
    canvas.drawPath(
        path, Paint()..color = const Color(0x3340C4FF)); // translucent fill
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFF40C4FF));
  }

  /// Draw animated flames on every burning building tile (the per-tile fire
  /// effect). Each fire is a cluster of flickering flame tongues + a smoke plume
  /// + an ember glow, sized by burn intensity, sitting on the terrain.
  void _drawFires(Canvas canvas) {
    fires.forEach((k, intensity) {
      final gx = k % grid, gy = k ~/ grid;
      final tz = _z(gx, gy);
      final cx = (gx + 0.5) * cell, cy = (gy + 0.5) * cell;
      final scale = (0.5 + intensity); // bigger as it rages
      // Ember glow on the ground.
      final glowBase = cam.project(cx, cy, tz + 0.2);
      canvas.drawCircle(
          glowBase,
          (cell * cam.scale) * 0.32 * scale,
          Paint()
            ..color = const Color(0xFFFF7020)
                .withValues(alpha: 0.35 * intensity)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
      // A handful of flame tongues, jittered around the tile, flickering on phase.
      final n = (3 + intensity * 5).round();
      var seed = (gx * 92837111) ^ (gy * 689287499);
      for (var i = 0; i < n; i++) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        final ox = ((seed % 1000) / 1000 - 0.5) * 0.5;
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        final oy = ((seed % 1000) / 1000 - 0.5) * 0.5;
        // Flicker the flame height with time (phase) + a per-flame offset.
        final flick = 0.6 + 0.4 * math.sin(phase * 18 + i * 1.7 + gx + gy);
        final fh = (3.0 + 5.0 * intensity) * flick; // metres
        final fx = cx + ox * cell, fy = cy + oy * cell;
        final base0 = cam.project(fx - 0.06 * cell, fy, tz + 0.2);
        final base1 = cam.project(fx + 0.06 * cell, fy, tz + 0.2);
        final tip = cam.project(fx, fy, tz + fh);
        final mid = cam.project(fx, fy, tz + fh * 0.45);
        // Outer (orange) flame.
        canvas.drawPath(
            Path()
              ..moveTo(base0.dx, base0.dy)
              ..quadraticBezierTo(
                  mid.dx - 4, mid.dy, tip.dx, tip.dy)
              ..quadraticBezierTo(
                  mid.dx + 4, mid.dy, base1.dx, base1.dy)
              ..close(),
            Paint()..color = const Color(0xFFFF6A1A).withValues(alpha: 0.9));
        // Inner (yellow) core.
        final core = cam.project(fx, fy, tz + fh * 0.7);
        canvas.drawPath(
            Path()
              ..moveTo(base0.dx + (base1.dx - base0.dx) * 0.3, base0.dy)
              ..quadraticBezierTo(mid.dx, mid.dy, core.dx, core.dy)
              ..quadraticBezierTo(mid.dx, mid.dy,
                  base1.dx - (base1.dx - base0.dx) * 0.3, base1.dy)
              ..close(),
            Paint()..color = const Color(0xFFFFD23F).withValues(alpha: 0.9));
      }
      // Smoke plume drifting up + sideways.
      final smoke = Paint()
        ..color = const Color(0xFF2A2622).withValues(alpha: 0.35 * intensity)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
      for (var i = 0; i < 3; i++) {
        final t = ((phase * 0.6 + i / 3) % 1.0);
        final sz = (cell * cam.scale) * 0.12 * (0.5 + t);
        final sp = cam.project(cx + t * 0.3 * cell, cy,
            tz + (6.0 + intensity * 6) + t * 14);
        canvas.drawCircle(sp, sz, smoke);
      }
    });
  }

  /// Render the active disaster as a simple animated screen-space effect.
  void _drawWeather(Canvas canvas, Size size) {
    final rnd = math.Random(7);
    // Fade the whole overlay in/out (weatherFade) so effects don't pop in at
    // full strength. A translucent layer scales every effect's alpha at once.
    final fade = weatherFade.clamp(0.0, 1.0);
    if (fade <= 0) return;
    final layered = fade < 0.999;
    if (layered) {
      canvas.saveLayer(Offset.zero & size,
          Paint()..color = Color.fromRGBO(0, 0, 0, fade));
    }
    switch (disaster) {
      case 1: // rain
        _precip(canvas, size, 180, const Color(0xAA8FB7D9), 14, vertical: true);
      case 2: // thunderstorm
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFF0A0E18).withValues(alpha: 0.4));
        _precip(canvas, size, 220, const Color(0xCC9FC0E0), 18, vertical: true);
        _drawLightning(canvas, size);
      case 3: // snow
        _precip(canvas, size, 160, const Color(0xCCFFFFFF), 5, vertical: false);
      case 4: // dust storm
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFFB08A4A).withValues(alpha: 0.35));
        _precip(canvas, size, 120, const Color(0x66D8C088), 22, vertical: false);
      case 5: // tornado
        _drawTornado(canvas, size);
      case 6: // fire — the blaze is drawn PER-TILE (_drawFires); just a faint
        // smoke haze across the sky so the air reads hot, not a full-screen wash.
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFF3A2A20).withValues(alpha: 0.10));
      case 7: // meteor shower
        for (var i = 0; i < 18; i++) {
          final t = (phase * 1.5 + i / 18) % 1.0;
          final sx = rnd.nextDouble() * size.width;
          final x = sx + t * 120, y = t * size.height;
          canvas.drawLine(Offset(x, y), Offset(x - 24, y - 36),
              Paint()..color = const Color(0xFFFFD54F)..strokeWidth = 2);
        }
      case 8: // plague — sickly green miasma + drifting motes
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFF6B8E23).withValues(alpha: 0.18));
        for (var i = 0; i < 30; i++) {
          final x = (rnd.nextDouble() + phase * 0.3) % 1 * size.width;
          final y = rnd.nextDouble() * size.height;
          canvas.drawCircle(Offset(x, y), 3 + rnd.nextDouble() * 4,
              Paint()..color = const Color(0xFF9CCC65).withValues(alpha: 0.25));
        }
      case 9: // famine — withered brown wash
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFF7A5230).withValues(alpha: 0.22));
      case 10: // solar storm — bright aurora flicker
        final pulse = 0.3 + 0.3 * (0.5 + 0.5 * math.sin(phase * 40));
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFFFFF59D).withValues(alpha: pulse * 0.3));
        // Aurora ribbons up top.
        for (var i = 0; i < 4; i++) {
          final y = size.height * 0.1 + i * 18.0;
          final col = i.isEven
              ? const Color(0x4480FFEA)
              : const Color(0x44FF80AB);
          canvas.drawRect(
              Rect.fromLTWH(0, y + math.sin(phase * 20 + i) * 6, size.width, 8),
              Paint()..color = col);
        }
      case 11: // nuke flash + mushroom
        final flash = (1 - phase).clamp(0.0, 1.0);
        canvas.drawRect(Offset.zero & size,
            Paint()..color = Colors.white.withValues(alpha: flash * 0.7));
        final c = Offset(size.width / 2, size.height * 0.6);
        canvas.drawCircle(c, size.width * 0.12 * (0.5 + phase),
            Paint()..color = const Color(0xFFFF7043).withValues(alpha: 0.5));
        canvas.drawCircle(Offset(c.dx, c.dy - size.width * 0.18 * phase),
            size.width * 0.09,
            Paint()..color = const Color(0xFFBF360C).withValues(alpha: 0.6));
      case 12: // hurricane — broad travelling cyclone + rain
        _precip(canvas, size, 200, const Color(0xCC9FC0E0), 20, vertical: false);
        _drawTornado(canvas, size, wide: true);
      case 13: // blizzard — heavy driving snow + whiteout
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0x55E8F0FF));
        _precip(canvas, size, 320, const Color(0xEEFFFFFF), 12, vertical: false);
      case 14: // fog — soft grey haze
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFFB8C0C6).withValues(alpha: 0.34));
        for (var i = 0; i < 5; i++) {
          final y = size.height * (0.2 + i * 0.16) +
              math.sin(phase * 4 + i) * 10;
          canvas.drawRect(Rect.fromLTWH(0, y, size.width, 26),
              Paint()..color = const Color(0x33FFFFFF));
        }
      case 15: // acid rain — sickly yellow-green precip
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFF9AA82A).withValues(alpha: 0.16));
        _precip(canvas, size, 200, const Color(0xCCC6E04A), 16, vertical: true);
      case 16: // earthquake — screen shake fissures
        final shake = math.sin(phase * 60) * 4;
        canvas.save();
        canvas.translate(shake, 0);
        for (var i = 0; i < 5; i++) {
          final x = size.width * (0.15 + i * 0.18);
          final path = Path()..moveTo(x, size.height);
          for (var s = 1; s <= 5; s++) {
            path.lineTo(x + (rnd.nextDouble() - 0.5) * 40,
                size.height - s * size.height * 0.18);
          }
          canvas.drawPath(
              path,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2
                ..color = const Color(0xAA5A3A22));
        }
        canvas.restore();
      case 17: // radiation storm — green particle haze + flicker
        final pulse = 0.2 + 0.2 * (0.5 + 0.5 * math.sin(phase * 30));
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFF7CFF4A).withValues(alpha: pulse));
        for (var i = 0; i < 50; i++) {
          final x = rnd.nextDouble() * size.width;
          final y = (rnd.nextDouble() + phase) % 1 * size.height;
          canvas.drawCircle(Offset(x, y), 1.5,
              Paint()..color = const Color(0xCCB9FF80));
        }
      case 18: // glass rain — sharp glinting silicate shards
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFF402A1A).withValues(alpha: 0.2));
        final g = Paint()
          ..color = const Color(0xCCFFE0B2)
          ..strokeWidth = 1.4;
        for (var i = 0; i < 160; i++) {
          final bx = rnd.nextDouble() * size.width;
          final t = (phase * 22 + i * 0.13) % 1.0;
          final y = t * size.height;
          final x = bx + t * 60;
          canvas.drawLine(Offset(x, y), Offset(x - 8, y - 14), g);
        }
      case 19: // ammonia storm — bluish toxic clouds
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFF6A8CFF).withValues(alpha: 0.2));
        _precip(canvas, size, 160, const Color(0xAAB8C8FF), 18, vertical: false);
      case 20: // cryovolcanism — pale ice plumes rising
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFFAEE5FF).withValues(alpha: 0.12));
        for (var i = 0; i < 30; i++) {
          final x = rnd.nextDouble() * size.width;
          final y = size.height - (rnd.nextDouble() + phase) % 1 * size.height * 0.6;
          canvas.drawCircle(Offset(x, y), 2 + rnd.nextDouble() * 3,
              Paint()..color = const Color(0x99D6F4FF));
        }
      case 21: // miasma — heavy sickly PURPLE ground fog with drifting motes
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFF4A2A5C).withValues(alpha: 0.28));
        // Low rolling fog banks near the bottom (ground level).
        for (var i = 0; i < 6; i++) {
          final y = size.height * (0.55 + i * 0.07) +
              math.sin(phase * 3 + i) * 8;
          canvas.drawRect(
              Rect.fromLTWH(0, y, size.width, 30),
              Paint()
                ..color = const Color(0x33A14EB7)
                ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));
        }
        // Drifting decay motes.
        for (var i = 0; i < 36; i++) {
          final x = (rnd.nextDouble() + phase * 0.2) % 1 * size.width;
          final y = size.height * (0.4 + rnd.nextDouble() * 0.6);
          canvas.drawCircle(Offset(x, y), 2 + rnd.nextDouble() * 4,
              Paint()..color = const Color(0x55C46AD8));
        }
      // ===== Wave 2 =====
      case 22: // lava flow — glowing molten blob at the front
        _stormFront(canvas, const Color(0xFFFF6D00), const Color(0xFFFFD180),
            1.4, glow: true);
      case 23: // sandworm — churned-sand mound + dust at the front
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFFB08A4A).withValues(alpha: 0.12));
        _stormFront(canvas, const Color(0xFF8D6E4A), const Color(0xFFD8C088),
            1.0);
      case 24: // gray goo — shimmering metallic nanite swarm
        _stormFront(canvas, const Color(0xFFB0BEC5), const Color(0xFFECEFF1),
            1.6, glow: true);
      case 25: // crawling forest — green creeping mass
        _stormFront(canvas, const Color(0xFF2E7D32), const Color(0xFF7CFFA0),
            1.5);
      case 26: // rolling glitch — magenta render-tear band at the front
        _stormFront(canvas, const Color(0xFFE040FB), const Color(0xFF18FFFF),
            1.4, glitch: true);
      case 27: // aurora bloom — sweeping colour ribbons (benign)
        for (var i = 0; i < 6; i++) {
          final y = size.height * 0.08 + i * 14.0;
          final col = i.isEven
              ? const Color(0x5564FFDA)
              : const Color(0x55B388FF);
          canvas.drawRect(
              Rect.fromLTWH(0, y + math.sin(phase * 12 + i) * 10, size.width, 10),
              Paint()
                ..color = col
                ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
        }
      case 28: // eclipse — deep darkening + a corona ring up top
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFF05060A).withValues(alpha: 0.7));
        final c = Offset(size.width * 0.5, size.height * 0.18);
        canvas.drawCircle(c, 34, Paint()..color = const Color(0xFF0A0A0F));
        canvas.drawCircle(
            c,
            40,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 4
              ..color = const Color(0xFFFFE082)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
      case 29: // gamma-ray burst — searing white-green flash
        final f = (1 - phase).clamp(0.0, 1.0);
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFFCCFFCC).withValues(alpha: f * 0.85));
      case 30: // falling star — a single bright streak (benign)
        final t = phase % 1.0;
        final x = size.width * (0.1 + t * 0.8), y = size.height * (0.1 + t * 0.5);
        canvas.drawLine(
            Offset(x, y),
            Offset(x - 60, y - 40),
            Paint()
              ..strokeWidth = 3
              ..strokeCap = StrokeCap.round
              ..color = Colors.white
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
      case 31: // sky crack — jagged glowing fissures across the sky
        final p = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0xFFB39DDB)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
        for (var i = 0; i < 3; i++) {
          final path = Path()..moveTo(0, size.height * (0.15 + i * 0.12));
          for (var s = 1; s <= 8; s++) {
            path.lineTo(size.width * s / 8,
                size.height * (0.15 + i * 0.12) + (rnd.nextDouble() - 0.5) * 40);
          }
          canvas.drawPath(path, p);
        }
      case 32: // time dilation — pulsing concentric rings
        for (var i = 0; i < 5; i++) {
          final r = ((phase + i / 5) % 1.0) * size.width * 0.6;
          canvas.drawCircle(
              Offset(size.width / 2, size.height / 2),
              r,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 2
                ..color = const Color(0x66B388FF));
        }
      case 33: // spore bloom — drifting green spores
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFF4C6B2A).withValues(alpha: 0.14));
        for (var i = 0; i < 50; i++) {
          final x = (rnd.nextDouble() + phase * 0.2) % 1 * size.width;
          final y = (rnd.nextDouble() + phase * 0.4) % 1 * size.height;
          canvas.drawCircle(Offset(x, y), 1.5 + rnd.nextDouble() * 2,
              Paint()..color = const Color(0x88AEEA00));
        }
      case 34: // crystal growth — glinting sparkles (benign)
        for (var i = 0; i < 40; i++) {
          final x = rnd.nextDouble() * size.width;
          final y = rnd.nextDouble() * size.height;
          final tw = (0.5 + 0.5 * math.sin(phase * 30 + i)).clamp(0.0, 1.0);
          canvas.drawCircle(Offset(x, y), 1.5,
              Paint()..color = const Color(0xFF9CFFD8).withValues(alpha: tw));
        }
      case 35: // bioluminescent tide — soft glowing wash (benign)
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFF18FFFF).withValues(alpha: 0.10));
        for (var i = 0; i < 4; i++) {
          final y = size.height * (0.6 + i * 0.1) + math.sin(phase * 6 + i) * 6;
          canvas.drawRect(Rect.fromLTWH(0, y, size.width, 12),
              Paint()..color = const Color(0x3300E5FF));
        }
      case 36: // chemical rain — green-violet precip
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFF7E57C2).withValues(alpha: 0.14));
        _precip(canvas, size, 200, const Color(0xCCB388FF), 16, vertical: true);
      case 37: // diamond rain — bright sparkling shards (benign-ish)
        final g = Paint()
          ..color = const Color(0xEEE1F5FE)
          ..strokeWidth = 1.4;
        for (var i = 0; i < 140; i++) {
          final bx = rnd.nextDouble() * size.width;
          final t = (phase * 20 + i * 0.11) % 1.0;
          final y = t * size.height, x = bx + t * 40;
          canvas.drawLine(Offset(x, y), Offset(x - 5, y - 10), g);
        }
      case 38: // iron snow — grey metallic flakes
        _precip(canvas, size, 200, const Color(0xCCB0BEC5), 8, vertical: false);
      case 39: // methane downpour — amber hydrocarbon rain
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFF8D6E00).withValues(alpha: 0.12));
        _precip(canvas, size, 220, const Color(0xCCFFCA28), 18, vertical: true);
      case 40: // blood rain — red precip
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFF7A0E0E).withValues(alpha: 0.16));
        _precip(canvas, size, 200, const Color(0xCCEF5350), 16, vertical: true);
      case 41: // black rain — dark fallout streaks
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFF000000).withValues(alpha: 0.3));
        _precip(canvas, size, 220, const Color(0xCC424242), 16, vertical: true);
      // 42-44, 46-48 meta events have no map effect (UI/economy only).
      case 45: // festival — falling multicolour confetti
        const confetti = [
          Color(0xFFFF5252),
          Color(0xFFFFD740),
          Color(0xFF40C4FF),
          Color(0xFF69F0AE),
          Color(0xFFE040FB),
        ];
        for (var i = 0; i < 80; i++) {
          final bx = rnd.nextDouble() * size.width;
          final t = (phase * 4 + i * 0.07) % 1.0;
          final x = bx + math.sin((t + i) * 6) * 12;
          final y = t * size.height;
          final col = confetti[i % confetti.length];
          canvas.save();
          canvas.translate(x, y);
          canvas.rotate((phase * 10 + i) * 2);
          canvas.drawRect(
              const Rect.fromLTWH(-3, -2, 6, 4), Paint()..color = col);
          canvas.restore();
        }
      case 49: // alien beacon — a faint cyan shimmer in the sky (the monolith
        // itself is drawn as a real object on its grid tile, not here).
        final pulse = 0.04 + 0.05 * (0.5 + 0.5 * math.sin(phase * 20));
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0xFF00E5FF).withValues(alpha: pulse));
      case 50: // raining frogs — little green dots falling (benign meme)
        for (var i = 0; i < 40; i++) {
          final bx = rnd.nextDouble() * size.width;
          final t = (phase * 8 + i * 0.1) % 1.0;
          canvas.drawCircle(Offset(bx, t * size.height), 3,
              Paint()..color = const Color(0xFF66BB6A));
        }
    }
    if (layered) canvas.restore();
  }

  /// A moving-front marker (lava/goo/forest/sandworm/glitch) drawn at the storm
  /// epicentre projected from its world cell — a glowing blob the size of a few
  /// tiles so you can see WHERE the hazard is on the map.
  void _stormFront(Canvas canvas, Color core, Color hot, double radiusCells,
      {bool glow = false, bool glitch = false}) {
    if (stormX < 0 || stormY < 0) return;
    final c = cam.project(stormX * cell, stormY * cell, 0.1);
    final r = (cell * cam.scale) * radiusCells;
    if (glitch) {
      // Render-tear band: offset coloured slabs.
      for (var i = -2; i <= 2; i++) {
        final col = i.isEven ? core : hot;
        canvas.drawRect(
            Rect.fromCenter(
                center: c.translate(i * 4.0, 0), width: r * 1.6, height: r * 0.5),
            Paint()..color = col.withValues(alpha: 0.5));
      }
      return;
    }
    if (glow) {
      canvas.drawCircle(
          c,
          r * 1.4,
          Paint()
            ..color = hot.withValues(alpha: 0.4)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14));
    }
    canvas.drawCircle(c, r, Paint()..color = core.withValues(alpha: 0.8));
    canvas.drawCircle(c, r * 0.55, Paint()..color = hot.withValues(alpha: 0.9));
  }

  /// Jagged, glowing lightning bolts striking random tiles. A bolt is a vertical
  /// zig-zag from the sky to a tile centre, drawn with a soft glow underlay + a
  /// bright core, plus a flash on the struck tile. New strikes pick fresh tiles
  /// each ~0.2s of the phase so it reads as an ongoing storm.
  void _drawLightning(Canvas canvas, Size size) {
    if (cells.isEmpty && roads.isEmpty) {
      // No tiles to strike — fall back to a sky flash.
      if ((phase * 13).floor().isEven) {
        canvas.drawRect(Offset.zero & size,
            Paint()..color = const Color(0x22FFFFFF));
      }
      return;
    }
    // A new strike every ~0.18 of the loop; seed from that bucket so the bolt is
    // stable for its brief life then jumps to a new tile.
    final bucket = (phase / 0.18).floor();
    final rnd = math.Random(bucket * 2654435761 & 0x7fffffff);
    final life = (phase / 0.18) - bucket; // 0..1 within this strike
    if (life > 0.5) return; // bolt only visible for the first half (flicker)

    // Pick a target WEIGHTED BY HEIGHT — lightning favours the tallest things
    // (real physics) but can hit ANY tile: open ground + roads get a small
    // baseline chance, buildings scale with their height. So it strikes the
    // landscape, not only the buildings.
    final n = grid * grid;
    final targets = <int>[];
    final weights = <double>[];
    for (var k = 0; k < n; k++) {
      final b = cells[k];
      if (b != null) {
        targets.add(k);
        weights.add(2.0 + heightOf(b) * 1.5); // taller -> much likelier
      } else {
        targets.add(k);
        weights.add(roads.contains(k) ? 0.25 : 0.4); // bare ground / road
      }
    }
    if (targets.isEmpty) return;
    final total = weights.fold(0.0, (a, w) => a + w);
    var pick = rnd.nextDouble() * total;
    var target = targets.first;
    for (var i = 0; i < targets.length; i++) {
      pick -= weights[i];
      if (pick <= 0) {
        target = targets[i];
        break;
      }
    }
    // Strike the TOP of whatever's there (roof height), not the ground.
    final hitZ = (cells[target] != null ? heightOf(cells[target]!) : 0.2) + 0.5;
    final tx = (target % grid + 0.5) * cell, ty = (target ~/ grid + 0.5) * cell;
    final strike = cam.project(tx, ty, hitZ);
    // Build a jagged path from high above the tile down to it.
    final topZ = math.max(60.0, hitZ + 50);
    final top = cam.project(tx, ty, topZ);
    final path = Path()..moveTo(top.dx, top.dy);
    const segs = 7;
    for (var i = 1; i <= segs; i++) {
      final f = i / segs;
      final z = topZ + (hitZ - topZ) * f; // top -> roof
      final jitter = (rnd.nextDouble() - 0.5) * cell * 1.2 * (1 - f);
      final pt = cam.project(tx + jitter, ty, z);
      path.lineTo(pt.dx, pt.dy);
    }
    path.lineTo(strike.dx, strike.dy);
    final alpha = (1 - life * 2).clamp(0.0, 1.0);
    // Glow underlay.
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 7
          ..strokeCap = StrokeCap.round
          ..color = const Color(0xFF9FB8FF).withValues(alpha: alpha * 0.5)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    // Bright core.
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2
          ..strokeCap = StrokeCap.round
          ..color = Colors.white.withValues(alpha: alpha));
    // Impact flash on the struck tile.
    canvas.drawCircle(
        strike,
        (cell * cam.scale) * 0.5,
        Paint()
          ..color = const Color(0xFFE8F0FF).withValues(alpha: alpha * 0.7)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
  }

  void _precip(Canvas canvas, Size size, int n, Color color, double speed,
      {required bool vertical}) {
    final rnd = math.Random(3);
    final p = Paint()
      ..color = color
      ..strokeWidth = vertical ? 1.2 : 1.0;
    for (var i = 0; i < n; i++) {
      final bx = rnd.nextDouble() * size.width;
      final t = (phase * speed + i * 0.137) % 1.0;
      final y = t * size.height;
      final x = vertical ? bx : bx + (t * 40);
      if (vertical) {
        canvas.drawLine(Offset(x, y), Offset(x - 1, y + 10), p);
      } else {
        canvas.drawCircle(Offset(x, y), 1.6, p);
      }
    }
  }

  /// Tornado/hurricane funnel anchored at the moving storm epicentre (projected
  /// from its world cell), so the disk-stack actually travels over the terrain.
  /// [wide] draws a broader, slower hurricane spiral; otherwise a tight funnel.
  void _drawTornado(Canvas canvas, Size size, {bool wide = false}) {
    canvas.drawRect(Offset.zero & size,
        Paint()..color = const Color(0xFF3A3A40).withValues(alpha: 0.28));
    // Ground point the funnel touches down on (storm cell -> screen).
    final hasPos = stormX >= 0 && stormY >= 0;
    final ground = hasPos
        ? cam.project((stormX) * cell, (stormY) * cell, 0)
        : Offset(size.width / 2, size.height * 0.7);
    final tiles = (cell * cam.scale); // px per cell, for sizing
    final n = wide ? 12 : 10;
    for (var i = 0; i < n; i++) {
      final fy = i / n; // 0 = base (ground), 1 = top
      final baseW = (wide ? 0.9 : 0.35) * tiles;
      final w = baseW * (0.25 + fy);
      final sway = math.sin((phase * 6 + i) * 2) * tiles * 0.25;
      final cx = ground.dx + sway * (1 - fy);
      final cy = ground.dy - fy * tiles * (wide ? 5 : 4);
      canvas.drawOval(
          Rect.fromCenter(center: Offset(cx, cy), width: w, height: w * 0.45),
          Paint()
            ..color = Color.lerp(const Color(0xDD8A8A92),
                const Color(0x668A8A92), fy)!);
    }
    // Debris ring scuffing the ground at the touchdown point.
    canvas.drawCircle(
        ground,
        tiles * (wide ? 1.1 : 0.5),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = const Color(0x88BCAAA4));
  }

  void _drawZoneTile(Canvas canvas, int gx, int gy, Color tint) {
    // Drape the tint over the terrain (corner elevations).
    final p00 = cam.project(gx * cell, gy * cell, 0.04 + _cornerZ(gx, gy));
    final p10 = cam.project((gx + 1) * cell, gy * cell, 0.04 + _cornerZ(gx + 1, gy));
    final p11 = cam.project((gx + 1) * cell, (gy + 1) * cell, 0.04 + _cornerZ(gx + 1, gy + 1));
    final p01 = cam.project(gx * cell, (gy + 1) * cell, 0.04 + _cornerZ(gx, gy + 1));
    final path = Path()
      ..moveTo(p00.dx, p00.dy)
      ..lineTo(p10.dx, p10.dy)
      ..lineTo(p11.dx, p11.dy)
      ..lineTo(p01.dx, p01.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = tint.withValues(alpha: 0.28));
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = tint.withValues(alpha: 0.7));
  }

  /// Is there another ROAD (or the hub) in cell [k] that this road tile should
  /// link an arm to? Buildings are NOT road neighbours — they connect via a
  /// separate driveway, so a road never merges straight into a building.
  bool _roadNeighbour(int k) {
    if (k < 0) return false;
    return roads.contains(k) || hubs.contains(k);
  }

  int? _nbr(int gx, int gy, int dx, int dy) {
    final nx = gx + dx, ny = gy + dy;
    if (nx < 0 || ny < 0 || nx >= grid || ny >= grid) return null;
    return ny * grid + nx;
  }

  /// Draw a road tile shaped by its connections: a central pad plus a paved arm
  /// toward each connected neighbour, with a dashed centre-line down each arm
  /// (so straights, corners, T-junctions and crossroads all read correctly and
  /// the lane markings face the right way). A lone road tile is a small pad.
  void _drawRoadTile(Canvas canvas, int gx, int gy) {
    final n = _roadNeighbour(_nbr(gx, gy, 0, -1) ?? -1);
    final s = _roadNeighbour(_nbr(gx, gy, 0, 1) ?? -1);
    final e = _roadNeighbour(_nbr(gx, gy, 1, 0) ?? -1);
    final w = _roadNeighbour(_nbr(gx, gy, -1, 0) ?? -1);

    // Stations / cloud decks have no open roads — they get TRANSPORT TUBES. So
    // do surface roads laid while the air was hostile (captured as sealed).
    if (colonyMode != 0 || roadSealed.contains(gy * grid + gx)) {
      _drawTransitTube(canvas, gx, gy, n, s, e, w);
      return;
    }

    const half = 0.30; // half road width as a fraction of the cell
    final x = gx.toDouble(), y = gy.toDouble();
    final rz = 0.05 + _z(gx, gy); // road sits on the terrain
    final road = Paint()..color = const Color(0xFF3A3F46);
    final lane = Paint()
      ..color = const Color(0xFFFFD23F).withValues(alpha: 0.55)
      ..strokeWidth = 1;

    // Central junction pad.
    _fillRect(canvas, x + 0.5 - half, y + 0.5 - half, x + 0.5 + half,
        y + 0.5 + half, rz, road);

    // Arms toward each connected side + a lane dash along each arm.
    if (n) {
      _fillRect(canvas, x + 0.5 - half, y, x + 0.5 + half, y + 0.5, rz, road);
      _dash(canvas, x + 0.5, y + 0.08, x + 0.5, y + 0.42, lane, rz);
    }
    if (s) {
      _fillRect(canvas, x + 0.5 - half, y + 0.5, x + 0.5 + half, y + 1, rz, road);
      _dash(canvas, x + 0.5, y + 0.58, x + 0.5, y + 0.92, lane, rz);
    }
    if (e) {
      _fillRect(canvas, x + 0.5, y + 0.5 - half, x + 1, y + 0.5 + half, rz, road);
      _dash(canvas, x + 0.58, y + 0.5, x + 0.92, y + 0.5, lane, rz);
    }
    if (w) {
      _fillRect(canvas, x, y + 0.5 - half, x + 0.5, y + 0.5 + half, rz, road);
      _dash(canvas, x + 0.08, y + 0.5, x + 0.42, y + 0.5, lane, rz);
    }
    // Lone tile: nothing connects — leave just the pad (a small lot).
  }

  /// A pressurised TRANSPORT TUBE segment on a station / cloud deck — the
  /// orbital/floating equivalent of a road. Raised glassy tube: a glowing core
  /// line down each connected arm + a node hub, lifted above the deck so it
  /// reads as a skyway, not paint on the floor.
  void _drawTransitTube(
      Canvas canvas, int gx, int gy, bool n, bool s, bool e, bool w) {
    final x = gx.toDouble(), y = gy.toDouble();
    // On a station the tube floats above the flat deck; on a sealed SURFACE road
    // it rides just above the terrain tile so it follows the ground.
    final deck = colonyMode == 0 ? _z(gx, gy) : 0.0;
    final tz = deck + (colonyMode == 0 ? 0.4 : 1.6);
    final orbital = colonyMode == 2;
    final shell = (orbital ? const Color(0xFF8FB4FF) : const Color(0xFFB8E0FF))
        .withValues(alpha: 0.35);
    final core = orbital ? const Color(0xFF9AD0FF) : const Color(0xFFE6F6FF);
    final tubeW = (cell * cam.scale) * 0.18;
    final shellPaint = Paint()
      ..color = shell
      ..strokeWidth = tubeW
      ..strokeCap = StrokeCap.round;
    final corePaint = Paint()
      ..color = core
      ..strokeWidth = tubeW * 0.4
      ..strokeCap = StrokeCap.round;
    void seg(double x0, double y0, double x1, double y1) {
      final a = cam.project(x0 * cell, y0 * cell, tz);
      final b = cam.project(x1 * cell, y1 * cell, tz);
      canvas.drawLine(a, b, shellPaint);
      canvas.drawLine(a, b, corePaint);
    }

    final cx = x + 0.5, cy = y + 0.5;
    if (n) seg(cx, cy, cx, y);
    if (s) seg(cx, cy, cx, y + 1);
    if (e) seg(cx, cy, x + 1, cy);
    if (w) seg(cx, cy, x, cy);
    // Node hub at the junction (support pylon down to the deck + a glow ring).
    final node = cam.project(cx * cell, cy * cell, tz);
    canvas.drawLine(node, cam.project(cx * cell, cy * cell, deck),
        shellPaint..strokeWidth = tubeW * 0.5);
    canvas.drawCircle(node, tubeW * 0.6, Paint()..color = shell);
    canvas.drawCircle(node, tubeW * 0.28, Paint()..color = core);
  }

  /// A driveway: a short, plain grey strip from a building cell to the road tile
  /// it touches (orthogonal or diagonal). No lane lines — it's a private apron,
  /// not part of the road grid. Points at the FIRST adjacent road found, so a
  /// building hugging a road corner gets a little diagonal driveway.
  void _drawDriveway(Canvas canvas, int gx, int gy) {
    // Search orthogonals first (cleaner straight driveways), then diagonals.
    const dirs = [
      [0, -1], [0, 1], [1, 0], [-1, 0], // N S E W
      [1, -1], [1, 1], [-1, 1], [-1, -1], // diagonals
    ];
    int? rx, ry;
    for (final d in dirs) {
      final nx = gx + d[0], ny = gy + d[1];
      if (nx < 0 || nx >= grid || ny < 0 || ny >= grid) continue;
      if (roads.contains(ny * grid + nx) || hubs.contains(ny * grid + nx)) {
        rx = nx;
        ry = ny;
        break;
      }
    }
    if (rx == null || ry == null) return;
    // Run the driveway all the way from the building cell centre INTO the road
    // tile's centre, so it visibly bridges the gap (was stopping at the shared
    // edge, leaving a stub that didn't reach the road).
    final bx = gx + 0.5, by = gy + 0.5;
    final tx = rx + 0.5, ty = ry + 0.5;
    final a = cam.project(bx * cell, by * cell, 0.05 + _z(gx, gy));
    final b = cam.project(tx * cell, ty * cell, 0.05 + _z(rx, ry));
    canvas.drawLine(
        a,
        b,
        Paint()
          ..color = const Color(0xFF4A4F57)
          ..strokeWidth = (cell * cam.scale) * 0.16
          ..strokeCap = StrokeCap.round);
  }

  /// Fill a ground-plane rectangle (cell-fraction coords) at height [z].
  void _fillRect(Canvas canvas, double x0, double y0, double x1, double y1,
      double z, Paint paint) {
    final a = cam.project(x0 * cell, y0 * cell, z);
    final b = cam.project(x1 * cell, y0 * cell, z);
    final c = cam.project(x1 * cell, y1 * cell, z);
    final d = cam.project(x0 * cell, y1 * cell, z);
    canvas.drawPath(
        Path()
          ..moveTo(a.dx, a.dy)
          ..lineTo(b.dx, b.dy)
          ..lineTo(c.dx, c.dy)
          ..lineTo(d.dx, d.dy)
          ..close(),
        paint);
  }

  void _dash(Canvas canvas, double x0, double y0, double x1, double y1, Paint p,
      [double z = 0.06]) {
    final a = cam.project(x0 * cell, y0 * cell, z + 0.01);
    final b = cam.project(x1 * cell, y1 * cell, z + 0.01);
    canvas.drawLine(a, b, p);
  }

  /// Commuter dots flowing through a road tile. A dot traverses the WHOLE cell
  /// along each axis the road runs on (edge → edge), so when it leaves this tile
  /// it enters the neighbour at the exact same world position — a seamless,
  /// continuous stream with no jump at the arm end (the previous bug). The phase
  /// is offset by the integer tile coordinate so adjacent tiles' dots line up
  /// into one moving chain.
  void _drawCommuters(Canvas canvas, int gx, int gy) {
    // Per-tile load: a road that nobody routes over (a road to nowhere) carries
    // no dots; busy arteries near the hub get the full lane count. Skip tiles
    // with negligible load entirely.
    final load = trafficAt(gy * grid + gx);
    if (load <= 0.02) return;
    final x = gx.toDouble(), y = gy.toDouble();
    final n = _roadNeighbour(_nbr(gx, gy, 0, -1) ?? -1);
    final s = _roadNeighbour(_nbr(gx, gy, 0, 1) ?? -1);
    final e = _roadNeighbour(_nbr(gx, gy, 1, 0) ?? -1);
    final w = _roadNeighbour(_nbr(gx, gy, -1, 0) ?? -1);
    // Dot count scales with THIS tile's load, not the global average.
    final perAxis = (1 + (load * 3)).round().clamp(1, 4);
    // Congested arteries tint amber-red; quiet streets stay calm blue.
    final dot = Paint()
      ..color = Color.lerp(
          const Color(0xFFB3E5FC), const Color(0xFFFF7043), load * load)!;
    final r = (cell * cam.scale) * 0.035;

    // Horizontal flow (cell spans gx..gx+1) when the road runs E-W.
    if (e || w) {
      for (var i = 0; i < perAxis; i++) {
        // World-position phase: gx is the integer base, so dots chain across
        // tiles. Lane offset +0.12 below centre = one travel direction.
        final t = (phase + i / perAxis - gx) % 1.0;
        final p = cam.project((x + t) * cell, (y + 0.5 + 0.12) * cell, 0.08);
        canvas.drawCircle(p, r, dot);
        // Opposing lane above centre, flowing the other way.
        final t2 = (-phase + i / perAxis - gx) % 1.0;
        final p2 = cam.project((x + t2) * cell, (y + 0.5 - 0.12) * cell, 0.08);
        canvas.drawCircle(p2, r, dot);
      }
    }
    // Vertical flow (cell spans gy..gy+1) when the road runs N-S.
    if (n || s) {
      for (var i = 0; i < perAxis; i++) {
        final t = (phase + i / perAxis - gy) % 1.0;
        final p = cam.project((x + 0.5 + 0.12) * cell, (y + t) * cell, 0.08);
        canvas.drawCircle(p, r, dot);
        final t2 = (-phase + i / perAxis - gy) % 1.0;
        final p2 = cam.project((x + 0.5 - 0.12) * cell, (y + t2) * cell, 0.08);
        canvas.drawCircle(p2, r, dot);
      }
    }

    // Pedestrians on the sidewalks: smaller, paler, near the road EDGE (offset
    // 0.26 vs the 0.12 traffic lanes), moving at ~0.4x the vehicle phase. People
    // walk the network too, so foot traffic scales with the tile's load.
    final peds = (load * 2).round().clamp(0, 2);
    if (peds > 0) {
      final foot = Paint()..color = const Color(0xFFCFD8DC);
      final pr = r * 0.7;
      final pphase = (phase * 0.4) % 1.0;
      if (e || w) {
        for (var i = 0; i < peds; i++) {
          final t = (pphase + i / peds - gx) % 1.0;
          canvas.drawCircle(
              cam.project((x + t) * cell, (y + 0.5 + 0.26) * cell, 0.08), pr, foot);
          final t2 = (-pphase + i / peds - gx) % 1.0;
          canvas.drawCircle(
              cam.project((x + t2) * cell, (y + 0.5 - 0.26) * cell, 0.08), pr, foot);
        }
      }
      if (n || s) {
        for (var i = 0; i < peds; i++) {
          final t = (pphase + i / peds - gy) % 1.0;
          canvas.drawCircle(
              cam.project((x + 0.5 + 0.26) * cell, (y + t) * cell, 0.08), pr, foot);
          final t2 = (-pphase + i / peds - gy) % 1.0;
          canvas.drawCircle(
              cam.project((x + 0.5 - 0.26) * cell, (y + t2) * cell, 0.08), pr, foot);
        }
      }
    }
  }

  /// Stationary corpses on a road tile. Count scales with [corpseDensity];
  /// positions are deterministic (hashed from the tile coord) so they don't
  /// flicker frame to frame. Dark, motionless — clearly NOT traffic.
  void _drawCorpses(Canvas canvas, int gx, int gy) {
    final count = (corpseDensity * 6).round().clamp(0, 6);
    if (count == 0) return;
    final body = Paint()..color = const Color(0xFF4A3B32);
    final r = (cell * cam.scale) * 0.04;
    var seed = (gx * 73856093) ^ (gy * 19349663);
    for (var i = 0; i < count; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final fx = 0.2 + (seed % 1000) / 1000 * 0.6;
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final fy = 0.2 + (seed % 1000) / 1000 * 0.6;
      final p = cam.project((gx + fx) * cell, (gy + fy) * cell, 0.07 + _z(gx, gy));
      canvas.drawCircle(p, r, body);
    }
  }

  /// Rubble pile: a small flat debris slab plus scattered grey chunks, marking
  /// where a disaster flattened a building. Deterministic from the tile coord.
  void _drawRubble(Canvas canvas, int gx, int gy) {
    final tz = _z(gx, gy);
    _fillRect(canvas, gx + 0.12, gy + 0.12, gx + 0.88, gy + 0.88, 0.04 + tz,
        Paint()..color = const Color(0xFF3B3531));
    final chunk = Paint()..color = const Color(0xFF6B635B);
    final r = (cell * cam.scale) * 0.05;
    var seed = (gx * 40503) ^ (gy * 12289) ^ 0x5bd1;
    for (var i = 0; i < 6; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final fx = 0.2 + (seed % 1000) / 1000 * 0.6;
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final fy = 0.2 + (seed % 1000) / 1000 * 0.6;
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final z = 0.06 + tz + (seed % 100) / 100 * 1.4;
      canvas.drawCircle(
          cam.project((gx + fx) * cell, (gy + fy) * cell, z), r, chunk);
    }
  }

  /// Overgrowth tile: a cluster of upright teal-green shards (crystal / spore /
  /// vine cover). Deterministic per tile so it doesn't shimmer.
  void _drawCrystal(Canvas canvas, int gx, int gy) {
    final tz = _z(gx, gy);
    _fillRect(canvas, gx + 0.08, gy + 0.08, gx + 0.92, gy + 0.92, 0.05 + tz,
        Paint()..color = const Color(0x66163A2E));
    var seed = (gx * 49157) ^ (gy * 98317) ^ 0x2c7;
    for (var i = 0; i < 5; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final fx = 0.2 + (seed % 1000) / 1000 * 0.6;
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final fy = 0.2 + (seed % 1000) / 1000 * 0.6;
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final hgt = 1.2 + (seed % 100) / 100 * 2.5;
      final base = cam.project((gx + fx) * cell, (gy + fy) * cell, 0.05 + tz);
      final tip = cam.project((gx + fx) * cell, (gy + fy) * cell, hgt + tz);
      canvas.drawLine(
          base,
          tip,
          Paint()
            ..strokeWidth = (cell * cam.scale) * 0.05
            ..strokeCap = StrokeCap.round
            ..color = const Color(0xCC3DD6A0));
      canvas.drawCircle(tip, (cell * cam.scale) * 0.03,
          Paint()..color = const Color(0xFF9CFFD8));
    }
  }

  /// Litter on a road tile: black garbage circles + dark-green sewage disks,
  /// counts scaling with the backlogs. Deterministic per tile (no flicker), drawn
  /// the same way as corpses.
  void _drawWaste(Canvas canvas, int gx, int gy) {
    final r = (cell * cam.scale) * 0.045;
    final tz = _z(gx, gy);
    var seed = (gx * 2246822519) ^ (gy * 3266489917) ^ 0xabc;
    final gN = (garbageDensity * 5).round().clamp(0, 5);
    final sN = (sewageDensity * 5).round().clamp(0, 5);
    final garbage = Paint()..color = const Color(0xFF15140F); // near-black bags
    final sewage = Paint()..color = const Color(0xFF26402A); // dark green pools
    for (var i = 0; i < gN; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final fx = 0.15 + (seed % 1000) / 1000 * 0.7;
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final fy = 0.15 + (seed % 1000) / 1000 * 0.7;
      canvas.drawCircle(
          cam.project((gx + fx) * cell, (gy + fy) * cell, 0.07 + tz), r, garbage);
    }
    for (var i = 0; i < sN; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final fx = 0.15 + (seed % 1000) / 1000 * 0.7;
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final fy = 0.15 + (seed % 1000) / 1000 * 0.7;
      // Flatter, wider disk for a pool.
      final c = cam.project((gx + fx) * cell, (gy + fy) * cell, 0.05 + tz);
      canvas.drawOval(
          Rect.fromCenter(center: c, width: r * 3.2, height: r * 1.6), sewage);
    }
  }

  /// Terrain elevation (metres) at a tile, 0 if flat / unknown.
  double _z(int gx, int gy) {
    if (gx < 0 || gy < 0 || gx >= grid || gy >= grid) return 0;
    return elevation[gy * grid + gx] ?? 0;
  }

  /// Corner height = average of the up-to-4 tiles meeting at a grid vertex, so
  /// the surface is continuous (no per-tile cliffs).
  double _cornerZ(int vx, int vy) {
    var sum = 0.0, n = 0;
    for (final d in const [[-1, -1], [0, -1], [-1, 0], [0, 0]]) {
      final gx = vx + d[0], gy = vy + d[1];
      if (gx >= 0 && gy >= 0 && gx < grid && gy < grid) {
        sum += elevation[gy * grid + gx] ?? 0;
        n++;
      }
    }
    return n > 0 ? sum / n : 0;
  }

  /// Station / cloud-deck floor: an open structural GRID (truss) instead of a
  /// solid deck, so it reads as a built platform floating in space / cloud, not
  /// ground. Translucent panels in each cell with bright truss lines between
  /// them; orbital (colonyMode 2) is cooler/darker steel, floating (1) lighter.
  void _drawStationGrid(Canvas canvas) {
    final orbital = colonyMode == 2;
    final panel = orbital ? const Color(0x551A222C) : const Color(0x443A4658);
    final truss = orbital ? const Color(0xAA5B6B7E) : const Color(0xAA7E94AD);
    Offset p(int vx, int vy) =>
        cam.project(vx * cell.toDouble(), vy * cell.toDouble(), 0);
    // Filled panels per cell (depth doesn't matter — all coplanar at z=0).
    for (var gy = 0; gy < grid; gy++) {
      for (var gx = 0; gx < grid; gx++) {
        final a = p(gx, gy), b = p(gx + 1, gy);
        final c = p(gx + 1, gy + 1), d = p(gx, gy + 1);
        canvas.drawPath(
            Path()
              ..moveTo(a.dx, a.dy)
              ..lineTo(b.dx, b.dy)
              ..lineTo(c.dx, c.dy)
              ..lineTo(d.dx, d.dy)
              ..close(),
            Paint()..color = panel);
      }
    }
    // Truss lines along every grid line.
    final line = Paint()
      ..color = truss
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    for (var v = 0; v <= grid; v++) {
      canvas.drawLine(p(0, v), p(grid, v), line); // rows
      canvas.drawLine(p(v, 0), p(v, grid), line); // cols
    }
  }

  /// Draw the ground as a non-flat heightmap (rolling terrain), depth-sorted
  /// back-to-front, each tile shaded by its height + sloped, with liquid tiles
  /// (below sea/lava level) rendered as the surface ocean/lava.
  void _drawTerrain(Canvas canvas) {
    if (colonyMode != 0) {
      _drawStationGrid(canvas);
      return;
    }
    // Order tiles far -> near.
    final order = <int>[for (var k = 0; k < grid * grid; k++) k]
      ..sort((a, b) => cam
          .depth((b % grid + 0.5) * cell, (b ~/ grid + 0.5) * cell, 0)
          .compareTo(cam.depth(
              (a % grid + 0.5) * cell, (a ~/ grid + 0.5) * cell, 0)));
    final water = Color(liquidColor);
    for (final k in order) {
      final gx = k % grid, gy = k ~/ grid;
      final z00 = _cornerZ(gx, gy), z10 = _cornerZ(gx + 1, gy);
      final z11 = _cornerZ(gx + 1, gy + 1), z01 = _cornerZ(gx, gy + 1);
      final p00 = cam.project(gx * cell, gy * cell, z00);
      final p10 = cam.project((gx + 1) * cell, gy * cell, z10);
      final p11 = cam.project((gx + 1) * cell, (gy + 1) * cell, z11);
      final p01 = cam.project(gx * cell, (gy + 1) * cell, z01);
      final path = Path()
        ..moveTo(p00.dx, p00.dy)
        ..lineTo(p10.dx, p10.dy)
        ..lineTo(p11.dx, p11.dy)
        ..lineTo(p01.dx, p01.dy)
        ..close();
      Color col;
      if (liquidTiles.contains(k)) {
        col = water; // ocean / lava surface
        if (liquidMolten) {
          // Lava shimmer.
          col = Color.lerp(water, const Color(0xFFFFB300),
              0.3 + 0.3 * math.sin(phase * 12 + gx + gy))!;
        }
      } else {
        // Land: shade by height (higher = lighter) for relief.
        final avg = (z00 + z10 + z11 + z01) / 4;
        col = _scale(groundTint, (0.8 + avg / 120).clamp(0.7, 1.25));
        // Beach: a sandy band on land that borders the water (coastlines).
        if (liquidTiles.isNotEmpty && !liquidMolten) {
          var shore = false;
          for (final d in const [[0, -1], [0, 1], [1, 0], [-1, 0]]) {
            final nx = gx + d[0], ny = gy + d[1];
            if (nx >= 0 && ny >= 0 && nx < grid && ny < grid &&
                liquidTiles.contains(ny * grid + nx)) {
              shore = true;
              break;
            }
          }
          if (shore) col = Color.lerp(col, const Color(0xFFD9C48A), 0.6)!;
        }
      }
      canvas.drawPath(path, Paint()..color = col);
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.6
            ..color = const Color(0x331F3327));
    }
  }

  /// Full-canvas backdrop for non-surface colonies: a drifting cloud sea for a
  /// floating colony, a deep starfield for an orbital station.
  void _drawColonyBackdrop(Canvas canvas, Size size) {
    final rnd = math.Random(99);
    if (colonyMode == 2) {
      // Orbital — black space + stars.
      canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF02030A));
      final star = Paint()..color = Colors.white;
      for (var i = 0; i < 140; i++) {
        final x = rnd.nextDouble() * size.width;
        final y = rnd.nextDouble() * size.height;
        final tw = (0.4 + 0.6 * math.sin(phase * 10 + i)).clamp(0.0, 1.0);
        canvas.drawCircle(Offset(x, y), rnd.nextDouble() * 1.2 + 0.3,
            star..color = Colors.white.withValues(alpha: 0.4 + tw * 0.6));
      }
    } else {
      // Floating — a sky/cloud gradient + drifting cloud bands below the deck.
      canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF6A8CB5), Color(0xFFC9B79A)],
          ).createShader(Offset.zero & size),
      );
      for (var i = 0; i < 8; i++) {
        final y = size.height * (0.45 + i * 0.07);
        final off = (phase * 0.3 + i * 0.2) % 1.0 * size.width;
        canvas.drawOval(
            Rect.fromLTWH(-200 + off, y, 260, 40),
            Paint()
              ..color = const Color(0x88FFFFFF)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14));
      }
    }
  }

  /// A structural-support tile: a metallic grid platform/truss the colony builds
  /// on (orbital = bright truss, floating = warm lift-frame, water = grey pontoon
  /// platform). Drawn as a cross-hatched panel raised slightly off the ground.
  void _drawSupport(Canvas canvas, int gx, int gy) {
    final col = switch (colonyMode) {
      2 => const Color(0xFF90CAF9), // orbital truss — cool steel-blue
      1 => const Color(0xFFB0A080), // floating lift-frame — warm alloy
      _ => const Color(0xFF7A8590), // platform/pontoon — grey
    };
    final z = 0.08 + _z(gx, gy);
    _fillRect(canvas, gx + 0.04, gy + 0.04, gx + 0.96, gy + 0.96, z,
        Paint()..color = _scale(col, 0.45));
    // Cross-hatch struts.
    final strut = Paint()
      ..color = col
      ..strokeWidth = 1.2;
    for (final f in [0.2, 0.5, 0.8]) {
      canvas.drawLine(cam.project((gx + f) * cell, (gy + 0.06) * cell, z),
          cam.project((gx + f) * cell, (gy + 0.94) * cell, z), strut);
      canvas.drawLine(cam.project((gx + 0.06) * cell, (gy + f) * cell, z),
          cam.project((gx + 0.94) * cell, (gy + f) * cell, z), strut);
    }
    _strokeRect(canvas, gx + 0.04, gy + 0.04, gx + 0.96, gy + 0.96, z, col, 1.5);
  }

  /// Natural ground cover for a tile, by kind index (matches _Scatter.index).
  /// Deterministic placement within the tile so it doesn't shimmer.
  void _drawScatter(Canvas canvas, int gx, int gy, int kind) {
    final s = (cell * cam.scale);
    // Scatter FOLLOWS the terrain: every item sits at the tile's elevation.
    final tz = _z(gx, gy);
    Offset pj(double fx, double fy, double z) =>
        cam.project(fx * cell, fy * cell, z + tz);
    var seed = (gx * 1900813) ^ (gy * 2606467) ^ (kind * 40503);
    double rndf() {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      return (seed % 1000) / 1000.0;
    }

    final n = (kind == 3 || kind == 8) ? 3 : (kind == 6 || kind == 9 ? 1 : 2);
    for (var i = 0; i < n; i++) {
      final fx = gx + 0.25 + rndf() * 0.5, fy = gy + 0.25 + rndf() * 0.5;
      final base = pj(fx, fy, 0.05);
      switch (kind) {
        case 0: // tree — brown trunk + green round canopy
        case 1: // conifer — brown trunk + green triangle
          final topZ = 2.2 + rndf() * 1.5;
          final top = pj(fx, fy, topZ);
          canvas.drawLine(base, top,
              Paint()..color = const Color(0xFF5D4037)..strokeWidth = s * 0.03);
          if (kind == 0) {
            canvas.drawCircle(top, s * 0.09, Paint()..color = const Color(0xFF2E7D32));
          } else {
            final cz = pj(fx, fy, topZ * 0.55);
            canvas.drawPath(
                Path()
                  ..moveTo(top.dx, top.dy)
                  ..lineTo(cz.dx - s * 0.08, cz.dy)
                  ..lineTo(cz.dx + s * 0.08, cz.dy)
                  ..close(),
                Paint()..color = const Color(0xFF2E5D34));
          }
        case 2: // bush — small green blob
          canvas.drawCircle(pj(fx, fy, 0.6), s * 0.06,
              Paint()..color = const Color(0xFF558B2F));
        case 3: // grass — short green tufts
          canvas.drawLine(base, pj(fx, fy, 0.6),
              Paint()..color = const Color(0xFF7CB342)..strokeWidth = s * 0.02);
        case 4: // cactus — green vertical with arms
          canvas.drawLine(base, pj(fx, fy, 1.8 + rndf()),
              Paint()..color = const Color(0xFF388E3C)..strokeWidth = s * 0.05);
        case 5: // rock — small grey lump
          canvas.drawCircle(base, s * 0.05, Paint()..color = const Color(0xFF757575));
        case 6: // boulder — bigger grey lump
          canvas.drawCircle(base, s * 0.1, Paint()..color = const Color(0xFF616161));
        case 7: // ice shard — pale blue spike
          canvas.drawLine(base, pj(fx, fy, 1.4 + rndf()),
              Paint()..color = const Color(0xFFB3E5FC)..strokeWidth = s * 0.04..strokeCap = StrokeCap.round);
        case 8: // fungus — small purple cap
          canvas.drawCircle(pj(fx, fy, 0.4), s * 0.045,
              Paint()..color = const Color(0xFF8E24AA));
        case 9: // crystal spire — tall glowing teal
          final top = pj(fx, fy, 3.0 + rndf() * 2);
          canvas.drawLine(base, top,
              Paint()..color = const Color(0xFF26C6DA)..strokeWidth = s * 0.05..strokeCap = StrokeCap.round);
          canvas.drawCircle(top, s * 0.02, Paint()..color = const Color(0xFFB2FFFF));
        case 10: // crater — a shallow ring depression in the regolith
          final r = s * (0.07 + rndf() * 0.06);
          canvas.drawCircle(base, r, Paint()..color = const Color(0xFF4A4A4A));
          canvas.drawCircle(
              base,
              r,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = s * 0.02
                ..color = const Color(0xFF8A8A8A));
      }
    }
  }

  void _drawTransitStop(Canvas canvas, int gx, int gy) {
    final tz = _z(gx, gy);
    final c = cam.project((gx + 0.5) * cell, (gy + 0.5) * cell, 0.4 + tz);
    final r = (cell * cam.scale) * 0.14;
    canvas.drawCircle(c, r, Paint()..color = const Color(0xFF7C4DFF));
    canvas.drawCircle(
        c,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Colors.white);
    // A little "M" mast.
    final top = cam.project((gx + 0.5) * cell, (gy + 0.5) * cell, 4.0 + tz);
    canvas.drawLine(c, top,
        Paint()..color = const Color(0xFF7C4DFF)..strokeWidth = 1.5);
  }

  void _drawHubPad(Canvas canvas, int gx, int gy) {
    final z = 0.06 + _z(gx, gy);
    final p00 = cam.project(gx * cell, gy * cell, z);
    final p10 = cam.project((gx + 1) * cell, gy * cell, z);
    final p11 = cam.project((gx + 1) * cell, (gy + 1) * cell, z);
    final p01 = cam.project(gx * cell, (gy + 1) * cell, z);
    final path = Path()
      ..moveTo(p00.dx, p00.dy)
      ..lineTo(p10.dx, p10.dy)
      ..lineTo(p11.dx, p11.dy)
      ..lineTo(p01.dx, p01.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFF2A4A66));
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = const Color(0xFF4FC3F7));
    // The lander cone + flag are tall, so they're drawn in the depth-sorted
    // building pass (not here) to avoid z-order/clipping against nearby boxes.
  }

  /// The alien-beacon monolith: a tall, narrow black slab standing on its tile,
  /// with a slow cyan glow pulse — a real object on the grid (not a screen
  /// overlay). Drawn as a thin depth-sorted box.
  void _drawMonolith(Canvas canvas, int gx, int gy) {
    const inset = 0.34; // narrow footprint
    const hgt = 16.0;
    final x0 = gx + inset, x1 = gx + 1 - inset;
    final y0 = gy + inset, y1 = gy + 1 - inset;
    final pulse = 0.4 + 0.4 * (0.5 + 0.5 * math.sin(phase * 20));
    final tz = _z(gx, gy);
    // Ground glow halo.
    canvas.drawCircle(
        cam.project((gx + 0.5) * cell, (gy + 0.5) * cell, tz + 0.1),
        (cell * cam.scale) * 0.4,
        Paint()
          ..color = const Color(0xFF00E5FF).withValues(alpha: pulse * 0.5)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10));
    // The slab — reuse the box renderer's corner projection inline.
    Offset p(double x, double y, double z) =>
        cam.project(x * cell, y * cell, z + tz);
    final faces = <(List<Offset>, double)>[
      ([p(x0, y0, 0), p(x1, y0, 0), p(x1, y0, hgt), p(x0, y0, hgt)], 0.5),
      ([p(x1, y0, 0), p(x1, y1, 0), p(x1, y1, hgt), p(x1, y0, hgt)], 0.7),
      ([p(x0, y0, 0), p(x0, y1, 0), p(x0, y1, hgt), p(x0, y0, hgt)], 0.4),
      ([p(x0, y1, 0), p(x1, y1, 0), p(x1, y1, hgt), p(x0, y1, hgt)], 0.6),
      ([p(x0, y0, hgt), p(x1, y0, hgt), p(x1, y1, hgt), p(x0, y1, hgt)], 0.9),
    ];
    for (final (pts, shade) in faces) {
      final path = Path()..moveTo(pts[0].dx, pts[0].dy);
      for (var i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
      path.close();
      final v = (10 + shade * 18).round();
      canvas.drawPath(path, Paint()..color = Color.fromARGB(255, v, v, v + 6));
    }
    // A glowing seam up one edge.
    canvas.drawLine(
        p(x0, y0, 0),
        p(x0, y0, hgt),
        Paint()
          ..strokeWidth = 2
          ..color = const Color(0xFF00E5FF).withValues(alpha: pulse));
  }

  /// A planted flag near the landing site: a thin pole with a triangular
  /// pennant, standing on a corner of the hub pad.
  void _drawFlag(Canvas canvas, int gx, int gy) {
    final fx = (gx + 0.85) * cell, fy = (gy + 0.85) * cell;
    final tz = _z(gx, gy);
    final base = cam.project(fx, fy, tz + 0.06);
    final top = cam.project(fx, fy, tz + 9.0);
    canvas.drawLine(
        base,
        top,
        Paint()
          ..color = const Color(0xFFE0E0E0)
          ..strokeWidth = (cell * cam.scale) * 0.018
          ..strokeCap = StrokeCap.round);
    // Pennant hanging off the top toward +X.
    final tip = cam.project(fx + 0.35 * cell, fy, tz + 7.6);
    final low = cam.project(fx, fy, tz + 6.6);
    canvas.drawPath(
        Path()
          ..moveTo(top.dx, top.dy)
          ..lineTo(tip.dx, tip.dy)
          ..lineTo(low.dx, low.dy)
          ..close(),
        Paint()..color = const Color(0xFFE53935));
  }

  /// A shuttle flying onto a spaceport pad: it descends (phase 0..0.12), dwells
  /// on the pad (0.12..0.88, ~30 s, with a glow ring), then ascends + fades out
  /// (0.88..1). [relief] tints it (white = relief, amber = a resource delivery).
  void _drawReliefCraft(Canvas canvas, int gx, int gy, double phase,
      {bool relief = true}) {
    final cx = (gx + 0.5) * cell, cy = (gy + 0.5) * cell;
    final tz = _z(gx, gy);
    const roofZ = 0.6; // rests ON the pad deck (was floating high above)
    const cruise = 130.0; // height it flies in/out at
    // Height fraction above the roof: 1 high .. 0 landed .. 1 high. The descent
    // EASES OUT (cubic) so the craft slows as it nears the pad — a soft landing,
    // not a constant-speed slam. The ascent eases IN symmetrically.
    double easeOut(double t) => 1 - math.pow(1 - t, 3).toDouble();
    double easeIn(double t) => math.pow(t, 3).toDouble();
    final double hf;
    final double fade;
    if (phase < 0.12) {
      final t = phase / 0.12; // 0 high .. 1 landed
      hf = 1 - easeOut(t); // decelerate into the pad
      fade = 1.0;
    } else if (phase < 0.88) {
      hf = 0; // landed (dwell)
      fade = 1.0;
    } else {
      final t = (phase - 0.88) / 0.12; // 0 landed .. 1 high
      hf = easeIn(t); // accelerate away
      fade = (1 - t).clamp(0.0, 1.0); // fade as it leaves
    }
    final baseZ = tz + roofZ + cruise * hf;
    final rad = cell * 0.16;
    final apexH = baseZ + cell * 0.42;
    const seg = 12;
    final tint = relief
        ? Color.fromARGB((255 * fade).round(), 210, 224, 235) // white
        : Color.fromARGB((255 * fade).round(), 235, 200, 120); // amber cargo
    // Descent/ascent flame when not settled.
    if (hf > 0.02) {
      final flameLen = cell * (0.5 + 0.5 * hf);
      final ft = cam.project(cx, cy, baseZ);
      final fb = cam.project(cx, cy, baseZ - flameLen);
      canvas.drawLine(
          ft,
          fb,
          Paint()
            ..strokeWidth = (cell * cam.scale) * 0.10
            ..strokeCap = StrokeCap.round
            ..color = Color.fromARGB((220 * fade).round(), 255, 180, 70));
    }
    // Landing target ring — drawn ON the ground plane (projected, so it sits
    // flat on the pad and foreshortens with the camera instead of being a
    // perfect screen circle from every angle).
    if (hf < 0.3) {
      final rr = 0.34 * (1 - hf / 0.3); // cell-fraction radius, shrinks as it lands
      final ringPath = Path();
      const rseg = 20;
      for (var i = 0; i <= rseg; i++) {
        final a = i / rseg * 2 * math.pi;
        final p = cam.project((gx + 0.5 + rr * math.cos(a)) * cell,
            (gy + 0.5 + rr * math.sin(a)) * cell, tz + 0.08);
        if (i == 0) {
          ringPath.moveTo(p.dx, p.dy);
        } else {
          ringPath.lineTo(p.dx, p.dy);
        }
      }
      canvas.drawPath(
          ringPath,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = const Color(0xFF8FE3FF).withValues(alpha: 0.6 * fade));
    }
    // Thruster dust kicked up off the pad while close to the ground — an
    // expanding, fading puff animated by [phase] (the pad-activity animation).
    if (hf < 0.2) {
      final puff = (0.5 + 0.5 * math.sin(phase * 30)); // pulse
      final pr = (cell * cam.scale) * (0.18 + 0.12 * puff) * (1 - hf / 0.2);
      canvas.drawCircle(
          cam.project(cx, cy, tz + 0.3),
          pr,
          Paint()
            ..color = const Color(0xFFBFC6CC)
                .withValues(alpha: 0.18 * (1 - hf / 0.2) * fade)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
    }
    // Cone body (apex up), depth-shaded like the lander.
    final apex = cam.project(cx, cy, apexH);
    final rim = <Offset>[];
    final rimW = <(double, double)>[];
    for (var i = 0; i < seg; i++) {
      final a = i / seg * 2 * math.pi;
      final wx = cx + rad * math.cos(a), wy = cy + rad * math.sin(a);
      rim.add(cam.project(wx, wy, baseZ));
      rimW.add((wx, wy));
    }
    final faces = <({Path path, double shade, double depth})>[];
    for (var i = 0; i < seg; i++) {
      final j = (i + 1) % seg;
      final p = Path()
        ..moveTo(apex.dx, apex.dy)
        ..lineTo(rim[i].dx, rim[i].dy)
        ..lineTo(rim[j].dx, rim[j].dy)
        ..close();
      final mx = (rimW[i].$1 + rimW[j].$1) / 2;
      final my = (rimW[i].$2 + rimW[j].$2) / 2;
      final nx = mx - cx, ny = my - cy;
      final shade =
          (0.5 + 0.5 * ((nx * 0.5 + ny * -0.5) / rad + 1) / 2).clamp(0.35, 1.0);
      faces.add((path: p, shade: shade, depth: cam.depth(mx, my, apexH)));
    }
    faces.sort((a, b) => b.depth.compareTo(a.depth));
    for (final f in faces) {
      canvas.drawPath(f.path, Paint()..color = _scale(tint, f.shade));
    }
    // A red-cross style relief marker dot on the nose.
    canvas.drawCircle(apex, (cell * cam.scale) * 0.02,
        Paint()..color = Color.fromARGB((255 * fade).round(), 255, 90, 90));
  }

  /// A delivery craft IN FLIGHT above the map: drawn at a compressed render
  /// height (real altitude in metres mapped log-ish into a tall column over the
  /// pad) + a downrange slide, with a leader line down to its pad so you can see
  /// it climbing out / arcing back in.
  void _drawFlyingCraft(Canvas canvas, int gx, int gy, double altM,
      double downrangeTiles, bool relief) {
    // Compress altitude (which runs to tens of km) into a render column a few
    // tens of "cell-metres" tall, so a craft in orbit sits high over the map but
    // doesn't shoot off-screen. sqrt gives a fast initial rise then flattens.
    final renderZ = (math.sqrt(altM) * 0.6).clamp(2.0, 90.0);
    final cx = (gx + 0.5) * cell + downrangeTiles * cell;
    final cy = (gy + 0.5) * cell;
    final tz = _z(gx, gy);
    final base = cam.project(cx, cy, tz + renderZ);
    // Leader line from the pad straight up to the craft.
    final padPt = cam.project((gx + 0.5) * cell, cy, tz + 0.2);
    canvas.drawLine(
        padPt,
        base,
        Paint()
          ..color = const Color(0x33A9C6E0)
          ..strokeWidth = 1);
    // A small cone marker (apex up) + engine flame below.
    final tint = relief
        ? const Color(0xFFD2E0EB)
        : const Color(0xFFE0C878); // amber cargo
    final apex = cam.project(cx, cy, tz + renderZ + cell * 0.4);
    final r = cell * 0.14;
    final rim = <Offset>[
      for (var i = 0; i < 10; i++)
        cam.project(cx + r * math.cos(i / 10 * 2 * math.pi),
            cy + r * math.sin(i / 10 * 2 * math.pi), tz + renderZ),
    ];
    final faces = <({Path path, double shade, double depth})>[];
    for (var i = 0; i < rim.length; i++) {
      final j = (i + 1) % rim.length;
      final a = i / rim.length * 2 * math.pi;
      faces.add((
        path: Path()
          ..moveTo(apex.dx, apex.dy)
          ..lineTo(rim[i].dx, rim[i].dy)
          ..lineTo(rim[j].dx, rim[j].dy)
          ..close(),
        shade: (0.5 + 0.4 * math.sin(a)).clamp(0.35, 1.0),
        depth: a,
      ));
    }
    faces.sort((p, q) => q.depth.compareTo(p.depth));
    for (final f in faces) {
      canvas.drawPath(f.path, Paint()..color = _scale(tint, f.shade));
    }
    // Engine flame pointing down (climbing) or up... keep it simple: a short
    // glow below the craft.
    canvas.drawLine(
        base,
        cam.project(cx, cy, tz + renderZ - cell * 0.5),
        Paint()
          ..color = const Color(0xCCFFB347)
          ..strokeWidth = (cell * cam.scale) * 0.06
          ..strokeCap = StrokeCap.round);
  }

  /// The lander cone standing on the city hub — a small 3D cone (base ring in
  /// the ground plane, apex up) projected + depth-shaded so it reads as the
  /// craft that founded the colony.
  void _drawLanderCone(Canvas canvas, int gx, int gy) {
    final tz = _z(gx, gy);
    final cx = (gx + 0.5) * cell, cy = (gy + 0.5) * cell;
    final rad = cell * 0.22;
    final apexH = cell * 0.7 + tz;
    const seg = 14;
    const tint = Color(0xFFB0BEC5); // metallic grey
    final apex = cam.project(cx, cy, apexH);
    final rim = <Offset>[];
    final rimW = <(double, double)>[]; // world x,y for depth + normal
    for (var i = 0; i < seg; i++) {
      final a = i / seg * 2 * math.pi;
      final wx = cx + rad * math.cos(a), wy = cy + rad * math.sin(a);
      rim.add(cam.project(wx, wy, 0.06 + tz));
      rimW.add((wx, wy));
    }
    // Side faces, depth-sorted far->near so it reads solid.
    final faces = <({Path path, double shade, double depth})>[];
    for (var i = 0; i < seg; i++) {
      final j = (i + 1) % seg;
      final p = Path()
        ..moveTo(apex.dx, apex.dy)
        ..lineTo(rim[i].dx, rim[i].dy)
        ..lineTo(rim[j].dx, rim[j].dy)
        ..close();
      final mx = (rimW[i].$1 + rimW[j].$1) / 2;
      final my = (rimW[i].$2 + rimW[j].$2) / 2;
      // Shade by facing the up-right light; depth for ordering.
      final nx = mx - cx, ny = my - cy;
      final shade = (0.45 + 0.5 * ((nx * 0.5 + ny * -0.5) / rad + 1) / 2)
          .clamp(0.3, 1.0);
      faces.add((path: p, shade: shade, depth: cam.depth(mx, my, apexH / 2)));
    }
    faces.sort((a, b) => b.depth.compareTo(a.depth));
    for (final f in faces) {
      canvas.drawPath(f.path, Paint()..color = _scale(tint, f.shade));
    }
    // Apex highlight + a thin nose tip.
    canvas.drawCircle(apex, (cell * cam.scale) * 0.012,
        Paint()..color = const Color(0xFFECEFF1));
  }

  /// A low-poly faceted "pentagon sphere" pressurised hab — a geodesic dome of
  /// flat pentagon/hex facets sitting on the terrain, used instead of a box for
  /// the sealed (domed) colony style on INHOSPITABLE worlds. Lit per-facet so the
  /// facets read; a metal hull with a few warm window facets.
  void _drawPentaSphere(Canvas canvas, int gx, int gy, int fw, int fh,
      Building b, bool live) {
    var col = colorOf(b);
    if (!live) col = Color.lerp(col, const Color(0xFF555B63), 0.7)!;
    final metal = Color.lerp(col, const Color(0xFFB8C2CC), 0.45)!;
    final cx = (gx + fw / 2), cy = (gy + fh / 2);
    final tz = _z(gx, gy);
    // Radius in CELL units for horizontal, metres for vertical (cam.project
    // takes metres in all three axes — see _drawModule note).
    final rCell = math.max(fw, fh) * 0.42;
    final rM = rCell * cell; // sphere radius in metres

    const lat = 3; // latitude RINGS (ring 0 is the flat-top pentagon edge)
    const lon = 6; // facets around
    const topTheta = 0.42; // ring-0 polar angle (small flat-ish top cap)
    final botTheta = math.pi * 0.60; // ring-lat angle (a bit past equator)
    // Anchor the centre so the LOWEST ring rests exactly on the deck (z = tz):
    // bottomZ = ctrZ + rM*cos(botTheta) = tz.
    final ctrZ = tz - rM * math.cos(botTheta);
    // World surface point at ring li (0 top .. lat bottom) + longitude lj.
    ({Offset p, double depth, double up}) vert(int li, int lj) {
      final theta = topTheta + (li / lat) * (botTheta - topTheta);
      final phi = (lj / lon) * 2 * math.pi;
      final sinT = math.sin(theta), cosT = math.cos(theta);
      final wx = cx + rCell * sinT * math.cos(phi);
      final wy = cy + rCell * sinT * math.sin(phi);
      final wz = ctrZ + rM * cosT;
      return (
        p: cam.project(wx * cell, wy * cell, wz),
        depth: cam.depth(wx * cell, wy * cell, wz),
        up: cosT, // +1 top (lit), lower = dimmer
      );
    }

    final faces = <({List<Offset> pts, double depth, double shade})>[];
    // Body: quad facets between successive rings.
    for (var li = 0; li < lat; li++) {
      for (var lj = 0; lj < lon; lj++) {
        final lj2 = (lj + 1) % lon;
        final a = vert(li, lj), bb = vert(li, lj2);
        final c = vert(li + 1, lj2), d = vert(li + 1, lj);
        final upMid = (a.up + c.up) / 2;
        final shade = (0.4 + 0.55 * (0.5 + 0.5 * upMid)).clamp(0.0, 1.0);
        faces.add((
          pts: [a.p, bb.p, c.p, d.p],
          depth: (a.depth + bb.depth + c.depth + d.depth) / 4,
          shade: shade,
        ));
      }
    }
    // Top cap: the ring-0 polygon as one bright facet (faces up).
    {
      final ring0 = [for (var lj = 0; lj < lon; lj++) vert(0, lj)];
      faces.add((
        pts: [for (final v in ring0) v.p],
        depth: ring0.map((v) => v.depth).reduce((a, b) => a + b) / lon,
        shade: 0.95,
      ));
    }
    faces.sort((p, q) => q.depth.compareTo(p.depth)); // far first
    var fi = 0;
    for (final f in faces) {
      final path = Path()..moveTo(f.pts[0].dx, f.pts[0].dy);
      for (var i = 1; i < f.pts.length; i++) {
        path.lineTo(f.pts[i].dx, f.pts[i].dy);
      }
      path.close();
      // A few warm-lit window facets near the front/top when live.
      final isWindow = live && (fi % 7 == 3) && f.shade > 0.7;
      canvas.drawPath(
          path,
          Paint()
            ..color = isWindow
                ? const Color(0xFFFFE08A)
                : _scale(metal, f.shade));
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8
            ..color = _scale(metal, f.shade * 0.55));
      fi++;
    }
    _drawBuildingBadge(canvas, gx, gy, fw, fh, ctrZ + rM, live);
  }

  /// True if any tube/road tile borders this footprint along the given axis.
  /// [horiz] checks the E/W sides (an E-W tube), else the N/S sides.
  bool _moduleAxisConnects(int gx, int gy, int fw, int fh, bool horiz) {
    if (horiz) {
      for (var dy = 0; dy < fh; dy++) {
        if (_roadNeighbour(_nbr(gx, gy + dy, -1, 0) ?? -1) ||
            _roadNeighbour(_nbr(gx + fw - 1, gy + dy, 1, 0) ?? -1)) {
          return true;
        }
      }
    } else {
      for (var dx = 0; dx < fw; dx++) {
        if (_roadNeighbour(_nbr(gx + dx, gy, 0, -1) ?? -1) ||
            _roadNeighbour(_nbr(gx + dx, gy + fh - 1, 0, 1) ?? -1)) {
          return true;
        }
      }
    }
    return false;
  }

  /// An orbital hull module — a rounded capsule (no open box) for the orbital
  /// colony style. Lit metallic shell, laid HORIZONTAL along its connecting tube
  /// (long axis parallel to the road/tube it touches) instead of standing up.
  void _drawModule(Canvas canvas, int gx, int gy, int fw, int fh, Building b,
      bool live, double growth) {
    var col = colorOf(b);
    if (!live) col = Color.lerp(col, const Color(0xFF555B63), 0.7)!;
    final metal = Color.lerp(col, const Color(0xFFCFD8DC), 0.5)!;
    final tz = _z(gx, gy);
    const inset = 0.14;
    final x0 = gx + inset, x1 = gx + fw - inset;
    final y0 = gy + inset, y1 = gy + fh - inset;
    final cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;

    // Long axis = direction of the connecting tube. Prefer an actual connection;
    // otherwise lie along the footprint's longer side, then default E-W.
    final hConn = _moduleAxisConnects(gx, gy, fw, fh, true);
    final vConn = _moduleAxisConnects(gx, gy, fw, fh, false);
    final bool horiz;
    if (hConn != vConn) {
      horiz = hConn; // exactly one side has a tube -> align to it
    } else {
      horiz = fw >= fh; // tie/none -> along the longer footprint side
    }

    // Low-poly octagonal-prism hull: 8 flat side faces + 2 octagon end caps. The
    // octagon cross-section lies in the plane perpendicular to the long axis
    // (cross-axis + Z), so it's a chunky tube on its side, not a flat sphere.
    //
    // CRITICAL: cam.project takes (xMetres, yMetres, zMetres). Footprint coords
    // are cell-fractions scaled by [cell]; the VERTICAL radius must be in the
    // SAME metres scale or the hull collapses flat. So the cross-axis radius is a
    // cell-fraction ([capR]) but the Z radius is that times [cell] ([capRz]).
    final halfLen = (horiz ? (x1 - x0) : (y1 - y0)) / 2;
    final shortHalf = (horiz ? (y1 - y0) : (x1 - x0)) / 2;
    final capR = math.max(shortHalf, halfLen * 0.42); // cross-axis (cell-frac)
    final capRz = capR * cell; // vertical radius in metres (so it stands up)
    // Centreline sits ON the deck (z = terrain), so the tube's midsection aligns
    // with the roads/transport tubes it connects to (bottom half below the deck).
    final axisZ = tz;
    const sides = 8;

    // World point on the hull surface: end e (-1 near cap .. +1 far cap), vertex
    // angle a around the octagon. Horizontal (cross-axis) uses cell-fraction *
    // cell; vertical (Z) uses metres. For horiz the long axis is X and the
    // cross-axis Y; for vertical it's swapped.
    Offset proj(double e, double a) {
      final cross = capR * math.cos(a);
      final wz = axisZ + capRz * math.sin(a);
      final fx = horiz ? cx + halfLen * e : cx + cross;
      final fy = horiz ? cy + cross : cy + halfLen * e;
      return cam.project(fx * cell, fy * cell, wz);
    }

    // 8 octagon angles (offset so a flat face sits on top + bottom).
    final ang = [for (var s = 0; s < sides; s++) (s + 0.5) / sides * 2 * math.pi];
    // Pre-project both end rings.
    final near = [for (final a in ang) proj(-1, a)];
    final far = [for (final a in ang) proj(1, a)];

    // Collect faces with a depth key + a shade from the face normal's Z (top lit,
    // underside dark) so the low-poly facets read.
    final faces = <({List<Offset> pts, double depth, double shade})>[];
    // Side faces.
    for (var s = 0; s < sides; s++) {
      final s2 = (s + 1) % sides;
      // Face-normal angle = vertex angle + half a step (the face spans s..s+1).
      final mid = ang[s] + math.pi / sides;
      final lit = 0.5 + 0.5 * math.sin(mid); // +Z up = bright
      final crossM = capR * math.cos(mid), zM = axisZ + capRz * math.sin(mid);
      final mcx = horiz ? cx : cx + crossM, mcy = horiz ? cy + crossM : cy;
      faces.add((
        pts: [near[s], near[s2], far[s2], far[s]],
        depth: cam.depth(mcx * cell, mcy * cell, zM),
        shade: (0.38 + 0.55 * lit).clamp(0.0, 1.0),
      ));
    }
    // End caps (octagons). Near cap brightest (faces the front), far cap dim.
    faces.add((
      pts: near,
      depth: cam.depth((horiz ? cx - halfLen : cx) * cell,
          (horiz ? cy : cy - halfLen) * cell, axisZ),
      shade: 0.9,
    ));
    faces.add((
      pts: far,
      depth: cam.depth((horiz ? cx + halfLen : cx) * cell,
          (horiz ? cy : cy + halfLen) * cell, axisZ),
      shade: 0.55,
    ));
    faces.sort((p, q) => q.depth.compareTo(p.depth)); // far first
    for (final f in faces) {
      final path = Path()..moveTo(f.pts[0].dx, f.pts[0].dy);
      for (var i = 1; i < f.pts.length; i++) {
        path.lineTo(f.pts[i].dx, f.pts[i].dy);
      }
      path.close();
      canvas.drawPath(path, Paint()..color = _scale(metal, f.shade));
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8
            ..color = _scale(metal, f.shade * 0.6));
    }
    // Windows: a row of lit dots along the TOP ridge of the hull.
    final winPaint = Paint()..color = const Color(0xFFFFE08A);
    const wins = 6;
    for (var i = 0; i < wins; i++) {
      final e = -0.7 + 1.4 * (i / (wins - 1));
      final px = horiz ? cx + halfLen * e : cx;
      final py = horiz ? cy : cy + halfLen * e;
      canvas.drawCircle(cam.project(px * cell, py * cell, axisZ + capRz * 0.92),
          (cell * cam.scale) * 0.02, winPaint);
    }
    _drawBuildingBadge(canvas, gx, gy, fw, fh, axisZ + capRz, live);
  }

  void _drawBox(Canvas canvas, int gx, int gy, int fw, int fh, Building b,
      bool live, {double heightScale = 1.0}) {
    var col = colorOf(b);
    if (!live) {
      // Disconnected from the road network -> greyed out / dormant.
      col = Color.lerp(col, const Color(0xFF555B63), 0.7)!;
    }
    // A bigger footprint reads as a bigger structure: scale height with the
    // footprint's smaller side so a 2×2 isn't a tall thin tower. [heightScale]
    // further scales it by the building's utilisation (small -> max).
    final h = heightOf(b) *
        (1 + (math.min(fw, fh) - 1) * 0.35) *
        heightScale;
    const inset = 0.12; // footprint margin within the cell
    final x0 = (gx + inset) * cell, x1 = (gx + fw - inset) * cell;
    final y0 = (gy + inset) * cell, y1 = (gy + fh - inset) * cell;

    // 8 corners: base (z=ground elevation) + top (z=ground+h), so buildings sit
    // ON the terrain instead of at sea level.
    final z0 = _z(gx, gy);
    Offset p(double x, double y, double z) => cam.project(x, y, z + z0);
    final b00 = p(x0, y0, 0), b10 = p(x1, y0, 0);
    final b11 = p(x1, y1, 0), b01 = p(x0, y1, 0);
    final t00 = p(x0, y0, h), t10 = p(x1, y0, h);
    final t11 = p(x1, y1, h), t01 = p(x0, y1, h);

    // Four side walls + roof. Each wall is depth-sorted by its world centroid so
    // the FAR walls draw first and the near ones paint over them (a back wall no
    // longer overdraws a front wall — fixes the "backfaces showing" look). The
    // roof draws last (always on top at this top-down-ish tilt).
    final cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
    final walls = <({List<Offset> pts, double shade, double depth})>[
      (pts: [b00, b10, t10, t00], shade: 0.62, depth: cam.depth(cx, y0, h / 2)), // -Y
      (pts: [b10, b11, t11, t10], shade: 0.78, depth: cam.depth(x1, cy, h / 2)), // +X
      (pts: [b11, b01, t01, t11], shade: 0.5, depth: cam.depth(cx, y1, h / 2)), // +Y
      (pts: [b01, b00, t00, t01], shade: 0.7, depth: cam.depth(x0, cy, h / 2)), // -X
    ]..sort((a, b2) => b2.depth.compareTo(a.depth)); // far first
    final faces = <({List<Offset> pts, double shade})>[
      for (final w in walls) (pts: w.pts, shade: w.shade),
      (pts: [t00, t10, t11, t01], shade: 1.0), // roof (brightest, on top)
    ];
    for (final f in faces) {
      final path = Path()..moveTo(f.pts[0].dx, f.pts[0].dy);
      for (var i = 1; i < f.pts.length; i++) {
        path.lineTo(f.pts[i].dx, f.pts[i].dy);
      }
      path.close();
      canvas.drawPath(path, Paint()..color = _scale(col, f.shade));
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8
            ..color = _scale(col, f.shade * 0.6));
    }
    _drawBuildingBadge(canvas, gx, gy, fw, fh, h, live);
  }

  /// Float a status badge (no-road / understaffed) over a building's footprint
  /// centre. Shared by the box + custom-art renderers.
  void _drawBuildingBadge(
      Canvas canvas, int gx, int gy, int fw, int fh, double h, bool live) {
    if (!live) {
      _drawBadge(canvas, gx, gy, fw, fh, h, const Color(0xFFFF6B6B),
          _BadgeKind.noRoad);
    } else if (understaffed(gy * grid + gx)) {
      _drawBadge(canvas, gx, gy, fw, fh, h, const Color(0xFFFF5252),
          _BadgeKind.worker);
    }
  }

  /// A large status badge floating WELL above the building, joined to the roof
  /// by a same-coloured leader line so it reads clearly at any zoom.
  void _drawBadge(Canvas canvas, int gx, int gy, int fw, int fh, double h,
      Color color, _BadgeKind kind) {
    final mx = (gx + fw / 2) * cell, my = (gy + fh / 2) * cell;
    // Roof anchor + the raised badge centre (further up the more zoomed out).
    final roof = cam.project(mx, my, h + 1);
    final badge = cam.project(mx, my, h + 22);
    // Leader line.
    canvas.drawLine(roof, badge,
        Paint()..color = color..strokeWidth = 1.5);
    final r = (cell * cam.scale) * 0.11;
    // Filled disc + ring.
    canvas.drawCircle(badge, r, Paint()..color = color);
    canvas.drawCircle(
        badge,
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = const Color(0xFF1A1014));
    // Glyph: a person for understaffed, an exclamation slash for no-road.
    final g = Paint()..color = const Color(0xFF1A1014);
    if (kind == _BadgeKind.worker) {
      canvas.drawCircle(badge.translate(0, -r * 0.35), r * 0.32, g);
      canvas.drawPath(
          Path()
            ..moveTo(badge.dx - r * 0.5, badge.dy + r * 0.6)
            ..lineTo(badge.dx - r * 0.35, badge.dy - r * 0.05)
            ..lineTo(badge.dx + r * 0.35, badge.dy - r * 0.05)
            ..lineTo(badge.dx + r * 0.5, badge.dy + r * 0.6)
            ..close(),
          g);
    } else {
      // Exclamation mark.
      canvas.drawRect(
          Rect.fromCenter(
              center: badge.translate(0, -r * 0.15),
              width: r * 0.22,
              height: r * 0.8),
          g);
      canvas.drawCircle(badge.translate(0, r * 0.5), r * 0.16, g);
    }
  }

  /// Warm window-lights speckled up a building's facade at night. Count + height
  /// scale with the building; positions are deterministic per tile so they don't
  /// flicker. [night] (0..1) fades them in as it gets dark.
  void _drawWindowLights(
      Canvas canvas, int gx, int gy, Building b, double night) {
    final fw = footOf(gy * grid + gx).$1, fh = footOf(gy * grid + gx).$2;
    final h = heightOf(b);
    final flat = h < 4; // solar/farm/etc — lights sit on the ground, not floating
    // Tall buildings get window-lights up the facade; flat ones get a few
    // ground-level lamps. Light height is always clamped to the structure so
    // nothing floats above a flat building.
    final maxZ = math.max(0.3, h - 1.0);
    final count = flat
        ? (1.5 * fw * fh).round().clamp(1, 6)
        : (h * 0.4 * fw * fh).round().clamp(2, 30);
    final glow = Paint()
      ..color = const Color(0xFFFFE08A).withValues(alpha: night * 0.95)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5);
    var seed = (gx * 374761393) ^ (gy * 668265263) ^ 0x9e37;
    final r = (cell * cam.scale) * 0.018;
    final tz = _z(gx, gy);
    for (var i = 0; i < count; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final fx = gx + 0.16 + (seed % 1000) / 1000 * (fw - 0.32);
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      final fy = gy + 0.16 + (seed % 1000) / 1000 * (fh - 0.32);
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      // Flat: ground-hugging (0.1..maxZ). Tall: spread up the facade.
      final z = flat
          ? 0.1 + (seed % 1000) / 1000 * maxZ
          : (1.0 + (seed % 1000) / 1000 * (h - 1.5)).clamp(0.1, maxZ);
      canvas.drawCircle(cam.project(fx * cell, fy * cell, tz + z), r, glow);
    }
  }

  /// A building under construction: a dirt-brown foundation slab + sandy
  /// scaffold posts, rising to a fraction of the final height as [growth] (0..0.3)
  /// climbs. Reads clearly as "being built", not a finished structure.
  void _drawConstruction(
      Canvas canvas, int gx, int gy, int fw, int fh, Building b, double growth) {
    const inset = 0.16;
    final tz = _z(gx, gy);
    final x0 = gx + inset, x1 = gx + fw - inset;
    final y0 = gy + inset, y1 = gy + fh - inset;
    // Foundation slab.
    _fillRect(canvas, x0, y0, x1, y1, tz + 0.05,
        Paint()..color = const Color(0xFF5A4A38));
    _strokeRect(canvas, x0, y0, x1, y1, tz + 0.05, const Color(0xFF7A6A52), 1);
    // Scaffold posts at the corners, partial height (fraction of final box).
    final full = heightOf(b);
    final postH = tz + full * (0.2 + growth / 0.3 * 0.5);
    final post = Paint()
      ..color = const Color(0xFFCBB279)
      ..strokeWidth = (cell * cam.scale) * 0.02
      ..strokeCap = StrokeCap.round;
    for (final c in [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]) {
      canvas.drawLine(cam.project(c.$1 * cell, c.$2 * cell, tz + 0.05),
          cam.project(c.$1 * cell, c.$2 * cell, postH), post);
    }
    // A horizontal scaffold band near the top.
    final bandZ = postH * 0.7;
    final band = [
      cam.project(x0 * cell, y0 * cell, bandZ),
      cam.project(x1 * cell, y0 * cell, bandZ),
      cam.project(x1 * cell, y1 * cell, bandZ),
      cam.project(x0 * cell, y1 * cell, bandZ),
    ];
    canvas.drawPath(
        Path()
          ..moveTo(band[0].dx, band[0].dy)
          ..lineTo(band[1].dx, band[1].dy)
          ..lineTo(band[2].dx, band[2].dy)
          ..lineTo(band[3].dx, band[3].dy)
          ..close(),
        post);
    _drawBuildingBadge(canvas, gx, gy, fw, fh, postH, true);
  }

  /// Solar farm: a field of flat blue PV panels (a 2×2 grid of squares per
  /// cell), tilted slightly off the ground. No box — solar reads as panels.
  void _drawSolar(Canvas canvas, int gx, int gy, int fw, int fh, bool live) {
    final panel = live ? const Color(0xFF2E63D6) : const Color(0xFF44505E);
    final frame = live ? const Color(0xFF8FB4FF) : const Color(0xFF566270);
    const m = 0.06; // gap between panels
    for (var cy = 0; cy < fh; cy++) {
      for (var cx = 0; cx < fw; cx++) {
        final bx = gx + cx, by = gy + cy;
        final tz = _z(bx, by);
        // 2×2 panels in this cell.
        for (var py = 0; py < 2; py++) {
          for (var px = 0; px < 2; px++) {
            final x0 = bx + px * 0.5 + m, x1 = bx + (px + 1) * 0.5 - m;
            final y0 = by + py * 0.5 + m, y1 = by + (py + 1) * 0.5 - m;
            // Slight raise so panels sit above the ground plane.
            _fillRect(canvas, x0, y0, x1, y1, tz + 0.3, Paint()..color = panel);
            _strokeRect(canvas, x0, y0, x1, y1, tz + 0.3, frame, 1);
          }
        }
      }
    }
    _drawBuildingBadge(canvas, gx, gy, fw, fh, 1, live);
  }

  /// Farm: a flat yellow-green crop field with a small barn box in one corner.
  /// Hydroponics reuses this (greener field) — both are low, ground-hugging.
  void _drawFarm(
      Canvas canvas, int gx, int gy, int fw, int fh, Building b, bool live) {
    var field = colorOf(b);
    var barnCol = const Color(0xFF8D6E63);
    if (!live) {
      field = Color.lerp(field, const Color(0xFF555B63), 0.7)!;
      barnCol = Color.lerp(barnCol, const Color(0xFF555B63), 0.7)!;
    }
    final tz = _z(gx, gy);
    // Field tile (flat, just above ground).
    _fillRect(canvas, gx + 0.04, gy + 0.04, gx + fw - 0.04, gy + fh - 0.04,
        tz + 0.04, Paint()..color = field);
    // Furrow lines across the field for a tilled look.
    final furrow = Paint()
      ..color = _scale(field, 0.8)
      ..strokeWidth = 1;
    final rows = (fh * 4).clamp(3, 16);
    for (var i = 1; i < rows; i++) {
      final fy = gy + 0.1 + (fh - 0.2) * i / rows;
      _dashLine(canvas, gx + 0.1, fy, gx + fw - 0.1, fy, tz + 0.05, furrow);
    }
    // A barn in the near corner. Tiny shed for a regular Farm; a MASSIVE
    // building for an Industrial Farm (bigger footprint = bigger structure).
    final industrial = fw >= 2 || fh >= 2;
    final bSize = industrial ? 0.85 : 0.34; // fraction of a cell
    final bh = industrial ? 14.0 : 4.0; // height (m)
    final x0 = gx.toDouble(), y1 = (gy + fh).toDouble();
    final bx0 = x0 + 0.08, bx1 = x0 + 0.08 + bSize;
    final by1 = y1 - 0.08, by0 = y1 - 0.08 - bSize;
    _drawColumnBox(canvas, bx0, by0, bx1, by1, bh, barnCol, tz);
    _drawBuildingBadge(canvas, gx, gy, fw, fh, industrial ? bh : 6, live);
  }

  /// A simple lit box in fractional-cell coords (used for the farm barn). Four
  /// depth-sorted walls + a roof, shaded like the main building boxes.
  void _drawColumnBox(Canvas canvas, double x0, double y0, double x1, double y1,
      double h, Color col, [double zBase = 0]) {
    Offset p(double x, double y, double z) =>
        cam.project(x * cell, y * cell, z + zBase);
    final b00 = p(x0, y0, 0), b10 = p(x1, y0, 0), b11 = p(x1, y1, 0), b01 = p(x0, y1, 0);
    final t00 = p(x0, y0, h), t10 = p(x1, y0, h), t11 = p(x1, y1, h), t01 = p(x0, y1, h);
    final cx = (x0 + x1) / 2, cy = (y0 + y1) / 2;
    final walls = <({List<Offset> pts, double shade, double depth})>[
      (pts: [b00, b10, t10, t00], shade: 0.62, depth: cam.depth(cx, y0, h / 2)),
      (pts: [b10, b11, t11, t10], shade: 0.78, depth: cam.depth(x1, cy, h / 2)),
      (pts: [b11, b01, t01, t11], shade: 0.5, depth: cam.depth(cx, y1, h / 2)),
      (pts: [b01, b00, t00, t01], shade: 0.7, depth: cam.depth(x0, cy, h / 2)),
    ]..sort((a, b2) => b2.depth.compareTo(a.depth));
    for (final w in [
      ...walls.map((w) => (pts: w.pts, shade: w.shade)),
      (pts: [t00, t10, t11, t01], shade: 1.0),
    ]) {
      final path = Path()..moveTo(w.pts[0].dx, w.pts[0].dy);
      for (var i = 1; i < w.pts.length; i++) {
        path.lineTo(w.pts[i].dx, w.pts[i].dy);
      }
      path.close();
      canvas.drawPath(path, Paint()..color = _scale(col, w.shade));
    }
  }

  /// Quarry: a sunken open-pit mine — concentric terraces stepping DOWN into the
  /// ground (negative z), darkening toward the floor, with a haul road notch.
  void _drawQuarry(
      Canvas canvas, int gx, int gy, int fw, int fh, Building b, bool live) {
    final base = live ? const Color(0xFF8A7A5C) : const Color(0xFF5A5E64);
    const steps = 5;
    final tz = _z(gx, gy);
    final w = fw.toDouble(), h = fh.toDouble();
    // Outer rim flush with the ground, then each terrace insets + sinks.
    for (var i = 0; i < steps; i++) {
      final t = i / steps; // 0 outer .. ->1 inner
      final inset = 0.08 + t * (math.min(w, h) * 0.42);
      final z = tz - t * 6.0; // sink deeper each ring
      final x0 = gx + inset, x1 = gx + w - inset;
      final y0 = gy + inset, y1 = gy + h - inset;
      if (x1 - x0 < 0.1 || y1 - y0 < 0.1) break;
      _fillRect(canvas, x0, y0, x1, y1, z, Paint()..color = _scale(base, 1 - t * 0.5));
      _strokeRect(canvas, x0, y0, x1, y1, z, _scale(base, (1 - t) * 0.7), 1);
    }
    _drawBuildingBadge(canvas, gx, gy, fw, fh, 1, live);
  }

  /// Spaceport as an L-shape: a flat LAUNCH PAD covering most of the footprint
  /// (with hazard chevrons + a central circle) plus a tall service TOWER/gantry
  /// standing in one corner. Reads as a real pad-and-tower complex, not a box.
  void _drawSpaceport(Canvas canvas, int gx, int gy, int fw, int fh, Building b,
      bool live) {
    final tz = _z(gx, gy);
    final pad = live ? const Color(0xFF3A3F46) : const Color(0xFF50545C);
    final mark = live ? const Color(0xFFEC407A) : const Color(0xFF6B6F77);
    final steel = live ? const Color(0xFF9AA4AE) : const Color(0xFF6B6F77);
    const towerH = 34.0;
    // Launch pad deck (the whole footprint).
    _fillRect(canvas, gx + 0.06, gy + 0.06, gx + fw - 0.06, gy + fh - 0.06,
        tz + 0.06, Paint()..color = pad);
    _strokeRect(canvas, gx + 0.06, gy + 0.06, gx + fw - 0.06, gy + fh - 0.06,
        tz + 0.06, _scale(pad, 1.4), 1.5);
    // One PAD per footprint tile: each gets a landing circle + a service tower,
    // so a bigger spaceport has multiple launch towers (one per craft it can
    // service). Towers drawn back-to-front so near ones paint over far ones.
    final pads = <(int, int)>[
      for (var dy = 0; dy < fh; dy++)
        for (var dx = 0; dx < fw; dx++) (gx + dx, gy + dy)
    ]..sort((a, b) => cam
        .depth((a.$1 + 0.5) * cell, (a.$2 + 0.5) * cell, 0)
        .compareTo(cam.depth((b.$1 + 0.5) * cell, (b.$2 + 0.5) * cell, 0)));
    final markPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = mark;
    for (final (px, py) in pads) {
      // Landing circle centred on the pad tile.
      final cc = cam.project((px + 0.5) * cell, (py + 0.5) * cell, tz + 0.07);
      final r = (cell * cam.scale) * 0.26;
      canvas.drawCircle(cc, r, markPaint);
      canvas.drawCircle(cc, r * 0.18, Paint()..color = mark);
      // Service tower/gantry in the tile's far corner + a gantry arm + beacon.
      const tw = 0.34;
      final tx0 = px + 1 - 0.12 - tw, tx1 = px + 1 - 0.12;
      final ty0 = py + 0.12, ty1 = py + 0.12 + tw;
      _drawColumnBox(canvas, tx0, ty0, tx1, ty1, towerH, steel, tz);
      final top = cam.project((tx0 + tx1) / 2 * cell, (ty0 + ty1) / 2 * cell,
          tz + towerH);
      final armEnd = cam.project((px + 0.5) * cell, (ty0 + ty1) / 2 * cell,
          tz + towerH * 0.82);
      canvas.drawLine(top, armEnd,
          Paint()..color = _scale(steel, 0.8)..strokeWidth = 2.5);
      canvas.drawCircle(top, (cell * cam.scale) * 0.02,
          Paint()..color = const Color(0xFFFF5252));
    }
    _drawBuildingBadge(canvas, gx, gy, fw, fh, towerH, live);
  }

  /// Stroke a ground-plane rectangle outline (cell-fraction coords) at height z.
  void _strokeRect(Canvas canvas, double x0, double y0, double x1, double y1,
      double z, Color c, double w) {
    final a = cam.project(x0 * cell, y0 * cell, z);
    final b = cam.project(x1 * cell, y0 * cell, z);
    final cc = cam.project(x1 * cell, y1 * cell, z);
    final d = cam.project(x0 * cell, y1 * cell, z);
    canvas.drawPath(
        Path()
          ..moveTo(a.dx, a.dy)
          ..lineTo(b.dx, b.dy)
          ..lineTo(cc.dx, cc.dy)
          ..lineTo(d.dx, d.dy)
          ..close(),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = w
          ..color = c);
  }

  /// A line on the ground plane at height z (cell-fraction coords).
  void _dashLine(Canvas canvas, double x0, double y0, double x1, double y1,
      double z, Paint p) {
    canvas.drawLine(cam.project(x0 * cell, y0 * cell, z),
        cam.project(x1 * cell, y1 * cell, z), p);
  }

  Color _scale(Color c, double f) => Color.fromARGB(
        255,
        (c.r * 255 * f).clamp(0, 255).round(),
        (c.g * 255 * f).clamp(0, 255).round(),
        (c.b * 255 * f).clamp(0, 255).round(),
      );

  @override
  bool shouldRepaint(covariant _CityPainter old) => true;
}
