// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Procedural tiles for colony buildings: a concrete facade, a glazing sheet,
/// and the emissive mask that lights its panes at night.
///
/// Pure byte generators — no GPU, no `dart:ui` — for the same reason the
/// scatter bakes are: they can be unit tested, and they cost no asset files to
/// ship or license.
///
/// The mullions live HERE rather than in geometry. At ten thousand buildings a
/// per-pane quad is the difference between a frame and a slideshow, so the
/// window grid is drawn into the texture once and every tower in the colony
/// samples it.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import '../../../domain/architecture/architecture_style.dart';

class CityTextureBakes {
  CityTextureBakes._();

  /// How many masonries the facade atlas carries. One texture, one material,
  /// one draw call — and a street that is not all the same colour.
  ///
  /// The alternative was a material per masonry, which is a draw call per
  /// masonry per body and throws away the archetype batching the whole colony
  /// renderer is built on. Same trick the ground palette already uses, one
  /// axis over: the palette bands along U and holds flat colours, this bands
  /// along U and holds tiling detail, with V left free to repeat up a wall.
  static const int facadeMaterials = kFacadeMaterials;

  /// Index of the plain precast band — the one an industrial shed and the
  /// utilitarian kit want.
  static const int facadePrecast = FacadeMaterial.precast;

  /// Opaque wall: an ATLAS of masonries, banded along U.
  ///
  /// Each band is seamless left-to-right within itself and top-to-bottom over
  /// the whole tile, so a wall segment maps one band across it and V repeats
  /// freely up the storeys. Callers must inset their U by a texel or two — see
  /// [BuildingGenerator], which does — because a mip level averages across the
  /// band boundary and would otherwise bleed the neighbour's brick in at
  /// distance.
  ///
  /// The set is drawn off the reference cities: common red brick and buff
  /// brick are most of the Third Ward and Wicker Park, cream terracotta and
  /// grey limestone are most of the Loop, and painted render is what a
  /// low-rent corner block gets when someone has had a go at it.
  static Uint8List facade(int size) {
    final out = Uint8List(size * size * 4);
    // Band edges at the same fractions [BuildingGenerator.bandUV] samples
    // at, so a count that does not divide the size leaves no unwritten
    // column at the right edge and no band a texel off its sampler.
    for (var m = 0; m < facadeMaterials; m++) {
      final x0 = m * size ~/ facadeMaterials;
      final x1 = (m + 1) * size ~/ facadeMaterials;
      _facadeBand(out, size, x0, x1 - x0, m);
    }
    return out;
  }

  /// One masonry, written into columns [x0, x0+w) of [out].
  static void _facadeBand(
      Uint8List out, int size, int x0, int w, int material) {
    // A fresh generator per band, so adding a band cannot reshuffle the grain
    // of the ones beside it.
    final rnd = math.Random(0xB21C + material * 7919);

    // (base colour, mortar colour, brick w, course h, grime, glossy)
    final ({List<int> face, List<int> joint, int bw, int ch, double grime})
        kit = switch (material) {
      // Common red brick: small units, deep mortar, heavy weathering. The
      // default wall of every one of the reference photographs.
      0 => (face: [148, 82, 62], joint: [126, 116, 106], bw: 16, ch: 6, grime: 0.55),
      // Buff / brown brick.
      1 => (face: [150, 124, 94], joint: [132, 124, 112], bw: 16, ch: 6, grime: 0.45),
      // Cream glazed terracotta: big units, tight joints, barely weathers —
      // which is exactly why the Loop's terracotta towers still look new.
      2 => (face: [214, 204, 182], joint: [200, 192, 174], bw: 32, ch: 16, grime: 0.16),
      // Limestone ashlar: large smooth blocks, pale grey.
      3 => (face: [178, 176, 168], joint: [160, 158, 152], bw: 42, ch: 21, grime: 0.3),
      // Painted render: flat, no unit at all, and it always looks tired.
      4 => (face: [196, 178, 140], joint: [196, 178, 140], bw: 0, ch: 0, grime: 0.62),
      // Dark pressed brick.
      5 => (face: [104, 62, 56], joint: [96, 90, 84], bw: 16, ch: 6, grime: 0.5),
      // Precast concrete panel — the pre-atlas wall, kept because it is right
      // for a works and for the utilitarian kit.
      6 => (face: [168, 168, 166], joint: [120, 120, 120], bw: 0, ch: 0, grime: 0.35),
      // Photovoltaic modules: deep blue cells in an aluminium frame, and
      // clean — a farm washes its panels.
      8 => (face: [38, 58, 104], joint: [200, 206, 214], bw: 0, ch: 0, grime: 0.0),
      // Paving: gravel-grey concrete, bay joints, weathered but not sooted.
      9 => (face: [134, 132, 126], joint: [108, 106, 100], bw: 0, ch: 0, grime: 0.1),
      // Bare and galvanised steel: stacks, racks, gantries, masts, fences.
      10 => (face: [172, 178, 186], joint: [136, 142, 150], bw: 0, ch: 0, grime: 0.1),
      // Painted sheet metal, white: tanks, sheds, containers.
      11 => (face: [226, 228, 230], joint: [186, 190, 194], bw: 0, ch: 0, grime: 0.12),
      // Industrial blue, safety red, plant yellow: trims, signs, machines.
      12 => (face: [42, 88, 146], joint: [32, 68, 116], bw: 0, ch: 0, grime: 0.15),
      13 => (face: [178, 46, 40], joint: [140, 36, 32], bw: 0, ch: 0, grime: 0.15),
      14 => (face: [216, 172, 40], joint: [172, 136, 30], bw: 0, ch: 0, grime: 0.15),
      // Profiled metal cladding: vertical ribs, no courses.
      _ => (face: [150, 154, 158], joint: [116, 120, 124], bw: 0, ch: 0, grime: 0.28),
    };

    // Unit sizes are snapped so a whole number fits the band in each axis.
    // Off by even one texel and the band tiles with a visible step in the
    // course lines every time it wraps.
    final bw = kit.bw == 0 ? 0 : math.max(4, w ~/ math.max(1, w ~/ kit.bw));
    final ch = kit.ch == 0
        ? 0
        // Even course count, so the half-brick offset alternates back to
        // where it started at the wrap.
        : math.max(3, size ~/ math.max(2, (size ~/ kit.ch) ~/ 2 * 2));

    for (var y = 0; y < size; y++) {
      for (var x = 0; x < w; x++) {
        final i = ((y * size) + x0 + x) * 4;
        var r = kit.face[0].toDouble();
        var g = kit.face[1].toDouble();
        var b = kit.face[2].toDouble();

        if (bw > 0 && ch > 0) {
          final course = y ~/ ch;
          // Running bond: every other course shifts half a unit.
          final shift = course.isOdd ? bw ~/ 2 : 0;
          final ux = (x + shift) % w;
          final inUnit = ux % bw, inCourse = y % ch;
          // Per-unit tone. Real brick is never one colour, and this variation
          // is most of what stops a wall reading as a printed pattern.
          final unit = ((ux ~/ bw) * 31 + course * 17) % 11;
          final shade = 0.86 + unit * 0.026;
          r *= shade;
          g *= shade;
          b *= shade;
          // Mortar: the bed joint reads heavier than the perpend, which is
          // what makes courses legible from across a street.
          if (inCourse < math.max(1, ch ~/ 6)) {
            r = kit.joint[0].toDouble();
            g = kit.joint[1].toDouble();
            b = kit.joint[2].toDouble();
          } else if (inUnit < math.max(1, bw ~/ 12)) {
            r = (r + kit.joint[0]) / 2;
            g = (g + kit.joint[1]) / 2;
            b = (b + kit.joint[2]) / 2;
          }
        } else if (material == facadePrecast) {
          // Precast: a seam grid at panel scale rather than unit scale.
          final panel = math.max(8, w ~/ 2);
          if (y % (panel * 2) <= 1) {
            r *= 0.72;
            g *= 0.72;
            b *= 0.72;
          }
          if (x % panel <= 1) {
            r *= 0.86;
            g *= 0.86;
            b *= 0.86;
          }
        } else if (material == FacadeMaterial.photovoltaic) {
          // Modules two to a band, portrait, framed, with the cell grid
          // inside: what a solar table is from the air and from the fence.
          final mw = math.max(8, w ~/ 2);
          final mh = math.max(8, size ~/ 8);
          final ix = x % mw, iy = y % mh;
          if (ix < 2 || iy < 2 || ix >= mw - 2 || iy >= mh - 2) {
            r = kit.joint[0].toDouble();
            g = kit.joint[1].toDouble();
            b = kit.joint[2].toDouble();
          } else {
            final cw = math.max(2, (mw - 4) ~/ 6), chh = math.max(2, (mh - 4) ~/ 10);
            if ((ix - 2) % cw == 0 || (iy - 2) % chh == 0) {
              r *= 1.6;
              g *= 1.5;
              b *= 1.3;
            }
          }
        } else if (material == FacadeMaterial.pavement) {
          // Paving: a bay joint each way at panel scale, a coarser speckle
          // than a wall's grain, and no direction to it at all.
          final bay = math.max(8, w ~/ 2), bayV = math.max(8, size ~/ 8);
          if (x % bay <= 1 || y % bayV <= 1) {
            r = kit.joint[0].toDouble();
            g = kit.joint[1].toDouble();
            b = kit.joint[2].toDouble();
          } else {
            final fleck = ((x * 7 + y * 13) % 23 == 0) ? 0.88 : ((x * 5 + y * 3) % 19 == 0 ? 1.08 : 1.0);
            r *= fleck;
            g *= fleck;
            b *= fleck;
          }
        } else if (material >= FacadeMaterial.steel &&
            material <= FacadeMaterial.safetyYellow) {
          // Painted and bare metal: a panel seam each way, and on steel a
          // soft highlight across the band that reads as a brushed sheen.
          final seamV = math.max(8, size ~/ 6), seamU = math.max(8, w ~/ 2);
          if (y % seamV <= 1 || x % seamU <= 1) {
            r = kit.joint[0].toDouble();
            g = kit.joint[1].toDouble();
            b = kit.joint[2].toDouble();
          } else if (material == FacadeMaterial.steel) {
            final t = (x % w) / w;
            final lit = 0.82 + 0.3 * math.sin(t * math.pi);
            r *= lit;
            g *= lit;
            b *= lit;
          }
        } else if (material == FacadeMaterial.metalPanel) {
          // Profiled metal: a vertical rib every few texels, shaded as if lit
          // from one side so the ribs read as a section, not as stripes.
          final rib = math.max(3, w ~/ 12);
          final t = (x % rib) / rib;
          final lit = 0.78 + 0.34 * math.sin(t * math.pi);
          r *= lit;
          g *= lit;
          b *= lit;
        }

        // Grain, then grime that gathers downward — walls are dirtiest under
        // their own courses and cleanest where the rain runs.
        final grain = (rnd.nextDouble() - 0.5) * 15;
        r += grain;
        g += grain;
        b += grain;
        final streak = math.sin(x * 0.63) * math.sin(x * 0.117 + material);
        if (streak > 0.5) {
          final soot = 1 - kit.grime * 0.14;
          r *= soot;
          g *= soot;
          b *= soot;
        }

        out[i] = r.clamp(0, 255).round();
        out[i + 1] = g.clamp(0, 255).round();
        out[i + 2] = b.clamp(0, 255).round();
        out[i + 3] = 255;
      }
    }
  }

  /// Glazing sheet: RGBA, alpha 0 in the mullions so the wall behind shows
  /// through and the band reads as separate panes rather than a ribbon.
  static Uint8List glazing(int size, {int panesPerTile = 6}) {
    final out = Uint8List(size * size * 4);
    final cell = math.max(2, size ~/ panesPerTile);
    const frame = 2; // mullion half-width in texels
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final i = (y * size + x) * 4;
        final ex = x % cell, ey = y % cell;
        final isMullion =
            ex < frame || ey < frame || ex >= cell - frame || ey >= cell - frame;
        if (isMullion) {
          out[i] = 46;
          out[i + 1] = 48;
          out[i + 2] = 52;
          out[i + 3] = 255; // opaque frame
        } else {
          // Cool tinted glass, slightly darker toward the pane bottom so it
          // catches a gradient instead of reading as a flat swatch.
          final t = ey / cell;
          final shade = 1.0 - t * 0.25;
          out[i] = (78 * shade).round();
          out[i + 1] = (104 * shade).round();
          out[i + 2] = (128 * shade).round();
          out[i + 3] = 235;
        }
      }
    }
    return out;
  }

  /// Emissive mask for [glazing]: which panes are lit, and how warmly.
  ///
  /// A deterministic subset is lit rather than all of them — a fully lit
  /// facade reads as a texture, not a building — and the lit ones vary in
  /// colour temperature so a tower at night has some life in it. The renderer
  /// scales the whole thing by the night factor, so this is the pattern, not
  /// the brightness.
  static Uint8List windowEmissive(
    int size, {
    int panesPerTile = 6,
    double litFraction = 0.45,
    int seed = 0x11FE,
  }) {
    final out = Uint8List(size * size * 4);
    final cell = math.max(2, size ~/ panesPerTile);
    const frame = 2;
    final rnd = math.Random(seed);
    final cells = math.max(1, size ~/ cell);
    // Decide each pane up front so every texel of a pane agrees.
    final lit = List<double>.generate(cells * cells, (_) {
      if (rnd.nextDouble() > litFraction) return 0.0;
      return 0.55 + rnd.nextDouble() * 0.45;
    });
    final warm = List<double>.generate(cells * cells, (_) => rnd.nextDouble());

    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final i = (y * size + x) * 4;
        final cx = (x ~/ cell).clamp(0, cells - 1);
        final cy = (y ~/ cell).clamp(0, cells - 1);
        final ex = x % cell, ey = y % cell;
        final isMullion =
            ex < frame || ey < frame || ex >= cell - frame || ey >= cell - frame;
        final level = isMullion ? 0.0 : lit[cy * cells + cx];
        if (level <= 0) {
          out[i] = 0;
          out[i + 1] = 0;
          out[i + 2] = 0;
          out[i + 3] = 255;
          continue;
        }
        // Warm tungsten through to cool office fluorescent.
        final w = warm[cy * cells + cx];
        out[i] = (255 * level).round();
        out[i + 1] = (255 * level * (0.82 + w * 0.16)).round();
        out[i + 2] = (255 * level * (0.58 + w * 0.40)).round();
        out[i + 3] = 255;
      }
    }
    return out;
  }

  /// Ground-patch palette: one vertical swatch per patch kind.
  ///
  /// A palette rather than a per-patch colour because the mesh format carries
  /// position, normal and UV only — no vertex colour — and one material per
  /// colour would be five draws for what is a single sheet of ground. Every
  /// vertex of a patch samples the CENTRE of its swatch, so no filtering or
  /// mip level can bleed one kind's colour into its neighbour.
  static Uint8List groundPalette(int size, {int swatches = 10}) {
    // road, residential, commercial, industrial, support, CURSOR, REFUSED,
    // SITE-OK, SITE-STEEP, LEAF — the heatmap pair paints placement, which
    // needs to say "here, but the ground is against you" as well as yes/no;
    // the leaf is the crown of every sprawl tree, its own band so the green
    // of a suburb can be tuned without recolouring its lawns.
    // Count must match `kGroundSwatches` in city_nodes.dart.
    const colours = [
      [92, 94, 99],
      [86, 128, 96],
      [72, 108, 138],
      [138, 116, 74],
      [96, 102, 112],
      [120, 240, 255],
      [235, 84, 64],
      [96, 210, 128],
      [226, 176, 72],
      [62, 108, 54],
    ];
    final out = Uint8List(size * size * 4);
    final band = math.max(1, size ~/ swatches);
    final rnd = math.Random(0x0ADD);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final i = (y * size + x) * 4;
        final swatch = math.min(x ~/ band, colours.length - 1);
        final c = colours[swatch];
        var r = c[0].toDouble(), g = c[1].toDouble(), b = c[2].toDouble();

        if (swatch == 0) {
          // The ROAD swatch is a real tile, not a flat colour: a cell maps its
          // whole quad across it, so what is painted here is the road surface.
          // Aggregate speckle first — a uniform grey slab reads as a hole in
          // the ground rather than as pavement.
          final speck = (rnd.nextDouble() - 0.5) * 26;
          r += speck;
          g += speck;
          b += speck;
          final u = (x % band) / band, v = (y % band) / band;
          // Dashed centre lines along BOTH axes. The grid network has no
          // travel direction to key off, and a cross reads correctly either
          // way: on a straight run it is a centre line, at a junction it is
          // the junction markings.
          const lineHalf = 0.022;
          bool dash(double along) => (along * 6).floor().isEven;
          final onV = (u - 0.5).abs() < lineHalf && dash(v);
          final onH = (v - 0.5).abs() < lineHalf && dash(u);
          if (onV || onH) {
            r = 196;
            g = 190;
            b = 150;
          } else if (u < 0.045 || u > 0.955 || v < 0.045 || v > 0.955) {
            // Curb: a touch lighter than the carriageway, so a run of cells
            // shows its edges and the road is legible against dark ground.
            r += 26;
            g += 26;
            b += 26;
          }
        } else {
          // A little vertical grain so a big zoned block is not a flat slab.
          final n = ((y * 37) % 11) - 5;
          r += n;
          g += n;
          b += n;
        }
        out[i] = r.clamp(0, 255).round();
        out[i + 1] = g.clamp(0, 255).round();
        out[i + 2] = b.clamp(0, 255).round();
        out[i + 3] = 255;
      }
    }
    return out;
  }

  /// The spline-road surface: asphalt with curbs at the edges and a dashed
  /// centre line ALONG the tile.
  ///
  /// Separate from [groundPalette]'s road swatch on purpose. The grid draws a
  /// square cell, where markings must read at any junction, so its tile
  /// carries a cross; a ribbon has a direction, and wrapping the cross tile
  /// along it would paint transverse stripes across the carriageway every few
  /// metres. U runs ACROSS the road, V along it.
  /// The alley surface: worn concrete with a centre drainage channel, patched
  /// asphalt, and NO curbs and no centre line.
  ///
  /// A separate tile rather than a narrow road strip, because the road strip's
  /// two defining features are the things an alley does not have. Drawn with
  /// one it read as a very small street, which is the one thing that would
  /// stop an alley doing its job of looking like the back of the block.
  static Uint8List alleyStrip(int size) {
    final out = Uint8List(size * size * 4);
    final rnd = math.Random(0x0A11E4);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final i = (y * size + x) * 4;
        final u = x / size;
        var v = 118.0 + (rnd.nextDouble() - 0.5) * 20;
        // Centre channel: darker, damp, and slightly sunken-looking.
        if ((u - 0.5).abs() < 0.05) v *= 0.72;
        // Patches — an alley is resurfaced a square at a time, never a lane at
        // a time, and the mismatched patches are most of what reads as "back".
        final px = (x ~/ math.max(1, size ~/ 5));
        final py = (y ~/ math.max(1, size ~/ 5));
        if ((px * 5 + py * 3) % 7 < 2) v *= 0.86;
        // Slab joints, cast transverse.
        if (y % math.max(1, size ~/ 4) <= 1) v *= 0.8;
        final c = v.clamp(0.0, 255.0).round();
        out[i] = c;
        out[i + 1] = c;
        out[i + 2] = (c * 0.97).round();
        out[i + 3] = 255;
      }
    }
    return out;
  }

  /// How many bands the road atlas carries along U.
  static const int roadBands = 8;

  /// The bands of the road atlas, by index. Every carriageway in the world
  /// — a dirt-free local street, an eight-lane expressway, a viaduct deck —
  /// is drawn from these: an asphalt ribbon the full width of the road,
  /// then one thin strip per painted line, each strip mapping one band
  /// across itself. The paint is geometry, not texture, so a road with any
  /// number of lanes draws from ONE tile and the lane count is a number the
  /// road class carries rather than a texture somebody has to bake.
  ///
  /// The single two-lane strip this replaced was stretched across every
  /// road regardless of width, which is why a 36 m interstate had one
  /// dashed line down the middle of it like a lane in a car park.
  static const int roadAsphalt = 0;
  static const int roadConcrete = 1;
  static const int roadWhite = 2;
  static const int roadYellow = 3;
  static const int roadDashedWhite = 4;
  static const int roadDashedYellow = 5;
  static const int roadHatch = 6;
  static const int roadShoulder = 7;

  /// Metres of road one repeat of the atlas covers along V. Twelve, because
  /// a lane line is a three-metre dash and a nine-metre gap, and a band
  /// that holds exactly one cycle tiles seamlessly.
  static const double roadTileM = 12.0;

  /// The road atlas: [roadBands] bands along U, seamless along V.
  ///
  /// U runs ACROSS whichever strip maps the band, V along the road. The
  /// dashed bands are painted for the first quarter of V — three metres of
  /// [roadTileM] — and asphalt for the rest, so a strip that advances V by
  /// distance travelled gets a real dash cycle. Callers inset their U a
  /// texel or two from the band edges, as the facade atlas's callers do,
  /// because a mip level averages across the boundary.
  static Uint8List roadAtlas(int size) {
    final out = Uint8List(size * size * 4);
    final rnd = math.Random(0x0AD5);
    final bandW = size / roadBands;
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final i = (y * size + x) * 4;
        final band = math.min(roadBands - 1, x ~/ bandW);
        final v = y / size;
        var r = 92.0, g = 94.0, b = 99.0;
        // Aggregate speckle: a uniform grey slab reads as a hole, not tarmac.
        final speck = (rnd.nextDouble() - 0.5) * 26;
        r += speck;
        g += speck;
        b += speck;
        void paint(int pr, int pg, int pb, {double wear = 12}) {
          final w = (rnd.nextDouble() - 0.5) * wear;
          r = pr + w;
          g = pg + w;
          b = pb + w;
        }

        switch (band) {
          case roadConcrete:
            paint(168, 168, 164, wear: 14);
            // A transverse joint every quarter tile, as a poured median has.
            if (y % math.max(1, size ~/ 4) <= 1) {
              r *= 0.8;
              g *= 0.8;
              b *= 0.8;
            }
          case roadWhite:
            paint(222, 222, 214);
          case roadYellow:
            paint(222, 180, 46);
          case roadDashedWhite:
            if (v < 0.25) paint(222, 222, 214);
          case roadDashedYellow:
            if (v < 0.25) paint(222, 180, 46);
          case roadHatch:
            // Yellow chevrons on asphalt: the gore and the painted median.
            final period = math.max(4, size ~/ 8);
            if ((x + y) % period < math.max(1, period ~/ 4)) {
              paint(222, 180, 46);
            }
          case roadShoulder:
            // A touch paler and greyer than the running lanes: a shoulder is
            // laid to a different spec and reads as one from the air.
            r += 12;
            g += 12;
            b += 10;
          default:
            break;
        }
        out[i] = r.clamp(0, 255).round();
        out[i + 1] = g.clamp(0, 255).round();
        out[i + 2] = b.clamp(0, 255).round();
        out[i + 3] = 255;
      }
    }
    return out;
  }

  /// The sidewalk surface: concrete flags with transverse joints, a faint
  /// longitudinal joint, and the CURB STONES along the road edge.
  ///
  /// U runs ACROSS the walk — 0 at the curb, 1 at the building line — so the
  /// curb band lives at u < 0.06 and the emitter can wrap the same band down
  /// the curb's vertical face. V runs along the walk, four flags per tile.
  static Uint8List sidewalkStrip(int size) {
    final out = Uint8List(size * size * 4);
    final rnd = math.Random(0x51DE);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final i = (y * size + x) * 4;
        final u = x / size;
        var v = 146.0 + (rnd.nextDouble() - 0.5) * 16;
        if (u < 0.06) {
          // Curb stones: a touch lighter than the flags, jointed shorter.
          v = 160.0 + (rnd.nextDouble() - 0.5) * 12;
          if (y % math.max(1, size ~/ 8) <= 1) v *= 0.8;
        } else {
          // Flag joints: transverse every quarter tile, one longitudinal.
          if (y % math.max(1, size ~/ 4) <= 1) v *= 0.8;
          if ((u - 0.53).abs() < 0.01) v *= 0.85;
          // Per-flag tone drift — a pavement is poured a flag at a time.
          final px = ((x - size * 0.06) ~/ math.max(1, size ~/ 2));
          final py = y ~/ math.max(1, size ~/ 4);
          if ((px * 3 + py * 5) % 5 == 0) v *= 0.94;
        }
        final c = v.clamp(0.0, 255.0).round();
        out[i] = c;
        out[i + 1] = c;
        out[i + 2] = (c * 1.01).clamp(0, 255).round();
        out[i + 3] = 255;
      }
    }
    return out;
  }

  /// The dirt-path surface: graded earth with wheel ruts, no curbs and no
  /// paint — a path is a road to the network and a track to the eye.
  static Uint8List dirtStrip(int size) {
    final out = Uint8List(size * size * 4);
    final rnd = math.Random(0xD1127);
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final i = (y * size + x) * 4;
        final u = x / size;
        var r = 118.0, g = 96.0, b = 72.0;
        final speck = (rnd.nextDouble() - 0.5) * 30;
        r += speck;
        g += speck * 0.9;
        b += speck * 0.8;
        // Twin wheel ruts, compacted darker.
        if ((u - 0.3).abs() < 0.055 || (u - 0.7).abs() < 0.055) {
          r *= 0.82;
          g *= 0.82;
          b *= 0.82;
        }
        // Soft verge fade at the edges rather than a curb.
        if (u < 0.08 || u > 0.92) {
          r *= 0.9;
          g *= 0.94;
          b *= 0.9;
        }
        out[i] = r.clamp(0, 255).round();
        out[i + 1] = g.clamp(0, 255).round();
        out[i + 2] = b.clamp(0, 255).round();
        out[i + 3] = 255;
      }
    }
    return out;
  }
}
