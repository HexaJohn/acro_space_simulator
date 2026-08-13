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
///   --radius 1737400 --units km --face 1024
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

/// The only tags this reader consumes: width, height, bits/sample,
/// compression, strip offsets, sample format.
const _wantedTags = {256, 257, 258, 259, 273, 339};

/// Bytes per element for the integer TIFF types. Anything else (rationals,
/// ASCII, floats) only ever appears in tags outside [_wantedTags].
const _typeSize = <int, int>{1: 1, 3: 2, 4: 4};

/// Minimal TIFF directory reader — enough for the uncompressed, strip-per-row
/// rasters these DEM products ship as. Not a general TIFF decoder.
class _Tiff {
  _Tiff(this.file, this.width, this.height, this.bits, this.sampleFormat,
      this.stripOffsets, this.little);

  final RandomAccessFile file;
  final int width, height, bits, sampleFormat;
  final List<int> stripOffsets;
  final bool little;

  static _Tiff open(String path) {
    final f = File(path).openSync();
    final head = f.readSync(8);
    final little = head[0] == 0x49 && head[1] == 0x49;
    final bd = ByteData.sublistView(Uint8List.fromList(head));
    final ifd = bd.getUint32(4, little ? Endian.little : Endian.big);
    f.setPositionSync(ifd);
    final endian = little ? Endian.little : Endian.big;
    final countBytes = f.readSync(2);
    final n = ByteData.sublistView(Uint8List.fromList(countBytes))
        .getUint16(0, endian);

    int? width, height, bitsPerSample, sampleFormat, compression;
    var stripOffsets = <int>[];
    for (var i = 0; i < n; i++) {
      final e = Uint8List.fromList(f.readSync(12));
      final ed = ByteData.sublistView(e);
      final tag = ed.getUint16(0, endian);
      final type = ed.getUint16(2, endian);
      final count = ed.getUint32(4, endian);
      // Skip every tag we do not consume BEFORE decoding anything. A DEM
      // GeoTIFF carries rationals, ASCII and doubles in its geo-keys, and
      // trying to read those through an integer path walks off the end of the
      // value buffer.
      if (!_wantedTags.contains(tag)) continue;
      final size = _typeSize[type];
      if (size == null) continue; // unknown type in a tag we wanted; ignore
      List<int> values;
      if (size * count <= 4) {
        values = _read(ed.buffer.asByteData(ed.offsetInBytes + 8, 4), type,
            count, endian);
      } else {
        final off = ed.getUint32(8, endian);
        final save = f.positionSync();
        f.setPositionSync(off);
        final raw = Uint8List.fromList(f.readSync(size * count));
        f.setPositionSync(save);
        values = _read(ByteData.sublistView(raw), type, count, endian);
      }
      switch (tag) {
        case 256:
          width = values.first;
        case 257:
          height = values.first;
        case 258:
          bitsPerSample = values.first;
        case 259:
          compression = values.first;
        case 273:
          stripOffsets = values;
        case 339:
          sampleFormat = values.first;
      }
    }
    if (width == null || height == null) {
      throw StateError('TIFF missing dimensions');
    }
    if (compression != null && compression != 1) {
      throw StateError(
          'compressed TIFF (compression=$compression) not supported; '
          'export an uncompressed copy');
    }
    if (stripOffsets.length != height) {
      throw StateError(
          'expected one strip per row, got ${stripOffsets.length} for $height');
    }
    return _Tiff(f, width, height, bitsPerSample ?? 8, sampleFormat ?? 1,
        stripOffsets, little);
  }

  static List<int> _read(ByteData d, int type, int count, Endian e) => [
        for (var i = 0; i < count; i++)
          switch (type) {
            1 => d.getUint8(i),
            3 => d.getUint16(i * 2, e),
            _ => d.getUint32(i * 4, e),
          }
      ];

  /// One raster row as doubles, whatever the on-disk sample format.
  Float64List readRow(int y, Uint8List scratch) {
    file.setPositionSync(stripOffsets[y]);
    file.readIntoSync(scratch);
    final d = ByteData.sublistView(scratch);
    final e = little ? Endian.little : Endian.big;
    final out = Float64List(width);
    final bytes = bits ~/ 8;
    for (var x = 0; x < width; x++) {
      final o = x * bytes;
      out[x] = switch ((bits, sampleFormat)) {
        (32, 3) => d.getFloat32(o, e),
        (32, 2) => d.getInt32(o, e).toDouble(),
        (32, _) => d.getUint32(o, e).toDouble(),
        (16, 2) => d.getInt16(o, e).toDouble(),
        (16, _) => d.getUint16(o, e).toDouble(),
        _ => d.getUint8(o).toDouble(),
      };
    }
    return out;
  }

  int get rowBytes => width * (bits ~/ 8);
}

void main(List<String> args) {
  final opts = _parse(args);
  final inPath = opts['in'] ?? 'dem_src/ldem_64.tif';
  final outPath = opts['out'] ?? 'assets/terrain/moon.acrodem';
  final radiusM = double.parse(opts['radius'] ?? '1737400');
  final unitScale = (opts['units'] ?? 'm') == 'km' ? 1000.0 : 1.0;
  final faceSize = int.parse(opts['face'] ?? '1024');
  final levelCount = int.parse(opts['levels'] ?? '5');

  if (!File(inPath).existsSync()) {
    stderr.writeln('source not found: $inPath');
    exitCode = 2;
    return;
  }

  final tiff = _Tiff.open(inPath);
  stdout.writeln('source ${tiff.width}x${tiff.height} '
      'bits=${tiff.bits} format=${tiff.sampleFormat}');

  // --- Pass 1: stream down to an intermediate equirectangular grid ----------
  // Sized ~4x the finest cube face edge so the box filter has real support and
  // the cube resample is an interpolation rather than a magnification.
  final interW = math.min(tiff.width, faceSize * 4);
  final interH = math.max(1, interW ~/ 2);
  stdout.writeln('downsampling to ${interW}x$interH ...');

  final acc = Float64List(interW * interH);
  final counts = Int32List(interW * interH);
  final scratch = Uint8List(tiff.rowBytes);
  var minElev = double.infinity, maxElev = double.negativeInfinity;

  for (var y = 0; y < tiff.height; y++) {
    final row = tiff.readRow(y, scratch);
    final ty = (y * interH ~/ tiff.height).clamp(0, interH - 1);
    final base = ty * interW;
    for (var x = 0; x < tiff.width; x++) {
      final v = row[x] * unitScale;
      if (!v.isFinite) continue;
      final tx = (x * interW ~/ tiff.width).clamp(0, interW - 1);
      acc[base + tx] += v;
      counts[base + tx]++;
      if (v < minElev) minElev = v;
      if (v > maxElev) maxElev = v;
    }
    if (y % 1000 == 0) {
      stdout.writeln('  row $y / ${tiff.height}');
    }
  }
  tiff.file.closeSync();

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
  // rather than by someone wondering why the Moon looks off.
  for (final probe in [
    ('Mare Imbrium', 33.0, -16.0),
    ('Apollo 11', 0.67, 23.47),
    ('South Pole-Aitken', -53.0, -169.0),
  ]) {
    final lat = probe.$2 * math.pi / 180, lon = probe.$3 * math.pi / 180;
    final dir = Vector3(math.cos(lat) * math.cos(lon),
        math.cos(lat) * math.sin(lon), math.sin(lat));
    stdout.writeln('  ${probe.$1}: baked '
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
