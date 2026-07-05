// ignore_for_file: implementation_imports
import 'dart:typed_data';

import 'package:flutter_scene/gpu.dart' as gpu;
import 'package:flutter_scene/scene.dart' as fs;
import 'package:flutter_scene/src/gpu/gpu.dart' as igpu;
import 'package:vector_math/vector_math.dart' as vm;

import '../../../application/snapshot/world_snapshot.dart';
import '../../../domain/shared/quaternion.dart';
import '../../../domain/shared/vector3.dart';
import '../../../domain/terrain/terrain_field.dart';
import '../body_nodes.dart';
import '../coord_convert.dart';
import 'terrain_mesher.dart';
import 'terrain_textures.dart';

/// Renders a voxel-terrain patch on the focused body's surface.
///
/// Foundation (phase 3): ONE chunk under the camera. When the camera is near a
/// terrain body's surface, mesh an axis-aligned box at the sub-camera surface
/// point (in the body-fixed frame, so it spins with the planet) and draw it
/// through the triplanar procedural shader. The far textured sphere still
/// renders behind it. Re-meshes only when the sub-point drifts a good fraction
/// of the chunk. Cubed-sphere LOD + streaming is phase 4.
class TerrainNodes {
  TerrainNodes(this._scene);

  final fs.Scene _scene;

  /// Runtime kill switch (debug panel / dev ext).
  static bool enabled = true;

  /// Chunk side (m), grid resolution (cells/side), and the altitude (m) below
  /// which terrain meshes (above it the sphere alone suffices).
  static double chunkSizeM = 6000;
  static int resolution = 48;
  static double maxAltitudeM = 60000;

  /// Triplanar detail tuning (dev-tunable via ext.acro.camera). [tileMeters] =
  /// world size of one material tile; [sandWeight]/[grassWeight] blend the flat
  /// material toward sand/grass (0 = pure regolith, right for the Moon).
  static double tileMeters = 6.0;
  static double sandWeight = 0.0;
  static double grassWeight = 0.0;

  /// Generate + upload the procedural material tiles (idempotent).
  static Future<void> loadTextures() => TerrainTextures.load();

  static Object? _shader;
  static Future<void>? _loading;
  static Future<void> loadShader() => _loading ??= () async {
        final lib = await gpu
            .loadShaderLibraryAsync('build/shaderbundles/acro.shaderbundle');
        _shader = lib?['TerrainFragment'];
        if (_shader == null) {
          throw StateError(
            'TerrainFragment missing from acro.shaderbundle — the '
            'hook/build.dart shader compile should have produced it.',
          );
        }
      }();

  fs.Node? _node;
  _TerrainMaterial? _material;
  String? _bodyId;
  Vector3 _centerBF = Vector3.zero; // body-fixed chunk centre

  /// Debug line for the HUD (chunk tri count / state).
  static String debugLine = '';

  void update(
    WorldSnapshot snap,
    FloatingOrigin origin, {
    required Vector3 cameraEye, // focus-relative metres
    String? focusBodyId,
    String? focusVesselId,
    Vector3? starWorld,
  }) {
    final shader = _shader;
    // Hold off until the shader AND the material tiles are uploaded — the
    // fragment declares the tex_* samplers, and drawing with them unbound faults.
    if (shader == null || !enabled || !TerrainTextures.ready) {
      _clear();
      return;
    }

    final bodyId = focusBodyId ??
        (focusVesselId == null ? null : snap.vessels[focusVesselId]?.body);
    final b = bodyId == null ? null : snap.bodies[bodyId];
    final d = bodyId == null ? null : snap.descriptors[bodyId];
    if (b == null || d == null || !d.hasTerrain) {
      _clear();
      return;
    }

    final bodyWorld = Vector3(b.px, b.py, b.pz);
    final eyeWorld = origin.focusWorld + cameraEye;
    final altitude = (eyeWorld - bodyWorld).length - b.radius;
    if (altitude > maxAltitudeM) {
      _clear();
      return;
    }

    final field = TerrainField(
      radius: d.referenceRadius,
      amplitude: d.terrainAmplitude,
      featureScale: d.terrainFeatureScale,
      seaLevel: d.terrainSeaLevel,
      seed: d.terrainSeed,
      octaves: d.terrainOctaves,
    );

    // Focus on the surface — the followed vessel if any, else the camera.
    final fv = focusVesselId == null ? null : snap.vessels[focusVesselId];
    final vesselFocus = fv != null;
    var anchorWorld = eyeWorld;
    if (vesselFocus) {
      final vb = snap.bodies[fv.body];
      if (vb != null) {
        anchorWorld = Vector3(vb.px + fv.px, vb.py + fv.py, vb.pz + fv.pz);
      }
    }

    // The body's orientation (matches body_nodes exactly). The chunk MESH is
    // stored in the body-fixed frame; the node applies this quaternion, so the
    // terrain SPINS WITH THE BODY between re-anchors.
    final bodyQuat = Quaternion(b.qw, b.qx, b.qy, b.qz) *
        Quaternion.axisAngle(Vector3.unitZ, BodyNodes.textureYawRad);

    // Re-anchor only when the chunk's CURRENT WORLD position (which spins with
    // the body) drifts a chunk-width from where the focus is looking:
    //  * landed/co-rotating craft: chunk and craft co-rotate -> zero drift ->
    //    the chunk stays pinned and rotates with the planet;
    //  * fixed camera watching the body spin: the chunk rotates away with the
    //    surface and only re-anchors once it has drifted ~a chunk, so terrain
    //    visibly turns past like the texture instead of freezing under the eye.
    final chunkWorld = bodyWorld + bodyQuat.rotate(_centerBF);
    final focusSurf = vesselFocus
        ? anchorWorld
        : bodyWorld + (eyeWorld - bodyWorld).normalized * b.radius;
    final reanchor = _node == null ||
        _bodyId != bodyId ||
        (chunkWorld - focusSurf).length > chunkSizeM * 0.4;
    if (reanchor) {
      final dirBF =
          bodyQuat.conjugate.rotate(anchorWorld - bodyWorld).normalized;
      final groundR = field.groundRadiusAt(dirBF.x, dirBF.y, dirBF.z);
      final center = dirBF * groundR; // body-fixed chunk centre
      _remesh(field, center, shader as gpu.Shader);
      _bodyId = bodyId;
      _centerBF = center;
    }
    if (_node == null) return;

    // Per-frame: body-fixed transform + shader uniforms.
    _node!.localTransform = vm.Matrix4.compose(
      origin.worldToScene(bodyWorld),
      quatToScene(bodyQuat),
      vm.Vector3.all(lengthToScene(1.0)),
    );
    final sun = starWorld == null
        ? Vector3(-1, -0.2, -0.1).normalized
        : (bodyWorld - starWorld).normalized;
    _material?.setUniforms(
      centreScene: origin.worldToScene(bodyWorld),
      radiusScene: lengthToScene(field.radius),
      sunTravel: vm.Vector3(sun.x, sun.y, sun.z),
      amplitudeScene: lengthToScene(field.amplitude),
      seaRadiusScene: lengthToScene(field.seaRadius),
      tileMeters: tileMeters,
      sandWeight: sandWeight,
      grassWeight: grassWeight,
    );
    // Bind the procedural material tiles once they've finished uploading.
    _material?.bindTiles();
  }

  void _remesh(TerrainField field, Vector3 center, gpu.Shader shader) {
    final mesh = meshTerrainChunk(
      field,
      cx: center.x,
      cy: center.y,
      cz: center.z,
      sizeM: chunkSizeM,
      resolution: resolution,
    );
    if (mesh.isEmpty) {
      _clear();
      debugLine = 'terrain: empty chunk';
      return;
    }
    _material ??= _TerrainMaterial(shader);
    final geom = fs.MeshGeometry.fromArrays(
      positions: mesh.positions,
      normals: mesh.normals,
      indices: mesh.indices,
    );
    if (_node != null) _scene.remove(_node!);
    _node = fs.Node(mesh: fs.Mesh(geom, _material!));
    _scene.add(_node!);
    debugLine = 'terrain: ${mesh.triangleCount} tris';
  }

  void _clear() {
    if (_node != null) {
      _scene.remove(_node!);
      _node = null;
      _bodyId = null;
      debugLine = '';
    }
  }
}

/// Opaque triplanar-procedural terrain material. Double-sided (CullMode.none)
/// for now so Surface Nets winding never drops a face; the material tiles are
/// sampled triplanar and lit by the outward gradient normal.
class _TerrainMaterial extends fs.ShaderMaterial {
  _TerrainMaterial(gpu.Shader shader)
      : super(
          fragmentShader: shader,
          cullingMode: igpu.CullMode.none,
          isOpaqueOverride: true,
        );

  bool _tilesBound = false;

  void setUniforms({
    required vm.Vector3 centreScene,
    required double radiusScene,
    required vm.Vector3 sunTravel,
    required double amplitudeScene,
    required double seaRadiusScene,
    required double tileMeters,
    required double sandWeight,
    required double grassWeight,
  }) {
    setUniformBlockFromFloats('TerrainInfo', [
      centreScene.x, centreScene.y, centreScene.z, radiusScene,
      sunTravel.x, sunTravel.y, sunTravel.z, amplitudeScene,
      seaRadiusScene, 0.14, 0.6, 0.6, // sea, ambient, snowStart, rockSlope
      0.34, 0.32, 0.29, 0.0, // col_low  (dark tan/grey)
      0.55, 0.53, 0.50, 0.0, // col_high (light grey)
      0.30, 0.28, 0.27, 0.0, // col_rock (unused now; tex_rock carries colour)
      0.90, 0.92, 0.95, 0.0, // col_snow
      tileMeters, sandWeight, grassWeight, 1.0, // detail
    ]);
  }

  /// Bind the procedural material tiles once, after they finish uploading.
  /// Repeat wrapping + linear filtering for clean triplanar tiling.
  void bindTiles() {
    if (_tilesBound || !TerrainTextures.ready) return;
    final sampler = igpu.SamplerOptions(
      minFilter: igpu.MinMagFilter.linear,
      magFilter: igpu.MinMagFilter.linear,
      widthAddressMode: igpu.SamplerAddressMode.repeat,
      heightAddressMode: igpu.SamplerAddressMode.repeat,
    );
    setTexture('tex_regolith', TerrainTextures.regolith, sampler: sampler);
    setTexture('tex_rock', TerrainTextures.rock, sampler: sampler);
    setTexture('tex_sand', TerrainTextures.sand, sampler: sampler);
    setTexture('tex_grass', TerrainTextures.grass, sampler: sampler);
    _tilesBound = true;
  }

  @override
  void bind(
    igpu.RenderPass pass,
    igpu.HostBuffer transientsBuffer,
    fs.Lighting lighting,
  ) {
    // Pack this frame's cascaded-shadow state into ShadowInfo before the base
    // bind flushes the material's uniform blocks.
    _packShadow(lighting);
    super.bind(pass, transientsBuffer, lighting);
    // The depth atlas is fp32; the shader does its own PCF, so nearest sampling
    // is the portable choice (matches EngineLightingUniforms). A white
    // placeholder keeps the slot live when shadows are off this frame.
    pass.bindTexture(
      fragmentShader.getUniformSlot('shadow_map'),
      fs.Material.whitePlaceholder(lighting.shadowMap),
      sampler: igpu.SamplerOptions(
        minFilter: igpu.MinMagFilter.nearest,
        magFilter: igpu.MinMagFilter.nearest,
      ),
    );
  }

  /// Fills the `ShadowInfo` block (see terrain.frag) from [lighting] — the
  /// cascade matrices + world-space shadow params the fork's PCF path needs.
  /// std140 layout: mat4[4] (0..63), cascade_box_sizes vec4 (64..67),
  /// light_dir_count vec4 (68..71), sp0 vec4 (72..75), sp1 vec4 (76..79).
  void _packShadow(fs.Lighting lighting) {
    final cascades = lighting.shadowMap == null
        ? const <fs.ShadowCascade>[]
        : lighting.cascades;
    final f = Float32List(80);
    for (var i = 0; i < cascades.length && i < 4; i++) {
      f.setRange(i * 16, i * 16 + 16, cascades[i].lightSpaceMatrix.storage);
      f[64 + i] = cascades[i].boxSize;
    }
    final light = lighting.directionalLight;
    final dir = lighting.directionalLightDirection ??
        light?.direction ??
        vm.Vector3(0.0, -1.0, 0.0);
    f[68] = dir.x;
    f[69] = dir.y;
    f[70] = dir.z;
    f[71] = cascades.length.toDouble();
    f[72] = light == null ? 0.0 : 1.0 / light.shadowMapResolution;
    f[73] = light?.shadowNormalBias ?? 0.0;
    f[74] = light?.shadowSoftness ?? 0.0;
    f[75] = light?.shadowDepthBias ?? 0.0;
    f[76] = light?.shadowFadeRange ?? 0.0;
    f[77] = cascades.isEmpty ? 0.0 : 1.0;
    setUniformBlock('ShadowInfo', ByteData.sublistView(f));
  }
}
