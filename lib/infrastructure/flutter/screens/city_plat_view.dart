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
/// Scale: a colony can carry a hundred thousand lots, and stroking every one
/// every frame is not on. Two things keep it cheap. Zoom LOD: lots only draw
/// once a lot is a few pixels across, local streets once they are a pixel
/// wide, and the sections (a few hundred) always. And a cache per colony —
/// roads sampled once, parcel outlines batched into one path per use and
/// built state, section rectangles — so a frame is a transform and a handful
/// of path draws, not a walk of the plat.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../domain/colony/city/city_sim.dart';
import '../../../domain/colony/city/parcel.dart';
import '../../../domain/colony/city/spatial_index.dart';
import '../../../domain/colony/city/sprawl_plan.dart';
import 'app_theme.dart';

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

class CityPlatView extends StatefulWidget {
  const CityPlatView({
    super.key,
    required this.sim,
    required this.camera,
    this.extentM = 4000,
    this.onCameraChanged,
  });

  /// The colony, or null before one exists.
  final CitySim? sim;
  final CityPlatCamera camera;

  /// The core's extent, for the first fit and the grid pitch.
  final double extentM;
  final VoidCallback? onCameraChanged;

  @override
  State<CityPlatView> createState() => _CityPlatViewState();
}

class _CityPlatViewState extends State<CityPlatView> {
  _PlatCache? _cache;
  double _scaleStart = 1;
  Offset? _lastFocal;

  @override
  Widget build(BuildContext context) {
    final sim = widget.sim;
    if (sim != null && !identical(_cache?.sim, sim)) {
      _cache = _PlatCache.of(sim);
    } else if (sim == null) {
      _cache = null;
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
          child: CustomPaint(
            size: size,
            painter: _PlatPainter(
              cache: _cache,
              centreE: cam.centreE,
              centreN: cam.centreN,
              metresPerPx: cam.metresPerPx,
              extentM: widget.extentM,
            ),
          ),
        ),
      );
    });
  }
}

/// Everything the painter needs of a colony, derived once per colony.
class _PlatCache {
  _PlatCache._(this.sim);

  final CitySim sim;

  /// Road centrelines by class, as one path each, in colony metres with north
  /// up (y = -n; the painter flips the canvas).
  final Map<RoadClass, Path> roads = {};

  /// Lot outlines batched by use and by whether something stands on them.
  final Map<(ParcelUse, bool), Path> lots = {};

  /// Hand-placed plots (installations, stations, farms).
  final Path plots = Path();

  /// The sprawl's sections as squares, with their tint.
  final List<(Rect, Color)> sections = [];

  /// Lot bounding boxes, for the block tint at district scale: one filled
  /// rectangle per lot is far cheaper than its polygon and reads the same
  /// at a few pixels.
  final Map<ParcelUse, List<Rect>> lotBoxes = {};

  Box2 bounds = const Box2(-2000, -2000, 2000, 2000);

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
      final path = c.roads.putIfAbsent(r.roadClass, Path.new);
      path.moveTo(pts[0].e, -pts[0].n);
      for (var i = 1; i < pts.length; i++) {
        path.lineTo(pts[i].e, -pts[i].n);
      }
      if (r.closed) path.close();
      for (final p in pts) {
        grow(p.e, p.n);
      }
    }
    for (final lot in sim.layout.parcels) {
      final poly = lot.polygon;
      if (poly.length < 3) continue;
      final built = sim.parcelBuildings.containsKey(lot.id);
      final path = lot.manual
          ? c.plots
          : c.lots.putIfAbsent((lot.use, built), Path.new);
      path.moveTo(poly[0].e, -poly[0].n);
      for (var i = 1; i < poly.length; i++) {
        path.lineTo(poly[i].e, -poly[i].n);
      }
      path.close();
      if (!lot.manual) {
        final b = Box2.of(poly);
        (c.lotBoxes[lot.use] ??= []).add(
            Rect.fromLTRB(b.minE, -b.maxN, b.maxE, -b.minN));
      }
      for (final p in poly) {
        grow(p.e, p.n);
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
    required this.cache,
    required this.centreE,
    required this.centreN,
    required this.metresPerPx,
    required this.extentM,
  });

  final _PlatCache? cache;
  final double centreE, centreN, metresPerPx, extentM;

  static const _bg = Color(0xFF12161B);
  static const _grid = Color(0xFF1E252D);
  static const _text = Color(0xFFB8C0C8);

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

      // Lots. At district scale a filled box per lot; at street scale the
      // outline and the fill, built lots solid and empty ones faint.
      if (lod == PlatLod.district) {
        for (final e in c.lotBoxes.entries) {
          final paint = Paint()..color = _useColour(e.key).withValues(alpha: 0.55);
          for (final r in e.value) {
            if (r.overlaps(view)) canvas.drawRect(r, paint);
          }
        }
      } else if (lod == PlatLod.street) {
        for (final e in c.lots.entries) {
          final (use, built) = e.key;
          final colour = _useColour(use);
          canvas.drawPath(
              e.value,
              Paint()..color = colour.withValues(alpha: built ? 0.55 : 0.18));
          canvas.drawPath(
              e.value,
              Paint()
                ..style = PaintingStyle.stroke
                ..strokeWidth = 0.6 * mpp
                ..color = colour.withValues(alpha: built ? 0.9 : 0.45));
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

      // Roads, by class: widths are the real carriageway, floored to a
      // pixel so a street never vanishes at the scale it is drawn at.
      for (final e in c.roads.entries) {
        final cls = e.key;
        if (!_roadVisible(cls, lod)) continue;
        final width = math.max(cls.width, _minRoadPx(cls) * mpp);
        canvas.drawPath(
            e.value,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round
              ..strokeWidth = width
              ..color = _roadColour(cls));
      }
    }

    // The site's origin: the colony centre.
    final cross = 6 * mpp;
    final origin = Paint()
      ..color = const Color(0xFF7FE0FF)
      ..strokeWidth = 1.2 * mpp;
    canvas.drawLine(Offset(-cross, 0), Offset(cross, 0), origin);
    canvas.drawLine(Offset(0, -cross), Offset(0, cross), origin);
    canvas.restore();

    _paintScaleBar(canvas, size, mpp, lod, c);
  }

  static bool _roadVisible(RoadClass cls, PlatLod lod) => switch (cls.name) {
        'highway' || 'rail' || 'expressway' => true,
        'avenue' || 'arterial' || 'collector' => lod != PlatLod.county,
        _ => lod == PlatLod.street,
      };

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
        'dirt' => const Color(0xFF8B6B3E),
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
      old.centreE != centreE ||
      old.centreN != centreN ||
      old.metresPerPx != metresPerPx ||
      old.extentM != extentM;
}
