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
/// Earth combines the Blue Marble GEBCO_08 elev/bath pair (`--bath` switches
/// modes, same as bake_dem.dart):
///
/// ```
/// fvm dart run tool/bake_normals.dart \
///   --in dem_src/gebco_08_rev_elev_21600x10800.tif \
///   --bath dem_src/gebco_08_rev_bath_21600x10800.tif \
///   --out assets/terrain/earth.acronrm --radius 6371000 --width 4096
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

import 'src/dem_source.dart';

void main(List<String> args) {
  final opts = _parse(args);
  final outPath = opts['out'] ?? 'assets/terrain/moon.acronrm';
  final radiusM = double.parse(opts['radius'] ?? '1737400');
  final outW = int.parse(opts['width'] ?? '4096');
  final outH = outW ~/ 2;

  final HeightSource source;
  try {
    // ldem_64.tif is in kilometres, hence the km default — the GEBCO pair
    // path ignores units (its ramps are metres by definition).
    source = heightSourceFromOpts(opts,
        defaultIn: 'dem_src/ldem_64.tif', defaultUnits: 'km');
  } on StateError catch (e) {
    stderr.writeln(e.message);
    exitCode = 2;
    return;
  }
  stdout.writeln('source ${source.width}x${source.height}');
  stdout.writeln('height grid ${outW}x$outH ...');

  // --- Pass 1: stream source rows ONCE, box-filter into the output grid -----
  // Same shape as bake_dem: full-resolution gradients would alias (the source
  // is 5.6x the output), so heights are averaged down first and slopes come
  // from the filtered surface — features 2+ output texels wide survive, which
  // is all a ~2.7 km/texel map can honestly carry anyway.
  final acc = Float64List(outW * outH);
  final counts = Int32List(outW * outH);
  for (var y = 0; y < source.height; y++) {
    final row = source.row(y);
    final ty = (y * outH ~/ source.height).clamp(0, outH - 1);
    final base = ty * outW;
    for (var x = 0; x < source.width; x++) {
      final v = row[x];
      if (!v.isFinite) continue;
      final tx = (x * outW ~/ source.width).clamp(0, outW - 1);
      acc[base + tx] += v;
      counts[base + tx]++;
    }
    if (y % 2000 == 0) stdout.writeln('  row $y / ${source.height}');
  }
  source.close();
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

  final pair = flatRoughForOut(outPath);
  if (pair != null) {
    final (flat, rough) = pair;
    stdout.writeln('  ${flat.name} (flat):   '
        '${meanTilt(flat.latDeg, flat.lonDeg, 8).toStringAsFixed(4)}');
    stdout.writeln('  ${rough.name} (rough): '
        '${meanTilt(rough.latDeg, rough.lonDeg, 8).toStringAsFixed(4)}');
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
