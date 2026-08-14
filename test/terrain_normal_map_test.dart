// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Registration gate for the baked DEM normal map (assets/terrain/moon.acronrm,
// tool/bake_normals.dart) against the DEM pyramid the mesher uses.
//
// The map's east/north components must CORRELATE with finite-difference slopes
// of DemPyramid.elevationAt taken along the same body-fixed east/north
// directions, at the map's own feature scale. A sign flip in either axis
// (the classic "lighting reads inverted" bug), a swapped channel order, or a
// lat/lon mapping error all drive these correlations to ~0 or negative.
//
// Both artefacts derive from ldem_64.tif through different resampling paths
// (equirect vs cubed-sphere), so the correlation is high but not 1.

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

void main() {
  test('moon normal map slopes match DEM pyramid gradients', () {
    final demFile = File('assets/terrain/moon.acrodem');
    final nrmFile = File('assets/terrain/moon.acronrm');
    if (!demFile.existsSync() || !nrmFile.existsSync()) {
      markTestSkipped('run tool/bake_dem.dart + tool/bake_normals.dart first');
      return;
    }
    final dem = DemPyramid.decode(demFile.readAsBytesSync());

    final bytes = nrmFile.readAsBytesSync();
    final view = ByteData.sublistView(bytes);
    expect(view.getUint32(0), 0x4143524F, reason: 'ACRONRM magic0');
    expect(view.getUint32(4), 0x4E524D01, reason: 'ACRONRM magic1');
    final w = view.getUint32(8), h = view.getUint32(12);
    expect(bytes.length, 16 + w * h * 2, reason: 'RG payload size');

    // Map east/north components at (lat, lon), bilinear, the shader's uv.
    (double, double) mapEN(double lat, double lon) {
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

    // Finite-difference step matched to the map's texel (~2.7 km at 4096) so
    // both sides measure the same feature band.
    const radiusM = 1737400.0;
    final stepM = 2 * math.pi * radiusM / w;

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
        final (e, n) = mapEN(lat, lon);
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
    debugPrint('corr(map east, DEM east slope)  = ${rE.toStringAsFixed(3)}');
    debugPrint('corr(map north, DEM north slope) = ${rN.toStringAsFixed(3)}');
    debugPrint('cross east/north = ${rEN.toStringAsFixed(3)}, '
        '${rNE.toStringAsFixed(3)}');

    expect(rE, greaterThan(0.6),
        reason: 'east component disagrees with DEM east slope — sign or '
            'longitude mapping error in bake_normals or the shader uv');
    expect(rN, greaterThan(0.6),
        reason: 'north component disagrees with DEM north slope — sign or '
            'latitude mapping error (row 0 must be north)');
    expect(rE, greaterThan(rEN.abs()),
        reason: 'east matches the NORTH slope better — r/g channels swapped');
    expect(rN, greaterThan(rNE.abs()),
        reason: 'north matches the EAST slope better — r/g channels swapped');
  });
}
