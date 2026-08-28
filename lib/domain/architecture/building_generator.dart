// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Builds a building's geometry from primitives.
///
/// Everything is emitted through the same [MeshBuilder] the vegetation and rock
/// generators use, so buildings ride the existing instanced-prop pipeline —
/// LOD selection, imposter baking, two-material batching — instead of needing a
/// renderer of their own. That is what makes ten thousand of them affordable.
///
/// The mesh is split across the two channels a prop already has:
///   * SOLID   — walls, slabs, roofs, curbs, lamp columns. Opaque, back-face
///               culled.
///   * GLAZING — window bands and lamp heads, carried in the prop's alpha-masked
///               channel. These are the surfaces that light up at night, and
///               keeping them in their own draw is what lets the night pass
///               brighten them without touching the walls.
library;

import 'dart:math' as math;

import '../colony/city/city_building_spec.dart';
import '../colony/city/parcel.dart';
import '../scatter/mesh_builder.dart';
import '../scatter/prop_model.dart';
import '../shared/vector3.dart';
import 'architecture_style.dart';
import 'building_massing.dart';

/// What a generated building is made of, beyond its two meshes.
class GeneratedBuilding {
  /// Exterior + interior geometry, ready to instance.
  final PropModel model;

  /// The massing it was built from — kept so lighting, pathing and the parking
  /// pass can read the same numbers the geometry was cut from.
  final BuildingMassing massing;

  /// Street-lamp column bases in building-local metres, for the lighting pass.
  final List<Vector3> lampPosts;

  /// Window-band centres in building-local metres. The night pass emits its
  /// glow sprites from these rather than re-deriving them from the mesh.
  final List<Vector3> windowCentres;

  const GeneratedBuilding({
    required this.model,
    required this.massing,
    this.lampPosts = const [],
    this.windowCentres = const [],
  });
}

/// Detail tiers a building is generated at.
enum BuildingDetail {
  /// Everything: facades, glazing, interior slabs and partitions, roof plant,
  /// parking bays, curbs, lamps.
  full,

  /// Exterior shell, glazing and roof plant. No interior, simplified lot.
  exterior,

  /// A single massing silhouette. What a distant district is drawn from.
  block,
}

class BuildingGenerator {
  const BuildingGenerator({
    this.rules = const BuildingMassingRules(),
    this.windowHeightFraction = 0.55,
    this.lampHeightM = 9,
  });

  final BuildingMassingRules rules;

  /// The kit this generator builds in. Comes from the rules, so the siting and
  /// the detailing can never disagree about which idiom a building is in.
  ArchitectureStyle get style => rules.style;

  BuildingGenerator withStyle(ArchitectureStyle s) => BuildingGenerator(
        rules: rules.withStyle(s),
        windowHeightFraction: windowHeightFraction,
        lampHeightM: lampHeightM,
      );

  /// How much of a storey is glass. 0.55 leaves a spandrel band above and
  /// below, which is what stops a facade reading as a stack of glass boxes.
  final double windowHeightFraction;

  final double lampHeightM;

  GeneratedBuilding generate(
    CityBuildingSpec spec,
    Parcel parcel, {
    int seed = 0,
    BuildingDetail detail = BuildingDetail.full,
  }) {
    final massing = rules.massFor(spec, parcel, seed: seed);
    final b = PropBuilder();
    final lamps = <Vector3>[];
    final windows = <Vector3>[];

    final (bu0, bu1) = bandUV(massing.material);
    final (pu0, pu1) = bandUV(FacadeMaterial.precast);

    if (detail == BuildingDetail.block) {
      // One box covering the whole massing: the distant tier only has to hold
      // the silhouette and the roofline. It still takes the building's own
      // band, so a district does not change colour as it drops to silhouettes.
      final fp = massing.footprint;
      _box(
        b.solid,
        cx: 0,
        cy: 0,
        z0: 0,
        width: fp.width,
        depth: fp.depth,
        height: massing.height,
        uRepeat: math.max(1, (fp.width / 3).round()).toDouble(),
        vRepeat: math.max(1, (massing.height / 3).round()).toDouble(),
        u0: bu0,
        u1: bu1,
      );
      // And its windows: the same per-storey bands the near tiers carry, on
      // the collapsed silhouette. The mullions and the night emissive live
      // in the glazing texture, so a distant tower keeps its facade rhythm
      // by day and lights its windows by night exactly as a near one does —
      // a skyline of dead grey boxes after dark was the tell that the block
      // tier was a different kind of thing.
      _glazing(
        b.foliage,
        MassBox(
          x: 0,
          y: 0,
          z: 0,
          width: fp.width,
          depth: fp.depth,
          height: massing.height,
          floors: math.max(1, massing.height ~/ massing.storeyM),
        ),
        massing.storeyM,
        windows,
      );
      return GeneratedBuilding(
        model: PropModel(solid: b.solid.build(), foliage: b.foliage.build()),
        massing: massing,
        windowCentres: windows,
      );
    }

    final style = massing.style;
    final rnd = math.Random(seed * 2654435761 ^ spec.type.hashCode);
    final roof = _roofVolume(massing);

    for (final v in massing.volumes) {
      // Facade. UVs repeat once per storey vertically and about every 4 m
      // horizontally, so a wall texture keeps a constant real-world scale
      // whatever the building's size — the thing that goes wrong when a mesh
      // is authored once and scaled to fit.
      _box(
        b.solid,
        cx: v.x,
        cy: v.y,
        z0: v.z,
        width: v.width,
        depth: v.depth,
        height: v.height,
        uRepeat: math.max(1, (v.width / 3).round()).toDouble(),
        vRepeat: math.max(1, v.floors).toDouble(),
        u0: bu0,
        u1: bu1,
      );

      if (v.glazed && v.floors > 0) {
        switch (style.rhythm) {
          case FacadeRhythm.ribbon:
            _glazing(b.foliage, v, massing.storeyM, windows);
          case FacadeRhythm.punched:
            _punchedFacade(b, v, massing, windows, detail);
        }
      }

      // The cap. A cornice and a parapet cost a handful of quads and are most
      // of what separates a building from a box: without them every roof ends
      // in a bare edge against the sky.
      if (v.floors > 0 && style.corniceBandM > 0) {
        _cornice(b.solid, v, style, bu0, bu1);
      }
      if (v.floors > 0 && style.parapetM > 0) {
        _parapet(b.solid, v, style, bu0, bu1);
      }

      if (detail == BuildingDetail.full && v.floors > 1) {
        _interior(b.solid, v, massing.storeyM, pu0, pu1);
      }
    }

    // Roof plant, on the highest deck only — the one anything looking down at
    // the city actually sees.
    if (detail == BuildingDetail.full &&
        roof != null &&
        style.roofClutterPer100M2 > 0) {
      _roofClutter(b.solid, roof, style, rnd, pu0, pu1);
    }

    final lot = massing.parking;
    if (lot != null) {
      _parking(b.solid, b.foliage, lot,
          detail: detail,
          lamps: lamps,
          lampHeight: lampHeightM,
          u0: pu0,
          u1: pu1);
    }

    return GeneratedBuilding(
      model: PropModel(solid: b.solid.build(), foliage: b.foliage.build()),
      massing: massing,
      lampPosts: lamps,
      windowCentres: windows,
    );
  }

  /// U range of one band of the facade atlas.
  ///
  /// Inset by a texel and a half at 1024/8. A mip level averages across the
  /// band boundary, so a band sampled edge to edge picks up its neighbour's
  /// brick as soon as the building is more than a street away — which reads as
  /// the walls changing colour when you back off.
  static (double, double) bandUV(int material) {
    const e = 0.0015;
    final m = material.clamp(0, kFacadeMaterials - 1);
    return (m / kFacadeMaterials + e, (m + 1) / kFacadeMaterials - e);
  }

  /// The topmost OCCUPIED volume — the roof deck people walk out onto, and
  /// where the plant goes.
  ///
  /// Floored volumes only. A stepped-back building already carries a plant box
  /// above its tower, and that box was winning this comparison: the clutter
  /// pass then stacked condensers on top of the plant room instead of on the
  /// roof, and the parapet had nothing to enclose.
  static MassBox? _roofVolume(BuildingMassing m) {
    MassBox? best;
    for (final v in m.volumes) {
      if (v.floors <= 0) continue;
      if (best == null || v.top > best.top) best = v;
    }
    return best;
  }

  /// A PUNCHED facade: brick piers with an opening between each pair.
  ///
  /// This is the difference the reference photographs are actually made of.
  /// A ribbon of glass and a grid of punched openings are not two textures of
  /// the same wall — one is a continuous horizontal band with nothing
  /// structural in front of it, the other is a series of vertical piers with
  /// holes between them, and the second is what almost every building in a
  /// masonry city is. Modelling the piers rather than painting them is what
  /// gives the wall a shadow line, and the shadow line is what stops a street
  /// flattening into wallpaper the moment the sun moves off axis.
  ///
  /// Three bands, which is the classic tripartite composition:
  ///   * BASE — one tall storey, glazed nearly full width as a shopfront, with
  ///     a solid signage band over it.
  ///   * SHAFT — the repeating floors, openings between piers.
  ///   * CAP — handled by the cornice and parapet passes.
  void _punchedFacade(
    PropBuilder b,
    MassBox v,
    BuildingMassing m,
    List<Vector3> centres,
    BuildingDetail detail,
  ) {
    final (bu0, bu1) = bandUV(m.material);
    // ORNAMENT — awnings, bays, fire escapes — is the near tier only.
    //
    // Measured, because the middle tier was not earning its place: a tower was
    // 2,846 triangles at `full` and 2,418 at `exterior`, a 15% saving, against
    // 88 for the block silhouette. `exterior` only dropped the interior slabs,
    // which nobody can see anyway and which cost almost nothing; everything
    // expensive on a masonry facade is the articulation, and it was surviving
    // into a tier meant to be cheap.
    final ornament = detail == BuildingDetail.full;
    final style = m.style;
    final onGround = v.z <= 0.01;
    final hw = v.width / 2, hd = v.depth / 2;

    // Which walls get openings. A building with party walls has none on its
    // sides: there is a neighbour there, and where there is not, a blank brick
    // flank is exactly what a real end-of-terrace shows.
    final faces = <_Wall>[
      _Wall(const Vector3(0, -1, 0), v.width, v.y - hd, v.x, true),
      _Wall(const Vector3(0, 1, 0), v.width, v.y + hd, v.x, true),
      if (!style.blankPartyWalls) ...[
        _Wall(const Vector3(1, 0, 0), v.depth, v.x + hw, v.y, false),
        _Wall(const Vector3(-1, 0, 0), v.depth, v.x - hw, v.y, false),
      ] else if (m.corner)
        // A CORNER building has two public faces. Leaving its flank blank
        // because the kit says "party walls" would put a windowless brick
        // wall on a street — which is the one thing you never see on a corner
        // and the first thing you notice when it happens.
        _Wall(const Vector3(1, 0, 0), v.depth, v.x + hw, v.y, false),
    ];

    for (final w in faces) {
      // A wall narrower than a pier cannot be articulated at all — it is a
      // return, a sliver, or the flank of something tiny — and it stays solid.
      //
      // Not a cosmetic guard. Below this the pier arithmetic INVERTS: the
      // clamp keeping an end pier inside its own corner runs from
      // `-span/2 + pier/2` to `+span/2 - pier/2`, and once the span is under
      // the pier width the lower limit passes the upper one and `clamp`
      // throws. A quarry's processing shed comes out 0.72 m across on a small
      // plot, which crashed the whole colony's geometry pass every frame.
      if (w.spanM < style.pierM * 1.6) continue;

      final bays = style.baysAcross(w.spanM);
      final bayW = w.spanM / bays;
      // The pier has to FIT, whatever the kit asks for: never more than a
      // third of a bay, so an opening always survives between two of them.
      final pierW = math.min(style.pierM, bayW / 3);
      final openW = math.max(0.35, math.min(bayW * 0.92, bayW - pierW));

      for (var f = 0; f < v.floors; f++) {
        final base = v.z + (onGround ? m.floorBase(f) : f * m.storeyM);
        final storey =
            (onGround && f == 0) ? m.groundStoreyM : m.storeyM;

        if (onGround && f == 0 && style.storefront) {
          // Shopfront: glazed almost wall to wall, off a low bulkhead, with
          // the sign band above it. A tall continuous base under a punched
          // shaft is the single most reliable "this is a commercial street"
          // signal there is.
          final z0 = base + 0.45;
          final z1 = base + storey - style.signBandM;
          if (z1 > z0) {
            _wallQuad(b.foliage, w, z0, z1, -w.spanM / 2 + 0.35,
                w.spanM / 2 - 0.35, 0.04, centres);
          }
          continue;
        }

        final sill = base + storey * (1 - style.openingFrac) * 0.55;
        final head = sill + storey * style.openingFrac;
        for (var i = 0; i < bays; i++) {
          final c = -w.spanM / 2 + bayW * (i + 0.5);
          // A BAY: one opening per floor pushed proud of the wall, on the
          // street face, in a fixed column up the building. A flat wall of
          // identical punched holes is correct and lifeless; a bay throws a
          // vertical shadow the whole height of the facade and is most of
          // what gives a masonry street its relief.
          final isBay = ornament &&
              style.bayProjectionM > 0 &&
              w.normal.y < 0 &&
              bays >= 3 &&
              i == bays ~/ 2;
          final out = isBay ? style.bayProjectionM : 0.04;
          _wallQuad(b.foliage, w, sill, head, c - openW / 2, c + openW / 2,
              out, centres);
          if (isBay) {
            // Cheeks and a sill, so the bay is a box and not a floating pane.
            _wallBox(b.solid, w, sill - 0.18, 0.18, c, openW + 0.3,
                style.bayProjectionM, bu0, bu1);
            _wallBox(b.solid, w, head, 0.16, c, openW + 0.3,
                style.bayProjectionM, bu0, bu1);
            for (final e in [-1.0, 1.0]) {
              _wallBox(b.solid, w, sill, head - sill, c + e * openW / 2, 0.2,
                  style.bayProjectionM, bu0, bu1);
            }
          }
        }
      }

      // Awning over the shopfront. Cloth on a frame, sloping down to the
      // curb — and on the street face only, because that is where the shop is.
      if (ornament &&
          onGround &&
          style.storefront &&
          style.awnings &&
          w.normal.y < 0 &&
          v.floors > 0) {
        _awning(b.foliage, w, m.groundStoreyM - style.signBandM - 0.25, bu0);
      }

      // Fire escape, on the BACK. Landings, a stringer and a drop ladder —
      // the thing that says "American masonry" faster than any brick colour,
      // and it is a handful of thin boxes.
      if (ornament &&
          style.fireEscapes &&
          w.normal.y > 0 &&
          onGround &&
          v.floors > 2) {
        _fireEscape(b.solid, w, m, v, bu0, bu1);
      }

      // Piers, standing proud of the glass, running the height of the shaft.
      // They start above the shopfront where there is one — a masonry pier
      // does not run down through a shop window.
      final pierZ0 = v.z +
          ((onGround && style.storefront) ? m.groundStoreyM : 0.0);
      final pierTop = v.z + v.height;
      if (pierTop - pierZ0 < 0.5) continue;
      // The end piers sit inside the corner rather than straddling it, so a
      // corner reads as one solid quoin instead of two half-piers crossing.
      // `pierW` is bounded above by a third of a bay, so this limit is always
      // positive and the clamp can never invert.
      final edge = math.max(0.0, w.spanM / 2 - pierW / 2);
      for (var i = 0; i <= bays; i++) {
        final c = (-w.spanM / 2 + bayW * i).clamp(-edge, edge);
        _wallBox(b.solid, w, pierZ0, pierTop - pierZ0, c, pierW,
            style.reliefM, bu0, bu1);
      }
    }
  }

  /// A sloping awning over a shopfront, its high edge on the wall.
  void _awning(MeshBuilder m, _Wall w, double atZ, double u) {
    const projection = 1.7;
    const drop = 0.55;
    final n = w.normal;
    final axis = w.horizontal ? n.y : n.x;
    Vector3 at(double along, double out, double z) => w.horizontal
        ? Vector3(w.centre + along, w.offset + axis * out, z)
        : Vector3(w.offset + axis * out, w.centre + along, z);
    // Segmented, so a wide frontage gets separate bays of cloth rather than
    // one enormous sheet.
    final bays = math.max(1, (w.spanM / 5).round());
    final bw = w.spanM / bays;
    for (var i = 0; i < bays; i++) {
      final a = -w.spanM / 2 + bw * i + 0.25;
      final bpos = a + bw - 0.5;
      if (bpos <= a) continue;
      // Normal points up and out, which is what catches the light on a real
      // awning's slope. Metres, unscaled: a generated building is authored in
      // metres and the instance transform carries the conversion.
      const up = Vector3(0, 0, 1);
      final nn = (up * projection + n * drop).normalized;
      final i0 = m.vertex(at(a, 0.02, atZ), nn, u, 0);
      final i1 = m.vertex(at(bpos, 0.02, atZ), nn, u, 1);
      final i2 = m.vertex(at(bpos, projection, atZ - drop), nn, u, 1);
      final i3 = m.vertex(at(a, projection, atZ - drop), nn, u, 0);
      // OPPOSITE to the wall openings beside it. An awning's second axis runs
      // OUT from the wall where an opening's runs UP it, which flips the
      // handedness of the same corner order — measured against the shipping
      // glazing, not reasoned about.
      final flip = w.horizontal ? w.normal.y > 0 : w.normal.x < 0;
      if (flip) {
        m.quad(i0, i1, i2, i3);
      } else {
        m.quad(i3, i2, i1, i0);
      }
    }
  }

  /// Landings, stringers and a drop ladder up a rear wall.
  void _fireEscape(MeshBuilder m, _Wall w, BuildingMassing mass, MassBox v,
      double u0, double u1) {
    const platform = 1.5;
    const railH = 1.0;
    // Off centre, because a real one hangs off whichever bay the stair
    // happened to land in.
    final at = w.spanM * 0.18;
    for (var f = 1; f < v.floors; f++) {
      final z = v.z + mass.floorBase(f);
      // Landing.
      _wallBox(m, w, z, 0.12, at, 2.6, platform, u0, u1);
      // Rail, as a thin upstand at the outer edge.
      _wallBox(m, w, z + 0.12, railH, at, 2.6, 0.1, u0, u1);
      // The flight down to the landing below, as a single raking box.
      if (f > 1) {
        _wallBox(m, w, z - mass.storeyM * 0.9, mass.storeyM * 0.9, at + 1.1,
            0.9, platform * 0.8, u0, u1);
      }
    }
    // Drop ladder, hanging short of the ground the way they all do.
    _wallBox(m, w, mass.groundStoreyM * 0.45,
        mass.floorBase(1) - mass.groundStoreyM * 0.45, at + 1.1, 0.7, 0.12,
        u0, u1);
  }

  /// A quad on wall [w] between two heights and two positions along it,
  /// pushed [out] metres clear of the wall plane.
  void _wallQuad(
    MeshBuilder mesh,
    _Wall w,
    double z0,
    double z1,
    double a,
    double bpos,
    double out,
    List<Vector3> centres,
  ) {
    if (z1 <= z0 || bpos <= a) return;
    final n = w.normal;
    final off = w.offset + (w.horizontal ? n.y : n.x) * out;
    Vector3 at(double along, double z) => w.horizontal
        ? Vector3(w.centre + along, off, z)
        : Vector3(off, w.centre + along, z);
    // Wound so the quad faces OUT along the wall normal, whichever wall it is.
    // Which pair flips is not symmetric — it is fixed by the handedness of the
    // plan axes, and the pattern here is copied off the ribbon-glazing pass,
    // which is known to render right way out. Guessing it is how you get a
    // building with two of its four walls invisible.
    final flip = w.horizontal ? w.normal.y > 0 : w.normal.x < 0;
    final lo = flip ? bpos : a, hi = flip ? a : bpos;
    final u = math.max(1.0, ((bpos - a) / 1.7).roundToDouble());
    final i0 = mesh.vertex(at(lo, z0), n, 0, 1);
    final i1 = mesh.vertex(at(hi, z0), n, u, 1);
    final i2 = mesh.vertex(at(hi, z1), n, u, 0);
    final i3 = mesh.vertex(at(lo, z1), n, 0, 0);
    mesh.quad(i0, i1, i2, i3);
    centres.add(at((a + bpos) / 2, (z0 + z1) / 2));
  }

  /// A pilaster standing [out] proud of wall [w].
  void _wallBox(
    MeshBuilder mesh,
    _Wall w,
    double z0,
    double height,
    double along,
    double widthM,
    double out,
    double u0,
    double u1,
  ) {
    final n = w.normal;
    final centreOff =
        w.offset + (w.horizontal ? n.y : n.x) * (out / 2);
    _box(
      mesh,
      cx: w.horizontal ? w.centre + along : centreOff,
      cy: w.horizontal ? centreOff : w.centre + along,
      z0: z0,
      width: w.horizontal ? widthM : out,
      depth: w.horizontal ? out : widthM,
      height: height,
      uRepeat: 1,
      vRepeat: math.max(1, (height / 3.5).round()).toDouble(),
      u0: u0,
      u1: u1,
    );
  }

  /// The oversailing band at the top of a wall.
  void _cornice(MeshBuilder mesh, MassBox v, ArchitectureStyle style,
      double u0, double u1) {
    final p = style.corniceProjectionM;
    _box(
      mesh,
      cx: v.x,
      cy: v.y,
      z0: v.top - style.corniceBandM,
      width: v.width + p * 2,
      depth: v.depth + p * 2,
      height: style.corniceBandM,
      uRepeat: math.max(1, (v.width / 3).round()).toDouble(),
      vRepeat: 1,
      u0: u0,
      u1: u1,
    );
  }

  /// The wall that carries on past the roof deck. Four thin slabs rather than
  /// a hollowed box: a parapet is only ever seen from outside and from above,
  /// and four boxes is eight fewer than a ring of mitred ones.
  void _parapet(MeshBuilder mesh, MassBox v, ArchitectureStyle style, double u0,
      double u1) {
    const t = 0.35;
    final z = v.top;
    final h = style.parapetM;
    for (final (cx, cy, wdt, dep) in [
      (v.x, v.y - v.depth / 2 + t / 2, v.width, t),
      (v.x, v.y + v.depth / 2 - t / 2, v.width, t),
      (v.x - v.width / 2 + t / 2, v.y, t, v.depth - t * 2),
      (v.x + v.width / 2 - t / 2, v.y, t, v.depth - t * 2),
    ]) {
      if (wdt <= 0 || dep <= 0) continue;
      _box(
        mesh,
        cx: cx,
        cy: cy,
        z0: z,
        width: wdt,
        depth: dep,
        height: h,
        uRepeat: math.max(1, (math.max(wdt, dep) / 3).round()).toDouble(),
        vRepeat: 1,
        u0: u0,
        u1: u1,
      );
    }
  }

  /// Stair bulkheads, tanks, ducts and condenser banks.
  ///
  /// Look at any photograph taken from above a city — the roofs are the
  /// busiest surfaces in it. An empty roof deck is the thing that gives a
  /// generated skyline away from any window above the fourth floor, and it is
  /// a handful of boxes to fix.
  void _roofClutter(
    MeshBuilder mesh,
    MassBox v,
    ArchitectureStyle style,
    math.Random rnd,
    double u0,
    double u1,
  ) {
    final area = v.width * v.depth;
    final n = (area / 100 * style.roofClutterPer100M2).round().clamp(0, 24);
    if (n == 0) return;
    // Keep clear of the parapet, so nothing pokes through the wall.
    final inset = style.parapetM + 1.2;
    final w = v.width - inset * 2, d = v.depth - inset * 2;
    if (w <= 1.5 || d <= 1.5) return;

    // One bulkhead — the stair and lift overrun, always the tallest thing up
    // there and always near the core.
    _box(
      mesh,
      cx: v.x + (rnd.nextDouble() - 0.5) * w * 0.3,
      cy: v.y + (rnd.nextDouble() - 0.5) * d * 0.3,
      z0: v.top,
      width: math.min(w, 3.6),
      depth: math.min(d, 4.2),
      height: 2.8,
      uRepeat: 1,
      vRepeat: 1,
      u0: u0,
      u1: u1,
    );

    for (var i = 1; i < n; i++) {
      final sw = 0.9 + rnd.nextDouble() * 2.2;
      final sd = 0.9 + rnd.nextDouble() * 2.2;
      _box(
        mesh,
        cx: v.x + (rnd.nextDouble() - 0.5) * (w - sw),
        cy: v.y + (rnd.nextDouble() - 0.5) * (d - sd),
        z0: v.top,
        width: sw,
        depth: sd,
        height: 0.5 + rnd.nextDouble() * 1.6,
        uRepeat: 1,
        vRepeat: 1,
        u0: u0,
        u1: u1,
      );
    }
  }

  /// Window bands, one per storey per facade, inset slightly so they read as
  /// glazing set into a wall rather than as decals on it.
  void _glazing(
    MeshBuilder m,
    MassBox v,
    double storey,
    List<Vector3> centres,
  ) {
    const inset = 0.12;
    final bandH = storey * windowHeightFraction;
    final hw = v.width / 2, hd = v.depth / 2;
    for (var f = 0; f < v.floors; f++) {
      final z0 = v.z + f * storey + (storey - bandH) * 0.55;
      final z1 = z0 + bandH;
      // Four faces. Each is a single band quad; the window MULLIONS come from
      // the material's texture, not from geometry — at ten thousand buildings
      // per city, per-pane geometry is the difference between a frame and a
      // slideshow.
      final faces = <(Vector3, Vector3, Vector3)>[
        // (corner A, corner B, outward normal)
        (Vector3(v.x - hw, v.y - hd - inset, 0),
            Vector3(v.x + hw, v.y - hd - inset, 0), const Vector3(0, -1, 0)),
        (Vector3(v.x + hw, v.y + hd + inset, 0),
            Vector3(v.x - hw, v.y + hd + inset, 0), const Vector3(0, 1, 0)),
        (Vector3(v.x + hw + inset, v.y - hd, 0),
            Vector3(v.x + hw + inset, v.y + hd, 0), const Vector3(1, 0, 0)),
        (Vector3(v.x - hw - inset, v.y + hd, 0),
            Vector3(v.x - hw - inset, v.y - hd, 0), const Vector3(-1, 0, 0)),
      ];
      for (final (a, bb, n) in faces) {
        final span = (bb - a).length;
        final u = math.max(1, (span / 3.2).round()).toDouble();
        final i0 = m.vertex(Vector3(a.x, a.y, z0), n, 0, 1);
        final i1 = m.vertex(Vector3(bb.x, bb.y, z0), n, u, 1);
        final i2 = m.vertex(Vector3(bb.x, bb.y, z1), n, u, 0);
        final i3 = m.vertex(Vector3(a.x, a.y, z1), n, 0, 0);
        m.quad(i0, i1, i2, i3);
        centres.add(Vector3((a.x + bb.x) / 2, (a.y + bb.y) / 2, (z0 + z1) / 2));
      }
    }
  }

  /// Bare interior: a slab per storey and a service core. Enough that a window
  /// looks into a room instead of into the far wall, without paying for
  /// furniture nobody can see.
  /// Bare precast whatever the outside is faced in: a slab and a core are
  /// structure, and structure is concrete in every one of these kits.
  void _interior(
      MeshBuilder m, MassBox v, double storey, double u0, double u1) {
    const wall = 0.25;
    final iw = v.width - wall * 2, id = v.depth - wall * 2;
    if (iw <= 1 || id <= 1) return;
    for (var f = 1; f < v.floors; f++) {
      _box(
        m,
        cx: v.x,
        cy: v.y,
        z0: v.z + f * storey - 0.15,
        width: iw,
        depth: id,
        height: 0.15,
        uRepeat: 1,
        vRepeat: 1,
        u0: u0,
        u1: u1,
      );
    }
    // Service core: stairs, lifts, risers. One box through the full height.
    final coreW = math.max(2.0, iw * 0.18);
    final coreD = math.max(2.0, id * 0.18);
    _box(
      m,
      cx: v.x,
      cy: v.y,
      z0: v.z,
      width: coreW,
      depth: coreD,
      height: v.floors * storey,
      uRepeat: 1,
      vRepeat: v.floors.toDouble(),
      u0: u0,
      u1: u1,
    );
  }

  /// The car park: deck, curb, bay markings at close range, and lamp columns.
  void _parking(
    MeshBuilder solid,
    MeshBuilder glow,
    ParkingLot lot, {
    required BuildingDetail detail,
    required List<Vector3> lamps,
    required double lampHeight,
    required double u0,
    required double u1,
  }) {
    // Deck, raised a few centimetres so it wins the depth test against the pad
    // it sits on instead of z-fighting with it.
    _box(
      solid,
      cx: lot.x,
      cy: lot.y,
      z0: 0,
      width: lot.width,
      depth: lot.depth,
      height: 0.08,
      uRepeat: math.max(1, (lot.width / 6).round()).toDouble(),
      vRepeat: math.max(1, (lot.depth / 6).round()).toDouble(),
      u0: u0,
      u1: u1,
    );

    for (final (lx, ly) in lot.lampPosts) {
      lamps.add(Vector3(lx, ly, 0));
      if (detail == BuildingDetail.block) continue;
      // Column.
      _box(
        solid,
        cx: lx,
        cy: ly,
        z0: 0,
        width: 0.28,
        depth: 0.28,
        height: lampHeight,
        uRepeat: 1,
        vRepeat: 1,
        u0: u0,
        u1: u1,
      );
      // Head, in the glowing channel so the night pass can light it.
      _box(
        glow,
        cx: lx,
        cy: ly,
        z0: lampHeight,
        width: 1.1,
        depth: 0.5,
        height: 0.22,
        uRepeat: 1,
        vRepeat: 1,
      );
    }
  }

  /// An axis-aligned box with outward normals and per-face UVs.
  ///
  /// [z0] is the BASE, matching how props are authored (origin on the ground),
  /// so a building drops onto its pad without a vertical fudge.
  ///
  /// [u0]/[u1] select a BAND of the facade atlas — one masonry out of the
  /// eight it carries. A band cannot rely on the sampler's repeat to tile
  /// horizontally (wrapping would walk straight into the next material), so a
  /// banded face is SUBDIVIDED into one quad per repeat, each mapping the
  /// whole band. V is left alone: every band runs the full height of the tile
  /// and is seamless top to bottom, so it repeats up a wall for free.
  static void _box(
    MeshBuilder m, {
    required double cx,
    required double cy,
    required double z0,
    required double width,
    required double depth,
    required double height,
    required double uRepeat,
    required double vRepeat,
    double u0 = 0,
    double u1 = 1,
  }) {
    final hw = width / 2, hd = depth / 2;
    final z1 = z0 + height;
    final uD = math.max(1, (depth / 4).round()).toDouble();
    final banded = u1 - u0 < 0.999;

    void face(Vector3 a, Vector3 b, Vector3 c, Vector3 d, Vector3 n, double u,
        double v) {
      if (!banded) {
        final i0 = m.vertex(a, n, 0, v);
        final i1 = m.vertex(b, n, u, v);
        final i2 = m.vertex(c, n, u, 0);
        final i3 = m.vertex(d, n, 0, 0);
        m.quad(i0, i1, i2, i3);
        return;
      }
      final segs = math.max(1, u.round());
      for (var k = 0; k < segs; k++) {
        final t0 = k / segs, t1 = (k + 1) / segs;
        final a0 = a + (b - a) * t0, b0 = a + (b - a) * t1;
        final d0 = d + (c - d) * t0, c0 = d + (c - d) * t1;
        final i0 = m.vertex(a0, n, u0, v);
        final i1 = m.vertex(b0, n, u1, v);
        final i2 = m.vertex(c0, n, u1, 0);
        final i3 = m.vertex(d0, n, u0, 0);
        m.quad(i0, i1, i2, i3);
      }
    }

    // -Y (street face), +Y, +X, -X, top. No bottom: it is never visible and
    // every building would otherwise pay for a hidden quad.
    face(
      Vector3(cx - hw, cy - hd, z0),
      Vector3(cx + hw, cy - hd, z0),
      Vector3(cx + hw, cy - hd, z1),
      Vector3(cx - hw, cy - hd, z1),
      const Vector3(0, -1, 0),
      uRepeat,
      vRepeat,
    );
    face(
      Vector3(cx + hw, cy + hd, z0),
      Vector3(cx - hw, cy + hd, z0),
      Vector3(cx - hw, cy + hd, z1),
      Vector3(cx + hw, cy + hd, z1),
      const Vector3(0, 1, 0),
      uRepeat,
      vRepeat,
    );
    face(
      Vector3(cx + hw, cy - hd, z0),
      Vector3(cx + hw, cy + hd, z0),
      Vector3(cx + hw, cy + hd, z1),
      Vector3(cx + hw, cy - hd, z1),
      const Vector3(1, 0, 0),
      uD,
      vRepeat,
    );
    face(
      Vector3(cx - hw, cy + hd, z0),
      Vector3(cx - hw, cy - hd, z0),
      Vector3(cx - hw, cy - hd, z1),
      Vector3(cx - hw, cy + hd, z1),
      const Vector3(-1, 0, 0),
      uD,
      vRepeat,
    );
    face(
      Vector3(cx - hw, cy - hd, z1),
      Vector3(cx + hw, cy - hd, z1),
      Vector3(cx + hw, cy + hd, z1),
      Vector3(cx - hw, cy + hd, z1),
      const Vector3(0, 0, 1),
      uRepeat,
      uD,
    );
  }
}

/// Key a generated building can be POOLED under.
///
/// Ten thousand buildings cannot each own a mesh. Bucketing the massing inputs
/// — type, rounded footprint, floor count, detail tier — means a district of
/// apartment blocks shares a handful of meshes drawn as instances, and only a
/// genuinely different building pays for new geometry.
class BuildingArchetype {
  final String type;
  final int widthBucket;
  final int depthBucket;
  final BuildingDetail detail;
  final int variant;

  /// Which kit this was generated in. Part of the KEY, not just a label: the
  /// same spec on the same lot is a completely different building in two
  /// styles, and a cache that ignored this would keep serving the old one
  /// after a switch.
  final String styleId;

  /// Corner buildings are their own archetype: two public faces instead of
  /// one is a different mesh, not a different transform.
  final bool corner;

  const BuildingArchetype({
    required this.type,
    required this.widthBucket,
    required this.depthBucket,
    required this.detail,
    required this.variant,
    this.styleId = 'utilitarian',
    this.corner = false,
  });

  /// Bucket a spec/parcel pair. [variants] different meshes per bucket keep a
  /// street from looking cloned; 4 is enough to break the pattern by eye.
  ///
  /// Floor count is deliberately NOT part of the key: it is derived from the
  /// bucketed lot size, so including it would split buckets that the library
  /// then generates identical geometry for.
  factory BuildingArchetype.of(
    CityBuildingSpec spec,
    Parcel parcel, {
    BuildingDetail detail = BuildingDetail.full,
    int seed = 0,
    double bucketM = 6,
    int variants = 4,
    String styleId = 'utilitarian',
    bool? corner,
  }) {
    final extent = parcel.buildableExtent;
    return BuildingArchetype(
      type: spec.type,
      widthBucket: math.max(1, (extent.width / bucketM).round()),
      depthBucket: math.max(1, (extent.depth / bucketM).round()),
      detail: detail,
      variant: seed.abs() % variants,
      styleId: styleId,
      corner: corner ?? parcel.isCorner,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BuildingArchetype &&
      other.type == type &&
      other.widthBucket == widthBucket &&
      other.depthBucket == depthBucket &&
      other.detail == detail &&
      other.variant == variant &&
      other.styleId == styleId &&
      other.corner == corner;

  @override
  int get hashCode => Object.hash(
      type, widthBucket, depthBucket, detail, variant, styleId, corner);
}

/// Generate-once cache keyed by [BuildingArchetype].
///
/// Buildings are generated from the BUCKETED lot rather than the exact one, so
/// every instance sharing a key shares byte-identical geometry and can be drawn
/// in one instanced call. The cost is up to half a bucket of misfit against the
/// real property line, which at a 6 m bucket is not visible from the street and
/// is certainly not visible from orbit.
class BuildingLibrary {
  BuildingLibrary({
    this.generator = const BuildingGenerator(),
    this.bucketM = 6,
    this.variants = 4,
  });

  final BuildingGenerator generator;

  /// Lot-size quantisation. Smaller buckets fit better and cost more meshes.
  final double bucketM;

  final int variants;

  final Map<BuildingArchetype, GeneratedBuilding> _cache = {};

  int get meshCount => _cache.length;

  GeneratedBuilding get(
    CityBuildingSpec spec,
    Parcel parcel, {
    int seed = 0,
    BuildingDetail detail = BuildingDetail.full,
  }) {
    final key = BuildingArchetype.of(spec, parcel,
        detail: detail,
        seed: seed,
        bucketM: bucketM,
        variants: variants,
        styleId: generator.style.id,
        corner: parcel.isCorner);
    return _cache.putIfAbsent(
      key,
      () => generator.generate(spec, _canonicalLot(key),
          seed: key.variant, detail: detail),
    );
  }

  /// The representative lot a bucket is generated against.
  Parcel _canonicalLot(BuildingArchetype key) {
    final w = key.widthBucket * bucketM;
    final d = key.depthBucket * bucketM;
    return Parcel(
      id: 'archetype',
      polygon: [
        Vec2(-w / 2, 0),
        Vec2(w / 2, 0),
        Vec2(w / 2, d),
        Vec2(-w / 2, d),
      ],
      frontage: (Vec2(-w / 2, 0), Vec2(w / 2, 0)),
      sideStreet: key.corner ? (Vec2(w / 2, 0), Vec2(w / 2, d)) : null,
    );
  }

  void clear() => _cache.clear();
}

/// One face of a volume, described so the facade pass can work along it
/// without a special case per axis.
///
/// [centre] and [offset] are the wall's position in the two plan axes;
/// [horizontal] says which is which. Positions ALONG the wall are measured
/// from its middle, so a bay index maps the same way on all four faces.
class _Wall {
  const _Wall(
      this.normal, this.spanM, this.offset, this.centre, this.horizontal);

  /// Outward normal, one of ±X or ±Y.
  final Vector3 normal;

  /// How wide the wall is.
  final double spanM;

  /// Plan coordinate of the wall plane, on the normal's axis.
  final double offset;

  /// Plan coordinate of the wall's middle, on the other axis.
  final double centre;

  /// True when the wall runs along X (its normal is ±Y).
  final bool horizontal;
}
