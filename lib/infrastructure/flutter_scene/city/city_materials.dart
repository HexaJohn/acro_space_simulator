// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// ignore_for_file: implementation_imports
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

  static fs.PhysicallyBasedMaterial? _facade;
  static fs.PhysicallyBasedMaterial? _glazing;
  static fs.PhysicallyBasedMaterial? _ground;

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

  /// Drop the cached materials so a texture reload rebinds.
  static void reset() {
    _facade = null;
    _glazing = null;
    _ground = null;
  }
}

/// Trilinear sampling, for the same reason the prop material overrides it: the
/// stock material leaves every slot on flutter_gpu's `nearest` defaults, and an
/// unfiltered window grid crawls and aliases into moiré the moment a tower is
/// more than a few hundred metres off.
class _CitySurfaceMaterial extends fs.PhysicallyBasedMaterial {
  @override
  void bind(
    igpu.RenderPass pass,
    igpu.HostBuffer transientsBuffer,
    fs.Lighting lighting,
  ) {
    super.bind(pass, transientsBuffer, lighting);
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
