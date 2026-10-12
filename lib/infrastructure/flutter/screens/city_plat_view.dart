// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// The colony as a plat: roads, lots, buildings and sprawl sections drawn
/// flat in the city's own east/north metres.
///
/// No drape, no meshing, no tiles — the layout is 2D data already, so this
/// draws the moment the generator has finished, minutes before the 3D frame
/// has been captured on a big colony. It is also where the debug overlays
/// are easiest to read: everything is a flat shape.
///
/// Scale: a colony can carry two hundred thousand lots, and tessellating
/// every one every frame is not on. Three things keep it cheap. Zoom LOD:
/// lots only draw once a lot is a few pixels across, their outlines once
/// they are a dozen, local streets once they are a pixel wide, and the
/// sections (a few hundred) always. A cache per colony, bucketed by cell
/// (see `city_plat_tiles.dart`): roads sampled once and cut into 500 m
/// cells, lot fills as one retained triangle batch per cell with a colour
/// per vertex, lot outlines as a path per cell and use, district boxes as
/// a batch per 2 km block, the few major road classes as whole paths — so
/// a frame draws the cells under the viewport and nothing else. The first
/// plat drew the whole colony as colony-wide paths, and the renderer
/// tessellated all of it whatever the clip: 206 ms of raster thread a
/// frame at street scale for the nine percent on screen. And a repaint
/// boundary, so a plat that has not moved is not painted again because the
/// panel beside it ticked.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../domain/colony/city/city_sim.dart';
import '../../../domain/colony/city/colony_relief.dart';
import '../../../domain/colony/city/parcel.dart';
import '../../../domain/colony/city/spatial_index.dart';
import '../../../domain/colony/city/sprawl_plan.dart';
import '../../../domain/colony/city/trails/trail_field.dart';
import 'app_theme.dart';
import 'city_plat_tiles.dart';

/// Where the plat view looks: the colony-local point under the middle of the
/// viewport and the scale. Held OUTSIDE the view so toggling 2D/3D keeps it.
class CityPlatCamera {
  CityPlatCamera({this.centreE = 0, this.centreN = 0, this.metresPerPx = 0});

  double centreE;
  double centreN;

  /// Metres per screen pixel. Zero or less means "not placed yet": the view
  /// fits [fitM] metres across its shorter side on first layout.
  double metresPerPx;

  /// The span to fit when [metresPerPx] is unset.
  double fitM = 4000;

  /// Ask for a fit on the next layout.
  void fit(double spanM) {
    fitM = spanM;
    metresPerPx = 0;
    centreE = 0;
    centreN = 0;
  }

  /// Screen → colony metres for a viewport of [size].
  ({double e, double n}) toLocal(Offset p, Size size) => (
        e: centreE + (p.dx - size.width / 2) * metresPerPx,
        n: centreN - (p.dy - size.height / 2) * metresPerPx,
      );

  /// Colony metres → screen for a viewport of [size].
  Offset toScreen(double e, double n, Size size) => Offset(
        size.width / 2 + (e - centreE) / metresPerPx,
        size.height / 2 - (n - centreN) / metresPerPx,
      );

  /// Zoom by [factor] about the screen point [at], which stays put.
  void zoomAbout(double factor, Offset at, Size size) {
    final before = toLocal(at, size);
    metresPerPx = (metresPerPx * factor).clamp(0.05, 500.0);
    final after = toLocal(at, size);
    centreE += before.e - after.e;
    centreN += before.n - after.n;
  }
}

/// What the plat view draws at a given scale.
enum PlatLod {
  /// Sections and highways only: the county at a glance.
  county,

  /// Plus avenues and lot fills as one tint per block.
  district,

  /// Plus streets and every lot's outline and use.
  street;

  /// The level for [metresPerPx]: a lot is worth drawing once it is a few
  /// pixels across, a street once it is about a pixel wide.
  static PlatLod forScale(double metresPerPx) {
    if (metresPerPx > 24) return PlatLod.county;
    if (metresPerPx > 7) return PlatLod.district;
    return PlatLod.street;
  }
}

/// What the plat draws, as switches for the perf sweep's A/B (see
/// `PerfKnobs`): each layer costs the raster thread something, and the
/// only honest way to know how much is to turn it off and measure.
class PlatLayers {
  PlatLayers._();

  /// Lot fills at street scale (retained triangle batches per cell).
  static bool fills = true;

  /// Lot outlines at street scale (a stroked path per cell and use).
  static bool outlines = true;

  /// Local streets at street scale (a stroked path per cell and class).
  static bool streets = true;

  /// District-scale lot boxes as one image per 2 km block, rendered once
  /// and drawn as a texture, instead of a triangle batch re-uploaded
  /// every frame: 214k boxes were 1.3M vertices and 15 MB a frame, and
  /// a district pan cost the raster thread 17.8 ms. Off, the batches
  /// draw as they did.
  static bool blockImages = true;
}

class CityPlatView extends StatefulWidget {
  const CityPlatView({
    super.key,
    required this.sim,
    required this.camera,
    this.extentM = 4000,
    this.onCameraChanged,
    this.revision = 0,
    this.onTapLocal,
    this.overlay,
  });

  /// The colony, or null before one exists.
  final CitySim? sim;
  final CityPlatCamera camera;

  /// The core's extent, for the first fit and the grid pitch.
  final double extentM;
  final VoidCallback? onCameraChanged;

  /// What the plat was drawn from: when it changes the cache is cut again.
  /// The studio's colony is generated once and keeps 0; a live colony grows
  /// under the view, and its host passes something that moves when a road,
  /// lot or building does.
  final int revision;

  /// A click on the plat, in colony-local metres (the live view opens the
  /// site under it).
  final void Function(double e, double n)? onTapLocal;

  /// Drawn over the plat, in its own frame: given the camera and the size,
  /// whatever the host lays on top (the live view's battle and missiles).
  final Widget Function(CityPlatCamera camera, Size size)? overlay;

  @override
  State<CityPlatView> createState() => _CityPlatViewState();
}

class _CityPlatViewState extends State<CityPlatView> {
  _PlatCache? _cache;
  int _cachedRevision = 0;
  _TrailPaint? _trails;
  _ReliefPaint? _relief;
  bool _reliefPumping = false;
  double _scaleStart = 1;
  Offset? _lastFocal;

  @override
  void dispose() {
    _cache?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sim = widget.sim;
    if (sim != null && (!identical(_cache?.sim, sim) || _cachedRevision != widget.revision)) {
      _cache?.dispose();
      _cache = _PlatCache.of(sim);
      _cachedRevision = widget.revision;
    } else if (sim == null) {
      _cache?.dispose();
      _cache = null;
    }
    // The desire paths: cut again as a leg wears them, and every few
    // seconds for the fading, which moves no revision.
    final net = sim?.trails;
    final tf = net?.field;
    final tp = _trails;
    if (net == null || tf == null) {
      _trails = null;
    } else if (tp == null ||
        !identical(tp.field, tf) ||
        tp.rev != tf.wearRev ||
        tp.tubeRev != net.tubeRev ||
        tp.age.elapsedMilliseconds > 5000) {
      _trails = _TrailPaint.of(tf, net.tubes, net.tubeRev);
    }
    // The lie of the land: sampled a few hundred points a frame until the
    // lattice is whole, then traced once.
    if (sim == null) {
      _relief = null;
    } else {
      final r = _relief;
      if (r == null || !identical(r.sim, sim)) {
        _relief = _ReliefPaint(sim, widget.extentM);
      }
      if (!_relief!.ready && !_reliefPumping) {
        _reliefPumping = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _reliefPumping = false;
          if (!mounted) return;
          final rp = _relief;
          if (rp != null && !rp.ready) setState(rp.pump);
        });
      }
    }
    return LayoutBuilder(builder: (context, constraints) {
      final size = constraints.biggest;
      final cam = widget.camera;
      if (cam.metresPerPx <= 0 && size.shortestSide > 0) {
        cam.metresPerPx = (cam.fitM / size.shortestSide).clamp(0.05, 500.0);
      }
      return Listener(
        onPointerSignal: (e) {
          if (e is PointerScrollEvent) {
            setState(() => cam.zoomAbout(
                e.scrollDelta.dy > 0 ? 1.15 : 1 / 1.15, e.localPosition, size));
            widget.onCameraChanged?.call();
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (d) {
            _scaleStart = cam.metresPerPx;
            _lastFocal = d.localFocalPoint;
          },
          onScaleUpdate: (d) {
            setState(() {
              final last = _lastFocal;
              if (last != null) {
                final delta = d.localFocalPoint - last;
                cam.centreE -= delta.dx * cam.metresPerPx;
                cam.centreN += delta.dy * cam.metresPerPx;
              }
              _lastFocal = d.localFocalPoint;
              if (d.scale != 1.0) {
                final want = (_scaleStart / d.scale).clamp(0.05, 500.0);
                cam.zoomAbout(
                    want / cam.metresPerPx, d.localFocalPoint, size);
              }
            });
            widget.onCameraChanged?.call();
          },
          onScaleEnd: (_) => _lastFocal = null,
          onTapUp: widget.onTapLocal == null
              ? null
              : (d) {
                  final p = cam.toLocal(d.localPosition, size);
                  widget.onTapLocal!(p.e, p.n);
                },
          // Its own layer: the studio's panels repaint several times a
          // second, and without the boundary every one of those repainted
          // the plat with them.
          child: Stack(children: [
            RepaintBoundary(
              child: CustomPaint(
                size: size,
                painter: _PlatPainter(
                  repaint: _cache?.imagesReady,
                  cache: _cache,
                  trails: _trails,
                  relief: _relief?.ready == true ? _relief : null,
                  centreE: cam.centreE,
                  centreN: cam.centreN,
                  metresPerPx: cam.metresPerPx,
                  extentM: widget.extentM,
                ),
              ),
            ),
            if (widget.overlay case final o?) Positioned.fill(child: IgnorePointer(child: o(cam, size))),
          ]),
        ),
      );
    });
  }
}

/// One 500 m cell of the plat at street scale: its local streets, its lot
/// fills as a triangle batch, its lot outlines by use and built state.
class _PlatCell {
  final Map<RoadClass, Path> streets = {};
  final PlatTriangles lotFill = PlatTriangles();
  final Map<(ParcelUse, bool), Path> outlines = {};
  ui.Vertices? _fill;

  /// The fills as the engine's retained vertex object, built on first
  /// draw and kept: the batch never changes once the colony is cached.
  ui.Vertices? fill() {
    if (lotFill.isEmpty) return null;
    return _fill ??= ui.Vertices.raw(ui.VertexMode.triangles, lotFill.positions,
        colors: lotFill.colors);
  }
}

/// One 2 km block at district scale: a box per lot, as a triangle batch,
/// and — once it has been asked for — the same boxes as an image the
/// block draws as a texture instead (see [PlatLayers.blockImages]).
class _PlatBlock {
  _PlatBlock(this.bounds);

  /// The block's square in the drawing plane, metres.
  final Rect bounds;
  final PlatTriangles boxes = PlatTriangles();

  /// The district-scale road classes (avenues, arterials, collectors)
  /// cut to this block, a path per class.
  final Map<RoadClass, Path> roads = {};
  ui.Vertices? _v;

  /// The image's side in pixels: 7.8 m a texel on a 2 km block, under a
  /// screen pixel at every district scale (7 to 24 m/px), and 256 KiB
  /// a block — a 32 km colony's 256 blocks are 64 MiB at most.
  static const int imagePx = 256;
  ui.Image? image;
  bool _rendering = false;

  ui.Vertices? vertices() {
    if (boxes.isEmpty) return null;
    return _v ??= ui.Vertices.raw(ui.VertexMode.triangles, boxes.positions,
        colors: boxes.colors);
  }

  /// Starts the block's image if it has none: the boxes recorded once
  /// into a picture and rasterised off this frame; [onReady] fires when
  /// the image can be drawn, and the batch draws until then.
  void render(void Function() onReady) {
    if (image != null || _rendering) return;
    final v = vertices();
    if (v == null) return;
    _rendering = true;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final scale = imagePx / bounds.width;
    canvas.scale(scale);
    canvas.translate(-bounds.left, -bounds.top);
    canvas.drawVertices(v, BlendMode.dst, Paint());
    final picture = recorder.endRecording();
    picture.toImage(imagePx, imagePx).then((img) {
      picture.dispose();
      if (_disposed) {
        img.dispose();
        return;
      }
      image = img;
      _rendering = false;
      onReady();
    });
  }

  bool _disposed = false;
  void dispose() {
    _disposed = true;
    image?.dispose();
    image = null;
  }
}

/// Everything the painter needs of a colony, derived once per colony and
/// bucketed so a frame touches only what the viewport overlaps.
class _PlatCache {
  _PlatCache._(this.sim);

  final CitySim sim;

  static const double cellM = 500;
  static const double blockM = 2000;
  static const PlatGrid grid = PlatGrid(cellM);
  static const PlatGrid blocks = PlatGrid(blockM);

  /// Street-scale cells and district-scale blocks, by grid key.
  final Map<int, _PlatCell> cells = {};
  final Map<int, _PlatBlock> blockMap = {};

  /// Fires when a block's image has been rasterised: the painter listens
  /// and repaints, drawing the image where it drew the batch.
  final ChangeNotifier imagesReady = _Notifier();

  void dispose() {
    for (final b in blockMap.values) {
      b.dispose();
    }
    imagesReady.dispose();
  }

  /// The road classes that show at county scale — highways, expressways,
  /// rail — as one path each for the whole colony: a few dozen roads, and
  /// on screen nearly whole whenever the county is. Every other class is
  /// cut to the blocks and the cells: the first cut kept avenues,
  /// arterials and collectors whole too, and stroking those few thousand
  /// roads every frame was an eleven-millisecond floor under every plat
  /// scale, whatever else was turned off.
  final Map<RoadClass, Path> majorRoads = {};

  /// Hand-placed plots (installations, stations, farms): arbitrary
  /// polygons, few, outlined at every scale.
  final Path plots = Path();

  /// The sprawl's sections as squares, with their tint.
  final List<(Rect, Color)> sections = [];

  Box2 bounds = const Box2(-2000, -2000, 2000, 2000);

  /// Street names, a piece of road each, and building names, a site each.
  final List<_StreetLabel> streetLabels = [];
  final List<_SiteLabel> siteLabels = [];

  /// Whether a class is drawn whole from [majorRoads] (the county's).
  static bool _county(RoadClass cls) => switch (cls.name) {
        'highway' || 'rail' || 'expressway' => true,
        _ => false,
      };

  /// Whether a class shows at district scale, and so is cut to the
  /// blocks as well as the cells.
  static bool _district(RoadClass cls) => switch (cls.name) {
        'avenue' || 'arterial' || 'collector' => true,
        _ => false,
      };

  static void _polyline(Path path, List<Vec2> run) {
    path.moveTo(run[0].e, run[0].n);
    for (var i = 1; i < run.length; i++) {
      path.lineTo(run[i].e, run[i].n);
    }
  }

  /// The block for a grid key, made on first touch with the square the
  /// key names. By key, not by a point: a road run's first point is the
  /// crossing point that belongs to the cell before it.
  _PlatBlock _blockForKey(int key) => blockMap.putIfAbsent(key, () {
        final (ie, iy) = PlatGrid.indices(key);
        return _PlatBlock(
            Rect.fromLTWH(ie * blockM, iy * blockM, blockM, blockM));
      });

  _PlatBlock _blockAt(double e, double y) => _blockForKey(blocks.keyOf(e, y));

  static _PlatCache of(CitySim sim) {
    final c = _PlatCache._(sim);
    var lo = double.infinity, ln = double.infinity;
    var he = -double.infinity, hn = -double.infinity;
    void grow(double e, double n) {
      if (e < lo) lo = e;
      if (n < ln) ln = n;
      if (e > he) he = e;
      if (n > hn) hn = n;
    }

    for (final r in sim.layout.roads) {
      // A road's own sampler, at a coarse step: a plat line, not a kerb.
      final pts = r.sample(stepM: 12);
      if (pts.length < 2) continue;
      for (final p in pts) {
        grow(p.e, p.n);
      }
      if (r.roadClass.carriesCars) {
        c.streetLabels.add(_StreetLabel(sim.roadNameOf(r.id), pts,
            Box2.of(pts), _county(r.roadClass) || _district(r.roadClass)));
      }
      // In the drawing plane (y = -north); a closed loop is closed by
      // hand so the cuts see its last edge.
      final plane = [for (final p in pts) Vec2(p.e, -p.n)];
      if (r.closed) plane.add(plane.first);
      if (_county(r.roadClass)) {
        _polyline(c.majorRoads.putIfAbsent(r.roadClass, Path.new), plane);
      } else if (_district(r.roadClass)) {
        for (final (key, run) in blocks.splitPolyline(plane)) {
          final block = c._blockForKey(key);
          _polyline(block.roads.putIfAbsent(r.roadClass, Path.new), run);
        }
      }
      // Every class at street scale, cut per cell.
      for (final (key, run) in grid.splitPolyline(plane)) {
        final cell = c.cells.putIfAbsent(key, _PlatCell.new);
        _polyline(cell.streets.putIfAbsent(r.roadClass, Path.new), run);
      }
    }
    for (final lot in sim.layout.parcels) {
      final poly = lot.polygon;
      if (poly.length < 3) continue;
      for (final p in poly) {
        grow(p.e, p.n);
      }
      if (lot.manual) {
        c.plots.moveTo(poly[0].e, -poly[0].n);
        for (var i = 1; i < poly.length; i++) {
          c.plots.lineTo(poly[i].e, -poly[i].n);
        }
        c.plots.close();
        continue;
      }
      final built = sim.parcelBuildings.containsKey(lot.id);
      final b = Box2.of(poly);
      final cE = (b.minE + b.maxE) / 2, cY = -(b.minN + b.maxN) / 2;
      final colour = _useColour(lot.use);
      // Street scale: the fill as triangles (a subdivided lot is a convex
      // quad, so a fan is exact) and the outline as a path by use.
      final cell = c.cells.putIfAbsent(grid.keyOf(cE, cY), _PlatCell.new);
      cell.lotFill.addFan(
          poly, colour.withValues(alpha: built ? 0.55 : 0.18).toARGB32());
      final outline =
          cell.outlines.putIfAbsent((lot.use, built), Path.new);
      outline.moveTo(poly[0].e, -poly[0].n);
      for (var i = 1; i < poly.length; i++) {
        outline.lineTo(poly[i].e, -poly[i].n);
      }
      outline.close();
      // District scale: one box per lot in its 2 km block; far cheaper
      // than the polygon and it reads the same at a few pixels.
      final block = c._blockAt(cE, cY);
      block.boxes.addRect(b.minE, -b.maxN, b.maxE, -b.minN,
          colour.withValues(alpha: 0.55).toARGB32());
    }
    // Grid-placed buildings (a colony founded from the cockpit, the flat
    // builder's utilities): their cells' parcels, filled in the use's tint.
    for (final e in sim.occupiedCells()) {
      final poly = sim.parcelForCell(e.key, e.value).polygon;
      if (poly.length < 3) continue;
      for (final p in poly) {
        grow(p.e, p.n);
      }
      final b = Box2.of(poly);
      final cE = (b.minE + b.maxE) / 2, cY = -(b.minN + b.maxN) / 2;
      final colour = Color(e.value.colorArgb);
      final cell = c.cells.putIfAbsent(grid.keyOf(cE, cY), _PlatCell.new);
      cell.lotFill.addFan(poly, colour.withValues(alpha: 0.55).toARGB32());
      c.plots.moveTo(poly[0].e, -poly[0].n);
      for (var i = 1; i < poly.length; i++) {
        c.plots.lineTo(poly[i].e, -poly[i].n);
      }
      c.plots.close();
      c._blockAt(cE, cY).boxes.addRect(b.minE, -b.maxN, b.maxE, -b.minN, colour.withValues(alpha: 0.55).toARGB32());
    }
    // What stands where, by name: what the player placed (every grown
    // house would read "Small House"), on its lot or its grid cells.
    for (final e in sim.parcelBuildings.entries) {
      final p = sim.layout.parcelById(e.key);
      if (p != null && p.polygon.length >= 3) {
        c.siteLabels.add(_SiteLabel(e.value.label, Box2.of(p.polygon)));
      }
    }
    for (final e in sim.utils.entries) {
      final poly = sim.parcelForCell(e.key, e.value).polygon;
      if (poly.length >= 3) {
        c.siteLabels.add(_SiteLabel(e.value.label, Box2.of(poly)));
      }
    }
    final plan = sim.sprawl;
    if (plan != null) {
      for (final s in plan.sections) {
        final h = s.halfM;
        c.sections.add((
          Rect.fromLTRB(s.centre.e - h, -(s.centre.n + h), s.centre.e + h,
              -(s.centre.n - h)),
          _sectionTint(s),
        ));
        grow(s.centre.e - h, s.centre.n - h);
        grow(s.centre.e + h, s.centre.n + h);
      }
    }
    if (lo.isFinite) c.bounds = Box2(lo, ln, he, hn);
    return c;
  }

  static Color _sectionTint(SprawlSection s) {
    final base = switch (s.use) {
      SprawlUse.residential => const Color(0xFF3F8F4F),
      SprawlUse.commercial => const Color(0xFF3A7BD5),
      _ => const Color(0xFFD08A2E),
    };
    return base.withValues(alpha: 0.10 + 0.25 * s.density.clamp(0.0, 1.0));
  }
}

/// A notifier the cache can fire itself: [ChangeNotifier.notifyListeners]
/// is protected.
class _Notifier extends ChangeNotifier {
  void fire() => notifyListeners();
}

Color _useColour(ParcelUse use) => switch (use) {
      ParcelUse.residential => const Color(0xFF3F8F4F),
      ParcelUse.commercial => const Color(0xFF3A7BD5),
      ParcelUse.industrial => const Color(0xFFD08A2E),
      ParcelUse.civic => const Color(0xFF9C5BD8),
      ParcelUse.utility => const Color(0xFF8A8A8A),
      ParcelUse.unzoned => const Color(0xFF3A3F45),
    };

class _PlatPainter extends CustomPainter {
  _PlatPainter({
    super.repaint,
    required this.cache,
    this.trails,
    this.relief,
    required this.centreE,
    required this.centreN,
    required this.metresPerPx,
    required this.extentM,
  });

  final _PlatCache? cache;
  final _TrailPaint? trails;
  final _ReliefPaint? relief;
  final double centreE, centreN, metresPerPx, extentM;

  static const _bg = Color(0xFF12161B);
  static const _grid = Color(0xFF1E252D);
  static const _text = Color(0xFFB8C0C8);

  /// Lot outlines are stroked only once a lot is some twenty-five pixels
  /// across: under that the fill says everything the outline would, and a
  /// stroke is the dearest thing the renderer does per lot — at 2.5 m/px
  /// the outlines of a 1.9 km viewport were most of a 12.6 ms raster
  /// frame.
  static const double outlineMetresPerPx = 1.2;

  /// The vertex batches carry their own colours; the paint is a default
  /// one and the blend takes the vertices' colour alone.
  static final Paint _vertexPaint = Paint();

  /// Block images started per frame at district scale.
  static const int imagesPerFrame = 4;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = _bg);
    final mpp = metresPerPx <= 0 ? 1.0 : metresPerPx;
    final lod = PlatLod.forScale(mpp);

    // The visible window in colony metres, for culling and the grid.
    final halfW = size.width / 2 * mpp, halfH = size.height / 2 * mpp;
    final view = Rect.fromLTRB(
        centreE - halfW, -(centreN + halfH), centreE + halfW, -(centreN - halfH));

    canvas.save();
    // Colony metres → screen: translate to the centre, scale by 1/mpp. The
    // cache already stores y = -north, so up on screen is north.
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(1 / mpp);
    canvas.translate(-centreE, centreN);
    canvas.clipRect(view);

    _paintGrid(canvas, view, mpp);

    // Contours, under everything: thin, and the index contours a shade up.
    if (relief case final r?) {
      canvas.drawPath(
          r.minor,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.8 * mpp
            ..color = const Color(0xFF26323D));
      canvas.drawPath(
          r.major,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.3 * mpp
            ..color = const Color(0xFF3A4D5E));
    }

    // Desire paths under everything built: worn ground, darker the more
    // it is worn.
    if (trails case final t?) {
      for (final (path, paint) in t.layers) {
        canvas.drawPath(path, paint);
      }
    }

    final c = cache;
    if (c != null) {
      // Sections: the sprawl's zoning, always.
      for (final (rect, tint) in c.sections) {
        if (!rect.overlaps(view)) continue;
        canvas.drawRect(rect, Paint()..color = tint);
        canvas.drawRect(
            rect,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5 * mpp
              ..color = tint.withValues(alpha: 0.6));
      }

      // Lots. At district scale a box per lot from the blocks under the
      // view; at street scale the fills, the outlines once they are big
      // enough, and the local streets, from the cells under the view and
      // the ring around it (a lot sits in the cell of its centre).
      if (lod == PlatLod.district) {
        final imagePaint = Paint()..filterQuality = FilterQuality.low;
        final roadPaints = <RoadClass, Paint>{};
        // Images are started a few a frame: the first district frame
        // over a whole colony asked for eighty at once, and the burst of
        // rasterising them read as a 200 ms frame. A block whose image is
        // not ready draws nothing yet — its section tint is already
        // under it — and pops in over the next few frames, as a map does.
        var started = 0;
        for (final key in _PlatCache.blocks
            .keysIn(view.left, view.top, view.right, view.bottom)) {
          final block = c.blockMap[key];
          if (block == null) continue;
          if (PlatLayers.blockImages) {
            final img = block.image;
            if (img != null) {
              canvas.drawImageRect(
                  img,
                  Rect.fromLTWH(0, 0, _PlatBlock.imagePx.toDouble(),
                      _PlatBlock.imagePx.toDouble()),
                  block.bounds,
                  imagePaint);
            } else if (started < imagesPerFrame) {
              started++;
              block.render((c.imagesReady as _Notifier).fire);
            }
          } else {
            final v = block.vertices();
            if (v != null) {
              canvas.drawVertices(v, BlendMode.dst, _vertexPaint);
            }
          }
          for (final e in block.roads.entries) {
            canvas.drawPath(e.value,
                roadPaints.putIfAbsent(e.key, () => _roadPaint(e.key, mpp)));
          }
        }
      } else if (lod == PlatLod.street) {
        final outlines = mpp <= outlineMetresPerPx;
        final outlinePaints = <(ParcelUse, bool), Paint>{};
        final streetPaints = <RoadClass, Paint>{};
        for (final key in _PlatCache.grid
            .keysIn(view.left, view.top, view.right, view.bottom, margin: 1)) {
          final cell = c.cells[key];
          if (cell == null) continue;
          final fill = PlatLayers.fills ? cell.fill() : null;
          if (fill != null) {
            canvas.drawVertices(fill, BlendMode.dst, _vertexPaint);
          }
          if (outlines && PlatLayers.outlines) {
            for (final e in cell.outlines.entries) {
              final (use, built) = e.key;
              final paint = outlinePaints.putIfAbsent(
                  e.key,
                  () => Paint()
                    ..style = PaintingStyle.stroke
                    ..strokeJoin = StrokeJoin.bevel
                    ..strokeWidth = 0.6 * mpp
                    ..color = _useColour(use)
                        .withValues(alpha: built ? 0.9 : 0.45));
              canvas.drawPath(e.value, paint);
            }
          }
          if (!PlatLayers.streets) continue;
          for (final e in cell.streets.entries) {
            final cls = e.key;
            canvas.drawPath(
                e.value,
                streetPaints.putIfAbsent(cls, () => _roadPaint(cls, mpp)));
          }
        }
      }
      // Hand-placed plots: outlined in purple at every scale.
      canvas.drawPath(
          c.plots, Paint()..color = const Color(0xFF9C5BD8).withValues(alpha: 0.25));
      canvas.drawPath(
          c.plots,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5 * mpp
            ..color = const Color(0xFFC79BF0));

      // The county's roads, whole, at county and district scale; at
      // street scale the cells carry them.
      if (lod != PlatLod.street) {
        for (final e in c.majorRoads.entries) {
          canvas.drawPath(e.value, _roadPaint(e.key, mpp));
        }
      }
    }

    // Pedestrian tubes, over everything on the ground: they stand over it.
    if (trails case final t? when t.tubes != null) {
      canvas.drawPath(
          t.tubes!,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..strokeWidth = math.max(4.0, 3.0 * mpp)
            ..color = const Color(0xCC9FE8F0));
    }

    // The site's origin: the colony centre.
    final cross = 6 * mpp;
    final origin = Paint()
      ..color = const Color(0xFF7FE0FF)
      ..strokeWidth = 1.2 * mpp;
    canvas.drawLine(Offset(-cross, 0), Offset(cross, 0), origin);
    canvas.drawLine(Offset(0, -cross), Offset(0, cross), origin);
    canvas.restore();

    final placed = <Rect>[];
    if (c != null) _paintLabels(canvas, size, mpp, lod, c, view, placed);
    if (relief case final r?) _paintHeights(canvas, size, mpp, r, view, placed);
    _paintScaleBar(canvas, size, mpp, lod, c);
  }

  /// A road's stroke: widths are the real carriageway, floored to a pixel
  /// so a street never vanishes at the scale it is drawn at. Butt caps and
  /// bevel joins: a round join is a fan of triangles at every one of a
  /// street's twelve-metre samples, and at plat scale the difference is
  /// invisible.
  static Paint _roadPaint(RoadClass cls, double mpp) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.butt
    ..strokeJoin = StrokeJoin.bevel
    ..strokeWidth = math.max(cls.width, _minRoadPx(cls) * mpp)
    ..color = _roadColour(cls);

  static double _minRoadPx(RoadClass cls) => switch (cls.name) {
        'highway' || 'expressway' => 2.5,
        'rail' => 1.5,
        'avenue' || 'arterial' || 'collector' => 1.5,
        _ => 1.0,
      };

  static Color _roadColour(RoadClass cls) => switch (cls.name) {
        'highway' || 'expressway' => const Color(0xFFF2F2F2),
        'avenue' || 'arterial' || 'collector' => const Color(0xFFD0D0D0),
        'rail' => const Color(0xFFE0C060),
        'path' => const Color(0xFF8B6B3E),
        _ => const Color(0xFF9A9A9A),
      };

  void _paintGrid(Canvas canvas, Rect view, double mpp) {
    // A line every kilometre once a kilometre is more than 40 px, else
    // every 5 km; nothing when even that is dense.
    final pitch = mpp < 25 ? 1000.0 : (mpp < 125 ? 5000.0 : 0.0);
    if (pitch <= 0) return;
    final paint = Paint()
      ..color = _grid
      ..strokeWidth = 1.0 * mpp;
    final e0 = (view.left / pitch).floor() * pitch;
    for (var e = e0; e <= view.right; e += pitch) {
      canvas.drawLine(Offset(e, view.top), Offset(e, view.bottom), paint);
    }
    final n0 = (view.top / pitch).floor() * pitch;
    for (var n = n0; n <= view.bottom; n += pitch) {
      canvas.drawLine(Offset(view.left, n), Offset(view.right, n), paint);
    }
  }

  /// Colony metres to this frame's screen pixels.
  Offset _screen(double e, double n, Size size, double mpp) => Offset(
      (e - centreE) / mpp + size.width / 2,
      (centreN - n) / mpp + size.height / 2);

  static bool _inView(Box2 b, Rect view) =>
      b.maxE >= view.left &&
      b.minE <= view.right &&
      -b.minN >= view.top &&
      -b.maxN <= view.bottom;

  static bool _free(List<Rect> placed, Rect r) {
    for (final p in placed) {
      if (p.overlaps(r)) return false;
    }
    placed.add(r);
    return true;
  }

  /// Building names on their sites and street names along their roads, in
  /// screen space so they read the same at every zoom: a name is drawn
  /// only where it fits, and never over another ([placed]).
  void _paintLabels(Canvas canvas, Size size, double mpp, PlatLod lod,
      _PlatCache c, Rect view, List<Rect> placed) {
    // Sites first: a building's name is the more useful of the two.
    for (final l in c.siteLabels) {
      final b = l.box;
      if (!_inView(b, view)) continue;
      final tp = _Labels.of(l.text, 11.5, const Color(0xFFE8DDF5), bold: true);
      final wPx = (b.maxE - b.minE) / mpp, hPx = (b.maxN - b.minN) / mpp;
      if (tp.width + 8 > wPx || tp.height + 4 > hPx) continue;
      final at =
          _screen((b.minE + b.maxE) / 2, (b.minN + b.maxN) / 2, size, mpp);
      final r = Rect.fromCenter(
          center: at, width: tp.width + 6, height: tp.height + 2);
      if (!_free(placed, r)) continue;
      final o = at - Offset(tp.width / 2, tp.height / 2);
      _Labels.of(l.text, 11.5, null, bold: true).paint(canvas, o);
      tp.paint(canvas, o);
    }

    // Streets: at street scale every road, at district scale the larger
    // ones; along the road at its middle, turned to read left to right.
    if (lod == PlatLod.county) return;
    final seen = <String, List<Offset>>{};
    for (final l in c.streetLabels) {
      if (lod == PlatLod.district && !l.major) continue;
      if (!_inView(l.box, view)) continue;
      final tp = _Labels.of(l.text, 10.5, const Color(0xFFCFD6DD));
      final needM = (tp.width + 16) * mpp;
      if (l.lengthM < needM) continue;
      final mid = _along(l.points, l.lengthM / 2);
      final at = _screen(mid.e, mid.n, size, mpp);
      if (at.dx < 0 || at.dy < 0 || at.dx > size.width || at.dy > size.height) {
        continue;
      }
      // One label a name per 280 px: a long road cut into pieces at every
      // junction says what it is called once a screenful, not at each.
      final others = seen[l.text];
      if (others != null && others.any((o) => (o - at).distance < 280)) {
        continue;
      }
      final a = _along(l.points, l.lengthM / 2 - needM / 2);
      final z = _along(l.points, l.lengthM / 2 + needM / 2);
      var angle = math.atan2(-(z.n - a.n), z.e - a.e);
      if (angle > math.pi / 2) angle -= math.pi;
      if (angle < -math.pi / 2) angle += math.pi;
      final r = Rect.fromCenter(
          center: at,
          width: tp.width * math.cos(angle).abs() + tp.height,
          height: tp.width * math.sin(angle).abs() + tp.height);
      if (!_free(placed, r)) continue;
      (seen[l.text] ??= []).add(at);
      canvas.save();
      canvas.translate(at.dx, at.dy);
      canvas.rotate(angle);
      final o = Offset(-tp.width / 2, -tp.height / 2);
      _Labels.of(l.text, 10.5, null).paint(canvas, o);
      tp.paint(canvas, o);
      canvas.restore();
    }
  }

  /// The point [s] metres along [pts], clamped to its ends.
  static Vec2 _along(List<Vec2> pts, double s) {
    if (s <= 0) return pts.first;
    var acc = 0.0;
    for (var k = 1; k < pts.length; k++) {
      final d = pts[k].distanceTo(pts[k - 1]);
      if (acc + d >= s) {
        final t = d <= 0 ? 0.0 : (s - acc) / d;
        return Vec2(pts[k - 1].e + (pts[k].e - pts[k - 1].e) * t,
            pts[k - 1].n + (pts[k].n - pts[k - 1].n) * t);
      }
      acc += d;
    }
    return pts.last;
  }

  /// The heights of the index contours, a few to a screen: what the lines
  /// mean, without a legend.
  void _paintHeights(Canvas canvas, Size size, double mpp, _ReliefPaint r,
      Rect view, List<Rect> placed) {
    final mine = <Offset>[];
    for (final c in r.contours) {
      if (!c.major) continue;
      final segs = c.segments;
      var drawn = 0;
      for (var k = 0; k + 3 < segs.length && drawn < 3; k += 4) {
        final e = (segs[k] + segs[k + 2]) / 2, n = (segs[k + 1] + segs[k + 3]) / 2;
        if (e < view.left || e > view.right || -n < view.top || -n > view.bottom) {
          continue;
        }
        final at = _screen(e, n, size, mpp);
        if (mine.any((o) => (o - at).distance < 240)) continue;
        final text = '${c.level.round()} m';
        final tp = _Labels.of(text, 9.5, const Color(0xFF6F8494));
        final rect = Rect.fromCenter(
            center: at, width: tp.width + 4, height: tp.height + 2);
        if (!_free(placed, rect)) continue;
        mine.add(at);
        drawn++;
        final o = at - Offset(tp.width / 2, tp.height / 2);
        _Labels.of(text, 9.5, null).paint(canvas, o);
        tp.paint(canvas, o);
      }
    }
  }

  void _paintScaleBar(
      Canvas canvas, Size size, double mpp, PlatLod lod, _PlatCache? c) {
    // A round length that is 80–200 px wide.
    const steps = [10.0, 20.0, 50.0, 100.0, 200.0, 500.0, 1000.0, 2000.0, 5000.0, 10000.0, 20000.0];
    var barM = steps.last;
    for (final s in steps) {
      if (s / mpp >= 80) {
        barM = s;
        break;
      }
    }
    final barPx = barM / mpp;
    final y = size.height - 18.0;
    final p = Paint()
      ..color = _text
      ..strokeWidth = 2;
    canvas.drawLine(Offset(12, y), Offset(12 + barPx, y), p);
    canvas.drawLine(Offset(12, y - 5), Offset(12, y + 5), p);
    canvas.drawLine(Offset(12 + barPx, y - 5), Offset(12 + barPx, y + 5), p);
    final label = barM >= 1000
        ? '${(barM / 1000).toStringAsFixed(barM % 1000 == 0 ? 0 : 1)} km'
        : '${barM.round()} m';
    final counts = c == null
        ? 'no colony'
        : '${c.sim.layout.roads.length} roads · '
            '${c.sim.layout.parcels.length} lots · '
            '${c.sim.parcelBuildings.length} built';
    _text_(canvas, '$label   ${mpp.toStringAsFixed(mpp < 1 ? 2 : 1)} m/px   '
        '${lod.name}   $counts', Offset(12, y - 22));
  }

  void _text_(Canvas canvas, String s, Offset at) {
    final tp = TextPainter(
      text: TextSpan(
          text: s,
          style: AppTheme.mono.copyWith(fontSize: 11, color: _text)),
      textDirection: ui.TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_PlatPainter old) =>
      !identical(old.cache, cache) ||
      !identical(old.trails, trails) ||
      !identical(old.relief, relief) ||
      old.centreE != centreE ||
      old.centreN != centreN ||
      old.metresPerPx != metresPerPx ||
      old.extentM != extentM;
}

/// A colony's desire paths as a few filled paths, one per band of wear
/// (docs/plans/desire-paths.md §7 "Plat"): a cell a square, in the cache's
/// y = −north frame.
class _TrailPaint {
  _TrailPaint._(this.field, this.rev, this.layers, this.tubes, this.tubeRev);

  final TrailField field;
  final int rev;
  final List<(Path, Paint)> layers;

  /// The pedestrian tubes as one path, or null with none; and the revision
  /// they were cut at.
  final Path? tubes;
  final int tubeRev;
  final Stopwatch age = Stopwatch()..start();

  /// Wear below this is ground a rover or two has crossed, not a trail.
  static const double _faint = 0.12;
  static const _bands = [0.3, 0.55, 0.8, 1.01];
  static const _colour = Color(0xFFB08A5A);

  static _TrailPaint of(TrailField f, List<List<Vec2>> tubeLines, int tubeRev) {
    final paths = [for (final _ in _bands) Path()];
    final foot = Path();
    final cell = f.cellM;
    for (var i = 0; i < f.length; i++) {
      final w = f.wear[i];
      final e0 = f.originE + (i % f.cols) * cell;
      final n1 = f.originN + (i ~/ f.cols + 1) * cell;
      // Walkers' tracks, fainter and paler, where no rover has worn more.
      if (w < _faint) {
        if (f.footWear[i] >= 0.3 && !f.tube(i)) {
          foot.addRect(Rect.fromLTWH(e0, -n1, cell, cell));
        }
        continue;
      }
      var b = 0;
      while (w >= _bands[b]) {
        b++;
      }
      paths[b].addRect(Rect.fromLTWH(e0, -n1, cell, cell));
    }
    Path? tubes;
    for (final t in tubeLines) {
      if (t.length < 2) continue;
      final p = tubes ??= Path();
      p.moveTo(t.first.e, -t.first.n);
      for (var k = 1; k < t.length; k++) {
        p.lineTo(t[k].e, -t[k].n);
      }
    }
    return _TrailPaint._(f, f.wearRev, [
      (foot, Paint()..color = const Color(0x40C8D2DC)),
      for (var b = 0; b < _bands.length; b++)
        (
          paths[b],
          Paint()..color = _colour.withValues(alpha: 0.18 + 0.16 * b),
        ),
    ], tubes, tubeRev);
  }
}

/// A piece of road's name, where it runs, and whether it is a road of the
/// district scale (its name shows further out).
class _StreetLabel {
  _StreetLabel(this.text, this.points, this.box, this.major)
      : lengthM = _lengthOf(points);

  final String text;
  final List<Vec2> points;
  final Box2 box;
  final bool major;
  final double lengthM;

  static double _lengthOf(List<Vec2> pts) {
    var s = 0.0;
    for (var k = 1; k < pts.length; k++) {
      s += pts[k].distanceTo(pts[k - 1]);
    }
    return s;
  }
}

/// A placed building's name and the box of its site.
class _SiteLabel {
  const _SiteLabel(this.text, this.box);
  final String text;
  final Box2 box;
}

/// Laid-out names, kept: a label is laid out once, not every frame. A null
/// colour is the dark halo drawn under the text.
abstract final class _Labels {
  static final Map<(String, double, int?, bool), TextPainter> _cache = {};

  static TextPainter of(String text, double size, Color? colour,
      {bool bold = false}) {
    final key = (text, size, colour?.toARGB32(), bold);
    final hit = _cache[key];
    if (hit != null) return hit;
    if (_cache.length > 600) {
      for (final tp in _cache.values) {
        tp.dispose();
      }
      _cache.clear();
    }
    final base = TextStyle(
      fontSize: size,
      fontWeight: bold ? FontWeight.w600 : FontWeight.w400,
      letterSpacing: 0.2,
    );
    final style = colour != null
        ? base.copyWith(color: colour)
        : base.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3
              ..strokeJoin = StrokeJoin.round
              ..color = const Color(0xE612161B));
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: ui.TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return _cache[key] = tp;
  }
}

/// A colony's contours for the plat, sampled a budget a frame
/// ([ReliefGrid.fill]) and traced once the lattice is whole.
class _ReliefPaint {
  _ReliefPaint(this.sim, double extentM)
      : grid = ReliefGrid.around(0, 0,
            halfM: math.max(extentM, 1500) + 500,
            stepM: math.max(40.0, 2 * (math.max(extentM, 1500) + 500) / 160)),
        _ground = sim.naturalGround();

  final CitySim sim;
  final ReliefGrid grid;
  final double Function(double e, double n) _ground;

  /// Lattice points sampled a frame: some 5 ms of relief.
  static const int budget = 300;

  final Path minor = Path(), major = Path();
  List<Contour> contours = const [];
  bool ready = false;

  void pump() {
    if (ready) return;
    if (!grid.fill(_ground, budget)) return;
    contours = contoursOf(grid);
    for (final c in contours) {
      final path = c.major ? major : minor;
      final s = c.segments;
      for (var k = 0; k + 3 < s.length; k += 4) {
        path
          ..moveTo(s[k], -s[k + 1])
          ..lineTo(s[k + 2], -s[k + 3]);
      }
    }
    ready = true;
  }
}
