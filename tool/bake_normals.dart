// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Bakes a source elevation raster into an equirectangular TANGENT-SPACE
/// normal map (`.acronrm`) for the terrain shader's detail-normal path.
///
/// Mirrors `tool/bake_albedo.dart`: bulk source in `dem_src/` (gitignored),
/// small artefact in `assets/terrain/`.
///
/// ```
/// fvm dart run tool/bake_normals.dart \
///   --in dem_src/ldem_64.tif --out assets/terrain/moon.acronrm \
///   --radius 1737400 --units km --width 4096
/// ```
///
/// Why this exists: a coarse LOD chunk carries a handful of triangles, so
/// crater rims and ridges vanish from LIGHTING long before they leave the
/// data. The DEM pyramid can't help the fragment shader (it's CPU-side and
/// cubed-sphere); an equirect normal map samples through the exact uv the
/// shader already computes for the albedo map, and puts the relief back into
/// the sun term at any mesh resolution. Silhouettes stay mesh-bound — this is
/// lighting only.
///
/// Format `ACRONRM\x01`: u32 magic0 'ACRO', u32 magic1 'NRM\x01', u32 width,
/// u32 height (big-endian, like `.acroalb`), then width*height*2 bytes.
/// Per texel: r = east component, g = north component of the unit surface
/// normal in the local (east, north, up) frame, each mapped [-1,1] -> [0,255]
/// (z is reconstructed in the shader). Row 0 = north, column 0 = lon -180,
/// x increases eastward — the albedo map's layout exactly.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// The only tags this reader consumes: width, height, bits/sample,
/// compression, strip offsets, sample format.
const _wantedTags = {256, 257, 258, 259, 273, 339};

/// Bytes per element for the integer TIFF types (rationals/ASCII/doubles only
/// appear in tags outside [_wantedTags]).
const _typeSize = <int, int>{1: 1, 3: 2, 4: 4};

/// Minimal TIFF reader for the uncompressed, strip-per-row rasters the DEM
/// products ship as (same shape as tool/bake_dem.dart's).
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
    final n = ByteData.sublistView(Uint8List.fromList(f.readSync(2)))
        .getUint16(0, endian);

    int? width, height, bitsPerSample, sampleFormat, compression;
    var stripOffsets = <int>[];
    for (var i = 0; i < n; i++) {
      final e = Uint8List.fromList(f.readSync(12));
      final ed = ByteData.sublistView(e);
      final tag = ed.getUint16(0, endian);
      final type = ed.getUint16(2, endian);
      final count = ed.getUint32(4, endian);
      if (!_wantedTags.contains(tag)) continue;
      final size = _typeSize[type];
      if (size == null) continue;
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
  final outPath = opts['out'] ?? 'assets/terrain/moon.acronrm';
  final radiusM = double.parse(opts['radius'] ?? '1737400');
  final unitScale = (opts['units'] ?? 'km') == 'km' ? 1000.0 : 1.0;
  final outW = int.parse(opts['width'] ?? '4096');
  final outH = outW ~/ 2;

  if (!File(inPath).existsSync()) {
    stderr.writeln('source not found: $inPath');
    exitCode = 2;
    return;
  }

  final tiff = _Tiff.open(inPath);
  stdout.writeln('source ${tiff.width}x${tiff.height} '
      'bits=${tiff.bits} format=${tiff.sampleFormat}');
  stdout.writeln('height grid ${outW}x$outH ...');

  // --- Pass 1: stream source rows ONCE, box-filter into the output grid -----
  // Same shape as bake_dem: full-resolution gradients would alias (the source
  // is 5.6x the output), so heights are averaged down first and slopes come
  // from the filtered surface — features 2+ output texels wide survive, which
  // is all a ~2.7 km/texel map can honestly carry anyway.
  final acc = Float64List(outW * outH);
  final counts = Int32List(outW * outH);
  final scratch = Uint8List(tiff.rowBytes);
  for (var y = 0; y < tiff.height; y++) {
    final row = tiff.readRow(y, scratch);
    final ty = (y * outH ~/ tiff.height).clamp(0, outH - 1);
    final base = ty * outW;
    for (var x = 0; x < tiff.width; x++) {
      final v = row[x] * unitScale;
      if (!v.isFinite) continue;
      final tx = (x * outW ~/ tiff.width).clamp(0, outW - 1);
      acc[base + tx] += v;
      counts[base + tx]++;
    }
    if (y % 2000 == 0) stdout.writeln('  row $y / ${tiff.height}');
  }
  tiff.file.closeSync();
  final h = Float64List(outW * outH);
  for (var i = 0; i < h.length; i++) {
    h[i] = counts[i] > 0 ? acc[i] / counts[i] : 0.0;
  }

  // --- Pass 2: central-difference slopes -> tangent-space normals -----------
  stdout.writeln('computing normals ...');
  final rg = Uint8List(outW * outH * 2);
  // Metres per texel: latitude rows are evenly spaced; longitude columns
  // shrink by cos(lat) toward the poles.
  final dyM = math.pi * radiusM / outH;
  var slopeSum = 0.0;
  for (var y = 0; y < outH; y++) {
    final lat = (0.5 - (y + 0.5) / outH) * math.pi;
    // Pole guard: as cos(lat) -> 0 the east spacing collapses and the
    // quotient blows up on noise. Clamping flattens the last fraction of a
    // degree — the sampler clamps V there anyway.
    final dxM = math.max(math.cos(lat), 1e-3) * 2.0 * math.pi * radiusM / outW;
    final yN = math.max(y - 1, 0), yS = math.min(y + 1, outH - 1);
    for (var x = 0; x < outW; x++) {
      final xE = (x + 1) % outW, xW = (x - 1 + outW) % outW; // lon wraps
      final dhdE = (h[y * outW + xE] - h[y * outW + xW]) / (2.0 * dxM);
      // Row 0 is north: the northern neighbour is y-1.
      final dhdN = (h[yN * outW + x] - h[yS * outW + x]) / ((yS - yN) * dyM);
      // Surface normal of z = h(e,n) in the local (east, north, up) frame.
      final invLen = 1.0 / math.sqrt(1.0 + dhdE * dhdE + dhdN * dhdN);
      final ne = -dhdE * invLen, nn = -dhdN * invLen;
      final i = (y * outW + x) * 2;
      rg[i] = ((ne * 0.5 + 0.5) * 255.0).round().clamp(0, 255);
      rg[i + 1] = ((nn * 0.5 + 0.5) * 255.0).round().clamp(0, 255);
      slopeSum += math.sqrt(dhdE * dhdE + dhdN * dhdN);
    }
  }
  stdout.writeln('mean slope ${(slopeSum / (outW * outH)).toStringAsFixed(4)}');

  // --- Write ----------------------------------------------------------------
  const magic0 = 0x4143524F; // 'ACRO'
  const magic1 = 0x4E524D01; // 'NRM\x01'
  final header = ByteData(16)
    ..setUint32(0, magic0)
    ..setUint32(4, magic1)
    ..setUint32(8, outW)
    ..setUint32(12, outH);
  final out = File(outPath);
  out.parent.createSync(recursive: true);
  out.writeAsBytesSync(
      Uint8List.fromList([...header.buffer.asUint8List(), ...rg]));
  stdout.writeln('wrote $outPath ${outW}x$outH  '
      '${((16 + rg.length) / 1024 / 1024).toStringAsFixed(1)} MB');

  // Spot-check: maria are flat, highlands are rugged. If the mapping desynced
  // this prints as similar numbers instead of a clear split.
  double meanTilt(double latDeg, double lonDeg, int radiusPx) {
    final cx = (((lonDeg + 180) / 360) * outW).floor();
    final cy = (((90 - latDeg) / 180) * outH).floor();
    var sum = 0.0;
    var n = 0;
    for (var dy = -radiusPx; dy <= radiusPx; dy++) {
      final y = (cy + dy).clamp(0, outH - 1);
      for (var dx = -radiusPx; dx <= radiusPx; dx++) {
        final x = (((cx + dx) % outW) + outW) % outW;
        final i = (y * outW + x) * 2;
        final e = rg[i] / 127.5 - 1.0, no = rg[i + 1] / 127.5 - 1.0;
        sum += math.sqrt(e * e + no * no);
        n++;
      }
    }
    return sum / n;
  }

  stdout.writeln('  Mare Serenitatis (flat):   '
      '${meanTilt(28.0, 17.5, 8).toStringAsFixed(4)}');
  stdout.writeln('  southern highlands (rough): '
      '${meanTilt(-40.0, 10.0, 8).toStringAsFixed(4)}');
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
