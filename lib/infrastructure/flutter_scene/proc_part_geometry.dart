// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../domain/parts/proc_part_mesh.dart';
import '../../domain/parts/proc_shape.dart';
import '../../domain/scatter/prop_mesh.dart';

/// [ProcShape] -> the [fs.Mesh] that IS that part's art: the domain's
/// generated triangles ([ProcPartMesh]) under the finish the shape earns.
///
/// The straight `MeshGeometry.fromArrays` handoff the scatter props use, plus
/// a material switch. Meshes are built per call and never cached — an
/// [fs.Mesh] is bound into the node that draws it, and one shared instance
/// would couple every part using it (the same rule `PartPrimitivesByCategory`
/// states for the stand-ins). Materials are likewise per call: `fscene` reads
/// a material straight through to the render item, so a shared one is one
/// in-place edit away from recolouring every girder at once.
class ProcPartGeometry {
  ProcPartGeometry._();

  static fs.Mesh meshFor(ProcShape shape) => fs.Mesh(
        _geometry(ProcPartMesh.build(shape)),
        _material(shape),
      );

  static fs.MeshGeometry _geometry(PropMesh mesh) => fs.MeshGeometry.fromArrays(
        positions: mesh.positions,
        normals: mesh.normals,
        texCoords: mesh.texCoords,
        indices: mesh.indices,
      );

  static fs.Material _material(ProcShape shape) => switch (shape) {
        // Bright pressure-vessel metal, a shade cleaner than the grey
        // stand-in hull so a real tank reads as finished art.
        ProcSphere() || ProcPill() => fs.PhysicallyBasedMaterial()
          ..baseColorFactor = vm.Vector4(0.82, 0.83, 0.85, 1.0)
          ..roughnessFactor = 0.35
          ..metallicFactor = 0.9,
        // Industrial safety yellow: painted steel, so low metalness and a
        // rougher surface than the bare hulls.
        ProcTruss() => fs.PhysicallyBasedMaterial()
          ..baseColorFactor = vm.Vector4(0.85, 0.60, 0.05, 1.0)
          ..roughnessFactor = 0.55
          ..metallicFactor = 0.35,
        ProcPlate p => p.armor
            // Gunmetal: dark, rough, unmistakably heavier than skin.
            ? (fs.PhysicallyBasedMaterial()
              ..baseColorFactor = vm.Vector4(0.16, 0.17, 0.19, 1.0)
              ..roughnessFactor = 0.55
              ..metallicFactor = 0.85)
            // Bare aluminium skin.
            : (fs.PhysicallyBasedMaterial()
              ..baseColorFactor = vm.Vector4(0.70, 0.71, 0.73, 1.0)
              ..roughnessFactor = 0.4
              ..metallicFactor = 0.8),
      };
}
