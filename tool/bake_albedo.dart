// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Bakes a source colour raster into the small equirectangular albedo map the
/// terrain shader samples.
///
/// ```
/// fvm dart run tool/bake_albedo.dart \
///   --in dem_src/lroc_color_poles.tif --out assets/terrain/moon.acroalb \
///   --width 2048
/// ```
///
/// ## Equirectangular, not cube faces
///
/// The DEM bakes to cube faces because the mesher addresses chunks that way and
/// the poles would otherwise be a singularity. Albedo goes the other way: it is
/// consumed in a FRAGMENT SHADER, which gets a direction and needs one sampler.
/// Cube faces would mean six samplers or a texture array, and this pin has
/// neither (see `docs/plans/terrain-lod.md` §0). Latitude/longitude from a
/// direction is three instructions.
///
/// ## Raw pixels, not PNG
///
/// There is no image encoder in the toolchain, and adding one to ship a texture
/// the engine immediately decodes again is pure ceremony. The output is a tiny
/// header plus RGB bytes, uploaded straight to a GPU texture — the same shape
/// `TerrainTextures` already uses for its procedural tiles.
library;

import 'dart:io';
import 'dart:typed_data';

const _wantedTags = {256, 257, 258, 259, 273, 277, 278, 279, 317};
const _typeSize = <int, int>{1: 1, 3: 2, 4: 4};

/// File magic — 'ACROALB\x01'.
const int magic0 = 0x4143524F; // 'ACRO'
const int magic1 = 0x414C4201; // 'ALB\x01'

/// TIFF LZW, the variant with EARLY CHANGE: the code width steps up one code
/// before the dictionary is actually full. Miss that and the stream desyncs a
/// few hundred codes in, which decodes as plausible-looking colour noise rather
/// than as an obvious failure.
Uint8List lzwDecode(Uint8List input, int expectedLength) {
  final out = Uint8List(expectedLength);
  var outPos = 0;

  // Dictionary entries 0..255 are literals, 256 = clear, 257 = end.
  final prefix = Int32List(4096);
  final suffix = Uint8List(4096);
  final length = Int32List(4096);

  var next = 258;
  var codeWidth = 9;
  var previous = -1;

  var bitBuffer = 0;
  var bitCount = 0;
  var pos = 0;

  final stack = Uint8List(4096);

  while (true) {
    while (bitCount < codeWidth) {
      if (pos >= input.length) return Uint8List.sublistView(out, 0, outPos);
      bitBuffer = (bitBuffer << 8) | input[pos++];
      bitCount += 8;
    }
    final code = (bitBuffer >> (bitCount - codeWidth)) & ((1 << codeWidth) - 1);
    bitCount -= codeWidth;

    if (code == 257) break; // end of information
    if (code == 256) {
      next = 258;
      codeWidth = 9;
      previous = -1;
      continue;
    }

    int emit;
    if (code < next && (code < 256 || length[code] > 0)) {
      emit = code;
    } else if (previous >= 0) {
      // KwKwK: the code is the one about to be defined.
      emit = -1;
    } else {
      break; // corrupt
    }

    var sp = 0;
    if (emit == -1) {
      // Walk the PREVIOUS entry, then append its own first byte.
      var c = previous;
      while (c >= 256) {
        stack[sp++] = suffix[c];
        c = prefix[c];
      }
      stack[sp++] = c;
      // First byte of previous, which is the last thing pushed.
      final first = stack[sp - 1];
      for (var i = sp - 1; i >= 0; i--) {
        if (outPos < expectedLength) out[outPos++] = stack[i];
      }
      if (outPos < expectedLength) out[outPos++] = first;
    } else {
      var c = emit;
      while (c >= 256) {
        stack[sp++] = suffix[c];
        c = prefix[c];
      }
      stack[sp++] = c;
      for (var i = sp - 1; i >= 0; i--) {
        if (outPos < expectedLength) out[outPos++] = stack[i];
      }
    }
    final firstByte = stack[sp - 1];

    if (previous >= 0 && next < 4096) {
      prefix[next] = previous;
      suffix[next] = firstByte;
      length[next] = (previous < 256 ? 1 : length[previous]) + 1;
      next++;
    }
    previous = emit == -1 ? next - 1 : emit;

    // Early change: step up one code before the width is truly exhausted.
    if (next + 1 >= (1 << codeWidth) && codeWidth < 12) codeWidth++;
    if (outPos >= expectedLength) break;
  }
  return Uint8List.sublistView(out, 0, outPos);
}

/// Undo TIFF horizontal differencing (predictor 2), applied per row per channel.
void undoPredictor(Uint8List row, int width, int samples) {
  for (var x = 1; x < width; x++) {
    final o = x * samples, p = (x - 1) * samples;
    for (var c = 0; c < samples; c++) {
      row[o + c] = (row[o + c] + row[p + c]) & 0xff;
    }
  }
}

class _Tiff {
  _Tiff(this.file, this.width, this.height, this.samples, this.compression,
      this.rowsPerStrip, this.stripOffsets, this.stripBytes, this.predictor,
      this.little);

  final RandomAccessFile file;
  final int width, height, samples, compression, rowsPerStrip, predictor;
  final List<int> stripOffsets, stripBytes;
  final bool little;

  static _Tiff open(String path) {
    final f = File(path).openSync();
    final head = f.readSync(8);
    final little = head[0] == 0x49 && head[1] == 0x49;
    final endian = little ? Endian.little : Endian.big;
    final bd = ByteData.sublistView(Uint8List.fromList(head));
    f.setPositionSync(bd.getUint32(4, endian));
    final n = ByteData.sublistView(Uint8List.fromList(f.readSync(2)))
        .getUint16(0, endian);
    final tags = <int, List<int>>{};
    for (var i = 0; i < n; i++) {
      final e = Uint8List.fromList(f.readSync(12));
      final ed = ByteData.sublistView(e);
      final tag = ed.getUint16(0, endian);
      final type = ed.getUint16(2, endian);
      final count = ed.getUint32(4, endian);
      if (!_wantedTags.contains(tag)) continue;
      final size = _typeSize[type];
      if (size == null) continue;
      List<int> read(ByteData d) => [
            for (var i = 0; i < count; i++)
              switch (type) {
                1 => d.getUint8(i),
                3 => d.getUint16(i * 2, endian),
                _ => d.getUint32(i * 4, endian),
              }
          ];
      if (size * count <= 4) {
        tags[tag] = read(ByteData.sublistView(e, 8, 8 + size * count));
      } else {
        final off = ed.getUint32(8, endian);
        final save = f.positionSync();
        f.setPositionSync(off);
        final raw = Uint8List.fromList(f.readSync(size * count));
        f.setPositionSync(save);
        tags[tag] = read(ByteData.sublistView(raw));
      }
    }
    return _Tiff(
      f,
      tags[256]!.first,
      tags[257]!.first,
      tags[277]?.first ?? 1,
      tags[259]?.first ?? 1,
      tags[278]?.first ?? tags[257]!.first,
      tags[273]!,
      tags[279] ?? const [],
      tags[317]?.first ?? 1,
      little,
    );
  }

  /// Decoded bytes for one strip (rows * width * samples).
  Uint8List strip(int index) {
    final rows = (index + 1) * rowsPerStrip <= height
        ? rowsPerStrip
        : height - index * rowsPerStrip;
    final expected = rows * width * samples;
    file.setPositionSync(stripOffsets[index]);
    final raw = Uint8List.fromList(
        file.readSync(stripBytes.isEmpty ? expected : stripBytes[index]));
    final data = compression == 5 ? lzwDecode(raw, expected) : raw;
    if (predictor == 2) {
      for (var r = 0; r < rows; r++) {
        final o = r * width * samples;
        if (o + width * samples <= data.length) {
          undoPredictor(
              Uint8List.sublistView(data, o, o + width * samples), width, samples);
        }
      }
    }
    return data;
  }

  int get stripCount => stripOffsets.length;
}

void main(List<String> args) {
  final opts = <String, String>{};
  for (var i = 0; i + 1 < args.length; i++) {
    if (args[i].startsWith('--')) opts[args[i].substring(2)] = args[++i];
  }
  final inPath = opts['in'] ?? 'dem_src/lroc_color_poles.tif';
  final outPath = opts['out'] ?? 'assets/terrain/moon.acroalb';
  final outW = int.parse(opts['width'] ?? '2048');
  final outH = outW ~/ 2;

  if (!File(inPath).existsSync()) {
    stderr.writeln('source not found: $inPath');
    exitCode = 2;
    return;
  }

  final t = _Tiff.open(inPath);
  stdout.writeln('source ${t.width}x${t.height} samples=${t.samples} '
      'compression=${t.compression} predictor=${t.predictor} '
      'strips=${t.stripCount}');

  // Box-filter straight into the output grid, strip by strip, so the 518 MB
  // source never has to be resident.
  final acc = Float64List(outW * outH * 3);
  final counts = Int32List(outW * outH);

  for (var s = 0; s < t.stripCount; s++) {
    final data = t.strip(s);
    final rows = (s + 1) * t.rowsPerStrip <= t.height
        ? t.rowsPerStrip
        : t.height - s * t.rowsPerStrip;
    for (var r = 0; r < rows; r++) {
      final y = s * t.rowsPerStrip + r;
      final ty = (y * outH ~/ t.height).clamp(0, outH - 1);
      final rowBase = r * t.width * t.samples;
      for (var x = 0; x < t.width; x++) {
        final o = rowBase + x * t.samples;
        if (o + 2 >= data.length) break;
        final tx = (x * outW ~/ t.width).clamp(0, outW - 1);
        final di = (ty * outW + tx);
        acc[di * 3] += data[o].toDouble();
        acc[di * 3 + 1] += data[o + 1].toDouble();
        acc[di * 3 + 2] += data[o + 2].toDouble();
        counts[di]++;
      }
    }
    if (s % 20 == 0) stdout.writeln('  strip $s / ${t.stripCount}');
  }
  t.file.closeSync();

  final rgb = Uint8List(outW * outH * 3);
  var filled = 0;
  for (var i = 0; i < outW * outH; i++) {
    if (counts[i] == 0) continue;
    filled++;
    for (var c = 0; c < 3; c++) {
      rgb[i * 3 + c] = (acc[i * 3 + c] / counts[i]).round().clamp(0, 255);
    }
  }
  stdout.writeln('filled $filled / ${outW * outH} texels');

  final header = ByteData(16);
  header.setUint32(0, magic0);
  header.setUint32(4, magic1);
  header.setUint32(8, outW);
  header.setUint32(12, outH);
  final out = File(outPath);
  out.parent.createSync(recursive: true);
  out.writeAsBytesSync(
      Uint8List.fromList([...header.buffer.asUint8List(), ...rgb]));
  stdout.writeln('wrote $outPath ${outW}x$outH  '
      '${((16 + rgb.length) / 1024 / 1024).toStringAsFixed(1)} MB');

  // Spot-check: maria are markedly darker than highlands, and if the decode
  // desynced this is where it shows as noise instead of contrast.
  int lum(double latDeg, double lonDeg) {
    final x = (((lonDeg + 180) / 360) * outW).floor().clamp(0, outW - 1);
    final y = (((90 - latDeg) / 180) * outH).floor().clamp(0, outH - 1);
    final i = (y * outW + x) * 3;
    return ((rgb[i] + rgb[i + 1] + rgb[i + 2]) / 3).round();
  }
  stdout.writeln('  Mare Tranquillitatis (mare):  ${lum(8.5, 31.4)}');
  stdout.writeln('  Oceanus Procellarum (mare):   ${lum(18.4, -57.4)}');
  stdout.writeln('  southern highlands:           ${lum(-40, 10)}');
  stdout.writeln('  far-side highlands:           ${lum(0, 160)}');
}
