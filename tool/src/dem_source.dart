// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Shared elevation-raster access for the bake tools (`bake_dem.dart`,
/// `bake_normals.dart`): a minimal TIFF reader plus [HeightSource], which
/// yields rows of METRES regardless of what the file encodes.
///
/// Two sources exist because the survey products come in two shapes:
///
/// - [SingleTiffHeight] — one raster of real elevations (ldem_64.tif:
///   float32 kilometres).
/// - [ElevBathHeight] — the Blue Marble GEBCO_08 pair: TWO 8-bit rasters,
///   land in one (ocean masked to 0), ocean in the other (INVERTED, land
///   masked to 255). 8 bits cannot span both ranges, hence the split; the
///   value->metre ramps are linear per NASA's dataset page (see
///   dem_src/README.md): elevation 0..[elevMaxM] over 0..255, depth
///   0..-[bathMaxM] over 255..0.
library;

import 'dart:io';
import 'dart:typed_data';

/// Tags consumed: width, height, bits/sample, compression, strip offsets,
/// samples/pixel, rows/strip, sample format.
const _wantedTags = {256, 257, 258, 259, 273, 277, 278, 339};

/// Bytes per element for the integer TIFF types (rationals/ASCII/doubles only
/// appear in tags outside [_wantedTags]).
const _typeSize = <int, int>{1: 1, 3: 2, 4: 4};

/// Minimal TIFF directory reader for the uncompressed single-channel rasters
/// the DEM products ship as. Handles multi-row strips (the GEBCO pair packs
/// many rows per strip); compression is still out of scope — the colour bake
/// (`bake_albedo.dart`) keeps its own LZW-capable reader.
class DemTiff {
  DemTiff(this.file, this.width, this.height, this.bits, this.sampleFormat,
      this.rowsPerStrip, this.stripOffsets, this.little);

  final RandomAccessFile file;
  final int width, height, bits, sampleFormat, rowsPerStrip;
  final List<int> stripOffsets;
  final bool little;

  static DemTiff open(String path) {
    final f = File(path).openSync();
    final head = f.readSync(8);
    final little = head[0] == 0x49 && head[1] == 0x49;
    final bd = ByteData.sublistView(Uint8List.fromList(head));
    final ifd = bd.getUint32(4, little ? Endian.little : Endian.big);
    f.setPositionSync(ifd);
    final endian = little ? Endian.little : Endian.big;
    final n = ByteData.sublistView(Uint8List.fromList(f.readSync(2)))
        .getUint16(0, endian);

    int? width, height, bitsPerSample, sampleFormat, compression, samples;
    int? rowsPerStrip;
    var stripOffsets = <int>[];
    for (var i = 0; i < n; i++) {
      final e = Uint8List.fromList(f.readSync(12));
      final ed = ByteData.sublistView(e);
      final tag = ed.getUint16(0, endian);
      final type = ed.getUint16(2, endian);
      final count = ed.getUint32(4, endian);
      // Skip every tag we do not consume BEFORE decoding anything — geo-key
      // rationals/ASCII/doubles read through an integer path walk off the end
      // of the value buffer.
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
        case 277:
          samples = values.first;
        case 278:
          rowsPerStrip = values.first;
        case 339:
          sampleFormat = values.first;
      }
    }
    if (width == null || height == null) {
      throw StateError('TIFF missing dimensions');
    }
    if (compression != null && compression != 1) {
      throw StateError(
          'compressed TIFF (compression=$compression) not supported here; '
          'export an uncompressed copy');
    }
    if (samples != null && samples != 1) {
      throw StateError('expected a single-channel raster, got $samples '
          'samples/pixel — this reader is for elevation data, not colour');
    }
    final rps = rowsPerStrip ?? height;
    final expectedStrips = (height + rps - 1) ~/ rps;
    if (stripOffsets.length != expectedStrips) {
      throw StateError('expected $expectedStrips strips '
          '($rps rows each for $height rows), got ${stripOffsets.length}');
    }
    return DemTiff(f, width, height, bitsPerSample ?? 8, sampleFormat ?? 1,
        rps, stripOffsets, little);
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
    file.setPositionSync(
        stripOffsets[y ~/ rowsPerStrip] + (y % rowsPerStrip) * rowBytes);
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

  void close() => file.closeSync();
}

/// Rows of signed elevation METRES, streamed top (north) to bottom.
abstract class HeightSource {
  int get width;
  int get height;
  Float64List row(int y);
  void close();
}

/// A single raster of real elevations, scaled by [unitScale] (1000 for
/// kilometre products like ldem_64.tif).
class SingleTiffHeight implements HeightSource {
  SingleTiffHeight(String path, this.unitScale)
      : _tiff = DemTiff.open(path) {
    _scratch = Uint8List(_tiff.rowBytes);
  }

  final DemTiff _tiff;
  final double unitScale;
  late final Uint8List _scratch;

  @override
  int get width => _tiff.width;
  @override
  int get height => _tiff.height;

  @override
  Float64List row(int y) {
    final r = _tiff.readRow(y, _scratch);
    if (unitScale != 1.0) {
      for (var x = 0; x < r.length; x++) {
        r[x] *= unitScale;
      }
    }
    return r;
  }

  @override
  void close() => _tiff.close();
}

/// The GEBCO_08 8-bit complementary pair combined into signed metres.
///
/// Per texel: the ELEV raster is authoritative for land (ocean masked to 0),
/// the BATH raster for ocean (inverted: 255 = land/surface, 0 = deepest).
/// A texel with elev == 0 and bath == 255 is coastline at 0 m.
class ElevBathHeight implements HeightSource {
  ElevBathHeight(String elevPath, String bathPath,
      {required this.elevMaxM, required this.bathMaxM})
      : _elev = DemTiff.open(elevPath),
        _bath = DemTiff.open(bathPath) {
    if (_elev.width != _bath.width || _elev.height != _bath.height) {
      throw StateError('elev ${_elev.width}x${_elev.height} and bath '
          '${_bath.width}x${_bath.height} rasters must match');
    }
    if (_elev.bits != 8 || _bath.bits != 8) {
      throw StateError('the elev/bath pair path expects 8-bit rasters '
          '(got ${_elev.bits}/${_bath.bits})');
    }
    _scratchE = Uint8List(_elev.rowBytes);
    _scratchB = Uint8List(_bath.rowBytes);
  }

  final DemTiff _elev, _bath;

  /// Metres of elevation at grayscale 255 in the elev raster (6400 for the
  /// Blue Marble GEBCO_08 product).
  final double elevMaxM;

  /// Metres of depth at grayscale 0 in the bath raster (8000 for the same).
  final double bathMaxM;

  late final Uint8List _scratchE;
  late final Uint8List _scratchB;

  @override
  int get width => _elev.width;
  @override
  int get height => _elev.height;

  @override
  Float64List row(int y) {
    final e = _elev.readRow(y, _scratchE);
    final b = _bath.readRow(y, _scratchB);
    final out = Float64List(e.length);
    for (var x = 0; x < e.length; x++) {
      if (e[x] > 0) {
        out[x] = e[x] / 255.0 * elevMaxM;
      } else if (b[x] < 255) {
        out[x] = -(255.0 - b[x]) / 255.0 * bathMaxM;
      }
      // else coastline: both masked, 0 m.
    }
    return out;
  }

  @override
  void close() {
    _elev.close();
    _bath.close();
  }
}

/// Builds a [HeightSource] from the shared CLI options: `--in` (+ `--units`)
/// alone is a single raster; adding `--bath` switches to the elev/bath pair
/// (`--in` = land raster) with `--elevmax`/`--bathmax` ramps.
/// A named lat/lon spot-check location for a bake's sanity prints.
class Landmark {
  const Landmark(this.name, this.latDeg, this.lonDeg);
  final String name;
  final double latDeg, lonDeg;
}

/// Spot-check landmarks by the OUTPUT body id (the artefact basename:
/// `earth.acrodem` -> earth). A silently-wrong bake should be caught by its
/// own prints, and probing Earth with Moon maria labels hides exactly that.
List<Landmark> landmarksForOut(String outPath) {
  final base = outPath.replaceAll('\\', '/').split('/').last;
  if (base.startsWith('earth')) {
    return const [
      Landmark('Himalaya (high)', 28.0, 86.9),
      Landmark('Mariana Trench (deep)', 11.35, 142.2),
      Landmark('Amazon basin (near 0)', -3.0, -60.0),
      Landmark('Sahara (bright, land)', 23.0, 13.0),
      Landmark('mid-Pacific (dark, ocean)', 0.0, -160.0),
    ];
  }
  if (base.startsWith('moon')) {
    return const [
      Landmark('Mare Imbrium', 33.0, -16.0),
      Landmark('Apollo 11', 0.67, 23.47),
      Landmark('South Pole-Aitken', -53.0, -169.0),
      Landmark('Mare Crisium (dark)', 17.0, 59.1),
      Landmark('Tycho (bright)', -43.31, -11.36),
    ];
  }
  return const [];
}

/// A (flat, rough) region pair for the normal bake's tilt split print.
(Landmark, Landmark)? flatRoughForOut(String outPath) {
  final base = outPath.replaceAll('\\', '/').split('/').last;
  if (base.startsWith('earth')) {
    return (
      const Landmark('central Pacific abyssal plain', -10.0, -140.0),
      const Landmark('Himalaya', 28.0, 86.9),
    );
  }
  if (base.startsWith('moon')) {
    return (
      const Landmark('Mare Serenitatis', 28.0, 17.5),
      const Landmark('southern highlands', -40.0, 10.0),
    );
  }
  return null;
}

HeightSource heightSourceFromOpts(Map<String, String> opts,
    {required String defaultIn, String defaultUnits = 'm'}) {
  final inPath = opts['in'] ?? defaultIn;
  if (!File(inPath).existsSync()) {
    throw StateError('source not found: $inPath');
  }
  final bathPath = opts['bath'];
  if (bathPath == null) {
    final unitScale = (opts['units'] ?? defaultUnits) == 'km' ? 1000.0 : 1.0;
    return SingleTiffHeight(inPath, unitScale);
  }
  if (!File(bathPath).existsSync()) {
    throw StateError('source not found: $bathPath');
  }
  return ElevBathHeight(inPath, bathPath,
      elevMaxM: double.parse(opts['elevmax'] ?? '6400'),
      bathMaxM: double.parse(opts['bathmax'] ?? '8000'));
}
