// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// ignore_for_file: implementation_imports
import 'dart:typed_data';

import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart' as fs;
import 'package:flutter_scene/src/gpu/gpu.dart' as igpu;
import 'package:vector_math/vector_math.dart' as vm;

import 'city_textures.dart';

/// The colony's two surfaces: opaque facade, and glazing that lights up.
///
/// Two materials for a whole city. Every building in the colony draws from the
/// same pair, which is what lets the archetype batches collapse into a handful
/// of instanced calls.
class CityMaterials {
  CityMaterials._();

  /// How dark it is over the colony, 0..1. Set once per frame by the node
  /// family; the glazing material reads it when it binds, so a sunset sweeps
  /// the whole city's windows on at once without touching any geometry.
  static double nightFactor = 0;

  // ---- Night skyglow ------------------------------------------------------
  //
  // The city's own light thrown back by the air, evaluated PER FRAGMENT in
  // the custom surface shader with a falloff off each fragment's height
  // above the colony ground — pavements bathe in it, tower tops rise out of
  // it. The node family writes the frame-dependent values below each frame;
  // the materials pack them into the CityGlow uniform block at bind.

  /// The colony body's centre, SCENE units, same space as the shader's
  /// v_position. Written by CityNodes each frame (the origin moves).
  static vm.Vector3 glowCentreScene = vm.Vector3.zero();

  /// The colony's ground-shell radius, SCENE units — height is measured off
  /// the ground the city stands on, not the datum sphere.
  static double glowGroundRadiusScene = 0;

  /// Peak glow strength at street level, in the emissive scale.
  static double glowIntensity = 0.4;

  /// e-folding height of the glow, metres. Short on purpose: the glow is
  /// street light, and street light dies within a few storeys — 45 m had
  /// whole mid-rises washed in it.
  static double glowFalloffM = 16.0;

  /// The baked light-density map (r channel 0..1) and its frame. Written by
  /// CityNodes: the texture at rebuild, the frame every frame (the floating
  /// origin moves). Null until the first bake — the material binds the white
  /// placeholder, which is "density 1 everywhere", the pre-map behaviour.
  static Object? lightMap;
  static vm.Vector3 lightMapAnchorScene = vm.Vector3.zero();
  static vm.Vector3 lightMapEast = vm.Vector3(1, 0, 0);
  static vm.Vector3 lightMapNorth = vm.Vector3(0, 1, 0);
  static double lightMapHalfExtentScene = 1;

  /// Warm sodium-and-LED glow colour, linear.
  static vm.Vector3 glowColor = vm.Vector3(1.0, 0.62, 0.36);

  /// Scene-unit metre scale, written once by the node family (city_materials
  /// deliberately does not import the renderer's coord conversions).
  static double glowMetresToScene = 1e-3;

  /// The custom surface shader — the engine's standard PBR fragment with the
  /// CityGlow term added. Null until [loadShader] lands; materials built
  /// before that bind the stock shader, and CityNodes calls [reset] when the
  /// load completes so they rebuild against this one.
  static gpu.Shader? _surfaceShader;
  static Future<void>? _loadingShader;
  static bool get shaderReady => _surfaceShader != null;

  static Future<void> loadShader() => _loadingShader ??= () async {
        final library = await gpu
            .loadShaderLibraryAsync('build/shaderbundles/acro.shaderbundle');
        _surfaceShader = library?['CitySurfaceFragment'];
        if (_surfaceShader == null) {
          throw StateError(
            'CitySurfaceFragment missing from acro.shaderbundle — the '
            'hook/build.dart shader compile should have produced it.',
          );
        }
      }();

  static fs.PhysicallyBasedMaterial? _facade;
  static fs.PhysicallyBasedMaterial? _glazing;
  static fs.PhysicallyBasedMaterial? _ground;
  static fs.PhysicallyBasedMaterial? _road;
  static fs.PhysicallyBasedMaterial? _dirt;
  static fs.PhysicallyBasedMaterial? _alley;
  static fs.PhysicallyBasedMaterial? _sidewalk;

  static fs.PhysicallyBasedMaterial get facade =>
      _facade ??= _CitySurfaceMaterial()
        ..baseColorTexture = CityTextures.facade
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
        ..roughnessFactor = 0.92
        ..metallicFactor = 0.0;

  static fs.PhysicallyBasedMaterial get glazing =>
      _glazing ??= _GlazingMaterial()
        ..baseColorTexture = CityTextures.glazing
        ..emissiveTexture = CityTextures.windowEmissive
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
        // Glass is smooth and slightly metallic-looking under a sun; this is
        // what separates a window band from a painted stripe at grazing angles.
        ..roughnessFactor = 0.18
        ..metallicFactor = 0.1;

  /// Flat ground: roads, zoned lots, support decks. Colour comes from the
  /// patch's UV into the palette, so all of them are one draw.
  static fs.PhysicallyBasedMaterial get ground =>
      _ground ??= _CitySurfaceMaterial()
        ..baseColorTexture = CityTextures.groundPalette
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
        ..roughnessFactor = 1.0
        ..metallicFactor = 0.0;

  /// Every carriageway, junction plate and painted line: the road atlas,
  /// banded along U (see CityTextureBakes.roadAtlas), V along the road.
  static fs.PhysicallyBasedMaterial get road => _road ??= _CitySurfaceMaterial()
    ..baseColorTexture = CityTextures.roadAtlas
    ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
    ..roughnessFactor = 1.0
    ..metallicFactor = 0.0;

  /// Alleys: worn concrete, a centre channel, mismatched patches, no curbs.
  static fs.PhysicallyBasedMaterial get alley =>
      _alley ??= _CitySurfaceMaterial()
        ..baseColorTexture = CityTextures.alleyStrip
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
        ..roughnessFactor = 1.0
        ..metallicFactor = 0.0;

  /// Dirt paths: graded earth, ruts, no curbs.
  static fs.PhysicallyBasedMaterial get dirt => _dirt ??= _CitySurfaceMaterial()
    ..baseColorTexture = CityTextures.dirtStrip
    ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
    ..roughnessFactor = 1.0
    ..metallicFactor = 0.0;

  /// Sidewalks and their curb faces: concrete flags, curb stones at u < 0.06.
  static fs.PhysicallyBasedMaterial get sidewalk =>
      _sidewalk ??= _CitySurfaceMaterial()
        ..baseColorTexture = CityTextures.sidewalkStrip
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
        ..roughnessFactor = 1.0
        ..metallicFactor = 0.0;

  /// Drop the cached materials so a texture reload rebinds.
  static void reset() {
    _facade = null;
    _glazing = null;
    _ground = null;
    _road = null;
    _dirt = null;
    _alley = null;
    _sidewalk = null;
  }
}

/// Trilinear sampling, for the same reason the prop material overrides it: the
/// stock material leaves every slot on flutter_gpu's `nearest` defaults, and an
/// unfiltered window grid crawls and aliases into moiré the moment a tower is
/// more than a few hundred metres off.
class _CitySurfaceMaterial extends fs.PhysicallyBasedMaterial {
  _CitySurfaceMaterial() {
    // The stock PBR fragment with the per-fragment skyglow added. Every stock
    // uniform keeps its name and layout, so super.bind feeds it unchanged;
    // when the bundle has not landed yet the stock shader stands in and
    // CityNodes resets the materials the frame the load completes.
    final shader = CityMaterials._surfaceShader;
    if (shader != null) setFragmentShader(shader);
    _glow = shader != null;
  }

  /// Whether this material binds the CityGlow block (custom shader only —
  /// the stock fragment has no such slot to fill).
  late final bool _glow;

  @override
  void bind(
    igpu.RenderPass pass,
    igpu.HostBuffer transientsBuffer,
    fs.Lighting lighting,
  ) {
    super.bind(pass, transientsBuffer, lighting);
    if (_glow) {
      final s = CityMaterials.glowIntensity *
          CityMaterials.nightFactor.clamp(0.0, 1.0);
      final data = Float32List(20);
      data[0] = CityMaterials.glowCentreScene.x;
      data[1] = CityMaterials.glowCentreScene.y;
      data[2] = CityMaterials.glowCentreScene.z;
      data[3] = CityMaterials.glowGroundRadiusScene;
      data[4] = CityMaterials.glowColor.x * s;
      data[5] = CityMaterials.glowColor.y * s;
      data[6] = CityMaterials.glowColor.z * s;
      data[7] = CityMaterials.glowFalloffM * CityMaterials.glowMetresToScene;
      data[8] = CityMaterials.lightMapAnchorScene.x;
      data[9] = CityMaterials.lightMapAnchorScene.y;
      data[10] = CityMaterials.lightMapAnchorScene.z;
      data[11] = CityMaterials.lightMapHalfExtentScene;
      data[12] = CityMaterials.lightMapEast.x;
      data[13] = CityMaterials.lightMapEast.y;
      data[14] = CityMaterials.lightMapEast.z;
      data[16] = CityMaterials.lightMapNorth.x;
      data[17] = CityMaterials.lightMapNorth.y;
      data[18] = CityMaterials.lightMapNorth.z;
      pass.bindUniform(
        fragmentShader.getUniformSlot('CityGlow'),
        transientsBuffer.emplace(ByteData.sublistView(data)),
      );
      // The density map. The white placeholder is "1 everywhere" — the
      // pre-map behaviour — until the first colony bake lands.
      pass.bindTexture(
        fragmentShader.getUniformSlot('city_light_texture'),
        fs.Material.whitePlaceholder(CityMaterials.lightMap as igpu.Texture?),
        sampler: _trilinear,
      );
    }
    pass.bindTexture(
      fragmentShader.getUniformSlot('base_color_texture'),
      fs.Material.whitePlaceholder(baseColorTexture),
      sampler: _trilinear,
    );
  }

  static final _trilinear = igpu.SamplerOptions(
    minFilter: igpu.MinMagFilter.linear,
    magFilter: igpu.MinMagFilter.linear,
    mipFilter: CityTextures.mipmapped
        ? igpu.MipFilter.linear
        : igpu.MipFilter.nearest,
    widthAddressMode: igpu.SamplerAddressMode.repeat,
    heightAddressMode: igpu.SamplerAddressMode.repeat,
  );
}

/// Glazing: the same filtering, plus the night-driven emissive.
///
/// The emissive FACTOR is set at bind time rather than when the material is
/// built, because it changes every frame as the sun moves and the material is
/// shared by every building in the city — rebuilding it per frame would throw
/// away the batching this whole path exists for.
class _GlazingMaterial extends _CitySurfaceMaterial {
  @override
  void bind(
    igpu.RenderPass pass,
    igpu.HostBuffer transientsBuffer,
    fs.Lighting lighting,
  ) {
    final glow = CityMaterials.nightFactor.clamp(0.0, 1.0);
    emissiveFactor = vm.Vector4(glow, glow, glow, 1);
    super.bind(pass, transientsBuffer, lighting);
  }
}
