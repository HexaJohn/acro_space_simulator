// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// ignore_for_file: implementation_imports
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

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
import '../../../domain/terrain/mesh_scheduler.dart';
import '../../../domain/terrain/terrain_edits.dart';
import '../../../domain/terrain/terrain_feature.dart';
import '../../../domain/terrain/terrain_field.dart';
import '../../../domain/terrain/terrain_lod.dart';
import '../body_nodes.dart';
import '../coord_convert.dart';
import '../depth_materials.dart';
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

  /// Debug view for the terrain shader (debug panel / dev ext):
  /// 0 normal, 1 height bands + 1 km contours, 2 raw albedo map,
  /// 3 alignment overlay (albedo grey + contours + graticule),
  /// 4 raw detail-normal map (flat ground reads lavender 128/128/255).
  static int debugView = 0;
  static const int debugViewCount = 5;
  static const List<String> debugViewNames = [
    'normal', 'height', 'albedo', 'align', 'nrm',
  ];

  /// Lateral cells across one chunk.
  static int resolution = 24;

  // NOTE: there is deliberately NO apparent-size gate any more (the old
  // minBodyPx). Terrain draws whenever the focused body has any: at a few
  // pixels of screen the LOD tree collapses to the six cube-face roots — a
  // handful of triangles — so "always on" costs nothing, and the textured
  // sphere stops being the thing you see (it survives only as an under-shell
  // sunk below the lowest ground, backing gaps while chunks stream in).

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

  /// Mesh jobs in flight at once (phase 4c). Meshing runs on background
  /// isolates on native (inline on web), so this caps CPU occupancy, not a
  /// per-frame stall. Nearest-first submission order means the ground under
  /// the craft is always in the earliest batch.
  static int meshBudgetPerFrame = 6;

  /// Finished meshes turned into scene nodes per painted frame. THIS is the
  /// main-thread budget the plan says to enforce (§4: "budget the uploads,
  /// not the meshing") — geometry upload is the only part of streaming that
  /// still happens on the render thread.
  static int uploadBudgetPerFrame = 4;

  /// Kill switch: false forces inline meshing (the pre-4c behaviour) for A/B
  /// comparisons from the dev ext.
  static bool asyncMeshing = true;

  /// Frames a resident chunk may stay INVISIBLE before it is retired. The
  /// horizon cull has no hysteresis of its own, so without a grace window an
  /// orbiting camera retires and remeshes the same horizon ring every few
  /// frames. ~1.5 s at 60 fps; the watermark eviction still reclaims memory
  /// under real pressure.
  static int retireGraceFrames = 90;

  /// Retired meshes kept in the in-memory cache (see [_meshCache]).
  static int meshCacheSize = 512;

  /// Draw a wireframe "loading" grid (plus a spinner) over regions whose
  /// resident cover is missing entirely OR at least [placeholderLevelGap]
  /// LOD levels coarser than what selection wants — the honest "this ground
  /// is still streaming" state. Coverage roots land within a frame, so bare
  /// regions alone would almost never show it; the level gap is what makes
  /// the initial refine-in read as loading instead of as blurry ground.
  static bool loadingGrid = true;

  /// Cover this many levels coarser than wanted counts as "still loading".
  static int placeholderLevelGap = 6;

  /// At most this many grid patches at once (nearest first).
  static int maxPlaceholders = 48;

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

  /// How much of the baked DEM normal map (`.acronrm`) to blend into the
  /// lighting where one exists, 0..1. Restores crater-rim lighting on coarse
  /// LOD chunks; see the fade range below for why it is distance-gated.
  static double detailNormalStrength = 1.0;

  /// Camera-distance fade for the detail normal, in scene units (km). Below
  /// [normalFadeNearKm] the mesh resolves the same relief the map carries
  /// (~2.7 km/texel), so the map stays out — lighting a ridge that geometry
  /// already lights exaggerates it. Above [normalFadeFarKm] chunks are coarse
  /// and the map carries the relief alone.
  static double normalFadeNearKm = 10.0;
  static double normalFadeFarKm = 60.0;

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

  /// Second, macro octave of the ground materials: regolith + rock sampled
  /// again at [macroTileMeters] and blended in at [macroWeight] (0..1, 0
  /// disables). One 6 m tile repeated across a planet reads as wallpaper
  /// from a few hundred metres up; the macro octave breaks the repetition
  /// at hillside scale. 900 m sits in the gap between the fine tile and the
  /// baked albedo's ~5 km texel — visibly mottles the ground from orbit
  /// (A/B at 100 km: flat cream vs dappled) while acting as a slow local
  /// tint at ground level. Dev-tunable: ext.acro.camera?macroTileM=&macroW=.
  static double macroTileMeters = 900.0;
  static double macroWeight = 0.8;

  /// Lighting counterpart of the macro octave: how hard the baked tile
  /// normal (sampled at [macroTileMeters]) tilts the lighting normal. The
  /// tile itself implies ~5% relief-to-tile; this scales that. Also gated by
  /// [macroWeight], so one pair of knobs governs colour + bump together.
  /// Dev-tunable: ext.acro.camera?macroBump=. 1.5 verified by A/B at a
  /// grazing sun angle: visible hummocky relief without crunchy over-shading.
  static double macroBumpStrength = 1.5;

  /// Camera-distance fade for the whole macro octave (colour + bump), scene
  /// km. A 900 m pattern is ~1 px from ~800 km, below that it only aliases —
  /// whole-disc renders shimmered. Full below [macroFadeNearKm], off above
  /// [macroFadeFarKm]. ext.acro.camera?macroFadeNear=&macroFadeFar=.
  static double macroFadeNearKm = 200.0;
  static double macroFadeFarKm = 600.0;

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

  // --- Async meshing state (phase 4c) --------------------------------------
  // In-flight jobs cannot be cancelled (see mesh_scheduler.dart); staleness is
  // handled by tagging every job with [_generation] and dropping results whose
  // tag no longer matches. Bump the generation whenever the field the jobs
  // were built from stops being true: body switch, geometry knob, new edit.
  TerrainMeshScheduler? _scheduler;
  bool _schedulerAsync = true;
  final Set<ChunkKey> _pending = {};
  final List<_ArrivedMesh> _arrived = [];

  /// Chunks that meshed to NO geometry (isosurface not in their shell —
  /// legitimate, e.g. below a sea floor). Remembered so they are not
  /// resubmitted every frame; cleared with the generation.
  final Set<ChunkKey> _emptyChunks = {};

  /// Retired chunks' meshes, kept in memory so a revisit re-UPLOADS instead
  /// of re-MESHING — a camera swinging back gets its ground the same frame.
  /// Dart maps iterate in insertion order, so re-inserting on hit makes this
  /// an LRU; [meshCacheSize] bounds it (~100 KB per entry at resolution 24).
  /// Cleared with the generation — a cached mesh of a stale field is a lie.
  final Map<ChunkKey, CellMesh> _meshCache = {};

  /// Update counter driving the retirement grace window.
  int _frame = 0;

  // --- Loading placeholder ---------------------------------------------------
  /// Wireframe patch per bare (no cover at any LOD) chunk, plus one spinner
  /// billboard over the nearest of them.
  final Map<ChunkKey, _GridPatch> _gridPatches = {};
  fs.Node? _spinnerNode;
  fs.BillboardGeometry? _spinnerGeo;
  DepthSafeSpriteMaterial? _spinnerMat;
  bool _spinnerTexApplied = false;
  static Object? _spinnerTex;
  static bool _spinnerTexBuilding = false;

  /// 270-degree arc, the universal "working on it" glyph, baked once.
  static void _ensureSpinnerTex() {
    if (_spinnerTex != null || _spinnerTexBuilding) return;
    _spinnerTexBuilding = true;
    const s = 64.0;
    final rec = ui.PictureRecorder();
    final canvas = ui.Canvas(rec);
    canvas.drawArc(
      const ui.Rect.fromLTWH(8, 8, s - 16, s - 16),
      0,
      4.7, // ~270 deg
      false,
      ui.Paint()
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 7
        ..strokeCap = ui.StrokeCap.round
        ..color = const ui.Color(0xFFBFE3FF),
    );
    rec
        .endRecording()
        .toImage(s.toInt(), s.toInt())
        .then((img) => fs.gpuTextureFromImage(img))
        .then((tex) {
      _spinnerTex = tex as Object;
    }).catchError((Object _) {
      _spinnerTexBuilding = false;
    });
  }

  /// Cells that came back BOTH empty and clipped — the shell failed to
  /// contain the isosurface, which the mesher's own containment check calls
  /// a bug, and which renders as a permanently missing tile. Surfaced in
  /// [debugLine] so `ext.acro.terrain` answers "why is that tile missing".
  int _clippedEmpty = 0;
  int _generation = 0;

  TerrainLodTree? _tree;
  double _treeSplitPx = 0;
  // Geometry knobs the resident meshes were built with; a change invalidates
  // them (dev toggles), since the chunks themselves carry no record of it.
  double _builtSkirtVoxels = double.nan;
  int _builtResolution = -1;
  _TerrainMaterial? _material;
  String? _bodyId;

  /// The body terrain covered this frame (null when gated out), plus the
  /// field's relief bound. `SceneSync` hands these to [BodyNodes], which sinks
  /// that body's textured sphere fully inside the relief — the sphere is an
  /// under-shell backing streaming gaps, never the thing on screen. The
  /// descriptor's own amplitude is NOT enough for this on a DEM body: the
  /// field DERIVES a larger bound from the DEM's real elevation span.
  String? activeBodyId;
  double activeReliefM = 0;

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

    // The generator recipe, rebuilt from the descriptor via the ONE shared
    // builder (BodyDescriptorSnapshot.buildTerrainField — it must match what
    // `CelestialBody.terrainFieldWith` builds on the sim side; hand-rolling
    // the field here was a real bug class: the renderer drew plain fBm relief
    // while collision resolved against eroded, cratered ground). The detail
    // layer is cached per body — it is the expensive part.
    if (_detailBodyId != bodyId) {
      _detail = d.buildTerrainDetail();
      _detailBodyId = bodyId;
      // Fire-and-forget: the first frames draw with the placeholder and the
      // real colour appears when the upload lands.
      TerrainTextures.loadAlbedo(bodyId!);
      TerrainTextures.loadNormals(bodyId);
    }

    final field = d.buildTerrainField(edits: _edits, detail: _detail)!;
    activeBodyId = bodyId;
    activeReliefM = field.amplitude;

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
    // In-flight jobs were built with the old knobs — invalidate them too.
    if (_builtSkirtVoxels != skirtVoxels || _builtResolution != resolution) {
      for (final c in _chunks.values) {
        _scene.remove(c.node);
      }
      _chunks.clear();
      _invalidateInFlight();
      _builtSkirtVoxels = skirtVoxels;
      _builtResolution = resolution;
    }
    double apparentPx(ChunkKey k) {
      if (camera == null) return 0;
      final radius = k.circumradiusM(field.radius);
      // Over the horizon: not worth detail, and the margin keeps a chunk whose
      // centre has just dipped under from popping while its near edge shows.
      // reliefM matters: on a DEM body the ground — and the eye standing on
      // it — can sit kilometres below the datum sphere.
      if (isBeyondHorizon(k, eyeBF, field.radius,
          marginM: radius, reliefM: field.amplitude)) {
        return 0;
      }
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
    // In-flight jobs sampled the pre-edit field; drop their results wholesale
    // rather than intersecting each against the brush (edits are rare).
    if (editsChanged && edits != null) {
      _invalidateInFlight();
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
      if (isBeyondHorizon(k, eyeBF, field.radius,
          marginM: radius, reliefM: field.amplitude)) {
        continue;
      }
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

    // Retire chunks that dropped out of view or changed level — EXCEPT a
    // stale chunk standing in where its replacement has not arrived yet.
    // Retiring a parent before its children upload (or the children before
    // their parent) opens a hole straight through to the under-sphere for a
    // few frames on every LOD transition; with the sphere sunk below the
    // lowest ground, that hole reads as a dark pit. The stand-in overlaps its
    // replacement for a frame or two instead — the surfaces differ by less
    // than a voxel, so the nearer one simply wins the depth test.
    final missingNow = <ChunkKey>{
      for (final k in wanted)
        if (!_chunks.containsKey(k) && !_emptyChunks.contains(k)) k,
    };
    // The NEAREST resident ancestor of each missing chunk is its coarse
    // stand-in for a pending split — and ONLY the nearest. Protecting every
    // ancestor pinned the face ROOT for as long as anything anywhere on that
    // face was streaming, which near the surface is always; a root's surface
    // is sampled at ~100 km per cell, so in deep basins it floats kilometres
    // ABOVE the refined floor and drew as flat sphere-segment slabs over the
    // maria and crater floors (highlands hid it — there the root sits below).
    // `bareAncestors` marks the ancestors of missing chunks with NO resident
    // cover at all: the coverage-root path below meshes those, and the upload
    // pump must accept them on arrival even though they are not wanted.
    // Ancestors of every resident: `coveredBelow.contains(k)` == some finer
    // resident lies under k's region (the merge-direction cover).
    final coveredBelow = <ChunkKey>{
      for (final r in _chunks.keys) ...r.ancestors,
    };
    final protected = <ChunkKey>{};
    final bareAncestors = <ChunkKey>{};
    // Missing chunks whose cover is absent or far coarser than wanted — the
    // loading placeholder draws over them (the coverage-root path handles
    // the truly bare subset).
    final stillLoading = <ChunkKey>{};
    for (final m in missingNow) {
      ChunkKey? nearest;
      for (final a in m.ancestors) {
        if (_chunks.containsKey(a)) {
          nearest = a;
          break;
        }
      }
      if (nearest != null) {
        protected.add(nearest);
        if (m.level - nearest.level >= placeholderLevelGap) {
          stillLoading.add(m);
        }
      } else if (!coveredBelow.contains(m)) {
        stillLoading.add(m);
        bareAncestors.addAll(m.ancestors);
      }
    }
    bool standsIn(ChunkKey k) {
      if (protected.contains(k)) return true;
      // The fine stand-in for a pending merge: a resident whose own ancestor
      // is the missing chunk. Keep every such descendant — each covers a
      // distinct part of the missing region.
      for (final a in k.ancestors) {
        if (missingNow.contains(a)) return true;
      }
      return false;
    }

    // Retire against the UNTRUNCATED visible set, not `wanted`. When impact
    // refinement (plus its 2:1 staircase) pushes visible demand past the
    // resident cap, the nearest-first sort reorders with every camera move
    // and a different tail falls past the cap each frame — retiring on
    // `wanted` made the horizon tiles churn in and out (flicker) and the
    // farthest ring vanish outright. The cap below is ADMISSION control for
    // new work; residency ends only when a chunk stops being visible (or its
    // replacement arrived).
    //
    // And "stops being visible" carries a GRACE PERIOD (plan §4: evict by
    // "not visible + oldest"). The horizon cull has margins but no
    // hysteresis: an orbiting camera walks chunks across the horizon edge
    // every frame, and instant retirement turned each crossing into retire →
    // want again → remesh — a flickering ring of missing tiles at exactly
    // the range the player reads as "the horizon". A chunk now has to stay
    // invisible for [retireGraceFrames] consecutive frames before it is
    // dropped; drawing a just-hidden chunk for another second is free (the
    // planet occludes it), remeshing it every other frame is not.
    final visibleSet = visible.toSet();
    _frame++;
    for (final e in _chunks.entries) {
      if (visibleSet.contains(e.key)) e.value.lastVisibleFrame = _frame;
    }
    for (final k in _chunks.keys.toList()) {
      if (_frame - _chunks[k]!.lastVisibleFrame > retireGraceFrames &&
          !standsIn(k)) {
        _removeResident(k);
      }
    }
    // High-watermark eviction keeps the GPU set bounded when visible demand
    // genuinely exceeds the cap for a while: above cap+25%, drop the
    // FARTHEST residents that are neither wanted nor standing in, back down
    // to the cap. Hysteresis (the 25% band) is what stops the cap boundary
    // itself from thrashing.
    if (_chunks.length > maxResidentChunks + maxResidentChunks ~/ 4) {
      final evictable = [
        for (final k in _chunks.keys)
          if (!wanted.contains(k) && !standsIn(k)) k,
      ]..sort((x, y) {
          final dx = (x.centreDirection * field.radius - anchorPoint).length;
          final dy = (y.centreDirection * field.radius - anchorPoint).length;
          return dy.compareTo(dx); // farthest first
        });
      for (final k in evictable) {
        if (_chunks.length <= maxResidentChunks) break;
        _removeResident(k);
      }
    }

    // Turn finished meshes into scene nodes — the upload is the only part of
    // streaming still on the render thread (plan §4). Stale results (wrong
    // generation, no longer wanted, already resident) are dropped; a chunk
    // that is NOT wanted is accepted only when it covers a bare region (a
    // coverage root).
    //
    // LOD transitions are ATOMIC. Coarse and fine never draw together — the
    // sunk-stand-in overlap tried that and read as layered ground in every
    // basin. A split's children WAIT in the arrival queue until every
    // sibling needed to cover the parent's region is on hand, then the whole
    // set uploads and the parent leaves in the same frame; a merge uploads
    // the parent and drops its resident descendants in the same frame. Until
    // then the OLD LOD simply stays on screen, which is exactly "low detail
    // until the higher detail finishes loading". Atomic groups may overrun
    // the upload budget — a torn swap is worse than a long frame.
    var uploads = 0;
    final byKey = <ChunkKey, _ArrivedMesh>{};
    for (final a in _arrived) {
      if (a.generation != _generation || _chunks.containsKey(a.key)) continue;
      if (!wanted.contains(a.key) && !bareAncestors.contains(a.key)) continue;
      byKey[a.key] = a;
    }
    _arrived.clear();
    for (final a in byKey.values.toList()) {
      if (_chunks.containsKey(a.key)) continue; // landed in an earlier group
      if (uploads >= uploadBudgetPerFrame) {
        _arrived.add(a); // over budget: hold for next frame
        continue;
      }
      ChunkKey? coarse;
      for (final an in a.key.ancestors) {
        if (_chunks.containsKey(an)) {
          coarse = an;
          break;
        }
      }
      if (coarse != null) {
        // Split swap: every missing wanted chunk under `coarse` must be
        // resident or on hand before anything uploads.
        final under = [
          for (final m in missingNow)
            if (m == coarse || m.ancestors.contains(coarse)) m,
        ];
        final ready = under.every(
            (m) => _chunks.containsKey(m) || byKey.containsKey(m));
        if (!ready) {
          _arrived.add(a);
          continue;
        }
        for (final m in under) {
          final w = byKey[m];
          if (w == null || _chunks.containsKey(m)) continue;
          _addChunk(m, w.cell, shader as gpu.Shader);
          uploads++;
        }
        _removeResident(coarse);
      } else {
        _addChunk(a.key, a.cell, shader as gpu.Shader);
        uploads++;
        // Merge swap: this chunk replaces any finer residents under it, in
        // the same frame.
        for (final r in _chunks.keys.toList()) {
          if (r != a.key && r.ancestors.contains(a.key)) _removeResident(r);
        }
      }
    }

    // Submit what is missing, up to the in-flight cap. `visible` is already
    // sorted nearest-first, so filtering it preserves that order and the
    // ground under the craft fills in before the horizon does.
    final held = <ChunkKey>{for (final a in _arrived) a.key};
    final missing = [
      for (final k in visible)
        if (wanted.contains(k) &&
            !_chunks.containsKey(k) &&
            !_pending.contains(k) &&
            !held.contains(k) &&
            !_emptyChunks.contains(k))
          k,
    ];
    if (_scheduler == null || _schedulerAsync != asyncMeshing) {
      _scheduler?.dispose();
      _scheduler = asyncMeshing
          ? TerrainMeshScheduler.platform()
          : SyncTerrainMeshScheduler();
      _schedulerAsync = asyncMeshing;
    }
    // --- Coarse-first coverage -------------------------------------------
    // Zooming out WIDENS the horizon, so freshly revealed regions enter the
    // wanted set with no resident chunk at any level — nothing stands in, and
    // they render as holes for the whole time the backlog takes to drain
    // (measured: a fast zoom-out demanded ~190 leaves with a 100-chunk
    // backlog). Invariant instead: every visible face keeps SOMETHING
    // resident — if a missing chunk has no resident cover above or below it,
    // its face ROOT is meshed first (a root is a handful of triangles and
    // meshes in ~ms), and refinement replaces it from there. This is what
    // "tiles never unload completely" means operationally. `bareAncestors`
    // (computed with the stand-in protection above) already marks exactly
    // those regions: the roots in it are the faces needing coverage.
    final coverageRoots = <ChunkKey>{
      for (final a in bareAncestors)
        if (a.level == 0 &&
            !_chunks.containsKey(a) &&
            !_pending.contains(a) &&
            !_emptyChunks.contains(a))
          a,
    };
    for (final k in coverageRoots.followedBy(missing)) {
      // Cache first: a retired mesh re-enters through the normal arrival
      // path (same generation gating, same atomic swaps) without costing an
      // isolate round-trip or a slot in the in-flight budget.
      final cached = _meshCache.remove(k);
      if (cached != null) {
        // `held` (arrival-queue membership) keeps it out of `missing` next
        // frame, so it cannot double-submit while it waits for upload.
        _arrived.add(_ArrivedMesh(k, cached, _generation));
        continue;
      }
      if (_pending.length >= meshBudgetPerFrame) break;
      if (_pending.contains(k)) continue;
      _submit(field, k);
    }

    // "This ground is still streaming": wireframe patches + a spinner over
    // regions that have NO cover at any LOD. Runs before the no-chunks early
    // return — the initial fill is exactly when the placeholder matters.
    _updatePlaceholders(
        field, missing, stillLoading, bodyWorld, bodyQuat, origin);

    if (_chunks.isEmpty) {
      debugLine = 'terrain: no chunks';
      return;
    }

    // Per-frame transform per chunk. Each mesh is LOCAL to its own anchor, so
    // the node sits at that anchor (near the render origin for a landed craft)
    // — not at the body centre ~1e6 m away, which cancelled in float32 and
    // jittered. (LOD transitions are atomic — see the upload pump — so
    // coarse and fine never coexist and no depth trickery is needed here.)
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
        '${_pending.isNotEmpty ? '  ~${_pending.length}' : ''}'
        '${missing.length > _pending.length ? '  +${missing.length - _pending.length}' : ''}'
        '${_emptyChunks.isNotEmpty ? '  e${_emptyChunks.length}' : ''}'
        '${_meshCache.isNotEmpty ? '  mc${_meshCache.length}' : ''}'
        '${_gridPatches.isNotEmpty ? '  grid${_gridPatches.length}' : ''}'
        '${_clippedEmpty > 0 ? '  CLIPPED $_clippedEmpty' : ''}';

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
      // Night-side light floor: per-body override, else derived — sky scatter
      // keeps atmospheric bodies at the old 0.14, airless bodies drop to an
      // earthshine-scale floor so lunar night reads dark instead of mid-grey.
      ambient: d.terrainAmbient ?? (d.atmoPresent ? 0.14 : 0.005),
      // Spin axis (+Z) rotated the same way the node rotates vertices, so it
      // lands in v_position's world frame -> dot(up, pole) = latitude sine.
      // Rotated in the DOMAIN quaternion: vm's rotate()/rotated() applies the
      // inverse rotation (see coord_convert.dart), which counter-spun the
      // albedo longitude against the mesh.
      poleWorld: _rotatedAxis(bodyQuat, Vector3.unitZ),
      // Body +X through the same rotation. Latitude alone cannot index an
      // equirectangular map — longitude needs a second body-fixed axis, and
      // v_position is world-space so it cannot be recovered there.
      meridianWorld: _rotatedAxis(bodyQuat, Vector3.unitX),
      // Only bodies with a baked map get real colour; everything else stays on
      // the procedural blend exactly as before.
      albedoStrength:
          TerrainTextures.albedo.containsKey(bodyId) ? albedoStrength : 0.0,
      // Same gate for the DEM normal map: strength 0 keeps the geometric
      // normal alone on bodies without one.
      normalStrength: TerrainTextures.normals.containsKey(bodyId)
          ? detailNormalStrength
          : 0.0,
      normalFadeNear: normalFadeNearKm,
      normalFadeFar: normalFadeFarKm,
    );
    _material?.bindAlbedo(TerrainTextures.albedo[bodyId]);
    _material?.bindNormals(TerrainTextures.normals[bodyId]);
    // Bind the procedural material tiles once they've finished uploading.
    _material?.bindTiles();
  }

  /// A body axis through the DOMAIN rotation (standard Hamilton, matching the
  /// node's matrix transform), then component-copied into the scene frame.
  /// vm.Quaternion.rotate()/rotated() must not be used here — they apply the
  /// INVERSE rotation (see coord_convert.dart).
  static vm.Vector3 _rotatedAxis(Quaternion q, Vector3 axis) {
    final w = q.rotate(axis);
    return vm.Vector3(w.x, w.y, w.z);
  }

  /// Queue one chunk for meshing. The result lands in [_arrived] and becomes
  /// a node inside the next frame's upload budget; a result whose generation
  /// went stale in flight is dropped there.
  void _submit(TerrainField field, ChunkKey key) {
    final generation = _generation;
    _pending.add(key);
    _scheduler!
        .mesh(field, key, resolution: resolution, skirtVoxels: skirtVoxels)
        .then((cell) {
      _pending.remove(key);
      if (generation != _generation) return;
      if (cell.isEmpty) {
        // No isosurface in the shell (legitimate, e.g. below a sea floor).
        // Remember it, or the chunk would be resubmitted every frame. An
        // empty AND clipped cell is different: the band failed to contain
        // the surface, i.e. the mesher was wrong — count it for the HUD.
        _emptyChunks.add(key);
        if (cell.clipped) _clippedEmpty++;
      } else {
        _arrived.add(_ArrivedMesh(key, cell, generation));
      }
    }).catchError((Object e) {
      _pending.remove(key);
      debugLine = 'terrain: mesh $key failed: $e';
    });
  }

  /// Turn a finished mesh into a scene node (the GPU upload). The [CellMesh]
  /// is retained on the resident so retirement can drop it into [_meshCache].
  void _addChunk(ChunkKey key, CellMesh cell, gpu.Shader shader) {
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
      cell: cell,
    )..lastVisibleFrame = _frame;
  }

  /// Maintain the loading placeholders: one wireframe patch per bare missing
  /// chunk (nearest [maxPlaceholders]), one spinner over the nearest patch.
  ///
  /// The patch is honest geometry — its lattice corners sample the REAL
  /// field, lifted a few metres — so the grid hugs the ground that is about
  /// to appear there instead of floating at the datum. Depth-tested like
  /// terrain: hills in front hide it.
  void _updatePlaceholders(
    TerrainField field,
    List<ChunkKey> missing,
    Set<ChunkKey> stillLoading,
    Vector3 bodyWorld,
    Quaternion bodyQuat,
    FloatingOrigin origin,
  ) {
    _ensureSpinnerTex();
    final want = <ChunkKey>[];
    if (loadingGrid) {
      for (final k in missing) {
        if (stillLoading.contains(k)) {
          want.add(k);
          if (want.length >= maxPlaceholders) break;
        }
      }
    }
    final wantSet = want.toSet();
    for (final k in _gridPatches.keys.toList()) {
      if (!wantSet.contains(k)) {
        _scene.remove(_gridPatches.remove(k)!.node);
      }
    }
    for (final k in want) {
      _gridPatches.putIfAbsent(k, () => _buildGridPatch(field, k));
    }
    for (final p in _gridPatches.values) {
      p.node.localTransform = vm.Matrix4.compose(
        origin.worldToScene(bodyWorld + bodyQuat.rotate(p.anchorBF)),
        quatToScene(bodyQuat),
        vm.Vector3.all(lengthToScene(1.0)),
      );
    }

    // Spinner over the nearest patch (want[0] — `missing` arrives sorted).
    if (want.isEmpty) {
      _clearSpinner();
    } else {
      final geo = _spinnerGeo ??= fs.BillboardGeometry(capacity: 1);
      final mat = _spinnerMat ??= DepthSafeSpriteMaterial()
        ..blendMode = fs.SpriteBlendMode.additive;
      if (!_spinnerTexApplied && _spinnerTex != null) {
        mat.colorTexture = _spinnerTex;
        _spinnerTexApplied = true;
      }
      final anchor = _gridPatches[want.first]!.anchorBF;
      final centre = bodyWorld + bodyQuat.rotate(anchor);
      // A third of the chunk across, spinning ~1 rev / 1.5 s of wall time —
      // UI feedback, deliberately independent of sim warp.
      final sizeM = want.first.circumradiusM(field.radius) * 0.6;
      final spin =
          (DateTime.now().millisecondsSinceEpoch % 1500) / 1500 * 2 * math.pi;
      geo.setInstance(
        0,
        center: origin.worldToScene(centre),
        width: lengthToScene(sizeM),
        height: lengthToScene(sizeM),
        rotation: spin,
      );
      geo.commit(1);
      if (_spinnerNode == null) {
        final n = fs.Node(mesh: fs.Mesh(geo, mat));
        _scene.add(n);
        _spinnerNode = n;
      }
    }
  }

  /// A wireframe lattice over [key]'s footprint, vertices on the real ground
  /// (+ a small lift so terrain arriving underneath never z-fights it).
  _GridPatch _buildGridPatch(TerrainField field, ChunkKey key) {
    const lines = 5; // per direction, incl. borders
    const segs = 6; // segments per line, following curvature
    final anchorDir = key.centreDirection;
    final liftM = key.circumradiusM(field.radius) * 0.01 + 2.0;
    double radiusAt(Vector3 dir) =>
        field.radius + field.heightInDirection(dir.x, dir.y, dir.z) + liftM;
    final anchorBF = anchorDir * radiusAt(anchorDir);

    final positions = <double>[];
    final indices = <int>[];
    void polyline(List<Vector3> pts) {
      final base = positions.length ~/ 3;
      for (final p in pts) {
        positions.addAll([
          p.x - anchorBF.x,
          p.y - anchorBF.y,
          p.z - anchorBF.z,
        ]);
      }
      for (var i = 0; i < pts.length - 1; i++) {
        indices.addAll([base + i, base + i + 1]);
      }
    }

    Vector3 at(double s, double t) {
      final dir = directionOf(key.face, s, t);
      return dir * radiusAt(dir);
    }

    for (var l = 0; l < lines; l++) {
      final f = l / (lines - 1);
      final s = key.s0 + (key.s1 - key.s0) * f;
      final t = key.t0 + (key.t1 - key.t0) * f;
      polyline([
        for (var i = 0; i <= segs; i++)
          at(s, key.t0 + (key.t1 - key.t0) * i / segs),
      ]);
      polyline([
        for (var i = 0; i <= segs; i++)
          at(key.s0 + (key.s1 - key.s0) * i / segs, t),
      ]);
    }

    final geom = fs.MeshGeometry.fromArrays(
      positions: Float32List.fromList(positions),
      indices: indices,
      primitiveType: igpu.PrimitiveType.line,
    );
    final mat = DepthSafeUnlitMaterial()
      ..baseColorFactor = vm.Vector4(0.45, 0.78, 1.0, 0.55);
    final node = fs.Node(mesh: fs.Mesh(geom, mat));
    _scene.add(node);
    return _GridPatch(node: node, anchorBF: anchorBF);
  }

  void _clearSpinner() {
    final n = _spinnerNode;
    if (n != null) {
      _scene.remove(n);
      _spinnerNode = null;
    }
  }

  void _clearPlaceholders() {
    for (final p in _gridPatches.values) {
      _scene.remove(p.node);
    }
    _gridPatches.clear();
    _clearSpinner();
  }

  /// Retire a resident chunk, keeping its mesh in the LRU cache so a revisit
  /// re-uploads instead of re-meshing.
  void _removeResident(ChunkKey key) {
    final c = _chunks.remove(key);
    if (c == null) return;
    _scene.remove(c.node);
    _meshCache.remove(key); // re-insert -> newest LRU position
    _meshCache[key] = c.cell;
    while (_meshCache.length > meshCacheSize) {
      _meshCache.remove(_meshCache.keys.first);
    }
  }

  /// Invalidate every job in flight and every result not yet uploaded. The
  /// jobs still complete (no cancellation, see mesh_scheduler.dart); their
  /// results are dropped by the generation check. Cached meshes were built
  /// from the same now-stale field, so they go too.
  void _invalidateInFlight() {
    _generation++;
    _arrived.clear();
    _emptyChunks.clear();
    _meshCache.clear();
    _clippedEmpty = 0;
  }

  void _clear() {
    if (_chunks.isEmpty && _bodyId == null && _pending.isEmpty) return;
    for (final c in _chunks.values) {
      _scene.remove(c.node);
    }
    _chunks.clear();
    _clearPlaceholders();
    _invalidateInFlight();
    _tree?.reset();
    _bodyId = null;
    activeBodyId = null;
    activeReliefM = 0;
    // Force the edit store to rebuild on the next frame that renders — the
    // count alone cannot distinguish "same body, unchanged" from "gated out
    // and back with a different body's edits resident".
    _builtEditCount = -1;
    _edits = null;
    debugLine = '';
  }
}

/// A mesh that came back from the scheduler and is waiting for upload budget.
class _ArrivedMesh {
  _ArrivedMesh(this.key, this.cell, this.generation);

  final ChunkKey key;
  final CellMesh cell;

  /// [TerrainNodes._generation] at submit time; a mismatch at upload time
  /// means the field the mesh sampled is no longer the one on screen.
  final int generation;
}

/// A chunk currently in the scene. Keeps its [CellMesh] so retirement can
/// hand the mesh to the in-memory cache instead of discarding it.
class _ResidentChunk {
  _ResidentChunk({
    required this.node,
    required this.cell,
  });

  final fs.Node node;
  final CellMesh cell;

  Vector3 get anchorBF => cell.anchorBF;
  int get triangleCount => cell.mesh.triangleCount;

  /// Last [TerrainNodes._frame] this chunk was in the visible set. Fresh
  /// chunks start at the frame they were added; retirement waits until the
  /// chunk has been invisible for [TerrainNodes.retireGraceFrames].
  int lastVisibleFrame = 0;
}

/// One loading-grid wireframe patch (see [TerrainNodes.loadingGrid]).
class _GridPatch {
  _GridPatch({required this.node, required this.anchorBF});

  final fs.Node node;
  final Vector3 anchorBF;
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
    required double ambient,
    required vm.Vector3 poleWorld,
    required vm.Vector3 meridianWorld,
    required double albedoStrength,
    required double normalStrength,
    required double normalFadeNear,
    required double normalFadeFar,
  }) {
    setUniformBlockFromFloats('TerrainInfo', [
      centreScene.x, centreScene.y, centreScene.z, radiusScene,
      sunTravel.x, sunTravel.y, sunTravel.z, amplitudeScene,
      seaRadiusScene, ambient, 0.6, 0.6, // sea, ambient, snowStart, rockSlope
      0.34, 0.32, 0.29, // col_low rgb (dark tan/grey)
      TerrainNodes.macroFadeNearKm, // col_low.a = macro fade near (scene km)
      0.55, 0.53, 0.50, // col_high rgb (light grey)
      TerrainNodes.macroFadeFarKm, // col_high.a = macro fade far (scene km)
      0.30, 0.28, 0.27, // col_rock rgb (unused; tex_rock carries colour)
      TerrainNodes.macroTileMeters, // col_rock.a = macro material tile (m)
      0.90, 0.92, 0.95, 0.0, // col_snow
      tileMeters, sandAmount, grassAmount,
      TerrainNodes.debugView.toDouble(), // detail (w = debug view)
      poleWorld.x, poleWorld.y, poleWorld.z,
      TerrainNodes.macroBumpStrength, // pole (world) + w = macro bump

      meridianWorld.x, meridianWorld.y, meridianWorld.z,
      albedoStrength, // meridian (world) + real-albedo mix
      normalStrength, normalFadeNear, normalFadeFar,
      TerrainNodes.macroWeight.clamp(0.0, 1.0), // normal_params.w = macro mix
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
    setTexture('tex_tile_normal', TerrainTextures.tileNormal, sampler: sampler);
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

  Object? _boundNormals;
  bool _normalsEverBound = false;

  /// Bind the body's DEM normal map, or the flat placeholder when it has
  /// none — same live-slot requirement and strength gating as [bindAlbedo].
  void bindNormals(Object? texture) {
    final want = texture ?? TerrainTextures.normalPlaceholder;
    if (want == null) return;
    if (_normalsEverBound && identical(want, _boundNormals)) return;
    setTexture(
      'tex_normal',
      want,
      sampler: igpu.SamplerOptions(
        minFilter: igpu.MinMagFilter.linear,
        magFilter: igpu.MinMagFilter.linear,
        // Longitude wraps, latitude clamps — matches tex_albedo.
        widthAddressMode: igpu.SamplerAddressMode.repeat,
        heightAddressMode: igpu.SamplerAddressMode.clampToEdge,
      ),
    );
    _boundNormals = want;
    _normalsEverBound = true;
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
