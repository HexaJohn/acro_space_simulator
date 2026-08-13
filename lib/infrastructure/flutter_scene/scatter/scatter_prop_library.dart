// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// ignore_for_file: implementation_imports
import 'package:flutter_scene/scene.dart' as fs;
import 'package:flutter_scene/src/gpu/gpu.dart' as igpu;
import 'package:vector_math/vector_math.dart' as vm;

import '../../../domain/scatter/prop_catalog.dart';
import '../../../domain/scatter/prop_mesh.dart';
import '../../../domain/scatter/prop_model.dart';
import '../../../domain/scatter/scatter_instance.dart';
import '../../../domain/scatter/scatter_layer.dart';
import 'prop_imposter_baker.dart';
import 'scatter_textures.dart';

/// One generated prop, uploaded and ready to instance.
class ScatterProp {
  ScatterProp({
    required this.kind,
    required this.seed,
    required this.lodSet,
    required this.solid,
    required this.foliage,
  });

  final PropKind kind;
  final int seed;

  /// The domain-side meshes, bounds and imposter description this was built
  /// from — kept so callers can query height, cull radius and triangle counts
  /// without touching the GPU.
  final PropLodSet lodSet;

  /// Uploaded geometry per mesh LOD, null where that level has no geometry of
  /// that kind (grass has no solid part; rocks have no foliage part).
  final List<fs.MeshGeometry?> solid;
  final List<fs.MeshGeometry?> foliage;

  /// The painted billboard texture. Null until the async bake lands, or
  /// permanently if the bake failed — draw nothing rather than a white card.
  Object? imposterTexture;

  double get heightM => lodSet.heightM;
  double get radiusM => lodSet.radiusM;

  fs.MeshGeometry? solidFor(PropLod lod) =>
      lod == PropLod.billboard ? null : solid[lod.index];
  fs.MeshGeometry? foliageFor(PropLod lod) =>
      lod == PropLod.billboard ? null : foliage[lod.index];

  int triangleCountFor(PropLod lod) =>
      lod == PropLod.billboard ? 2 : lodSet[lod].triangleCount;
}

/// Builds, uploads and caches scattered props, and owns the two materials the
/// whole system shares.
///
/// The materials are deliberately SHARED across every prop kind. Two materials
/// means two instanced draw calls for an entire scattered field regardless of
/// how many species are in it — which is the property that makes scattering
/// affordable at all, and the reason every generator was made to draw from one
/// foliage atlas.
class ScatterPropLibrary {
  ScatterPropLibrary._();

  static final ScatterPropLibrary instance = ScatterPropLibrary._();

  final Map<String, ScatterProp> _cache = {};

  fs.PhysicallyBasedMaterial? _bark;
  fs.PhysicallyBasedMaterial? _foliage;
  fs.PhysicallyBasedMaterial? _stone;
  final Map<PropKind, fs.SpriteMaterial> _imposterMaterials = {};

  /// Generate + upload the shared textures. Must complete before any material
  /// is bound.
  static Future<void> loadTextures() => ScatterTextures.load();

  static bool get texturesReady => ScatterTextures.ready;

  /// Bark and wood: opaque, back-face culled, fully rough.
  fs.PhysicallyBasedMaterial get barkMaterial => _bark ??= PropSurfaceMaterial()
    ..baseColorTexture = ScatterTextures.bark
    ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
    ..roughnessFactor = 0.95
    ..metallicFactor = 0.0;

  /// Stone.
  fs.PhysicallyBasedMaterial get stoneMaterial => _stone ??=
      PropSurfaceMaterial()
        ..baseColorTexture = ScatterTextures.stone
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
        ..roughnessFactor = 1.0
        ..metallicFactor = 0.0;

  /// Leaves, needles, fronds and blades.
  ///
  /// [AlphaMode.mask] rather than [AlphaMode.blend] is the load-bearing choice
  /// here: a masked material still counts as OPAQUE, so foliage stays in the
  /// opaque pass where an instanced mesh is one draw call. Blending would move
  /// it to the translucent pass, which issues one draw call PER INSTANCE, and a
  /// field of ten thousand tufts would become ten thousand draws.
  ///
  /// Single-sided ON PURPOSE, even though a leaf card obviously has two faces.
  /// The generators emit every card twice with opposite winding and opposite
  /// normals (see [MeshBuilder.card]), so back-face culling keeps exactly the
  /// copy whose normal points at the eye. Turning `doubleSided` on instead would
  /// draw both copies and put the inverted-normal one back on screen — the very
  /// artefact the doubled geometry exists to remove.
  fs.PhysicallyBasedMaterial get foliageMaterial => _foliage ??=
      PropSurfaceMaterial()
        ..baseColorTexture = ScatterTextures.foliage
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
        // Fully rough. Any gloss at all puts a grazing-angle specular highlight
        // on cards that happen to face away from the sun, and since a specular
        // highlight is NOT tinted by albedo it washes those clumps out to flat
        // white-grey while their neighbours stay green.
        ..roughnessFactor = 1.0
        ..metallicFactor = 0.0
        ..alphaMode = fs.AlphaMode.mask
        // A little under half: the procedurally-baked masks are hard-edged, and
        // a higher cutoff nibbles the leaf outlines away at distant mips (where
        // averaging has pulled alpha down) until the canopy thins out on its
        // own.
        ..alphaCutoff = 0.42
        ..doubleSided = false;

  /// The billboard material for one kind. Per kind because each kind has its
  /// own painted card; a sprite batch is still ONE draw call per material.
  fs.SpriteMaterial imposterMaterial(PropKind kind) =>
      _imposterMaterials.putIfAbsent(
        kind,
        () => fs.SpriteMaterial()
          ..blendMode = fs.SpriteBlendMode.alpha
          // Clamped, not repeated: a card must never wrap onto its neighbour
          // edge. Linear on both axes because an imposter is by definition
          // being minified hard.
          ..sampler = igpu.SamplerOptions(
            minFilter: igpu.MinMagFilter.linear,
            magFilter: igpu.MinMagFilter.linear,
            mipFilter: igpu.MipFilter.linear,
            widthAddressMode: igpu.SamplerAddressMode.clampToEdge,
            heightAddressMode: igpu.SamplerAddressMode.clampToEdge,
          ),
      );

  final Set<void Function()> _listeners = {};

  /// Subscribe to "something finished baking asynchronously".
  ///
  /// A per-call completion callback looked simpler and was wrong: whoever asks
  /// for a prop FIRST starts its bake, and every later caller gets a cache hit
  /// whose callback is silently dropped. The screen warms the cache while
  /// framing the subject, so the drawing code — the one that actually needed
  /// telling — was always the later caller and never heard back.
  void addListener(void Function() listener) => _listeners.add(listener);
  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    for (final l in _listeners.toList()) {
      l();
    }
  }

  /// Seeds of the pre-grown individuals every scattered prop is drawn from.
  ///
  /// Instancing needs ONE geometry per draw, but the generators grow a distinct
  /// mesh per seed, so a field of genuinely unique props would be a field of
  /// individual draw calls. A small pool squares that: an instance picks its
  /// variant from its own seed, and yaw, scale and species carry the remaining
  /// variety. Four variants freely rotated and resized do not read as four
  /// trees — but they do cost four geometries per kind per level, which is why
  /// the pool is four and not forty.
  static const List<int> variantSeeds = [1, 2, 3, 4];

  /// The pre-grown variant a scattered instance draws as.
  ScatterProp variantFor(ScatterInstance instance) => get(
        instance.kind,
        seed: variantSeeds[instance.seed % variantSeeds.length],
      );

  /// Grow every variant of every kind that [layers] can produce.
  ///
  /// Generation is milliseconds per prop, which is invisible spread over a walk
  /// but very visible as a stall the first time a treeline comes over the
  /// horizon. Called once at startup, it moves that cost somewhere nobody is
  /// looking.
  void warmUp({List<ScatterLayer> layers = ScatterLayers.all}) {
    for (final layer in layers) {
      for (final kind in layer.kinds) {
        for (final seed in variantSeeds) {
          get(kind, seed: seed);
        }
      }
    }
  }

  /// Fetch (or build) the prop for [kind]/[seed].
  ///
  /// Generation and upload are synchronous and take a millisecond or two per
  /// prop; the imposter bake is async and fires [addListener] when it lands.
  /// Callers must tolerate [ScatterProp.imposterTexture] being null meanwhile.
  ScatterProp get(PropKind kind, {int seed = 1, double? sizeM}) {
    final key = '${kind.name}/$seed/${sizeM?.toStringAsFixed(3) ?? '-'}';
    final hit = _cache[key];
    if (hit != null) return hit;

    final lodSet = buildProp(kind, seed: seed, sizeM: sizeM);
    final prop = ScatterProp(
      kind: kind,
      seed: seed,
      lodSet: lodSet,
      solid: [
        for (final lod in _meshLods) _geometryOf(lodSet[lod].solid),
      ],
      foliage: [
        for (final lod in _meshLods) _geometryOf(lodSet[lod].foliage),
      ],
    );
    _cache[key] = prop;

    PropImposterBaker.bake(lodSet.imposter).then((tex) {
      if (tex == null) return;
      prop.imposterTexture = tex;
      // Sprite textures are only ever sampled inside their own card, so the
      // material can take the texture as soon as it exists.
      imposterMaterial(kind).colorTexture = tex;
      _notify();
    });

    return prop;
  }

  /// Drop every cached prop. The GPU geometry is released with it, so only call
  /// this when nothing is still drawing them (screen teardown).
  void clear() => _cache.clear();

  int get cachedCount => _cache.length;

  static const List<PropLod> _meshLods = [
    PropLod.lod0,
    PropLod.lod1,
    PropLod.lod2,
  ];

  /// Upload one [PropMesh]. The domain already emits structure-of-arrays in
  /// exactly this layout, so there is no repacking step.
  static fs.MeshGeometry? _geometryOf(PropMesh mesh) {
    if (mesh.isEmpty) return null;
    return fs.MeshGeometry.fromArrays(
      positions: mesh.positions,
      normals: mesh.normals,
      texCoords: mesh.texCoords,
      indices: mesh.indices,
    );
  }

}

/// A [fs.PhysicallyBasedMaterial] that samples its base colour TRILINEARLY.
///
/// The stock material binds every texture slot through a private repeat sampler
/// left at flutter_gpu's defaults, which are `nearest` for minification,
/// magnification AND mip selection. On bark that merely looks blocky. On
/// alpha-cut foliage it is far worse: with no mip filtering the alpha test
/// lands on a different texel every frame as a leaf card sub-pixel-jitters, and
/// a whole canopy crawls and sparkles as you move. Foliage is the one place in
/// this renderer where filtering is not a polish detail.
///
/// The slot is simply re-bound after `super.bind`, the same trick
/// `_TerrainMaterial` uses for its shadow map — the last bind for a slot wins,
/// so nothing about the base material has to be reachable.
class PropSurfaceMaterial extends fs.PhysicallyBasedMaterial {
  @override
  void bind(
    igpu.RenderPass pass,
    igpu.HostBuffer transientsBuffer,
    fs.Lighting lighting,
  ) {
    super.bind(pass, transientsBuffer, lighting);
    pass.bindTexture(
      fragmentShader.getUniformSlot('base_color_texture'),
      // Resolves to the engine's 1x1 white placeholder while an upload is still
      // pending, so a material bound before its texture lands still draws.
      fs.Material.whitePlaceholder(baseColorTexture),
      sampler: igpu.SamplerOptions(
        minFilter: igpu.MinMagFilter.linear,
        magFilter: igpu.MinMagFilter.linear,
        mipFilter: ScatterTextures.mipmapped
            ? igpu.MipFilter.linear
            : igpu.MipFilter.nearest,
        widthAddressMode: igpu.SamplerAddressMode.repeat,
        heightAddressMode: igpu.SamplerAddressMode.repeat,
      ),
    );
  }
}
