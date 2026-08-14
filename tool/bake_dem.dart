// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Bakes a source elevation raster into the cubed-sphere pyramid the app ships.
///
/// Mirrors `tool/import_mesh.dart`: bulk source lives in `dem_src/` (gitignored,
/// never bundled), and this writes a small artefact into `assets/`.
///
/// ```
/// fvm dart run tool/bake_dem.dart \
///   --in dem_src/ldem_64.tif --out assets/terrain/moon.acrodem \
///   --radius 1737400 --units km --face 512
/// ```
///
/// (The shipped moon.acrodem is `--face 512` — byte-verified against a rebake.
/// `--face` defaults to 1024, which is what Earth uses.)
///
/// Earth uses the Blue Marble GEBCO_08 8-bit pair instead of one raster —
/// `--bath` switches to it (see `ElevBathHeight` in src/dem_source.dart for
/// the mask/ramp rules):
///
/// ```
/// fvm dart run tool/bake_dem.dart \
///   --in dem_src/gebco_08_rev_elev_21600x10800.tif \
///   --bath dem_src/gebco_08_rev_bath_21600x10800.tif \
///   --out assets/terrain/earth.acrodem --radius 6371000 --face 1024
/// ```
///
/// ## Why it streams
///
/// `ldem_64.tif` is 23040 x 11520 float32 — 1.06 GB, more than is reasonable to
/// hold. But cube-face resampling is a SCATTERED read of the source, so reading
/// on demand would mean tens of millions of seeks.
///
/// The way out is a two-pass shape: stream the source rows ONCE, box-filtering
/// them down to an intermediate equirectangular grid small enough to hold
/// (a few tens of MB), then resample the cube faces from memory. Box-filtering
/// on the way down is not optional — point-sampling a 23040-wide source into a
/// 1024-per-face pyramid would alias every ridge in the dataset into noise.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/terrain/cubed_sphere.dart';
import 'package:acro_space_simulator/domain/terrain/dem_pyramid.dart';

import 'src/dem_source.dart';

void main(List<String> args) {
  final opts = _parse(args);
  final outPath = opts['out'] ?? 'assets/terrain/moon.acrodem';
  final radiusM = double.parse(opts['radius'] ?? '1737400');
  final faceSize = int.parse(opts['face'] ?? '1024');
  final levelCount = int.parse(opts['levels'] ?? '5');

  final HeightSource source;
  try {
    source = heightSourceFromOpts(opts, defaultIn: 'dem_src/ldem_64.tif');
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exitCode = 2;
    return;
  }
  stdout.writeln('source ${source.width}x${source.height}');

  // --- Pass 1: stream down to an intermediate equirectangular grid ----------
  // Sized ~4x the finest cube face edge so the box filter has real support and
  // the cube resample is an interpolation rather than a magnification.
  final interW = math.min(source.width, faceSize * 4);
  final interH = math.max(1, interW ~/ 2);
  stdout.writeln('downsampling to ${interW}x$interH ...');

  final acc = Float64List(interW * interH);
  final counts = Int32List(interW * interH);
  var minElev = double.infinity, maxElev = double.negativeInfinity;

  for (var y = 0; y < source.height; y++) {
    final row = source.row(y);
    final ty = (y * interH ~/ source.height).clamp(0, interH - 1);
    final base = ty * interW;
    for (var x = 0; x < source.width; x++) {
      final v = row[x];
      if (!v.isFinite) continue;
      final tx = (x * interW ~/ source.width).clamp(0, interW - 1);
      acc[base + tx] += v;
      counts[base + tx]++;
      if (v < minElev) minElev = v;
      if (v > maxElev) maxElev = v;
    }
    if (y % 1000 == 0) {
      stdout.writeln('  row $y / ${source.height}');
    }
  }
  source.close();

  final inter = Float64List(interW * interH);
  for (var i = 0; i < inter.length; i++) {
    inter[i] = counts[i] > 0 ? acc[i] / counts[i] : 0.0;
  }
  stdout.writeln('elevation range ${minElev.toStringAsFixed(1)} .. '
      '${maxElev.toStringAsFixed(1)} m');

  double sampleEquirect(double lat, double lon) {
    // lon in [-pi, pi] -> x, lat in [pi/2, -pi/2] -> y (north row first).
    final u = ((lon + math.pi) / (2 * math.pi) * interW)
        .clamp(0.0, interW - 1.0);
    final v =
        ((math.pi / 2 - lat) / math.pi * interH).clamp(0.0, interH - 1.0);
    final x0 = u.floor(), y0 = v.floor();
    final x1 = math.min(x0 + 1, interW - 1), y1 = math.min(y0 + 1, interH - 1);
    final fx = u - x0, fy = v - y0;
    final a = inter[y0 * interW + x0], b = inter[y0 * interW + x1];
    final c = inter[y1 * interW + x0], d = inter[y1 * interW + x1];
    return (a + (b - a) * fx) * (1 - fy) + (c + (d - c) * fx) * fy;
  }

  // --- Pass 2: resample onto cube faces, then build the mip chain -----------
  stdout.writeln('baking $faceSize per face, $levelCount levels ...');
  final levels = <List<Int16List>>[];
  final finest = <Float64List>[];
  for (final face in CubeFace.values) {
    final grid = Float64List(faceSize * faceSize);
    for (var y = 0; y < faceSize; y++) {
      final t = (y + 0.5) / faceSize * 2.0 - 1.0;
      for (var x = 0; x < faceSize; x++) {
        final s = (x + 0.5) / faceSize * 2.0 - 1.0;
        final dir = directionOf(face, s, t);
        final lat = math.asin(dir.z.clamp(-1.0, 1.0));
        final lon = math.atan2(dir.y, dir.x);
        grid[y * faceSize + x] = sampleEquirect(lat, lon);
      }
    }
    finest.add(grid);
    stdout.writeln('  face ${face.name} done');
  }

  List<Int16List> quantiseAll(List<Float64List> faces, int size) => [
        for (final g in faces)
          Int16List.fromList([
            for (var i = 0; i < size * size; i++)
              DemPyramid.quantise(g[i], minElev, maxElev)
          ])
      ];

  levels.add(quantiseAll(finest, faceSize));
  var current = finest;
  var size = faceSize;
  for (var l = 1; l < levelCount && size > 1; l++) {
    final half = size >> 1;
    final next = <Float64List>[];
    for (final g in current) {
      final out = Float64List(half * half);
      for (var y = 0; y < half; y++) {
        for (var x = 0; x < half; x++) {
          // Box filter, so a coarse level is the AVERAGE of the fine one.
          // Point-decimating instead would make each mip a different surface
          // and the LOD transitions would pop.
          out[y * half + x] = (g[(y * 2) * size + x * 2] +
                  g[(y * 2) * size + x * 2 + 1] +
                  g[(y * 2 + 1) * size + x * 2] +
                  g[(y * 2 + 1) * size + x * 2 + 1]) /
              4.0;
        }
      }
      next.add(out);
    }
    current = next;
    size = half;
    levels.add(quantiseAll(current, size));
  }

  final pyramid = DemPyramid(
    radiusM: radiusM,
    faceSize: faceSize,
    minElevM: minElev,
    maxElevM: maxElev,
    levels: levels,
  );
  final bytes = pyramid.encode();
  final out = File(outPath);
  out.parent.createSync(recursive: true);
  out.writeAsBytesSync(bytes);
  stdout.writeln('wrote $outPath  '
      '${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB');

  // Spot-check against the source so a silently-wrong bake is caught here
  // rather than by someone wondering why the body looks off. Landmarks come
  // from the OUTPUT body id — probing Earth with Moon labels hides errors.
  for (final probe in landmarksForOut(outPath)) {
    final lat = probe.latDeg * math.pi / 180, lon = probe.lonDeg * math.pi / 180;
    final dir = Vector3(math.cos(lat) * math.cos(lon),
        math.cos(lat) * math.sin(lon), math.sin(lat));
    stdout.writeln('  ${probe.name}: baked '
        '${pyramid.elevationAt(dir).toStringAsFixed(0)} m, source '
        '${sampleEquirect(lat, lon).toStringAsFixed(0)} m');
  }
}

Map<String, String> _parse(List<String> args) {
  final out = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    if (args[i].startsWith('--') && i + 1 < args.length) {
      out[args[i].substring(2)] = args[i + 1];
      i++;
    }
  }
  return out;
}
