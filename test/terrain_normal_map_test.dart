// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Registration gate for the baked DEM normal maps (assets/terrain/<id>.acronrm,
// tool/bake_normals.dart) against the DEM pyramids the mesher uses — for every
// body that ships the pair.
//
// The map's east/north components must CORRELATE with finite-difference slopes
// of DemPyramid.elevationAt taken along the same body-fixed east/north
// directions, at the map's own feature scale. A sign flip in either axis
// (the classic "lighting reads inverted" bug), a swapped channel order, or a
// lat/lon mapping error all drive these correlations to ~0 or negative.
//
// Both artefacts derive from the same survey source through different
// resampling paths (equirect vs cubed-sphere), so correlation is high, not 1.
//
// Earth additionally gets absolute landmark checks on the DEM itself, because
// its pyramid is COMBINED from the GEBCO_08 elev/bath pair (see
// tool/src/dem_source.dart) — a mask or ramp error there produces a map that
// still self-correlates but has the wrong planet on it.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/dem_pyramid.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

Vector3 _dir(double lat, double lon) => Vector3(
    math.cos(lat) * math.cos(lon),
    math.cos(lat) * math.sin(lon),
    math.sin(lat));

Vector3 _dirDeg(double latDeg, double lonDeg) =>
    _dir(latDeg * math.pi / 180, lonDeg * math.pi / 180);

double _pearson(List<double> a, List<double> b) {
  final n = a.length;
  var ma = 0.0, mb = 0.0;
  for (var i = 0; i < n; i++) {
    ma += a[i];
    mb += b[i];
  }
  ma /= n;
  mb /= n;
  var cab = 0.0, caa = 0.0, cbb = 0.0;
  for (var i = 0; i < n; i++) {
    final da = a[i] - ma, db = b[i] - mb;
    cab += da * db;
    caa += da * da;
    cbb += db * db;
  }
  final d = math.sqrt(caa * cbb);
  return d > 0 ? cab / d : 0.0;
}

/// Decoded .acronrm with bilinear sampling through the shader's uv formula.
class _NormalMap {
  _NormalMap(this.w, this.h, this.bytes);
  final int w, h;
  final Uint8List bytes; // 16-byte header + w*h*2 RG

  static _NormalMap? load(String path) {
    final f = File(path);
    if (!f.existsSync()) return null;
    final bytes = f.readAsBytesSync();
    final view = ByteData.sublistView(bytes);
    if (view.lengthInBytes < 16 ||
        view.getUint32(0) != 0x4143524F ||
        view.getUint32(4) != 0x4E524D01) {
      return null;
    }
    final w = view.getUint32(8), h = view.getUint32(12);
    if (bytes.length != 16 + w * h * 2) return null;
    return _NormalMap(w, h, bytes);
  }

  (double, double) sampleEN(double lat, double lon) {
    final u = lon / (2 * math.pi) + 0.5;
    final v = 0.5 - lat / math.pi;
    final x = u * w - 0.5, y = (v * h - 0.5).clamp(0.0, h - 1.0);
    final x0 = x.floor(), y0 = y.floor();
    final fx = x - x0, fy = y - y0;
    final y1 = math.min(y0 + 1, h - 1);
    int wrap(int xi) => ((xi % w) + w) % w;
    double at(int xi, int yi, int c) =>
        bytes[16 + (yi * w + wrap(xi)) * 2 + c] / 127.5 - 1.0;
    double ch(int c) =>
        (at(x0, y0, c) * (1 - fx) + at(x0 + 1, y0, c) * fx) * (1 - fy) +
        (at(x0, y1, c) * (1 - fx) + at(x0 + 1, y1, c) * fx) * fy;
    return (ch(0), ch(1));
  }
}

void _runBodyGate(String id, double radiusM) {
  final demFile = File('assets/terrain/$id.acrodem');
  final nrm = _NormalMap.load('assets/terrain/$id.acronrm');
  if (!demFile.existsSync() || nrm == null) {
    markTestSkipped('run tool/bake_dem.dart + tool/bake_normals.dart '
        'for $id first');
    return;
  }
  final dem = DemPyramid.decode(demFile.readAsBytesSync());

  // Finite-difference step matched to the map's texel so both sides measure
  // the same feature band.
  final stepM = 2 * math.pi * radiusM / nrm.w;

  final mapE = <double>[], mapN = <double>[];
  final demE = <double>[], demN = <double>[];
  const rows = 48, cols = 96;
  for (var yi = 0; yi < rows; yi++) {
    // Stay off the poles: east degenerates there and the shader guards it.
    final lat = (-60.0 + 120.0 * (yi + 0.5) / rows) * math.pi / 180;
    final dLon = stepM / (radiusM * math.cos(lat));
    final dLat = stepM / radiusM;
    for (var xi = 0; xi < cols; xi++) {
      final lon = (-180.0 + 360.0 * (xi + 0.5) / cols) * math.pi / 180;
      final (e, n) = nrm.sampleEN(lat, lon);
      mapE.add(e);
      mapN.add(n);
      // Slope = rise over run; the map stores -slope (normal tips AWAY from
      // uphill), so negate to compare like with like.
      demE.add(-(dem.elevationAt(_dir(lat, lon + dLon)) -
              dem.elevationAt(_dir(lat, lon - dLon))) /
          (2 * stepM));
      demN.add(-(dem.elevationAt(_dir(lat + dLat, lon)) -
              dem.elevationAt(_dir(lat - dLat, lon))) /
          (2 * stepM));
    }
  }

  final rE = _pearson(mapE, demE);
  final rN = _pearson(mapN, demN);
  // Cross-correlations catch a channel swap that same-axis thresholds miss.
  final rEN = _pearson(mapE, demN);
  final rNE = _pearson(mapN, demE);
  debugPrint('$id: corr(map east, DEM east slope)   = ${rE.toStringAsFixed(3)}');
  debugPrint('$id: corr(map north, DEM north slope) = ${rN.toStringAsFixed(3)}');
  debugPrint('$id: cross east/north = ${rEN.toStringAsFixed(3)}, '
      '${rNE.toStringAsFixed(3)}');

  expect(rE, greaterThan(0.6),
      reason: '$id: east component disagrees with DEM east slope — sign or '
          'longitude mapping error in bake_normals or the shader uv');
  expect(rN, greaterThan(0.6),
      reason: '$id: north component disagrees with DEM north slope — sign or '
          'latitude mapping error (row 0 must be north)');
  expect(rE, greaterThan(rEN.abs()),
      reason: '$id: east matches the NORTH slope better — r/g channels '
          'swapped');
  expect(rN, greaterThan(rNE.abs()),
      reason: '$id: north matches the EAST slope better — r/g channels '
          'swapped');
}

void main() {
  test('moon normal map slopes match DEM pyramid gradients', () {
    _runBodyGate('moon', 1737400.0);
  });

  test('earth normal map slopes match DEM pyramid gradients', () {
    _runBodyGate('earth', 6371000.0);
  });

  test('earth DEM has the right planet on it (GEBCO mask + ramps)', () {
    final demFile = File('assets/terrain/earth.acrodem');
    if (!demFile.existsSync()) {
      markTestSkipped('run tool/bake_dem.dart for earth first');
      return;
    }
    final dem = DemPyramid.decode(demFile.readAsBytesSync());

    final himalaya = dem.elevationAt(_dirDeg(28.0, 86.9));
    final mariana = dem.elevationAt(_dirDeg(11.35, 142.2));
    final amazon = dem.elevationAt(_dirDeg(-3.0, -60.0));
    final atlantic = dem.elevationAt(_dirDeg(30.0, -40.0));
    debugPrint('earth DEM: himalaya $himalaya, mariana $mariana, '
        'amazon $amazon, atlantic $atlantic (m)');

    // Loose bounds: the pyramid is box-filtered to ~6 km texels, so peaks and
    // trenches are regional means, not point extremes.
    expect(himalaya, greaterThan(2500),
        reason: 'Himalaya must be high — elev ramp or mask broken');
    expect(mariana, lessThan(-4000),
        reason: 'Mariana must be deep — bath ramp/inversion broken');
    expect(amazon.abs(), lessThan(500),
        reason: 'Amazon basin must sit near sea level');
    expect(atlantic, lessThan(-2000),
        reason: 'mid-Atlantic must be ocean — land/sea mask broken');
    // The pair's ramps clip at exactly these bounds; the decoded span must
    // stay inside them (plus int16 quantisation slack).
    expect(dem.minElevM, greaterThanOrEqualTo(-8001));
    expect(dem.maxElevM, lessThanOrEqualTo(6401));
  });
}
