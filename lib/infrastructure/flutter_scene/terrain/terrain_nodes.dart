// ignore_for_file: implementation_imports
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
  Vector3 _lastCenter = Vector3.zero;

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
    if (shader == null || !enabled) {
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

    // Anchor the chunk to the FOCUS on the surface — the followed vessel if
    // any, else the camera. Using the focus (not the camera eye) is what keeps
    // the patch planet-fixed: orbiting the camera around a landed craft no
    // longer drags the terrain with it.
    final fv = focusVesselId == null ? null : snap.vessels[focusVesselId];
    var anchorWorld = eyeWorld;
    if (fv != null) {
      final vb = snap.bodies[fv.body];
      if (vb != null) {
        anchorWorld = Vector3(vb.px + fv.px, vb.py + fv.py, vb.pz + fv.pz);
      }
    }

    // Sub-anchor surface point in the BODY-FIXED frame (matches body_nodes'
    // rotation exactly so terrain and the textured sphere share a frame).
    final bodyQuat = Quaternion(b.qw, b.qx, b.qy, b.qz) *
        Quaternion.axisAngle(Vector3.unitZ, BodyNodes.textureYawRad);
    final dirBF = bodyQuat.conjugate.rotate(anchorWorld - bodyWorld).normalized;
    final groundR = field.groundRadiusAt(dirBF.x, dirBF.y, dirBF.z);
    // Snap the surface point to a body-fixed grid so the chunk sits at a FIXED
    // planet location and only jumps to a neighbour when the anchor crosses a
    // cell — no continuous slide. A quarter-chunk grid keeps the true surface
    // well inside the box.
    final raw = dirBF * groundR;
    final g = chunkSizeM / 4;
    final center = Vector3(
      (raw.x / g).roundToDouble() * g,
      (raw.y / g).roundToDouble() * g,
      (raw.z / g).roundToDouble() * g,
    );

    final moved = _bodyId != bodyId || (center - _lastCenter).length > 1.0;
    if (_node == null || moved) {
      _remesh(field, center, shader as gpu.Shader);
      _bodyId = bodyId;
      _lastCenter = center;
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
    );
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

/// Opaque triplanar-procedural terrain material. Double-sided for now (the
/// shader flips the normal viewer-ward), so Surface Nets winding never shows
/// backfaces; back-face culling is a later optimisation.
class _TerrainMaterial extends fs.ShaderMaterial {
  _TerrainMaterial(gpu.Shader shader)
      : super(
          fragmentShader: shader,
          cullingMode: igpu.CullMode.none,
          isOpaqueOverride: true,
        );

  void setUniforms({
    required vm.Vector3 centreScene,
    required double radiusScene,
    required vm.Vector3 sunTravel,
    required double amplitudeScene,
    required double seaRadiusScene,
  }) {
    setUniformBlockFromFloats('TerrainInfo', [
      centreScene.x, centreScene.y, centreScene.z, radiusScene,
      sunTravel.x, sunTravel.y, sunTravel.z, amplitudeScene,
      seaRadiusScene, 0.08, 0.6, 0.6, // sea, ambient, snowStart, rockSlope
      0.34, 0.32, 0.29, 0.0, // col_low  (dark tan/grey)
      0.55, 0.53, 0.50, 0.0, // col_high (light grey)
      0.30, 0.28, 0.27, 0.0, // col_rock
      0.90, 0.92, 0.95, 0.0, // col_snow
    ]);
  }
}
