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
///   * SOLID   — walls, slabs, roofs, kerbs, lamp columns. Opaque, back-face
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
import '../scatter/prop_mesh.dart';
import '../scatter/prop_model.dart';
import '../shared/vector3.dart';
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
  /// parking bays, kerbs, lamps.
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

    if (detail == BuildingDetail.block) {
      // One box covering the whole massing: the distant tier only has to hold
      // the silhouette and the roofline.
      final fp = massing.footprint;
      _box(
        b.solid,
        cx: 0,
        cy: 0,
        z0: 0,
        width: fp.width,
        depth: fp.depth,
        height: massing.height,
        uRepeat: 1,
        vRepeat: 1,
      );
      return GeneratedBuilding(
        model: PropModel(solid: b.solid.build(), foliage: PropMesh.empty),
        massing: massing,
      );
    }

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
        uRepeat: math.max(1, (v.width / 4).round()).toDouble(),
        vRepeat: math.max(1, v.floors).toDouble(),
      );

      if (v.glazed && v.floors > 0) {
        _glazing(b.foliage, v, massing.storeyM, windows);
      }

      if (detail == BuildingDetail.full && v.floors > 1) {
        _interior(b.solid, v, massing.storeyM);
      }
    }

    final lot = massing.parking;
    if (lot != null) {
      _parking(b.solid, b.foliage, lot,
          detail: detail, lamps: lamps, lampHeight: lampHeightM);
    }

    return GeneratedBuilding(
      model: PropModel(solid: b.solid.build(), foliage: b.foliage.build()),
      massing: massing,
      lampPosts: lamps,
      windowCentres: windows,
    );
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
  void _interior(MeshBuilder m, MassBox v, double storey) {
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
    );
  }

  /// The car park: deck, kerb, bay markings at close range, and lamp columns.
  void _parking(
    MeshBuilder solid,
    MeshBuilder glow,
    ParkingLot lot, {
    required BuildingDetail detail,
    required List<Vector3> lamps,
    required double lampHeight,
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
  }) {
    final hw = width / 2, hd = depth / 2;
    final z1 = z0 + height;
    final uD = math.max(1, (depth / 4).round()).toDouble();

    void face(Vector3 a, Vector3 b, Vector3 c, Vector3 d, Vector3 n, double u,
        double v) {
      final i0 = m.vertex(a, n, 0, v);
      final i1 = m.vertex(b, n, u, v);
      final i2 = m.vertex(c, n, u, 0);
      final i3 = m.vertex(d, n, 0, 0);
      m.quad(i0, i1, i2, i3);
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

  const BuildingArchetype({
    required this.type,
    required this.widthBucket,
    required this.depthBucket,
    required this.detail,
    required this.variant,
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
  }) {
    final extent = parcel.buildableExtent;
    return BuildingArchetype(
      type: spec.type,
      widthBucket: math.max(1, (extent.width / bucketM).round()),
      depthBucket: math.max(1, (extent.depth / bucketM).round()),
      detail: detail,
      variant: seed.abs() % variants,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is BuildingArchetype &&
      other.type == type &&
      other.widthBucket == widthBucket &&
      other.depthBucket == depthBucket &&
      other.detail == detail &&
      other.variant == variant;

  @override
  int get hashCode =>
      Object.hash(type, widthBucket, depthBucket, detail, variant);
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
        detail: detail, seed: seed, bucketM: bucketM, variants: variants);
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
    );
  }

  void clear() => _cache.clear();
}
