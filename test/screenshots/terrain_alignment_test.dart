// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Registration diagnostic for the three Moon surface data sources:
//
//   1. the baked DEM pyramid   (assets/terrain/moon.acrodem, cubed-sphere)
//   2. the runtime TerrainField (procedural — what meshing + collision use)
//   3. the baked albedo map    (assets/terrain/moon.acroalb, equirectangular)
//
// Writes test_out/terrain_alignment_moon.png: four equirectangular panels on
// a shared lat/lon grid — DEM hillshade, field height, albedo sampled through
// THE SHADER'S OWN uv formula (terrain.frag, meridian=+X pole=+Z east=+Y),
// and albedo with DEM contours overlaid. Every panel carries the same
// lon0/lat0 crosshair and landmark crosses (Crisium, Tycho, Copernicus), so a
// frame mismatch shows as crosses/contours sitting off their features.
//
// Automated checks (skipped when the baked assets are absent):
//   - DEM-vs-albedo height/brightness correlation must beat the same
//     correlation with the albedo mirrored in lon and flipped in lat — a sign
//     or axis error in either mapping fails this.
//   - Mare Crisium must be lower AND darker than the southern highlands.
//
// The TerrainField panel rides the registered DEM (base relief + a
// DemDerivedControl detail layer), so its correlation with the raw DEM is
// asserted high — this is the regression gate for the registry wiring.
//
//   flutter test test/screenshots/terrain_alignment_test.dart

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/dem_pyramid.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

import '../helpers/register_baked_dems.dart';

const int panelW = 1024, panelH = 512;
const int fieldW = 512, fieldH = 256; // field sampling is the expensive one

/// Body-fixed direction for a latitude/longitude — the SAME convention
/// tool/bake_dem.dart bakes with: +Z pole, lon 0 along +X, east +Y.
Vector3 _dir(double lat, double lon) => Vector3(
    math.cos(lat) * math.cos(lon),
    math.cos(lat) * math.sin(lon),
    math.sin(lat));

/// Decoded .acroalb map with the shader's sampling semantics: bilinear,
/// longitude wraps, latitude clamps.
class _AlbedoMap {
  _AlbedoMap(this.w, this.h, this.rgb);
  final int w, h;
  final Uint8List rgb; // w*h*3, row 0 = north

  static _AlbedoMap? load(String path) {
    final f = File(path);
    if (!f.existsSync()) return null;
    final bytes = f.readAsBytesSync();
    final view = ByteData.sublistView(bytes);
    if (view.lengthInBytes < 16 ||
        view.getUint32(0) != 0x4143524F ||
        view.getUint32(4) != 0x414C4201) {
      return null;
    }
    final w = view.getUint32(8), h = view.getUint32(12);
    if (bytes.length < 16 + w * h * 3) return null;
    return _AlbedoMap(w, h, Uint8List.sublistView(bytes, 16, 16 + w * h * 3));
  }

  /// Sample along a body-fixed direction using terrain.frag's uv math
  /// verbatim (lon = atan2(dot(up,east), dot(up,mer)) with mer=+X, east=+Y).
  (double, double, double) sampleDir(Vector3 up) {
    final sinLat = up.z.clamp(-1.0, 1.0);
    final lat = math.asin(sinLat);
    final lon = math.atan2(up.y, up.x);
    final u = lon / (2 * math.pi) + 0.5;
    final v = 0.5 - lat / math.pi;
    return _bilinear(u, v);
  }

  (double, double, double) _bilinear(double u, double v) {
    final x = u * w - 0.5, y = (v * h - 0.5).clamp(0.0, h - 1.0);
    final x0 = x.floor(), y0 = y.floor();
    final fx = x - x0, fy = y - y0;
    final y1 = math.min(y0 + 1, h - 1);
    int wrap(int xi) => ((xi % w) + w) % w; // lon wraps at the +/-180 seam
    double at(int xi, int yi, int c) => rgb[(yi * w + wrap(xi)) * 3 + c] / 255.0;
    double ch(int c) =>
        (at(x0, y0, c) * (1 - fx) + at(x0 + 1, y0, c) * fx) * (1 - fy) +
        (at(x0, y1, c) * (1 - fx) + at(x0 + 1, y1, c) * fx) * fy;
    return (ch(0), ch(1), ch(2));
  }

  double lumDir(Vector3 up) {
    final (r, g, b) = sampleDir(up);
    return (r + g + b) / 3.0;
  }
}

/// 5x7 bitmap glyphs — flutter_test's bundled font draws boxes, so panel
/// labels are painted as pixels instead of text.
const Map<String, List<String>> _glyphs = {
  'A': ['.XXX.', 'X...X', 'X...X', 'XXXXX', 'X...X', 'X...X', 'X...X'],
  'B': ['XXXX.', 'X...X', 'X...X', 'XXXX.', 'X...X', 'X...X', 'XXXX.'],
  'D': ['XXXX.', 'X...X', 'X...X', 'X...X', 'X...X', 'X...X', 'XXXX.'],
  'E': ['XXXXX', 'X....', 'X....', 'XXXX.', 'X....', 'X....', 'XXXXX'],
  'F': ['XXXXX', 'X....', 'X....', 'XXXX.', 'X....', 'X....', 'X....'],
  'I': ['XXXXX', '..X..', '..X..', '..X..', '..X..', '..X..', 'XXXXX'],
  'L': ['X....', 'X....', 'X....', 'X....', 'X....', 'X....', 'XXXXX'],
  'M': ['X...X', 'XX.XX', 'X.X.X', 'X...X', 'X...X', 'X...X', 'X...X'],
  'O': ['.XXX.', 'X...X', 'X...X', 'X...X', 'X...X', 'X...X', '.XXX.'],
  'R': ['XXXX.', 'X...X', 'X...X', 'XXXX.', 'X.X..', 'X..X.', 'X...X'],
  'V': ['X...X', 'X...X', 'X...X', 'X...X', 'X...X', '.X.X.', '..X..'],
  'Y': ['X...X', 'X...X', '.X.X.', '..X..', '..X..', '..X..', '..X..'],
  ' ': ['.....', '.....', '.....', '.....', '.....', '.....', '.....'],
};

class _Panel {
  _Panel() : px = Uint8List(panelW * panelH * 4);
  final Uint8List px;

  void set(int x, int y, int r, int g, int b) {
    if (x < 0 || y < 0 || x >= panelW || y >= panelH) return;
    final i = (y * panelW + x) * 4;
    px[i] = r;
    px[i + 1] = g;
    px[i + 2] = b;
    px[i + 3] = 255;
  }

  void label(String text) {
    const scale = 3, ox = 10, oy = 10;
    for (var ci = 0; ci < text.length; ci++) {
      final rows = _glyphs[text[ci]]!;
      for (var gy = 0; gy < 7; gy++) {
        for (var gx = 0; gx < 5; gx++) {
          if (rows[gy][gx] != 'X') continue;
          for (var sy = 0; sy < scale; sy++) {
            for (var sx = 0; sx < scale; sx++) {
              set(ox + (ci * 6 + gx) * scale + sx, oy + gy * scale + sy,
                  255, 220, 40);
            }
          }
        }
      }
    }
  }

  /// lon=0 meridian + equator, faint blue — a shared registration reference.
  void crosshair() {
    for (var x = 0; x < panelW; x++) {
      set(x, panelH ~/ 2, 70, 120, 255);
    }
    for (var y = 0; y < panelH; y++) {
      set(panelW ~/ 2, y, 70, 120, 255);
    }
  }

  /// Magenta cross at a landmark's equirect position.
  void mark(double latDeg, double lonDeg) {
    final x = ((lonDeg / 360.0 + 0.5) * panelW).round();
    final y = ((0.5 - latDeg / 180.0) * panelH).round();
    for (var d = -6; d <= 6; d++) {
      set(x + d, y, 255, 0, 255);
      set(x, y + d, 255, 0, 255);
    }
  }
}

Future<ui.Image> _toImage(Uint8List rgba, int w, int h) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, w, h, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

/// Weighted Pearson correlation, cos(lat)-weighted so the over-sampled polar
/// rows of the equirect grid don't dominate.
double _pearson(List<double> a, List<double> b, List<double> wgt) {
  var sw = 0.0, ma = 0.0, mb = 0.0;
  for (var i = 0; i < a.length; i++) {
    sw += wgt[i];
    ma += wgt[i] * a[i];
    mb += wgt[i] * b[i];
  }
  ma /= sw;
  mb /= sw;
  var cab = 0.0, caa = 0.0, cbb = 0.0;
  for (var i = 0; i < a.length; i++) {
    final da = a[i] - ma, db = b[i] - mb;
    cab += wgt[i] * da * db;
    caa += wgt[i] * da * da;
    cbb += wgt[i] * db * db;
  }
  final d = math.sqrt(caa * cbb);
  return d > 0 ? cab / d : 0.0;
}

// Landmarks (lat deg, lon deg east). Crisium: dark mare basin. Southern
// highlands: bright, high. Tycho/Copernicus: bright ray craters — easy to
// eyeball against the crosses.
const _crisium = (17.0, 59.1);
const _highlands = (-30.0, 15.0);
const _tycho = (-43.31, -11.36);
const _copernicus = (9.62, -20.08);

void main() {
  test('moon DEM / terrain field / albedo registration', () async {
    final dem = () {
      final f = File('assets/terrain/moon.acrodem');
      return f.existsSync() ? DemPyramid.decode(f.readAsBytesSync()) : null;
    }();
    final alb = _AlbedoMap.load('assets/terrain/moon.acroalb');
    if (dem == null || alb == null) {
      markTestSkipped('run tool/bake_dem.dart + tool/bake_albedo.dart first');
      return;
    }

    registerBakedDemsForTest();
    final moon = RealSolarSystem.build().require(const BodyId('moon'));
    final field = moon.terrainFieldWith(null)!;

    // ---- DEM height grid + hillshaded panel --------------------------------
    final demH = Float32List(panelW * panelH);
    for (var y = 0; y < panelH; y++) {
      final lat = (0.5 - (y + 0.5) / panelH) * math.pi;
      for (var x = 0; x < panelW; x++) {
        final lon = ((x + 0.5) / panelW - 0.5) * 2 * math.pi;
        demH[y * panelW + x] = dem.elevationAt(_dir(lat, lon)).toDouble();
      }
    }
    final demPanel = _Panel();
    final span = math.max(dem.maxElevM - dem.minElevM, 1.0);
    for (var y = 0; y < panelH; y++) {
      for (var x = 0; x < panelW; x++) {
        final h = demH[y * panelW + x];
        final t = ((h - dem.minElevM) / span).clamp(0.0, 1.0);
        final hx = demH[y * panelW + math.min(x + 1, panelW - 1)] -
            demH[y * panelW + math.max(x - 1, 0)];
        final hy = demH[math.min(y + 1, panelH - 1) * panelW + x] -
            demH[math.max(y - 1, 0) * panelW + x];
        // Light from the north-west, strength scaled to the texel footprint.
        final shade = (1.0 - (hx + hy) * 4e-4).clamp(0.55, 1.45);
        final g = ((0.2 + 0.8 * t) * shade * 255).clamp(0.0, 255.0).round();
        demPanel.set(x, y, g, g, g);
      }
    }

    // ---- TerrainField height panel (coarser grid, upscaled on compose) -----
    final fldH = Float32List(fieldW * fieldH);
    var fMin = double.infinity, fMax = double.negativeInfinity;
    for (var y = 0; y < fieldH; y++) {
      final lat = (0.5 - (y + 0.5) / fieldH) * math.pi;
      for (var x = 0; x < fieldW; x++) {
        final lon = ((x + 0.5) / fieldW - 0.5) * 2 * math.pi;
        final d = _dir(lat, lon);
        final h = field.heightInDirection(d.x, d.y, d.z);
        fldH[y * fieldW + x] = h;
        if (h < fMin) fMin = h;
        if (h > fMax) fMax = h;
      }
    }
    final fldPx = Uint8List(fieldW * fieldH * 4);
    final fSpan = math.max(fMax - fMin, 1.0);
    for (var i = 0; i < fieldW * fieldH; i++) {
      final t = (fldH[i] - fMin) / fSpan;
      final g = (255 * (0.2 + 0.8 * t)).round();
      fldPx[i * 4] = g;
      fldPx[i * 4 + 1] = g;
      fldPx[i * 4 + 2] = g;
      fldPx[i * 4 + 3] = 255;
    }

    // ---- Albedo panel, sampled through the shader's uv path ----------------
    final albPanel = _Panel();
    for (var y = 0; y < panelH; y++) {
      final lat = (0.5 - (y + 0.5) / panelH) * math.pi;
      for (var x = 0; x < panelW; x++) {
        final lon = ((x + 0.5) / panelW - 0.5) * 2 * math.pi;
        final (r, g, b) = alb.sampleDir(_dir(lat, lon));
        albPanel.set(x, y, (r * 255).round(), (g * 255).round(),
            (b * 255).round());
      }
    }

    // ---- Overlay: albedo underlay + DEM contours every 1000 m --------------
    final ovrPanel = _Panel();
    const contourM = 1000.0;
    for (var y = 0; y < panelH; y++) {
      for (var x = 0; x < panelW; x++) {
        final i = y * panelW + x;
        final albI = (y * panelW + x) * 4;
        final lum = (albPanel.px[albI] + albPanel.px[albI + 1] +
                albPanel.px[albI + 2]) ~/
            3;
        final b0 = (demH[i] / contourM).floor();
        final onContour =
            (x + 1 < panelW && (demH[i + 1] / contourM).floor() != b0) ||
                (y + 1 < panelH &&
                    (demH[i + panelW] / contourM).floor() != b0);
        if (onContour) {
          ovrPanel.set(x, y, 255, 130, 20);
        } else {
          ovrPanel.set(x, y, lum, lum, lum);
        }
      }
    }

    for (final p in [demPanel, albPanel, ovrPanel]) {
      p.crosshair();
      for (final (la, lo) in const [_crisium, _highlands, _tycho, _copernicus]) {
        p.mark(la, lo);
      }
    }
    demPanel.label('DEM');
    albPanel.label('ALBEDO');
    ovrPanel.label('OVERLAY');

    // ---- Compose the 2x2 sheet --------------------------------------------
    final demImg = await _toImage(demPanel.px, panelW, panelH);
    final fldImg = await _toImage(fldPx, fieldW, fieldH);
    final albImg = await _toImage(albPanel.px, panelW, panelH);
    final ovrImg = await _toImage(ovrPanel.px, panelW, panelH);

    final rec = ui.PictureRecorder();
    final cv = ui.Canvas(rec);
    final paint = ui.Paint();
    cv.drawImage(demImg, ui.Offset.zero, paint);
    cv.drawImageRect(
        fldImg,
        ui.Rect.fromLTWH(0, 0, fieldW.toDouble(), fieldH.toDouble()),
        ui.Rect.fromLTWH(panelW.toDouble(), 0, panelW.toDouble(),
            panelH.toDouble()),
        paint);
    cv.drawImage(albImg, ui.Offset(0, panelH.toDouble()), paint);
    cv.drawImage(
        ovrImg, ui.Offset(panelW.toDouble(), panelH.toDouble()), paint);
    // The upscaled field panel gets its crosshair + label at sheet scale.
    final line = ui.Paint()..color = const ui.Color(0xFF4678FF);
    cv.drawRect(
        ui.Rect.fromLTWH(panelW * 1.5, 0, 1, panelH.toDouble()), line);
    cv.drawRect(
        ui.Rect.fromLTWH(panelW.toDouble(), panelH / 2, panelW.toDouble(), 1),
        line);
    final fLabel = _Panel()..label('FIELD');
    cv.drawImage(await _toImage(fLabel.px, panelW, panelH),
        ui.Offset(panelW.toDouble(), 0), ui.Paint());

    final sheet = await rec.endRecording().toImage(panelW * 2, panelH * 2);
    final png = await sheet.toByteData(format: ui.ImageByteFormat.png);
    Directory('test_out').createSync(recursive: true);
    final out = File('test_out/terrain_alignment_moon.png');
    out.writeAsBytesSync(png!.buffer.asUint8List());
    debugPrint('wrote ${out.path}');

    // ---- Numeric registration checks ---------------------------------------
    const cw = 256, ch = 128;
    final dv = <double>[], av = <double>[], avLon = <double>[],
        avLat = <double>[], fv = <double>[], wv = <double>[];
    for (var y = 0; y < ch; y++) {
      final lat = (0.5 - (y + 0.5) / ch) * math.pi;
      for (var x = 0; x < cw; x++) {
        final lon = ((x + 0.5) / cw - 0.5) * 2 * math.pi;
        final d = _dir(lat, lon);
        dv.add(dem.elevationAt(d));
        av.add(alb.lumDir(d));
        avLon.add(alb.lumDir(_dir(lat, -lon)));
        avLat.add(alb.lumDir(_dir(-lat, lon)));
        fv.add(field.heightInDirection(d.x, d.y, d.z));
        wv.add(math.cos(lat));
      }
    }
    final rAlb = _pearson(dv, av, wv);
    final rLon = _pearson(dv, avLon, wv);
    final rLat = _pearson(dv, avLat, wv);
    final rFld = _pearson(dv, fv, wv);
    debugPrint('corr(DEM elev, albedo lum)            = '
        '${rAlb.toStringAsFixed(3)}');
    debugPrint('corr(DEM elev, albedo lon-mirrored)   = '
        '${rLon.toStringAsFixed(3)}');
    debugPrint('corr(DEM elev, albedo lat-flipped)    = '
        '${rLat.toStringAsFixed(3)}');
    debugPrint('corr(DEM elev, terrain field)         = '
        '${rFld.toStringAsFixed(3)}  (DEM base + detail; must stay high)');

    for (final (name, la, lo) in const [
      ('Mare Crisium', 17.0, 59.1),
      ('S highlands', -30.0, 15.0),
      ('Tycho', -43.31, -11.36),
      ('Copernicus', 9.62, -20.08),
    ]) {
      final d = _dir(la * math.pi / 180, lo * math.pi / 180);
      debugPrint('$name: DEM ${dem.elevationAt(d).toStringAsFixed(0)} m, '
          'albedo ${alb.lumDir(d).toStringAsFixed(3)}, '
          'field ${field.heightInDirection(d.x, d.y, d.z).toStringAsFixed(0)} m');
    }

    final crisium = _dir(_crisium.$1 * math.pi / 180, _crisium.$2 * math.pi / 180);
    final high = _dir(_highlands.$1 * math.pi / 180, _highlands.$2 * math.pi / 180);
    expect(rAlb, greaterThan(rLon),
        reason: 'DEM/albedo agreement must beat a lon-mirrored albedo — '
            'a longitude sign error in either mapping flips this');
    expect(rAlb, greaterThan(rLat),
        reason: 'DEM/albedo agreement must beat a lat-flipped albedo — '
            'a north/south error in either mapping flips this');
    expect(dem.elevationAt(crisium), lessThan(dem.elevationAt(high)),
        reason: 'Mare Crisium must be lower than the southern highlands');
    expect(alb.lumDir(crisium), lessThan(alb.lumDir(high)),
        reason: 'Mare Crisium must be darker than the southern highlands');
    expect(rFld, greaterThan(0.8),
        reason: 'the runtime TerrainField rides the DEM now — low correlation '
            'means the registry wiring or the detail layer regressed');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
