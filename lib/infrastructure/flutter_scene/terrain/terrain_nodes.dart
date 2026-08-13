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

import '../../../adapters/presenters/camera_view.dart';
import '../../../application/snapshot/world_snapshot.dart';
import '../../../domain/shared/quaternion.dart';
import '../../../domain/shared/vector3.dart';
import '../../../domain/terrain/cell_mesher.dart';
import '../../../domain/terrain/cubed_sphere.dart';
import '../../../domain/terrain/terrain_edits.dart';
import '../../../domain/terrain/terrain_feature.dart';
import '../../../domain/terrain/terrain_field.dart';
import '../../../domain/terrain/terrain_lod.dart';
import '../../../domain/terrain/terrain_profile.dart';
import '../body_nodes.dart';
import '../coord_convert.dart';
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

  /// Lateral cells across one chunk.
  static int resolution = 24;

  /// Apparent body radius (px) below which terrain does not mesh at all and the
  /// textured sphere carries the body on its own. Replaces the old altitude
  /// cutoff: coverage is now body-wide, so what decides whether meshing is
  /// worth doing is how much screen the body occupies, not how far away it is.
  static double minBodyPx = 24;

  /// Hard cap on resident chunks. Screen-space LOD plus horizon culling already
  /// bound the leaf count, but forced refinement around terrain edits can push
  /// it, and an unbounded mesh set is an unbounded GPU upload. Farthest chunks
  /// are dropped first, so exceeding it truncates the horizon rather than
  /// punching holes near the craft.
  ///
  /// 1024 because low altitude is the expensive case, not orbit: at 500 m over
  /// the Moon the horizon is still ~42 km out, and the 2:1 staircase from the
  /// deeply-split chunks underfoot to the coarse ones at the limb measures ~590
  /// leaves. Orbit is far cheaper — the whole body resolves to a few dozen.
  ///
  /// The real cost here is DRAW CALLS, one per chunk, which is what wants
  /// batching before this number grows again.
  static int maxResidentChunks = 1024;

  /// Split a chunk once it projects wider than this many pixels. Fed to
  /// [TerrainLodTree], which pairs it with a merge threshold 2.2x lower so
  /// chunks on the boundary cannot thrash.
  static double splitPx = 220;

  /// New chunks meshed per frame. Synchronous meshing is 4a's stated
  /// simplification (4c moves it off-thread behind a scheduler); this cap is
  /// what stops a fast descent from collapsing into one enormous frame.
  ///
  /// Raised from 2 with body-wide coverage: first sight of a planet now needs
  /// tens of chunks rather than a handful, and at 2 per frame the horizon took
  /// visible seconds to fill in. Still bounded, because this runs on the main
  /// thread until the scheduler lands.
  static int meshBudgetPerFrame = 6;

  /// How close (m) the focus must be to a terrain edit before its chunks are
  /// force-refined. Deformation needs levels far past what screen-space
  /// selection picks, so refining a crater seen from orbit would carry a deep
  /// quadtree island — and the staircase of balanced chunks around it — for
  /// something a pixel wide.
  static double editRefineRangeM = 20000;

  /// How much of the body's REAL surface colour to use where a baked albedo
  /// map exists, 0..1. The map is ~5 km per texel, so it is applied as a
  /// modulation of the procedural blend rather than a replacement — it supplies
  /// the truth (where the maria are), the tiles supply the grain.
  static double albedoStrength = 1.0;

  /// Voxels across an edit's diameter once refined. Below ~6 a crater reads as
  /// a dent; much above it the chunk count climbs for detail the material
  /// shading already carries.
  static double editVoxelsAcross = 8;

  /// Depth of the crack-hiding apron, in chunk voxels (phase 4b). 2:1 balance
  /// caps a neighbour at one level coarser — voxels twice ours — so anything
  /// under 2 can leave a gap. 0 disables skirts, which is how you SEE the
  /// cracks they exist to hide.
  static double skirtVoxels = 2.5;

  /// Triplanar detail tuning. [tileMeters] = world size of one material tile.
  /// [sandWeight]/[grassWeight] are dev OVERRIDES of the body's own sand/grass
  /// amount (ext.acro.camera): < 0 means "use the body value" (the default, so
  /// each body picks its own materials); >= 0 forces that cap for preview.
  static double tileMeters = 6.0;
  static double sandWeight = -1.0;
  static double grassWeight = -1.0;

  /// Cast-shadow contact hardening (dev-tunable). [shadowHardness] = how fast the
  /// penumbra grows with the caster's height above the receiver (UV per clip-z
  /// gap); [maxPenumbraFactor] scales the light's softness into the maximum
  /// (far) penumbra width.
  ///
  /// The sun is a ~0.53 deg disc (9.3e-3 rad), so a caster a gap `g` above the
  /// receiver throws a penumbra of radius `g * 9.3e-3 / 2`. A cascade's clip-z
  /// spans `7 * box` world units (see terrain.frag) and the PCF radius is in UV
  /// (1.0 = box), so world cancels: hardness = 7 * 9.3e-3 / 2. Anything larger
  /// smears the 16-tap kernel over hundreds of texels, and the per-fragment IGN
  /// rotation that hides the undersampling then reads as dither. Real airless
  /// shadows are knife-edged; keep this physical.
  static double shadowHardness = 0.0326;

  /// Caps the far penumbra (and so the blocker-search disc, which the 8-tap
  /// search has to cover). softness is ~1.5 m, so 0.35 caps the penumbra near
  /// 0.5 m — generous for a ~15 m craft, whose true far penumbra is ~0.14 m.
  static double maxPenumbraFactor = 0.35;

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

  /// One resident chunk: its scene node plus the body-fixed point its vertices
  /// are relative to (see [CellMesh.anchorBF] for why they are not absolute).
  final Map<ChunkKey, _ResidentChunk> _chunks = {};
  TerrainLodTree? _tree;
  double _treeSplitPx = 0;
  // Geometry knobs the resident meshes were built with; a change invalidates
  // them (dev toggles), since the chunks themselves carry no record of it.
  double _builtSkirtVoxels = double.nan;
  int _builtResolution = -1;
  _TerrainMaterial? _material;
  String? _bodyId;

  /// The focused body's deformations, rebuilt from the snapshot only when the
  /// edit count moves. Re-indexing every brush every frame would cost more than
  /// meshing does.
  TerrainEdits? _edits;
  int _builtEditCount = -1;

  /// The focused body's detail layer, rebuilt only when the body changes —
  /// assembling it allocates the control field and every feature.
  TerrainDetail? _detail;
  String? _detailBodyId;

  /// Debug line for the HUD (chunk tri count / state).
  static String debugLine = '';

  /// Which gate suppressed terrain this frame, or '' when it rendered. Every
  /// early return below sets one, so `no terrain on <body>` is answerable from
  /// `ext.acro.terrain` instead of a rebuild-per-guess loop.
  static String gateReason = '';

  void update(
    WorldSnapshot snap,
    FloatingOrigin origin, {
    required Vector3 cameraEye, // focus-relative metres
    SceneCamera? camera, // drives the screen-space LOD budget
    String? focusBodyId,
    String? focusVesselId,
    Vector3? starWorld,
  }) {
    final shader = _shader;
    // Hold off until the shader AND the material tiles are uploaded — the
    // fragment declares the tex_* samplers, and drawing with them unbound faults.
    if (shader == null || !enabled || !TerrainTextures.ready) {
      gateReason = shader == null
          ? 'shader not loaded'
          : (!enabled ? 'disabled' : 'textures not ready');
      _clear();
      return;
    }

    final bodyId = focusBodyId ??
        (focusVesselId == null ? null : snap.vessels[focusVesselId]?.body);
    final b = bodyId == null ? null : snap.bodies[bodyId];
    final d = bodyId == null ? null : snap.descriptors[bodyId];
    if (b == null || d == null || !d.hasTerrain) {
      gateReason = bodyId == null
          ? 'no focus body (vessel $focusVesselId)'
          : (b == null
              ? 'body $bodyId not in snapshot'
              : (d == null
                  ? 'no descriptor for $bodyId'
                  : '$bodyId has no terrain config'));
      _clear();
      return;
    }

    final bodyWorld = Vector3(b.px, b.py, b.pz);
    final eyeWorld = origin.focusWorld + cameraEye;
    // Terrain now covers the WHOLE body, so the gate is apparent size rather
    // than altitude: mesh whenever the body is big enough on screen to be worth
    // it, at whatever LOD that works out to, and leave it to the textured
    // sphere when it is a few pixels wide. An altitude cutoff could not express
    // that — 60 km above the Moon and 60 km above Jupiter are not remotely the
    // same amount of screen.
    final bodyPx = camera == null
        ? double.infinity
        : camera.radiusPx(bodyWorld - origin.focusWorld, b.radius);
    if (bodyPx < minBodyPx) {
      gateReason = 'body ${bodyPx.toStringAsFixed(0)}px '
          '< minBodyPx ${minBodyPx.toStringAsFixed(0)}px';
      _clear();
      return;
    }
    gateReason = '';

    // Terrain deformation, replayed from the authoritative snapshot. The SAME
    // store feeds the field the mesher samples and the field collision samples
    // (via CelestialBody.terrainFieldWith), so a crater the physics knows about
    // is the crater that gets drawn.
    var editsChanged = false;
    var editCount = 0;
    for (final e in snap.terrainEdits) {
      if (e.body == bodyId) editCount++;
    }
    if (_builtEditCount != editCount || _bodyId != bodyId) {
      _edits = editCount == 0 ? null : snap.editsForBody(bodyId!);
      editsChanged = _builtEditCount != editCount;
      _builtEditCount = editCount;
    }

    // The generator recipe, rebuilt from the descriptor and cached per body.
    //
    // This MUST match what `CelestialBody.terrainFieldWith` builds on the sim
    // side. Omitting it was a real bug: the renderer drew plain fBm relief
    // while collision resolved against eroded, cratered ground, so a craft sank
    // straight through the visible surface hunting one that was drawn nowhere.
    if (_detailBodyId != bodyId) {
      _detail = d.terrainErodedDetail
          ? (d.terrainProfile ?? TerrainProfile.barren).detailFor(
              seed: d.terrainSeed,
              radiusM: d.referenceRadius,
              amplitudeM: d.terrainAmplitude,
              featureScaleM: d.terrainFeatureScale,
              octaves: d.terrainOctaves + 1,
            )
          : null;
      _detailBodyId = bodyId;
      // Fire-and-forget: the first frames draw with the placeholder and the
      // real colour appears when the upload lands.
      TerrainTextures.loadAlbedo(bodyId!);
    }

    final field = TerrainField(
      radius: d.referenceRadius,
      amplitude: d.terrainAmplitude,
      featureScale: d.terrainFeatureScale,
      seaLevel: d.terrainSeaLevel,
      seed: d.terrainSeed,
      octaves: d.terrainOctaves,
      edits: _edits,
      detail: _detail,
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

    // Switching bodies invalidates every resident chunk AND the quadtree —
    // keys are per-body, so carrying either across would place another
    // planet's geometry.
    if (_bodyId != bodyId) {
      _clear();
      _bodyId = bodyId;
    }

    // Everything below works in the BODY-FIXED frame, the frame the chunk
    // meshes and TerrainField share, so terrain co-rotates with the planet for
    // free (the node applies bodyQuat) and the landed-craft co-rotation fix
    // keeps working.
    final invQuat = bodyQuat.conjugate;
    final eyeBF = invQuat.rotate(eyeWorld - bodyWorld);
    final anchorBF = invQuat.rotate(anchorWorld - bodyWorld);
    final anchorDir = anchorBF.normalized;
    final anchorPoint = anchorDir * field.radius;

    // --- LOD selection -----------------------------------------------------
    // Apparent size comes from the SAME camera the rail culls use, so LOD and
    // culling cannot disagree about what is on screen (plan §2). Without a
    // camera there is no projection to budget against, so nothing splits.
    if (_tree == null || _treeSplitPx != splitPx) {
      _tree = TerrainLodTree(splitPx: splitPx);
      _treeSplitPx = splitPx;
    }
    // A geometry knob moved (dev toggle): drop every resident mesh so the ring
    // rebuilds with the new setting. Cheap because it only happens on a change.
    if (_builtSkirtVoxels != skirtVoxels || _builtResolution != resolution) {
      for (final c in _chunks.values) {
        _scene.remove(c.node);
      }
      _chunks.clear();
      _builtSkirtVoxels = skirtVoxels;
      _builtResolution = resolution;
    }
    double apparentPx(ChunkKey k) {
      if (camera == null) return 0;
      final radius = k.circumradiusM(field.radius);
      // Over the horizon: not worth detail, and the margin keeps a chunk whose
      // centre has just dipped under from popping while its near edge shows.
      if (isBeyondHorizon(k, eyeBF, field.radius, marginM: radius)) return 0;
      final centreWorld =
          bodyWorld + bodyQuat.rotate(k.centreDirection * field.radius);
      return camera.radiusPx(centreWorld - origin.focusWorld, radius);
    }
    // --- Deformation: forced refinement + invalidation ---------------------
    // A crater is orders of magnitude smaller than the cells LOD picks, so its
    // chunks are FORCED deeper (plan §3.5). Range-gated: refining an edit seen
    // from orbit would carry a deep quadtree island, and the balanced staircase
    // joining it to the coarse terrain around it, for a pixel of screen.
    final edits = _edits;
    final refine = <TerrainRefinement>[];
    if (edits != null) {
      for (final brush in edits.all) {
        if ((brush.centreBF - anchorPoint).length > editRefineRangeM) continue;
        refine.addAll(refinementsFor(
          brush,
          field.radius,
          resolution,
          voxelsAcrossBrush: editVoxelsAcross,
          maxLevel: _tree!.maxRefineLevel,
        ));
      }
    }
    // A new edit rewrites the density inside its footprint, so a resident chunk
    // overlapping it is stale even when its KEY is unchanged — the split path
    // alone would not retire it. Only runs on the frame the edit arrives.
    if (editsChanged && edits != null) {
      for (final k in _chunks.keys.toList()) {
        final centre = k.centreDirection * field.radius;
        final reach = k.circumradiusM(field.radius);
        for (final brush in edits.all) {
          if ((brush.centreBF - centre).length <= reach + brush.boundingRadiusM) {
            _scene.remove(_chunks.remove(k)!.node);
            break;
          }
        }
      }
    }
    final leaves = _tree!.update(apparentPx, refine: refine);

    // --- Visibility: the whole body, not a patch under the craft ------------
    // Every leaf this side of the horizon is meshed. LOD does the work of
    // keeping that affordable — distant chunks stay at coarse levels, where a
    // whole cube face is a handful of triangles — so full coverage costs far
    // less than the leaf COUNT suggests. The horizon test is the only spatial
    // cull needed, because a sphere hides its own far side.
    final visible = <ChunkKey>[];
    for (final k in leaves) {
      final radius = k.circumradiusM(field.radius);
      if (isBeyondHorizon(k, eyeBF, field.radius, marginM: radius)) continue;
      visible.add(k);
    }
    // Nearest first: it decides both what gets meshed within this frame's
    // budget and what survives the resident cap.
    visible.sort((x, y) {
      final dx = (x.centreDirection * field.radius - anchorPoint).length;
      final dy = (y.centreDirection * field.radius - anchorPoint).length;
      return dx.compareTo(dy);
    });
    final wanted = visible.length > maxResidentChunks
        ? visible.take(maxResidentChunks).toSet()
        : visible.toSet();

    // Retire chunks that dropped out of view or changed level.
    for (final k in _chunks.keys.toList()) {
      if (!wanted.contains(k)) {
        _scene.remove(_chunks.remove(k)!.node);
      }
    }

    // Mesh what is missing, capped per frame. `visible` is already sorted
    // nearest-first, so filtering it preserves that order and the ground under
    // the craft fills in before the horizon does.
    final missing = [
      for (final k in visible)
        if (wanted.contains(k) && !_chunks.containsKey(k)) k,
    ];
    var built = 0;
    for (final k in missing) {
      if (built >= meshBudgetPerFrame) break;
      _meshChunk(field, k, shader as gpu.Shader);
      built++;
    }

    if (_chunks.isEmpty) {
      debugLine = 'terrain: no chunks';
      return;
    }

    // Per-frame transform per chunk. Each mesh is LOCAL to its own anchor, so
    // the node sits at that anchor (near the render origin for a landed craft)
    // — not at the body centre ~1e6 m away, which cancelled in float32 and
    // jittered.
    for (final c in _chunks.values) {
      c.node.localTransform = vm.Matrix4.compose(
        origin.worldToScene(bodyWorld + bodyQuat.rotate(c.anchorBF)),
        quatToScene(bodyQuat),
        vm.Vector3.all(lengthToScene(1.0)),
      );
    }
    var tris = 0;
    var minLevel = 99, maxLevel = 0;
    for (final e in _chunks.entries) {
      tris += e.value.triangleCount;
      if (e.key.level < minLevel) minLevel = e.key.level;
      if (e.key.level > maxLevel) maxLevel = e.key.level;
    }
    debugLine = 'terrain: ${_chunks.length} chunks  $tris tris  '
        'lvl $minLevel-$maxLevel  q${leaves.length}'
        '${missing.length > built ? '  +${missing.length - built}' : ''}';

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
      // Per-body material amounts, unless a dev override (>= 0) is set.
      sandAmount: sandWeight >= 0 ? sandWeight : d.terrainSandAmount,
      grassAmount: grassWeight >= 0 ? grassWeight : d.terrainGrassAmount,
      // Spin axis (+Z) rotated the same way the node rotates vertices, so it
      // lands in v_position's world frame -> dot(up, pole) = latitude sine.
      poleWorld: quatToScene(bodyQuat).rotated(vm.Vector3(0.0, 0.0, 1.0)),
      // Body +X through the same rotation. Latitude alone cannot index an
      // equirectangular map — longitude needs a second body-fixed axis, and
      // v_position is world-space so it cannot be recovered there.
      meridianWorld: quatToScene(bodyQuat).rotated(vm.Vector3(1.0, 0.0, 0.0)),
      // Only bodies with a baked map get real colour; everything else stays on
      // the procedural blend exactly as before.
      albedoStrength:
          TerrainTextures.albedo.containsKey(bodyId) ? albedoStrength : 0.0,
    );
    _material?.bindAlbedo(TerrainTextures.albedo[bodyId]);
    // Bind the procedural material tiles once they've finished uploading.
    _material?.bindTiles();
  }

  /// Mesh one chunk and add it to the scene. A chunk whose shell holds no
  /// isosurface (nothing crosses zero) yields no geometry — legitimate, e.g.
  /// entirely below a sea floor — and is simply skipped.
  void _meshChunk(TerrainField field, ChunkKey key, gpu.Shader shader) {
    final cell = meshTerrainCell(field, key,
        resolution: resolution, skirtVoxels: skirtVoxels);
    if (cell.isEmpty) return;
    _material ??= _TerrainMaterial(shader);
    final geom = fs.MeshGeometry.fromArrays(
      positions: cell.mesh.positions,
      normals: cell.mesh.normals,
      indices: cell.mesh.indices,
    );
    final node = fs.Node(mesh: fs.Mesh(geom, _material!));
    _scene.add(node);
    _chunks[key] = _ResidentChunk(
      node: node,
      anchorBF: cell.anchorBF,
      triangleCount: cell.mesh.triangleCount,
    );
  }

  void _clear() {
    if (_chunks.isEmpty && _bodyId == null) return;
    for (final c in _chunks.values) {
      _scene.remove(c.node);
    }
    _chunks.clear();
    _tree?.reset();
    _bodyId = null;
    // Force the edit store to rebuild on the next frame that renders — the
    // count alone cannot distinguish "same body, unchanged" from "gated out
    // and back with a different body's edits resident".
    _builtEditCount = -1;
    _edits = null;
    debugLine = '';
  }
}

/// A chunk currently in the scene.
class _ResidentChunk {
  _ResidentChunk({
    required this.node,
    required this.anchorBF,
    required this.triangleCount,
  });

  final fs.Node node;

  /// Body-fixed point the node's vertices are relative to.
  final Vector3 anchorBF;

  final int triangleCount;
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
    required double sandAmount,
    required double grassAmount,
    required vm.Vector3 poleWorld,
    required vm.Vector3 meridianWorld,
    required double albedoStrength,
  }) {
    setUniformBlockFromFloats('TerrainInfo', [
      centreScene.x, centreScene.y, centreScene.z, radiusScene,
      sunTravel.x, sunTravel.y, sunTravel.z, amplitudeScene,
      seaRadiusScene, 0.14, 0.6, 0.6, // sea, ambient, snowStart, rockSlope
      0.34, 0.32, 0.29, 0.0, // col_low  (dark tan/grey)
      0.55, 0.53, 0.50, 0.0, // col_high (light grey)
      0.30, 0.28, 0.27, 0.0, // col_rock (unused now; tex_rock carries colour)
      0.90, 0.92, 0.95, 0.0, // col_snow
      tileMeters, sandAmount, grassAmount, 1.0, // detail
      poleWorld.x, poleWorld.y, poleWorld.z, 0.0, // pole (world)
      meridianWorld.x, meridianWorld.y, meridianWorld.z,
      albedoStrength, // meridian (world) + real-albedo mix
    ]);
  }

  /// Bind the procedural material tiles once, after they finish uploading.
  /// Repeat wrapping + linear filtering for clean triplanar tiling.
  void bindTiles() {
    if (_tilesBound || !TerrainTextures.ready) return;
    final sampler = igpu.SamplerOptions(
      minFilter: igpu.MinMagFilter.linear,
      magFilter: igpu.MinMagFilter.linear,
      mipFilter: TerrainTextures.mipmapped
          ? igpu.MipFilter.linear
          : igpu.MipFilter.nearest,
      widthAddressMode: igpu.SamplerAddressMode.repeat,
      heightAddressMode: igpu.SamplerAddressMode.repeat,
    );
    setTexture('tex_regolith', TerrainTextures.regolith, sampler: sampler);
    setTexture('tex_rock', TerrainTextures.rock, sampler: sampler);
    setTexture('tex_sand', TerrainTextures.sand, sampler: sampler);
    setTexture('tex_grass', TerrainTextures.grass, sampler: sampler);
    _tilesBound = true;
  }

  Object? _boundAlbedo;
  bool _albedoEverBound = false;

  /// Bind the body's real albedo map, or a white placeholder when it has none.
  ///
  /// The slot cannot be left empty: the fragment declares `tex_albedo`
  /// unconditionally and drawing with an unbound sampler faults. White is the
  /// right placeholder because the shader gates on the strength uniform, which
  /// is zero for bodies with no map — the texture is never read, but it must
  /// exist.
  void bindAlbedo(Object? texture) {
    final want = texture ?? TerrainTextures.albedoPlaceholder;
    if (want == null) return;
    if (_albedoEverBound && identical(want, _boundAlbedo)) return;
    setTexture(
      'tex_albedo',
      want,
      sampler: igpu.SamplerOptions(
        minFilter: igpu.MinMagFilter.linear,
        magFilter: igpu.MinMagFilter.linear,
        // Longitude wraps at the +/-180 seam; latitude must NOT, or the poles
        // would sample across to the opposite hemisphere.
        widthAddressMode: igpu.SamplerAddressMode.repeat,
        heightAddressMode: igpu.SamplerAddressMode.clampToEdge,
      ),
    );
    _boundAlbedo = want;
    _albedoEverBound = true;
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
    f[74] = light?.shadowSoftness ?? 0.0; // normal-offset bias softness
    f[75] = light?.shadowDepthBias ?? 0.0;
    f[76] = light?.shadowFadeRange ?? 0.0;
    f[77] = cascades.isEmpty ? 0.0 : 1.0;
    // Contact hardening: hardness (UV penumbra per clip-z gap) + max penumbra
    // (world). Sharp where the caster meets the ground, softening with the
    // caster's height above the receiver. Scaled off softness so scene_sync's
    // altitude tuning still moves it.
    f[78] = TerrainNodes.shadowHardness;
    f[79] = (light?.shadowSoftness ?? 0.0) * TerrainNodes.maxPenumbraFactor;
    setUniformBlock('ShadowInfo', ByteData.sublistView(f));
  }
}
