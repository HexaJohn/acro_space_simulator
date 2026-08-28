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
import '../../../domain/terrain/terrain_brush.dart';
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

  /// LOD X-RAY: hide the meshed ground and draw EVERY selected chunk as its
  /// wireframe patch, coloured by level (coarse blue, deep red). Streaming
  /// and selection keep running underneath, so what appears and vanishes on
  /// screen IS the quadtree deciding — which is the only way to see WHY a
  /// region splits or collapses instead of inferring it from ground detail.
  static bool gridOnly = false;

  /// Grid-only patch budget. Selection can want a few hundred chunks; the
  /// loading grid's 48 was sized for a streaming frontier, not a whole view.
  static int maxGridOnlyPatches = 500;

  /// The [gridOnly] value the current placeholder set was built with, so a
  /// toggle forces the selection pass that rebuilds it.
  bool _builtGridOnly = false;

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

  /// Max per-chunk lateral resolution multiplier for chunks overlapping an
  /// edit (power of two). Instead of forcing the quadtree log2(this) levels
  /// deeper — every level of which drags a ~21-chunk 2:1 staircase behind it
  /// (measured: ONE 16 m crater forced +117 chunks at boost 1) — the chunk
  /// covering the edit is meshed at `resolution * boost`: the same voxel
  /// size on the ground from far fewer, slightly heavier chunks. 1 restores
  /// the old split-only behaviour (A/B kill switch). Neighbours at unequal
  /// resolution mismatch like an LOD seam, which the skirts already cover.
  static int editResBoost = 4;

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

  // ---- Head lamp (the walker's flashlight) ----
  // flutter_scene gives a scene exactly one light and it is directional, so a
  // spot has to live in the terrain shader. These are the CPU side of the
  // lamp_* uniforms; the lamp rides the camera, so only the switch and its
  // shape are state.
  static bool lampOn = false;

  /// Beam length, metres. Past this the lamp contributes nothing.
  static double lampRangeM = 60.0;

  /// Cone half-angle, degrees — the hot spot.
  static double lampConeDeg = 26.0;

  /// Soft edge outside the hot spot, degrees.
  static double lampEdgeDeg = 10.0;

  /// Peak added shade at the centre of the beam, in the same units as the
  /// sun's Lambert term (1.0 ~ full sunlight).
  static double lampIntensity = 1.7;

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

  /// In-flight jobs whose chunk a NEW edit overlaps: they sampled the
  /// pre-edit field, so their results are dropped on arrival. The scoped
  /// alternative to bumping [_generation], which threw away every in-flight
  /// job and the whole mesh cache for an edit that touches a few chunks.
  final Set<ChunkKey> _staleInFlight = {};

  /// Chunks that meshed to NO geometry (isosurface not in their shell —
  /// legitimate, e.g. below a sea floor). Remembered so they are not
  /// resubmitted every frame; cleared with the generation.
  final Set<ChunkKey> _emptyChunks = {};

  /// Retired chunks' meshes, kept in memory so a revisit re-UPLOADS instead
  /// of re-MESHING — a camera swinging back gets its ground the same frame.
  /// Dart maps iterate in insertion order, so re-inserting on hit makes this
  /// an LRU; [meshCacheSize] bounds it (~100 KB per entry at resolution 24).
  /// Cleared with the generation — a cached mesh of a stale field is a lie.
  /// Each entry carries the RESOLUTION it was meshed at, because the edit
  /// boost makes resolution contextual and a wrong-variant re-serve is a
  /// lie of the same kind (a different voxel size is a different altitude).
  final Map<ChunkKey, (CellMesh, int)> _meshCache = {};

  /// Update counter driving the retirement grace window.
  int _frame = 0;

  // --- Selection cadence ----------------------------------------------------
  // The heavy half of update() — quadtree selection, horizon culling, the
  // nearest-first sort, retirement and eviction — is a pure function of the
  // eye, the camera zoom, and the edit set. None of those change on most
  // frames (a landed craft's body-fixed eye is STILL), yet it all ran every
  // frame and dominated the frame cost once a deformation island made the
  // leaf set big. Selection now reruns only when an input moved; the frames
  // between reuse its outputs below, which streaming (upload pump + submits)
  // consumes unchanged.
  List<ChunkKey> _selVisible = const [];
  Set<ChunkKey> _selVisibleSet = const {};
  Set<ChunkKey> _selWanted = const {};
  Set<ChunkKey> _selBareAncestors = const {};
  Set<ChunkKey> _selStillLoading = const {};
  Vector3 _selEyeBF = Vector3.zero;
  double _selProbePx = -1;
  int _selFrame = -1 << 30;
  bool _selectForce = true;

  /// Frames between forced re-selections when nothing else triggers one —
  /// the safety net, not the mechanism.
  static int selectEveryFrames = 30;

  /// Section timings for the last frame, updated when [profile] is true —
  /// readable through `ext.acro.terrain` next to [debugLine].
  static bool profile = false;
  static String profileLine = '';

  // --- Loading placeholder ---------------------------------------------------
  /// Wireframe patch per bare (no cover at any LOD) chunk, plus one spinner
  /// billboard over the nearest of them.
  final Map<ChunkKey, _GridPatch> _gridPatches = {};

  /// The patch the spinner sits over, picked on placeholder-rebuild frames.
  ChunkKey? _spinnerKey;
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

  /// How many times each chunk has come back empty AND clipped.
  ///
  /// A clipped cell is the mesher reporting its own failure: the radial band
  /// did not contain the surface, so "no isosurface here" is not a fact about
  /// the ground, it is a fact about the sample. Retiring the chunk on that —
  /// which is what happened — means the tile never comes back, because
  /// `_emptyChunks` is only ever cleared by a LATER edit that touches it.
  /// Stop mining and nothing ever touches it again.
  ///
  /// Mining is exactly the case that produces one: the field is changing under
  /// the mesher while it works, so a cell sampled mid-edit can easily fail its
  /// own band check. Retrying it against the settled field is almost always
  /// enough, and the count is what stops a chunk that really is a sealed void
  /// from being resubmitted forever.
  final Map<ChunkKey, int> _clippedRetries = {};

  /// Attempts a clipped chunk gets before it is retired as genuinely empty.
  static int clippedRetryLimit = 4;

  /// Chunks retired as empty after repeatedly failing their band check — a
  /// tile that is missing and will stay missing. Surfaced so it is visible
  /// rather than something you notice as a hole in the ground.
  int get retiredClipped => _retiredClipped;
  int _retiredClipped = 0;
  int _generation = 0;

  TerrainLodTree? _tree;
  double _treeSplitPx = 0;
  // Geometry knobs the resident meshes were built with; a change invalidates
  // them (dev toggles), since the chunks themselves carry no record of it.
  double _builtSkirtVoxels = double.nan;
  int _builtResolution = -1;
  int _builtResBoost = -1;
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

  /// Cached refinement targets + the range-gated brush list they came from.
  /// A pure function of (brush set, anchor, knobs); rebuilding every frame
  /// walked `levelForVoxelSize` per ring sample per brush — measurable once
  /// a colony has tens of pads.
  List<TerrainRefinement> _refine = const [];
  List<TerrainBrush> _nearBrushes = const [];
  Vector3 _refineAnchor = Vector3.zero;
  int _refineEditCount = -1;

  /// The focused body's detail layer, rebuilt only when the body changes —
  /// assembling it allocates the control field and every feature.
  TerrainDetail? _detail;
  String? _detailBodyId;

  /// The cached fields: [_baseField] is the pristine (no-edits) field for
  /// [_detailBodyId]; [_composedField] is it with [_edits] composed via
  /// [TerrainField.withEdits], re-derived only when the edit store instance
  /// changes. Stable instances are load-bearing: the pooled mesh scheduler
  /// keys "re-ship the DEM?" on the base field's identity.
  TerrainField? _baseField;
  TerrainField? _composedField;
  Object? _composedEditsId = _unset;
  static const Object _unset = Object();

  /// Debug line for the HUD (chunk tri count / state).
  static String debugLine = '';

  /// How many LOD levels a single streaming pass may climb at once.
  ///
  /// 0 requests target leaves directly, which is what this replaced. Small
  /// values sharpen the whole view together at the cost of meshing
  /// intermediate chunks that are later replaced; large ones approach the old
  /// leap.
  static int levelStep = 3;

  /// Per-frame counters, for a profiler that needs to know WHY terrain is
  /// expensive rather than just that it is.
  ///
  /// Forced refinement is the one that bites near a colony. The mechanism was
  /// built for craters — a handful of small edits, each deserving a deep
  /// island of quadtree — and a city hands it one brush per building. A
  /// six-block colony emits 1,719 brushes and asks for 15,471 refinement
  /// targets down to level 17, which is a great deal of terrain to mesh for
  /// ground that ends up under a house.
  static final Map<String, int> counters = {};

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
    final profSw = profile ? (Stopwatch()..start()) : null;
    var profPreUs = 0, profSelUs = 0, profStreamUs = 0;

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
    // Brushes added THIS frame, when knowable: the store is append-only in
    // tick order, so on the same body the new brushes are exactly the tail.
    // Empty when the added set is unknowable (body switch, count shrank,
    // first build) — invalidation then falls back to wholesale.
    var addedBrushes = const <TerrainBrush>[];
    var editCount = 0;
    for (final e in snap.terrainEdits) {
      if (e.body == bodyId) editCount++;
    }
    if (_builtEditCount != editCount || _bodyId != bodyId) {
      final prevCount = _builtEditCount;
      final sameBody = _bodyId == bodyId;
      _edits = editCount == 0 ? null : snap.editsForBody(bodyId!);
      editsChanged = prevCount != editCount;
      if (sameBody && _edits != null && prevCount >= 0 && editCount > prevCount) {
        addedBrushes = _edits!.all.sublist(prevCount);
      }
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
      _baseField = null;
      // Fire-and-forget: the first frames draw with the placeholder and the
      // real colour appears when the upload lands.
      TerrainTextures.loadAlbedo(bodyId!);
      TerrainTextures.loadNormals(bodyId);
    }

    // The field is cached: base per body, edits composed via withEdits per
    // edit-store instance. A fresh TerrainField per frame was not just waste —
    // the pooled mesh scheduler keys "do I need to re-ship the DEM to the
    // worker" on the BASE FIELD'S IDENTITY, so a stable instance is what lets
    // a submit cost a chunk key instead of a pyramid copy. (Descriptor terrain
    // knobs are reference data; a body switch resets the cache.)
    _baseField ??= d.buildTerrainField(detail: _detail)!;
    if (!identical(_composedEditsId, _edits)) {
      _composedField = _baseField!.withEdits(_edits);
      _composedEditsId = _edits;
    }
    final field = _composedField!;
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
      _selectForce = true;
    }
    // A geometry knob moved (dev toggle): drop every resident mesh so the ring
    // rebuilds with the new setting. Cheap because it only happens on a change.
    // In-flight jobs were built with the old knobs — invalidate them too.
    if (_builtSkirtVoxels != skirtVoxels ||
        _builtResolution != resolution ||
        _builtResBoost != editResBoost) {
      for (final c in _chunks.values) {
        _scene.remove(c.node);
      }
      _chunks.clear();
      _invalidateInFlight();
      _builtSkirtVoxels = skirtVoxels;
      _builtResolution = resolution;
      _builtResBoost = editResBoost;
      _refineEditCount = -1; // refine targets depend on the boost knob
      _selectForce = true;
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
    if (edits == null) {
      _refine = const [];
      _nearBrushes = const [];
      _refineEditCount = -1;
    } else if (editsChanged ||
        _refineEditCount != edits.length ||
        (anchorPoint - _refineAnchor).length > editRefineRangeM * 0.05) {
      final near = <TerrainBrush>[];
      for (final brush in edits.all) {
        if ((brush.centreBF - anchorPoint).length > editRefineRangeM) continue;
        near.add(brush);
      }
      // MERGED, not one island per brush. A city hands this a brush per
      // building; taken separately they ask for tens of thousands of targets,
      // nearly all of them either redundant with a neighbour's or refining the
      // flat middle of a levelled pad, which any level meshes exactly.
      //
      // `resolution * editResBoost` makes levelForVoxelSize account for the
      // boosted meshing the overlapping chunks will actually get, so the
      // forced level lands log2(boost) levels SHALLOWER — the boost carries
      // the rest of the way to the target voxel size (see [editResBoost]).
      final targets = mergedRefinementsFor(
        near,
        field.radius,
        resolution * editResBoost,
        voxelsAcrossBrush: editVoxelsAcross,
        maxLevel: _tree!.maxRefineLevel,
      );
      _refine = targets;
      counters['refineTargets'] = targets.length;
      counters['nearBrushes'] = near.length;
      _nearBrushes = near;
      _refineAnchor = anchorPoint;
      _refineEditCount = edits.length;
    }
    final refine = _refine;
    // A new edit rewrites the density inside its footprint, so everything
    // built from the pre-edit field and overlapping it is stale: resident
    // chunks (their KEY is unchanged, the split path would not retire them),
    // cached meshes, remembered-empty chunks, and jobs still in flight.
    // Scoped to the ADDED brushes — the old wholesale invalidation cleared
    // the whole mesh cache and every in-flight job, so each placed building
    // re-meshed the entire resident set. The surface can only move within a
    // brush's lateralReachM of its axis, hence that as the overlap radius.
    if (editsChanged && edits != null) {
      if (addedBrushes.isEmpty) {
        // Added set unknowable (count shrank / first sight of this body's
        // edits): fall back to invalidating everything against every brush.
        // The grid patches go wholesale too — they drape the field at build
        // time, and a patch built over pre-edit ground floats beside the
        // re-meshed terrain until something rebuilds it (toggling terrain
        // off and on was the accidental fix; this is the deliberate one).
        _clearPlaceholders();
        _invalidateInFlight();
        for (final k in _chunks.keys.toList()) {
          final reach = k.circumradiusM(field.radius);
          for (final brush in edits.all) {
            // The chunk centre at the BRUSH'S OWN radius, not the datum's.
            // Brushes anchor on real ground, which sits hundreds of metres
            // off the datum sphere (885 m below it at a typical lunar site),
            // and circumradiusM is a purely lateral chord — so measured to a
            // datum-pinned centre, a fine chunk directly over a brush missed
            // the overlap by the site's whole elevation and was never
            // retired. That is how a city kept its pre-grading ground: raw
            // chunks survived interleaved with re-meshed graded ones.
            final centre = k.centreDirection * brush.centreBF.length;
            if ((brush.centreBF - centre).length <=
                reach + brush.lateralReachM) {
              _scene.remove(_chunks.remove(k)!.node);
              break;
            }
          }
        }
      } else {
        bool touches(ChunkKey k) {
          final reach = k.circumradiusM(field.radius);
          for (final brush in addedBrushes) {
            // Radial-aware for the same reason as the wholesale branch above.
            final centre = k.centreDirection * brush.centreBF.length;
            if ((brush.centreBF - centre).length <=
                reach + brush.lateralReachM) {
              return true;
            }
          }
          return false;
        }

        _arrived.removeWhere((a) => touches(a.key));
        _staleInFlight.addAll(_pending.where(touches));
        _emptyChunks.removeWhere(touches);
        // Grid patches drape the field at BUILD time, so the ones over a
        // fresh brush hold pre-edit ground and float beside the re-meshed
        // terrain. Purged here, rebuilt this same frame — editsChanged
        // forces the selection pass the placeholder rebuild rides on.
        _gridPatches.removeWhere((k, p) {
          if (!touches(k)) return false;
          _scene.remove(p.node);
          return true;
        });
        // A fresh edit is a fresh chance: whatever made the band miss may
        // well be gone, so the attempt count starts again.
        _clippedRetries.removeWhere((k, _) => touches(k));
        _meshCache.removeWhere((k, _) => touches(k));
        for (final k in _chunks.keys.toList()) {
          if (touches(k)) _scene.remove(_chunks.remove(k)!.node);
        }
      }
    }
    // --- Selection cadence gate --------------------------------------------
    // Everything from the quadtree walk to eviction reruns only when one of
    // its inputs moved (see the field docs). The zoom probe is the apparent
    // size of a fixed 1 km ball at the anchor — cheap, and it moves with both
    // camera range and focal changes, the two things besides the eye and the
    // edits that can change what selection would pick.
    _frame++;
    if (profSw != null) profPreUs = profSw.elapsedMicroseconds;
    final probePx = camera == null
        ? 0.0
        : camera.radiusPx(anchorWorld - origin.focusWorld, 1000.0);
    final moved = (eyeBF - _selEyeBF).length >
        math.max(1.0, 0.02 * (eyeBF - anchorPoint).length);
    final probeMoved = _selProbePx < 0 ||
        (probePx - _selProbePx).abs() > math.max(_selProbePx, 1e-6) * 0.02;
    // The grid-only toggle rebuilds the placeholder set, which only happens
    // on selection frames — so flipping it forces one.
    final gridToggled = _builtGridOnly != gridOnly;
    _builtGridOnly = gridOnly;
    final reselect = _selectForce ||
        gridToggled ||
        editsChanged ||
        moved ||
        probeMoved ||
        _frame - _selFrame >= selectEveryFrames;

    if (reselect) {
      _selectForce = false;
      _selEyeBF = eyeBF;
      _selProbePx = probePx;
      _selFrame = _frame;

      final leaves = _tree!.update(apparentPx, refine: refine);

      // --- Visibility: the whole body, not a patch under the craft ----------
      // Every leaf this side of the horizon is meshed. LOD does the work of
      // keeping that affordable — distant chunks stay at coarse levels, where
      // a whole cube face is a handful of triangles — so full coverage costs
      // far less than the leaf COUNT suggests. The horizon test is the only
      // spatial cull needed, because a sphere hides its own far side.
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
      // budget and what survives the resident cap. Distances are computed
      // once per chunk, not twice per comparison — centreDirection allocates,
      // and a deformation-refined set sorts hundreds of keys.
      final distByKey = <ChunkKey, double>{
        for (final k in visible)
          k: (k.centreDirection * field.radius - anchorPoint).length,
      };
      visible.sort((x, y) => distByKey[x]!.compareTo(distByKey[y]!));
      final wanted = visible.length > maxResidentChunks
          ? visible.take(maxResidentChunks).toSet()
          : visible.toSet();

      // Retire chunks that dropped out of view or changed level — EXCEPT a
      // stale chunk standing in where its replacement has not arrived yet.
      // Retiring a parent before its children upload (or the children before
      // their parent) opens a hole straight through to the under-sphere for a
      // few frames on every LOD transition; with the sphere sunk below the
      // lowest ground, that hole reads as a dark pit. The stand-in overlaps
      // its replacement for a frame or two instead — the surfaces differ by
      // less than a voxel, so the nearer one simply wins the depth test.
      final missingNow = <ChunkKey>{
        for (final k in wanted)
          if (!_chunks.containsKey(k) && !_emptyChunks.contains(k)) k,
      };
      // The NEAREST resident ancestor of each missing chunk is its coarse
      // stand-in for a pending split — and ONLY the nearest. Protecting every
      // ancestor pinned the face ROOT for as long as anything anywhere on
      // that face was streaming, which near the surface is always; a root's
      // surface is sampled at ~100 km per cell, so in deep basins it floats
      // kilometres ABOVE the refined floor and drew as flat sphere-segment
      // slabs over the maria and crater floors (highlands hid it — there the
      // root sits below). `bareAncestors` marks the ancestors of missing
      // chunks with NO resident cover at all: the coverage-root path below
      // meshes those, and the upload pump must accept them on arrival even
      // though they are not wanted. Ancestors of every resident:
      // `coveredBelow.contains(k)` == some finer resident lies under k's
      // region (the merge-direction cover).
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
          // Coverage roots are for FRESHLY REVEALED regions only. A split in
          // progress — some sibling already resident under the same parent —
          // must not queue one: re-meshing coarse cover under ground the
          // player is watching refine would flash the whole face back over
          // it.
          final p = m.parent;
          if (p == null || !coveredBelow.contains(p)) {
            bareAncestors.addAll(m.ancestors);
          }
        }
      }
      bool standsIn(ChunkKey k) {
        if (protected.contains(k)) return true;
        // The fine stand-in for a pending merge: a resident whose own
        // ancestor is the missing chunk. Keep every such descendant — each
        // covers a distinct part of the missing region.
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
      // new work; residency ends only when a chunk stops being visible (or
      // its replacement arrived).
      //
      // And "stops being visible" carries a GRACE PERIOD (plan §4: evict by
      // "not visible + oldest"). The horizon cull has margins but no
      // hysteresis: an orbiting camera walks chunks across the horizon edge
      // every frame, and instant retirement turned each crossing into retire
      // → want again → remesh — a flickering ring of missing tiles at exactly
      // the range the player reads as "the horizon". A chunk now has to stay
      // invisible for [retireGraceFrames] consecutive frames before it is
      // dropped; drawing a just-hidden chunk for another second is free (the
      // planet occludes it), remeshing it every other frame is not.
      final visibleSet = visible.toSet();
      for (final e in _chunks.entries) {
        if (visibleSet.contains(e.key)) e.value.lastVisibleFrame = _frame;
      }
      for (final k in _chunks.keys.toList()) {
        // Two ways out of the scene: fell invisible past the grace window
        // (horizon churn protection), or REPLACED — still visible but no
        // longer LOD-selected, with no missing chunk left standing on it,
        // i.e. its finer (or coarser) successors are all resident. The
        // replaced case must not wait out the grace: the split's last child
        // just landed and the parent underneath is pure overdraw now.
        final c = _chunks[k]!;
        final invisible = _frame - c.lastVisibleFrame > retireGraceFrames;
        final replaced = visibleSet.contains(k) && !wanted.contains(k);
        if ((invisible || replaced) && !standsIn(k)) {
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
        ];
        final evictDist = <ChunkKey, double>{
          for (final k in evictable)
            k: (k.centreDirection * field.radius - anchorPoint).length,
        };
        evictable.sort(
            (x, y) => evictDist[y]!.compareTo(evictDist[x]!)); // farthest 1st
        for (final k in evictable) {
          if (_chunks.length <= maxResidentChunks) break;
          _removeResident(k);
        }
      }

      // Publish this selection for the frames between reselections: the
      // upload pump and submit loop below consume these caches every frame.
      _selVisible = visible;
      _selVisibleSet = visibleSet;
      _selWanted = wanted;
      _selBareAncestors = bareAncestors;
      _selStillLoading = stillLoading;
    } else {
      // Between selections, keep the retirement grace clock honest against
      // the cached visible set — cheap, and it stops a burst of skipped
      // frames from reading as "invisible" when the camera never moved.
      for (final e in _chunks.entries) {
        if (_selVisibleSet.contains(e.key)) e.value.lastVisibleFrame = _frame;
      }
    }
    final visible = _selVisible;
    final wanted = _selWanted;
    final bareAncestors = _selBareAncestors;
    final stillLoading = _selStillLoading;
    if (profSw != null) {
      profSelUs = profSw.elapsedMicroseconds - profPreUs;
    }

    // Turn finished meshes into scene nodes — the upload is the only part of
    // streaming still on the render thread (plan §4). Stale results (wrong
    // generation, no longer wanted, already resident) are dropped; a chunk
    // that is NOT wanted is accepted only when it covers a bare region (a
    // coverage root).
    //
    // Splits reveal INCREMENTALLY: every fine chunk draws the moment it
    // arrives, and the coarse parent stays underneath only until its LAST
    // missing child lands (the stand-in protection above), then retires in
    // the retire pass — a one-level overlap whose surfaces coincide within
    // a voxel, not the displaced layering the old sink produced. A merge is
    // the reverse LOD decision and swaps in one frame: the arriving coarse
    // chunk replaces every finer resident under it immediately.
    var uploads = 0;
    final held2 = <_ArrivedMesh>[];
    for (final a in _arrived) {
      if (a.generation != _generation || _chunks.containsKey(a.key)) continue;
      if (!wanted.contains(a.key) && !bareAncestors.contains(a.key)) continue;
      if (uploads >= uploadBudgetPerFrame) {
        held2.add(a); // over budget: hold for next frame
        continue;
      }
      _addChunk(a.key, a.cell, shader as gpu.Shader, a.resolution);
      uploads++;
      // The finest ground shows the moment it exists — and the coarse cover
      // above it is MASKED, not removed: its index buffer is refiltered so
      // it renders around the refined quadrant instead of underneath it
      // (removing it outright flickered — the whole region dropped to the
      // loading grid on every first-child arrival). When the last quadrant
      // refines, the mask empties the parent's interior and it leaves.
      for (final an in a.key.ancestors) {
        if (_chunks.containsKey(an)) _maskResident(an, a.key);
      }
      // Merge: replace finer residents under the new chunk in the same
      // frame. (For a split child this loop finds nothing — children have
      // no finer residents beneath them.)
      for (final r in _chunks.keys.toList()) {
        if (r != a.key && r.ancestors.contains(a.key)) _removeResident(r);
      }
    }
    _arrived
      ..clear()
      ..addAll(held2);

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
    for (final want in coverageRoots.followedBy(missing)) {
      // --- Step the level, do not leap it -------------------------------
      //
      // Coverage roots are level 0 and targets are often level 14+, so the
      // ladder had two rungs: one enormous face root, then the finished leaf.
      // Each region went from blocky to perfect in a single jump, and because
      // the queue is nearest-first that happened to one tile at a time — the
      // city assembled piece by piece instead of sharpening as a whole.
      //
      // Requesting an intermediate ancestor instead brings the visible area up
      // together, and an interrupted stream leaves uniform medium detail
      // rather than a few perfect tiles beside a cube face. Coarse chunks are
      // a handful of triangles, so the extra passes cost little next to the
      // leaves they stand in for.
      final k = levelStep <= 0 ? want : _stepToward(want);
      if (k != want && (_chunks.containsKey(k) || _pending.contains(k))) {
        continue; // this rung is up; the next frame climbs from it
      }
      // Cache first: a retired mesh re-enters through the normal arrival
      // path (same generation gating, same atomic swaps) without costing an
      // isolate round-trip or a slot in the in-flight budget.
      final cached = _meshCache.remove(k);
      if (cached != null) {
        // Re-serve only a mesh at the resolution THIS context would mesh:
        // the edit boost makes resolution contextual, and a variant cached
        // under the other context re-uploads at a different voxel size — a
        // visibly different altitude beside its neighbours and the analytic
        // grid patches. That was the "unload and reload the tile"
        // staleness: no field had changed, the VARIANT had. A mismatch just
        // falls through to a fresh mesh.
        //
        // `held` (arrival-queue membership) keeps a re-served mesh out of
        // `missing` next frame, so it cannot double-submit while it waits.
        if (cached.$2 == _resolutionFor(k, field.radius)) {
          _arrived.add(_ArrivedMesh(k, cached.$1, _generation, cached.$2));
          continue;
        }
      }
      if (_pending.length >= meshBudgetPerFrame) break;
      if (_pending.contains(k)) continue;
      _submit(field, k, _resolutionFor(k, field.radius));
    }

    if (profSw != null) {
      profStreamUs = profSw.elapsedMicroseconds - profPreUs - profSelUs;
    }

    // "This ground is still streaming": wireframe patches + a spinner over
    // regions that have NO cover at any LOD. Runs before the no-chunks early
    // return — the initial fill is exactly when the placeholder matters.
    // Candidates come from `visible` (nearest-sorted, complete), NOT from
    // `missing`: that list excludes pending/arrived chunks, so a patch
    // vanished the moment its chunk was SUBMITTED — seconds before the mesh
    // actually landed, leaving the region drawing nothing at all. The grid
    // must track "not yet resident", not "not yet queued". The want-list only
    // shifts when selection or residency does, so it rebuilds on selection
    // frames or after an upload; between those only transforms update.
    _updatePlaceholders(field, visible, stillLoading, bodyWorld, bodyQuat,
        origin,
        rebuild: reselect || uploads > 0);

    if (profSw != null) {
      final restUs = profSw.elapsedMicroseconds -
          profPreUs -
          profSelUs -
          profStreamUs;
      profileLine = 'terrain: pre ${profPreUs ~/ 1000}ms '
          'sel ${profSelUs ~/ 1000}ms${reselect ? '*' : ''} '
          'stream ${profStreamUs ~/ 1000}ms '
          'ph ${restUs ~/ 1000}ms '
          'total ${profSw.elapsedMicroseconds ~/ 1000}ms';
    }

    counters['chunks'] = _chunks.length;
    counters['brushes'] = _edits?.length ?? 0;
    counters['gridPatches'] = _gridPatches.length;
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
      // Grid-only hides the ground but keeps it RESIDENT: streaming carries
      // on, and toggling back is instant.
      c.node.visible = !gridOnly;
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
        'lvl $minLevel-$maxLevel  q${_tree!.leaves.length}'
        '${_pending.isNotEmpty ? '  ~${_pending.length}' : ''}'
        '${missing.length > _pending.length ? '  +${missing.length - _pending.length}' : ''}'
        '${_emptyChunks.isNotEmpty ? '  e${_emptyChunks.length}' : ''}'
        '${_meshCache.isNotEmpty ? '  mc${_meshCache.length}' : ''}'
        '${_gridPatches.isNotEmpty ? '  grid${_gridPatches.length}' : ''}'
        '${_clippedEmpty > 0 ? '  clipped $_clippedEmpty' : ''}'
        '${_retiredClipped > 0 ? '  RETIRED $_retiredClipped' : ''}';

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
      // The lamp is mounted on the eye and aims down the view axis. Scene
      // units, focus-relative — the same frame v_position arrives in.
      lampPosScene: relToScene(cameraEye),
      lampDirScene: camera == null
          ? vm.Vector3(0, 0, 1)
          : vm.Vector3(camera.forward.x, camera.forward.y, camera.forward.z)
            ..normalize(),
      lampRangeScene: lampOn ? lengthToScene(lampRangeM) : 0.0,
      lampConeCos: math.cos(lampConeDeg * math.pi / 180),
      lampEdgeCos: (math.cos(lampConeDeg * math.pi / 180) -
              math.cos((lampConeDeg + lampEdgeDeg) * math.pi / 180))
          .abs(),
      lampIntensity: lampIntensity,
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

  /// Resolution [k] should mesh at: the global knob, times the smallest
  /// power-of-two boost (capped at [editResBoost]) that resolves the finest
  /// nearby brush's target voxel — the "mesh finer instead of splitting
  /// deeper" half of the deformation strategy. Chunks too coarse for even
  /// the full boost to reach the target stay at base resolution; forced
  /// refinement is what descends to them.
  int _resolutionFor(ChunkKey k, double radiusM) {
    if (_nearBrushes.isEmpty || editResBoost <= 1) return resolution;
    final centre = k.centreDirection * radiusM;
    final reach = k.circumradiusM(radiusM);
    final chunkVoxelM = reach * 2.0 / resolution;
    var boost = 1;
    for (final b in _nearBrushes) {
      if ((b.centreBF - centre).length > reach + b.lateralReachM) continue;
      final targetM = b.radiusM * 2.0 / editVoxelsAcross;
      if (chunkVoxelM > targetM * editResBoost) continue; // splitting's job
      while (boost < editResBoost && chunkVoxelM > targetM * boost) {
        boost <<= 1;
      }
      if (boost >= editResBoost) break;
    }
    return resolution * boost;
  }

  /// Queue one chunk for meshing. The result lands in [_arrived] and becomes
  /// a node inside the next frame's upload budget; a result whose generation
  /// went stale in flight is dropped there.
  /// The rung to request next on the way to [want].
  ///
  /// Walks up from [want] to the deepest ancestor already resident (or the
  /// root), then comes back down by at most [levelStep]. Returns [want] itself
  /// once it is within a step.
  ChunkKey _stepToward(ChunkKey want) {
    var residentLevel = -1;
    for (final a in want.ancestors) {
      if (_chunks.containsKey(a)) {
        residentLevel = a.level;
        break;
      }
    }
    final next = residentLevel + levelStep;
    if (next >= want.level) return want;
    var k = want;
    while (k.level > next) {
      final p = k.parent;
      if (p == null) break;
      k = p;
    }
    return k;
  }

  void _submit(TerrainField field, ChunkKey key, int chunkResolution) {
    final generation = _generation;
    _pending.add(key);
    _scheduler!
        .mesh(field, key,
            resolution: chunkResolution, skirtVoxels: skirtVoxels)
        .then((cell) {
      _pending.remove(key);
      if (generation != _generation) return;
      if (_staleInFlight.remove(key)) return; // sampled a pre-edit field
      if (cell.isEmpty) {
        // No isosurface in the shell. Legitimately empty (below a sea floor,
        // inside a sealed void) it must be REMEMBERED, or the chunk is
        // resubmitted every frame forever.
        //
        // Empty AND CLIPPED is not that. It is the mesher saying its band
        // missed the surface — its own failure — and retiring the chunk on it
        // is how a tile disappears and never returns: `_emptyChunks` is only
        // cleared by a later edit that touches the chunk, so the moment you
        // stop mining, nothing ever will. Give it a few more looks at the
        // settled field first.
        if (cell.clipped) {
          _clippedEmpty++;
          final tries = (_clippedRetries[key] ?? 0) + 1;
          _clippedRetries[key] = tries;
          if (tries < clippedRetryLimit) return; // missing again → resubmitted
          _retiredClipped++;
        }
        _emptyChunks.add(key);
      } else {
        _clippedRetries.remove(key);
        _arrived.add(_ArrivedMesh(key, cell, generation, chunkResolution));
      }
    }).catchError((Object e) {
      _pending.remove(key);
      _staleInFlight.remove(key);
      debugLine = 'terrain: mesh $key failed: $e';
    });
  }

  /// Turn a finished mesh into a scene node (the GPU upload). The [CellMesh]
  /// is retained on the resident so retirement can drop it into [_meshCache].
  void _addChunk(
      ChunkKey key, CellMesh cell, gpu.Shader shader, int resolution) {
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
      resolution: resolution,
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
    List<ChunkKey> sortedCandidates,
    Set<ChunkKey> stillLoading,
    Vector3 bodyWorld,
    Quaternion bodyQuat,
    FloatingOrigin origin, {
    required bool rebuild,
  }) {
    _ensureSpinnerTex();
    if (rebuild) {
      final want = <ChunkKey>[];
      if (gridOnly) {
        // The LOD x-ray: a patch over EVERY selected chunk, resident or
        // not — the grid replaces the ground, it does not just cover gaps.
        for (final k in sortedCandidates) {
          want.add(k);
          if (want.length >= maxGridOnlyPatches) break;
        }
      } else if (loadingGrid) {
        for (final k in sortedCandidates) {
          if (stillLoading.contains(k) && !_chunks.containsKey(k)) {
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
        // Building a patch samples the field ~70 times; only on rebuild
        // frames, and only for patches that do not already exist.
        _gridPatches.putIfAbsent(k, () => _buildGridPatch(field, k));
      }
      // The spinner marks genuine streaming, in either mode: the nearest
      // wanted patch whose ground has not landed yet.
      _spinnerKey = null;
      for (final k in want) {
        if (stillLoading.contains(k) && !_chunks.containsKey(k)) {
          _spinnerKey = k;
          break;
        }
      }
    }
    for (final p in _gridPatches.values) {
      p.node.localTransform = vm.Matrix4.compose(
        origin.worldToScene(bodyWorld + bodyQuat.rotate(p.anchorBF)),
        quatToScene(bodyQuat),
        vm.Vector3.all(lengthToScene(1.0)),
      );
    }

    // Spinner over the nearest patch (chosen on rebuild frames — candidates
    // arrive nearest-sorted).
    final spinnerKey = _spinnerKey;
    final spinnerPatch = spinnerKey == null ? null : _gridPatches[spinnerKey];
    if (spinnerPatch == null) {
      _clearSpinner();
    } else {
      final geo = _spinnerGeo ??= fs.BillboardGeometry(capacity: 1);
      final mat = _spinnerMat ??= DepthSafeSpriteMaterial()
        ..blendMode = fs.SpriteBlendMode.additive;
      if (!_spinnerTexApplied && _spinnerTex != null) {
        mat.colorTexture = _spinnerTex;
        _spinnerTexApplied = true;
      }
      final anchor = spinnerPatch.anchorBF;
      final centre = bodyWorld + bodyQuat.rotate(anchor);
      // A third of the chunk across, spinning ~1 rev / 1.5 s of wall time —
      // UI feedback, deliberately independent of sim warp.
      final sizeM = spinnerKey!.circumradiusM(field.radius) * 0.6;
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
    // Lattice density grows as chunks COARSEN. A fixed five lines over a
    // hundred-kilometre cell puts the nearest line twenty-five kilometres
    // from a ground-level camera — at shallow angles the grid "disappeared"
    // not by culling but by sparseness: the viewer stood between the lines.
    // Deep chunks keep the cheap 5x6; each level below 10 buys more.
    final coarse = math.max(0, 10 - key.level);
    final lines = math.min(5 + coarse * 2, 25); // per direction, incl. borders
    final segs = math.min(6 + coarse * 2, 26); // segments, following curvature
    final anchorDir = key.centreDirection;
    // The anti-z-fight lift, CAPPED: one percent of a root-level chunk's
    // circumradius is tens of kilometres, and the coarse patches floated a
    // sky-grid far above the camera while the ground (and the brush cursor
    // on it) sat far below — two surfaces telling different stories.
    final liftM =
        math.min(key.circumradiusM(field.radius) * 0.01, 60.0) + 2.0;
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
    // Colour by LEVEL, coarse blue through deep red, so the quadtree's
    // structure reads at a glance in grid-only mode — a split shows as a
    // colour step, not just a density change. The plain loading grid keeps
    // its single pale blue by landing on the ramp's shallow end.
    final t = (key.level / 18.0).clamp(0.0, 1.0);
    final mat = DepthSafeUnlitMaterial()
      ..baseColorFactor = vm.Vector4(
          0.3 + 0.7 * t, 0.78 - 0.55 * t, 1.0 - 0.9 * t, 0.7);
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
    _spinnerKey = null;
    _clearSpinner();
  }

  /// Mask [coveredBy]'s footprint out of resident [ancestorKey]: refilter
  /// its index buffer (fresh geometry, swapped in — never a mutated live
  /// buffer) so the coarse chunk draws around the refined region. An empty
  /// interior means every quadrant has refined: the chunk leaves entirely.
  void _maskResident(ChunkKey ancestorKey, ChunkKey coveredBy) {
    final c = _chunks[ancestorKey];
    if (c == null) return;
    c.maskedBy.add(coveredBy);
    _rebuildMasked(ancestorKey, c);
  }

  void _rebuildMasked(ChunkKey key, _ResidentChunk c) {
    final masked = maskCellIndices(c.cell, c.maskedBy);
    if (masked.interiorRemaining == 0) {
      _removeResident(key);
      return;
    }
    final geom = fs.MeshGeometry.fromArrays(
      positions: c.cell.mesh.positions,
      normals: c.cell.mesh.normals,
      indices: masked.indices,
    );
    c.node.mesh = fs.Mesh(geom, _material!);
  }

  /// Retire a resident chunk, keeping its mesh in the LRU cache so a revisit
  /// re-uploads instead of re-meshing. Any coarser resident that was masking
  /// this chunk out UNMASKS it (the coarse ground reappears under the hole
  /// the departure would otherwise leave).
  void _removeResident(ChunkKey key) {
    final c = _chunks.remove(key);
    if (c == null) return;
    _scene.remove(c.node);
    _meshCache.remove(key); // re-insert -> newest LRU position
    // The FULL mesh — masks are runtime state — with its meshed resolution.
    _meshCache[key] = (c.cell, c.resolution);
    while (_meshCache.length > meshCacheSize) {
      _meshCache.remove(_meshCache.keys.first);
    }
    for (final e in _chunks.entries) {
      if (e.value.maskedBy.remove(key)) {
        _rebuildMasked(e.key, e.value);
        break; // only one ancestor can have been masking it
      }
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
    _staleInFlight.clear(); // generation check already drops these
    _clippedEmpty = 0;
    _clippedRetries.clear();
    _retiredClipped = 0;
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
    // Selection caches describe the old body/tree — force a fresh pass.
    _selVisible = const [];
    _selVisibleSet = const {};
    _selWanted = const {};
    _selBareAncestors = const {};
    _selStillLoading = const {};
    _selectForce = true;
    _composedField = null;
    _composedEditsId = _unset;
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
  _ArrivedMesh(this.key, this.cell, this.generation, this.resolution);

  final ChunkKey key;
  final CellMesh cell;

  /// [TerrainNodes._generation] at submit time; a mismatch at upload time
  /// means the field the mesh sampled is no longer the one on screen.
  final int generation;

  /// The resolution it was meshed at — CONTEXTUAL, because the edit boost
  /// raises it near brushes. Carried so the cache can refuse to re-serve a
  /// variant the current context would not have meshed.
  final int resolution;
}

/// A chunk currently in the scene. Keeps its [CellMesh] so retirement can
/// hand the mesh to the in-memory cache instead of discarding it.
class _ResidentChunk {
  _ResidentChunk({
    required this.node,
    required this.cell,
    required this.resolution,
  });

  final fs.Node node;
  final CellMesh cell;

  /// See [_ArrivedMesh.resolution] — retirement caches it with the mesh.
  final int resolution;

  /// Finer resident chunks whose footprints are filtered OUT of this chunk's
  /// index buffer (the geometric LOD mask). Runtime state — the cached
  /// [cell] always keeps the full mesh.
  final Set<ChunkKey> maskedBy = {};

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
    required vm.Vector3 lampPosScene,
    required vm.Vector3 lampDirScene,
    required double lampRangeScene,
    required double lampConeCos,
    required double lampEdgeCos,
    required double lampIntensity,
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
      // lamp_pos_range / lamp_dir_cone / lamp_params — range 0 = lamp off,
      // which is the shader's own early out.
      lampPosScene.x, lampPosScene.y, lampPosScene.z, lampRangeScene,
      lampDirScene.x, lampDirScene.y, lampDirScene.z, lampConeCos,
      lampIntensity, lampEdgeCos, 0.0, 0.0,
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
