// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../../domain/craft/craft_balance.dart';
import '../../../domain/craft/craft_design.dart';
import '../../../domain/parts/part_def.dart';
import '../../../domain/shared/quaternion.dart';
import '../../../domain/shared/vector3.dart';
import '../coord_convert.dart';
import '../depth_materials.dart';
import '../part_bake_cache.dart';
import '../part_primitives_category.dart';

/// A translucent preview of a part that has not been committed to the design
/// yet: the ghost the player is aiming, or one of its symmetry siblings.
///
/// [position] and [rotation] are the placement the commit would produce, and
/// the editor is expected to obtain them from the SAME `AttachSolver.solveMate`
/// the commit runs. Deriving them any other way is how a ghost comes to lie
/// about where the part will land.
class CraftGhost {
  const CraftGhost({
    required this.def,
    required this.position,
    required this.rotation,
    this.valid = true,
  });

  final PartDef def;

  /// Craft body frame, METRES (Z-up, nose on +Z) — the same frame
  /// [PlacedPart.position] uses.
  final Vector3 position;

  final Quaternion rotation;

  /// Whether the mate this previews would be accepted. Drives the colour only
  /// ([CraftEditorNodes.ghostColor]); a refused ghost is still drawn, at the
  /// pose the aim implies, because an aim with no ghost at all reads as a
  /// broken preview where a red one reads as the refusal it is.
  ///
  /// The judgement belongs to the caller, which is the side that ran the solve.
  /// The editor sets it false for an aim at an attach node NOTHING on the held
  /// part can mate to — a stack seat under a part with only surface nodes, a
  /// diameter class that does not match — which is the case that would
  /// otherwise show the player nothing at all and read as a dead marker.
  final bool valid;
}

/// Everything the craft editor puts in the flutter_scene graph: one node per
/// placed part, the ghost previews, the pad reference disc, and the key light.
///
/// The 2D overlay painter owns everything that must stay LEGIBLE (node markers,
/// labels, CoM). This class owns everything that must be OCCLUDED — if the
/// descent stage is between the eye and a landing leg, the leg has to be hidden
/// by it, and only the depth buffer can do that.
///
/// ## Frames and units
///
/// Input geometry is craft-frame METRES. The scene renders in KILOMETRES
/// ([kRenderScale]), and every node is built RELATIVE TO THE CAMERA PIVOT, which
/// is this editor's floating origin: a craft spans tens of metres, so at
/// 0.03 scene-km a float32 ulp is about 2 nm and no rebasing subtlety arises —
/// but keeping the pivot at the origin means the numbers the renderer sees stay
/// the numbers `CraftEditorCamera.project` sees, and the overlay and the image
/// agree by construction rather than by tuning.
///
/// ## The slot / stand-in / realize pattern
///
/// Copied deliberately from `VesselNodes._rebuildKitbash`, because the flight
/// view has already paid for every lesson in it:
///
///  * a part is a two-level node. The SLOT carries the part's placement in the
///    craft frame and nothing else; its single child carries the asset-space
///    correction. That split is what lets the procedural stand-in be swapped for
///    a realized bake without recomputing placement, and what keeps a transform
///    sync free of any knowledge of which of the two is currently showing;
///  * a part whose bake is still decoding draws its PROCEDURAL STAND-IN, never
///    nothing. A stand-in is the first frame of every part, not an error path:
///    bakes are absent on a fresh clone (licensed for use, not redistribution),
///    absent on web by build policy, and asynchronous everywhere else;
///  * the slot object is the GENERATION TOKEN for its own in-flight decode. A
///    realize that lands after its part was deleted (or after the part changed
///    def) finds a different object — or none — in [_slots] and drops the graph
///    unparented rather than leaking it into the scene. It is never disposed
///    inline: on web, disposing `Vertices`/`ImageShader` mid-frame blanks the
///    view a frame later.
///
/// ## What runs per frame, and what does not
///
/// [sync] is the single entry point and is safe to call every frame. Per frame
/// it does O(parts) matrix writes and O(parts) map reads, and nothing else:
///
///  * ORBIT / ZOOM only rewrites the light direction (one field on one object).
///  * PAN moves the pivot, which is already folded into the per-frame transform
///    write, so it costs nothing extra.
///  * A STRUCTURAL change is diffed PER INSTANCE ID against [_slots]: only the
///    parts that appeared or changed def build a node, and only they start a
///    bake. This is finer-grained than the flight view's whole-craft fingerprint
///    on purpose — staging is rare, but in an editor a part arrives every few
///    seconds, and a fingerprint would tear down and re-realize all forty slots
///    each time one was added.
///  * SELECTION is compared and re-walked only when it actually changes.
///  * A GHOST that appears and disappears under the cursor costs two scene
///    attach/detach calls and no allocation. See [CraftGhostPool].
///
/// There is no frame-coalescing gate in here. The gate belongs in the widget,
/// exactly as `SceneRenderView._lastSyncFrame` holds it for the flight view: a
/// gate inside would silently swallow a structural change made by a second build
/// in the same vsync.
class CraftEditorNodes {
  /// Takes ownership of the editor scene's lighting.
  ///
  /// The image-based ambient is dropped to [environmentIntensity] here rather
  /// than by the screen, because it is one half of a balance whose other half
  /// ([lightIntensity]) lives in this file: at the default 1.0 every hull washes
  /// out to flat white and the craft loses its shape, which is the one thing an
  /// assembly view exists to show.
  CraftEditorNodes(this._scene) {
    _scene.environmentIntensity = environmentIntensity;
  }

  /// The pad disc is 20 m across, which frames a lunar module with room to spare
  /// and gives the eye a ground plane to judge whether the footpads clear the
  /// engine bell.
  static const double padRadiusM = 10.0;

  /// Reference rings on the pad, every metre out from the craft axis. They are
  /// the only in-scene ruler the editor has.
  static const double padRingSpacingM = 1.0;

  /// Ring half-width, metres. Wide enough to survive the perspective divide at
  /// the far edge of the pad, narrow enough to read as a line.
  static const double padRingHalfWidthM = 0.02;

  /// Segments per ring. A 20 m circle at 96 segments has a 33 cm chord, which is
  /// under a pixel at any working zoom.
  static const int padRingSegments = 96;

  /// Rings sit this far above the disc so the two never sort ambiguously. At a
  /// working range of 20 m with a 0.7 m near plane the depth quantum is about
  /// 34 um, so 5 mm is roughly 150 quanta of separation.
  static const double padRingLiftM = 0.005;

  /// Pad opacity.
  ///
  /// The pad is a REFERENCE, and a reference that hides its subject is worse
  /// than no reference: `CraftEditorCamera` lets the player orbit below the
  /// plane, and an opaque disc would then cover the whole vehicle at exactly the
  /// moment they are checking whether the footpads clear the bell. Translucency
  /// also takes the pad out of the depth-writing opaque pass entirely
  /// (`Material.isOpaque` splits the two), so it can never occlude from any
  /// angle while still being depth-TESTED and therefore properly hidden BY the
  /// craft. 0.55 leaves the vehicle at 45% through the disc, which reads as a
  /// silhouette under glass rather than as a hole in the floor.
  static const double padAlpha = 0.55;

  /// Ghost opacity. High enough that the silhouette reads at a glance, low
  /// enough that it can never be mistaken for a committed part.
  static const double ghostAlpha = 0.45;

  /// Image-based ambient for the editor scene — the `scatter_lab_screen`
  /// balance, chosen there for the same reason: let the key light do the
  /// shading so the subject keeps its form.
  static const double environmentIntensity = 0.18;

  static const double lightIntensity = 2.6;

  /// How far the key light is swung off the view axis, radians. A light on the
  /// view axis flattens every surface it reveals, so the craft would read as a
  /// silhouette however you orbited it.
  static const double lightOffsetRad = 0.6;

  /// How far the light sits above the horizontal, as a fraction of its
  /// horizontal distance. Matches the `scatter_lab_screen` sun.
  static const double lightHeight = 0.55;

  /// Floor on a stand-in's box, metres. A [PartDef] with a zero extent would
  /// otherwise collapse its silhouette to an invisible plane.
  ///
  /// Aliases [PartPrimitivesByCategory.minExtentM] rather than restating it:
  /// the two renderers of a catalog part must floor at the same value or a
  /// degenerate part is a different size in the VAB and in flight.
  static const double minStandInM = PartPrimitivesByCategory.minExtentM;

  /// Ghost tint when the mate is legal — `AppTheme.accent2` (0xFF7FE0A0), and
  /// when it would be refused — `AppTheme.danger` (0xFFFF6B6B). The refused
  /// tint is what an aim at an incompatible attach node draws; see
  /// [CraftGhost.valid].
  ///
  /// Restated as numbers rather than imported: the flutter_scene layer depends
  /// on the Flutter widget layer nowhere else in this app, and a renderer that
  /// reaches into a screen's palette is the seam that later makes the renderer
  /// untestable. Held as plain component lists because `vm.Vector4` has no const
  /// constructor and a shared mutable instance is one in-place edit away from
  /// recolouring every ghost at once.
  static const List<double> ghostValidRgb = [0.498, 0.878, 0.627];
  static const List<double> ghostInvalidRgb = [1.0, 0.420, 0.420];

  final fs.Scene _scene;

  /// One slot per placed part, keyed by `instanceId`. The map entry IS the
  /// generation token an in-flight bake checks itself against.
  final Map<String, _PartSlot> _slots = {};

  /// The ghost previews. Built lazily so the scene tear-offs below close over a
  /// fully constructed object.
  late final CraftGhostPool _ghosts = CraftGhostPool(
    buildMesh: _ghostMeshNode,
    attach: _scene.add,
    detach: _scene.remove,
  );

  /// The pad, built once. Eleven meshes, and nothing about them depends on the
  /// craft: only the root's transform moves.
  fs.Node? _pad;
  bool _padAttached = false;

  fs.DirectionalLight? _light;

  /// The selection currently painted, as an owned copy — the caller's set is
  /// theirs to mutate.
  Set<String> _selection = const {};

  bool _disposed = false;

  /// Bumped once per [sync]; a slot still carrying an older stamp is one whose
  /// part left the design. Cheaper than allocating a seen-set per frame.
  int _generation = 0;

  /// Bring the scene into line with [design]. Call once per painted frame.
  ///
  /// [pivot] is the camera pivot in craft-frame metres and doubles as the
  /// floating origin; [azimuth] is the camera's turntable angle, which aims the
  /// key light. [ghosts] and [selection] may be empty, and the common case of
  /// "unchanged since last frame" costs a length compare.
  void sync(
    CraftDesign design, {
    required Vector3 pivot,
    required double azimuth,
    List<CraftGhost> ghosts = const [],
    Set<String> selection = const {},
  }) {
    if (_disposed) return;
    _syncLight(azimuth);
    _syncPad(design, pivot);
    _syncParts(design, pivot);
    _ghosts.sync(ghosts, pivot);
    _syncSelection(selection);
  }

  /// Detach everything this owns. The nodes are dropped, never disposed inline
  /// — see the class doc on the web `Vertices`/`ImageShader` trap. Clearing
  /// [_slots] is also what tells every in-flight bake to discard itself.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final slot in _slots.values) {
      _scene.remove(slot.node);
    }
    _slots.clear();
    _ghosts.clear();
    final pad = _pad;
    if (pad != null && _padAttached) _scene.remove(pad);
    _pad = null;
    _padAttached = false;
    if (identical(_scene.directionalLight, _light)) {
      _scene.directionalLight = null;
    }
    _light = null;
    _selection = const {};
  }

  // ---------------- parts ----------------

  void _syncParts(CraftDesign design, Vector3 pivot) {
    final gen = ++_generation;
    for (final p in design.parts) {
      var slot = _slots[p.instanceId];
      // A reused id carrying a different catalog part is a different object on
      // screen. Retiring the slot (rather than swapping its child) is what makes
      // the identity check in [_startRealize] reject the old part's decode.
      if (slot != null && slot.defId != p.def.id) {
        _scene.remove(slot.node);
        _slots.remove(p.instanceId);
        slot = null;
      }
      if (slot == null) {
        slot = _PartSlot(p.def.id);
        _slots[p.instanceId] = slot;
        _scene.add(slot.node);
        // Something is on screen from this frame on, whatever happens to the
        // bake. A part must never simply be absent.
        slot.node.add(_standIn(p.def));
        _startRealize(p.instanceId, slot, p.def);
        if (_selection.contains(p.instanceId)) {
          _paintHighlight(slot.node, selectionColor());
        }
      }
      slot.seen = gen;
      slot.node.localTransform = placementTransform(p.position, p.rotation, pivot);
      // Reapplied per frame rather than once at realize, mirroring
      // `VesselNodes._syncPartTransforms`: the correction is re-READ from the
      // def every frame, so a def swapped underneath the editor (a calibration
      // harness, a reloaded catalog) lands on the next frame with no rebuild.
      final modelNode = slot.modelNode;
      if (modelNode != null) modelNode.localTransform = partModelTransform(p.def);
    }
    // Every design part got a slot above, so the counts can only differ when
    // stale slots remain. Gating the sweep on that keeps the common frame free
    // of the key list `Map.removeWhere` builds.
    if (_slots.length != design.partCount) {
      _slots.removeWhere((id, slot) {
        if (slot.seen == gen) return false;
        _scene.remove(slot.node);
        return true;
      });
    }
  }

  /// The procedural silhouette for one part, scaled to the part's own box.
  fs.Node _standIn(PartDef def) =>
      fs.Node(mesh: PartPrimitivesByCategory.forPart(def))
        ..localTransform = vm.Matrix4.compose(
          vm.Vector3.zero(),
          vm.Quaternion.identity(),
          standInScale(def),
        );

  /// Start this part's bake, if it has one worth starting.
  void _startRealize(String instanceId, _PartSlot slot, PartDef def) {
    // [PartDef] is authoritative for the editor: the editor holds the catalog,
    // so it reads the binding the catalog author wrote instead of a second
    // registry keyed off names.
    final asset = def.modelAsset;
    // Null when the part has no art at all. A bake that already failed is not
    // retried: [PartBakeCache]'s record is per ASSET and process-wide, so one
    // missing part model costs one attempt per process, not one per placement.
    if (asset == null || PartBakeCache.hasFailed(asset)) return;
    PartBakeCache.realize(asset).then((model) {
      if (_disposed) return;
      // The slot object is the generation token. If the part was deleted, or its
      // id was reused by a different def, the map no longer holds THIS slot and
      // the realized graph belongs to something that is not on screen — drop it
      // unparented rather than parenting it into a scene that has moved on.
      if (!identical(_slots[instanceId], slot)) return;
      for (final child in List.of(slot.node.children)) {
        slot.node.remove(child); // retire the stand-in
      }
      slot.node.add(model);
      slot.modelNode = model;
      model.localTransform = partModelTransform(def);
      // The stand-in this replaced may have been carrying the selection.
      if (_selection.contains(instanceId)) {
        _paintHighlight(model, selectionColor());
      }
    }).catchError((Object e) {
      // Don't hammer this broken/missing bake. The stand-in already on screen
      // is now the permanent picture for this part.
      PartBakeCache.markFailed(asset);
      // ignore: avoid_print
      print('craft editor part model load failed ($asset): $e');
    });
  }

  // ---------------- ghosts ----------------

  /// One ghost's mesh child: the part's silhouette, filling the part's box,
  /// wearing the slot's own [material].
  ///
  /// The ghost draws the PROCEDURAL silhouette even for a part that has a bake,
  /// and deliberately never realizes one. A preview that only appears once a
  /// 36 MB asset has decoded is not a preview; and re-materialising a realized
  /// graph to 45% alpha would have to reach into materials the bake cache shares
  /// between every instance of that asset.
  fs.Node _ghostMeshNode(PartDef def, DepthSafeUnlitMaterial material) {
    final mesh = PartPrimitivesByCategory.forPart(def);
    for (final prim in mesh.primitives) {
      prim.material = material;
    }
    return fs.Node(mesh: mesh)
      ..localTransform = vm.Matrix4.compose(
        vm.Vector3.zero(),
        vm.Quaternion.identity(),
        standInScale(def),
      );
  }

  // ---------------- selection ----------------

  /// Repaint the selection outline if, and only if, the set changed.
  void _syncSelection(Set<String> selection) {
    if (selection.length == _selection.length &&
        selection.containsAll(_selection)) {
      return;
    }
    _selection = Set.of(selection);
    for (final entry in _slots.entries) {
      _paintHighlight(
        entry.value.node,
        _selection.contains(entry.key) ? selectionColor() : null,
      );
    }
  }

  /// Set (or clear) [fs.Node.highlightColor] over a whole subtree.
  ///
  /// SELECTION IS A NODE PROPERTY, NOT A MATERIAL EDIT. The obvious alternative
  /// — re-deriving `baseColorFactor` from a captured original, the way
  /// `VesselNodes._applyEclipse` dims a craft — is wrong here and quietly so:
  /// `fscene`'s `ResourceRealizer` MEMOISES materials per asset
  /// (`resource_realizer.dart:103`), so two parts realized from one bake share
  /// their `Material` objects, and tinting the selected one would tint the other
  /// as well. Four RCS quads cut from one export are exactly that case.
  /// [fs.Node.highlightColor] is per node, is read straight through to the
  /// render item, needs no captured original, and cannot accumulate — setting it
  /// twice is the same as setting it once.
  ///
  /// The walk is recursive because the property is not inherited: a realized
  /// bake is a tree and its meshes hang off descendants, not off the root.
  void _paintHighlight(fs.Node node, vm.Vector4? color) {
    node.highlightColor = color;
    for (final child in node.children) {
      _paintHighlight(child, color);
    }
  }

  // ---------------- pad and light ----------------

  void _syncPad(CraftDesign design, Vector3 pivot) {
    final pad = _pad ??= _buildPad();
    if (!_padAttached) {
      _scene.add(pad);
      _padAttached = true;
    }
    pad.localTransform = padTransform(pivot, padPlaneZ(design));
  }

  /// The pad: a translucent disc with concentric metre rings, authored about its
  /// own origin and placed at [padPlaneZ].
  ///
  /// IN 3D, not in the overlay, because it has to be OCCLUDED by the craft. A 2D
  /// grid drawn over a rocket reads as a HUD and destroys the sense of scale;
  /// a disc the descent stage stands on gives the eye something to measure
  /// against, which is what makes "do the footpads clear the bell" a judgement
  /// the player can actually make.
  ///
  /// Geometry is authored in METRES; the root's uniform `lengthToScene(1)` scale
  /// converts to scene units, the same convention `VesselNodes._buildAxisGizmo`
  /// uses.
  fs.Node _buildPad() {
    final root = fs.Node();

    // A 1 mm cylinder rather than a `DiscGeometry`: a disc is a single-sided
    // fan and back-face culling would delete the pad the moment the player
    // orbited underneath the craft, which is exactly when they are checking the
    // engine bell. A closed solid has an outward face on both sides.
    root.add(
      fs.Node(
        mesh: fs.Mesh(
          fs.CylinderGeometry(
            topRadius: padRadiusM,
            bottomRadius: padRadiusM,
            height: 0.001,
            radialSegments: 64,
          ),
          padMaterial(padColor(0.10, 0.11, 0.13)),
        ),
      )..localTransform = padChildTransform(0),
    );

    for (var r = padRingSpacingM; r <= padRadiusM + 1e-9; r += padRingSpacingM) {
      // Every fifth ring is brighter, so the pad reads as a ruler with major
      // gradations rather than as a target.
      final major = (r / padRingSpacingM).round() % 5 == 0;
      final v = major ? 0.42 : 0.24;
      root.add(
        fs.Node(
          mesh: fs.Mesh(
            _twoSidedRingGeometry(
              innerRadius: r - padRingHalfWidthM,
              outerRadius: r + padRingHalfWidthM,
            ),
            padMaterial(padColor(v, v * 1.05, v * 1.15)),
          ),
        )..localTransform = padChildTransform(padRingLiftM),
      );
    }
    return root;
  }

  /// A flat annulus in the geometry's XZ plane, wound BOTH ways.
  ///
  /// `fs.RingGeometry` emits one winding and relies on `doubleSided` to show the
  /// other face — but `Material.bind` honours `doubleSided` for OPAQUE materials
  /// only, and back-face culls every translucent draw unconditionally. A
  /// translucent ring built that way vanishes the moment the player orbits under
  /// the pad, while the solid disc beside it does not, which reads as a
  /// rendering fault rather than as a floor. Emitting the reverse triangles
  /// makes two-sidedness a property of the MESH, which no material flag can take
  /// away.
  ///
  /// Authored about +Y like every other flutter_scene primitive, so
  /// [padChildTransform]'s quarter turn puts it in the craft's XY plane.
  ///
  /// Normals are stated rather than generated: the pad is unlit, and the
  /// generator would average this mesh's opposed faces to zero.
  static fs.MeshGeometry _twoSidedRingGeometry({
    required double innerRadius,
    required double outerRadius,
    int segments = padRingSegments,
  }) {
    final positions = <double>[];
    final normals = <double>[];
    final indices = <int>[];
    for (var s = 0; s < segments; s++) {
      final a = 2 * math.pi * s / segments;
      final c = math.cos(a), sn = math.sin(a);
      positions.addAll([outerRadius * c, 0, outerRadius * sn]); // 2s
      positions.addAll([innerRadius * c, 0, innerRadius * sn]); // 2s + 1
      normals.addAll([0, 1, 0, 0, 1, 0]);
    }
    for (var s = 0; s < segments; s++) {
      final t = (s + 1) % segments;
      final o0 = 2 * s, i0 = 2 * s + 1, o1 = 2 * t, i1 = 2 * t + 1;
      indices
        ..addAll([o0, o1, i1]) // +Y face
        ..addAll([o0, i1, i0])
        ..addAll([o0, i1, o1]) // -Y face, the same quad reversed
        ..addAll([o0, i0, i1]);
    }
    return fs.MeshGeometry.fromArrays(
      positions: Float32List.fromList(positions),
      normals: Float32List.fromList(normals),
      indices: indices,
    );
  }

  void _syncLight(double azimuth) {
    final dir = lightDirection(azimuth);
    final light = _light;
    if (light == null || !identical(_scene.directionalLight, light)) {
      _light = fs.DirectionalLight(direction: dir, intensity: lightIntensity);
      _scene.directionalLight = _light;
    } else {
      light.direction = dir;
    }
  }

  // ---------------- pure transforms ----------------

  /// A craft-frame placement as a scene-graph transform, rebased on [pivot].
  ///
  /// Used for both a placed part's slot and a ghost, so the two can never drift:
  /// a ghost that composed its transform even slightly differently would put the
  /// preview somewhere the commit does not.
  static vm.Matrix4 placementTransform(
    Vector3 positionInCraft,
    Quaternion rotation,
    Vector3 pivot,
  ) =>
      vm.Matrix4.compose(
        relToScene(positionInCraft - pivot),
        quatToScene(rotation),
        vm.Vector3.all(1.0),
      );

  /// The transform of the model child INSIDE a part slot: an export's own axes
  /// and units carried into the part frame the slot places.
  ///
  /// `T(modelOffset) * R(modelRotation * glTF Y-up fix) * S(modelScale)`, which
  /// is exactly what [vm.Matrix4.compose] builds, and the order is the contract:
  ///
  ///  * SCALE innermost, so [PartDef.modelScale] converts model units to metres
  ///    before anything else looks at the mesh;
  ///  * ROTATION next, so [PartDef.modelRotation] is read in the PART frame on
  ///    top of the Y-up fix, not in the export's authored axes;
  ///  * OFFSET outermost, so it is metres along the part's own corrected axes.
  ///    Scaling it would silently redefine it as model units and rotating it
  ///    would redefine it as authored axes; either makes a screenshot-driven
  ///    calibration unrepeatable.
  ///
  /// Reads [PartDef] rather than `PartModelLibrary` because the editor holds the
  /// catalog. `kitbash_render_test.dart` already pins that the two agree
  /// field for field, so this is the same picture the flight view draws.
  ///
  /// ART ONLY: the slot — and with it every attach node, mass and inertia the
  /// domain anchors to the part origin — does not move.
  static vm.Matrix4 partModelTransform(PartDef def) => vm.Matrix4.compose(
        relToScene(def.modelOffset),
        quatToScene(def.modelRotation) * _yUpFix(),
        vm.Vector3.all(lengthToScene(def.modelScale)),
      );

  /// Scale that takes [def]'s procedural silhouette to [def]'s own box, in scene
  /// units.
  ///
  /// Non-uniform on purpose — a 2.5 m by 2.5 m by 4 m tank is not a cube — and
  /// divided by the primitive's OWN authored extent, because the primitives are
  /// not all unit cubes: `PartPrimitives.slab` is 1.0 x 0.4 x 0.06, and scaling
  /// it by a bare [PartDef.size] would draw a landing leg 0.19 m deep where
  /// `CraftEditorPick` hit-tests 3.22 m. Dividing makes the drawn box EQUAL the
  /// oriented box the picker tests, which is what keeps an unmodelled part
  /// honestly placeable rather than merely placeable: every pixel of the
  /// silhouette is clickable and nothing outside it is.
  ///
  /// The factor itself comes from [PartPrimitivesByCategory.standInScaleM],
  /// which is also what `VesselNodes.standInScale` applies in flight; this only
  /// converts it to scene units. One definition, because a craft that changed
  /// size when it launched would make the editor a liar about what it built.
  static vm.Vector3 standInScale(PartDef def) {
    final f = PartPrimitivesByCategory.standInScaleM(def);
    return vm.Vector3(
        lengthToScene(f.x), lengthToScene(f.y), lengthToScene(f.z));
  }

  /// Craft-frame z the pad plane sits at: the LOWEST point of the committed
  /// craft, so the vehicle stands on the pad however it is built. Zero for an
  /// empty design, which is where the root part is about to arrive.
  ///
  /// ## Why the pad moves and the craft does not
  ///
  /// Every catalog part authors its box and its attach nodes symmetrically about
  /// its own origin, and `placeRoot` seats the root origin at the craft origin,
  /// so a stack grows DOWNWARD from z = 0 by design: a lunar module built from
  /// the shipped roster spans z = -4.86 m to +1.73 m, and a fixed z = 0 datum
  /// would bury three quarters of it — footpads, engine bell and all — under its
  /// own reference plane.
  ///
  /// The alternative fix, re-seating the root so the craft rests on z = 0, moves
  /// the DOMAIN frame: `PlacedPart.position`, every solved mate, the codec's
  /// snapshots, `CraftBalance`'s readouts and `VesselAssembler`'s bake all live
  /// in that frame, and a leg added at the bottom of the stack would have to
  /// rewrite every part in the design (and every undo step) to keep the
  /// invariant. This is a VIEW datum, it costs one bounds read per frame, and it
  /// is exact for any craft: add a landing leg and the pad drops to meet it,
  /// delete it and the pad rises. The vehicle standing on the ground is what a
  /// pad means, and nothing about the craft has to move to express it.
  ///
  /// Tracks COMMITTED parts only, so a ghost dipping below the pad is the honest
  /// picture of a part that is about to become the craft's new lowest point.
  static double padPlaneZ(CraftDesign design) =>
      CraftBalance.bounds(design)?.min.z ?? 0.0;

  /// The pad root's transform: the pad plane at craft z = [planeZ], rebased on
  /// the camera [pivot] so it moves under a pan exactly as the craft does.
  ///
  /// The uniform `lengthToScene(1)` scale is what lets the pad's radii and lifts
  /// be written as the metre values they are — the convention
  /// `VesselNodes._buildAxisGizmo` established for authored-in-metres gizmos.
  static vm.Matrix4 padTransform(Vector3 pivot, double planeZ) =>
      vm.Matrix4.compose(
        relToScene(Vector3(0, 0, planeZ) - pivot),
        vm.Quaternion.identity(),
        vm.Vector3.all(lengthToScene(1.0)),
      );

  /// A pad child inside [padTransform]'s root: a quarter turn about +X, because
  /// the pad primitives are built about +Y and the craft's up is +Z, plus a
  /// [liftM] separation in METRES along craft +Z.
  ///
  /// SCALE IS 1 HERE, AND THAT IS THE POINT. The root already carries the
  /// metre-to-scene conversion; repeating it on the child would apply
  /// [kRenderScale] twice and draw a 20 m pad at 2 cm. That is the exact shape
  /// of the bug this repo has already shipped once ("city geometry was 1000x
  /// life size"), so the composition is a named function with a test on it
  /// rather than two literals inside a builder.
  static vm.Matrix4 padChildTransform(double liftM) => vm.Matrix4.compose(
        vm.Vector3(0, 0, liftM),
        _yUpFix(),
        vm.Vector3.all(1.0),
      );

  /// A pad colour, PREMULTIPLIED at [padAlpha].
  ///
  /// The translucent pass blends premultiplied, so a straight RGBA here would
  /// draw the pad at full strength over whatever is behind it. Components are
  /// linear, in the 0..1 the material expects.
  static vm.Vector4 padColor(double r, double g, double b) =>
      vm.Vector4(r * padAlpha, g * padAlpha, b * padAlpha, padAlpha);

  /// The material every piece of the pad wears.
  ///
  /// `AlphaMode.blend` is load-bearing twice over: it is what makes the alpha in
  /// [padColor] mean anything at all (`AlphaMode.opaque` ignores alpha outright),
  /// and it is what routes the draw into the translucent pass, which does not
  /// write depth. A reference plane that wrote depth would occlude the craft it
  /// exists to measure.
  static DepthSafeUnlitMaterial padMaterial(vm.Vector4 color) =>
      DepthSafeUnlitMaterial()
        ..alphaMode = fs.AlphaMode.blend
        ..baseColorFactor = color;

  /// Unit direction the key light TRAVELS, craft frame, for a camera at
  /// [azimuth].
  ///
  /// The eye's horizontal bearing follows from `PerspectiveCamera.forward =
  /// (cos(el) sin(az), cos(el) cos(az), -sin(el))`: the eye sits opposite the
  /// view axis, so its bearing is `(-sin(az), -cos(az))`. That bearing is swung
  /// [lightOffsetRad] about +Z and lifted [lightHeight], then negated because a
  /// [fs.DirectionalLight] stores the direction light travels IN, not the
  /// direction it comes FROM.
  static vm.Vector3 lightDirection(double azimuth) {
    final ex = -math.sin(azimuth), ey = -math.cos(azimuth);
    final c = math.cos(lightOffsetRad), s = math.sin(lightOffsetRad);
    final lx = ex * c - ey * s, ly = ex * s + ey * c;
    return vm.Vector3(-lx, -ly, -lightHeight)..normalize();
  }

  /// Ghost tint, PREMULTIPLIED. The translucent pass blends premultiplied and
  /// `AlphaMode.opaque` ignores alpha entirely, so a straight RGBA here would
  /// draw the ghost as a solid part — indistinguishable from a committed one.
  static vm.Vector4 ghostColor({required bool valid}) {
    final c = valid ? ghostValidRgb : ghostInvalidRgb;
    return vm.Vector4(
      c[0] * ghostAlpha,
      c[1] * ghostAlpha,
      c[2] * ghostAlpha,
      ghostAlpha,
    );
  }

  /// Selection outline colour — `AppTheme.accent` (0xFF4FC3F7).
  ///
  /// A fresh vector per call, for the same reason [_yUpFix] is: vector_math
  /// types are mutable, and one instance handed to every selected node is one
  /// in-place edit away from recolouring the whole scene.
  static vm.Vector4 selectionColor() => vm.Vector4(0.310, 0.765, 0.969, 1.0);

  /// glTF Y-up -> craft Z-up, nose on +Z. Built fresh per call: vector_math
  /// quaternions are mutable, and a shared instance is one careless in-place
  /// operation away from rotating every part in the editor. Duplicated from
  /// `VesselNodes` rather than shared because that copy is private and this file
  /// must not widen the flight renderer's API to ask a question only the editor
  /// asks.
  static vm.Quaternion _yUpFix() =>
      vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), math.pi / 2);
}

/// The ghost previews' node pool.
///
/// ## Why a slot outlives the ghost that filled it
///
/// A ghost appears and disappears at POINTER RATE. Sweeping the cursor across a
/// lunar module's twelve quad, leg and deflector markers takes about a second
/// and crosses two dozen enter/leave boundaries, and a preview is dropped
/// entirely whenever the aim misses. Destroying the slot on each leave would
/// build a mesh — and with it a vertex buffer and an index buffer on the device
/// — on each re-entry, and this file never disposes GPU resources inline (see
/// [CraftEditorNodes]'s class doc on the web `Vertices`/`ImageShader` trap), so
/// every rebuild ORPHANS the last: a routine aiming gesture would leak device
/// allocations as fast as the mouse moves.
///
/// So a slot that is not needed this frame is DETACHED from the scene and kept.
/// Its mesh child is rebuilt only when the held part changes, which is a catalog
/// click rather than a mouse move. Moving a four-way symmetry set is then four
/// matrix writes and no allocation, which is what the editor's per-frame budget
/// assumes.
///
/// The pool grows to the widest preview ever shown and never shrinks. That
/// bound is the largest symmetry set the player has aimed — single digits — and
/// paying for it is the point: those are exactly the slots about to be needed
/// again.
///
/// ## Why it is a class of its own
///
/// `fs.Mesh` needs a live Impeller context; `fs.Node` does not. Taking the mesh
/// build as a callback is what lets a headless test hand this class a builder
/// that counts its calls, which is the only way to SEE the difference between
/// reusing a slot and rebuilding one — the difference this class exists to make.
class CraftGhostPool {
  CraftGhostPool({
    required fs.Node Function(PartDef def, DepthSafeUnlitMaterial material)
        buildMesh,
    required void Function(fs.Node node) attach,
    required void Function(fs.Node node) detach,
  })  : _buildMesh = buildMesh,
        _attach = attach,
        _detach = detach;

  final fs.Node Function(PartDef, DepthSafeUnlitMaterial) _buildMesh;
  final void Function(fs.Node) _attach;
  final void Function(fs.Node) _detach;

  /// Slots, indexed positionally: ghost `i` of the preview keeps slot `i` across
  /// frames, so a symmetry set that merely MOVES touches no other state.
  final List<_GhostSlot> _slots = [];

  int _meshBuilds = 0;

  /// Slots held, attached or not. Never decreases short of [clear].
  int get slotCount => _slots.length;

  /// Slots in the scene right now — one per ghost of the last [sync].
  int get liveCount {
    var n = 0;
    for (final slot in _slots) {
      if (slot.attached) n++;
    }
    return n;
  }

  /// Mesh children this pool has built since it was created.
  ///
  /// The pool's whole contract is about what it does NOT allocate, and that is
  /// invisible from the outside otherwise: a leak here looks exactly like
  /// correct behaviour until the device runs out of buffers.
  int get meshBuilds => _meshBuilds;

  /// Show exactly [ghosts], in order, rebased on the camera [pivot].
  void sync(List<CraftGhost> ghosts, Vector3 pivot) {
    while (_slots.length < ghosts.length) {
      _slots.add(_GhostSlot());
    }
    for (var i = 0; i < _slots.length; i++) {
      final slot = _slots[i];
      if (i >= ghosts.length) {
        if (slot.attached) {
          _detach(slot.node);
          slot.attached = false;
        }
        continue;
      }
      final g = ghosts[i];
      // The HELD DEF is the only thing that invalidates a mesh. Everything else
      // about a ghost — where it sits, which way it faces, whether the mate is
      // legal — is a transform or a colour on geometry that is already there.
      if (slot.defId != g.def.id) {
        final old = slot.meshNode;
        if (old != null) slot.node.remove(old);
        final child = _buildMesh(g.def, slot.material);
        slot.node.add(child);
        slot.meshNode = child;
        slot.defId = g.def.id;
        _meshBuilds++;
      }
      if (slot.valid != g.valid) {
        slot.valid = g.valid;
        slot.material.baseColorFactor =
            CraftEditorNodes.ghostColor(valid: g.valid);
      }
      slot.node.localTransform =
          CraftEditorNodes.placementTransform(g.position, g.rotation, pivot);
      if (!slot.attached) {
        _attach(slot.node);
        slot.attached = true;
      }
    }
  }

  /// Detach every slot and drop the pool. The nodes are dropped, never disposed
  /// inline — the tear-down path of [CraftEditorNodes.dispose].
  void clear() {
    for (final slot in _slots) {
      if (slot.attached) _detach(slot.node);
      slot.attached = false;
    }
    _slots.clear();
  }
}

/// One placed part on screen.
///
/// [node] is the slot: it holds the part's placement in the craft frame and
/// NOTHING else, so its single child can be swapped from the procedural stand-in
/// to the realized bake without touching that placement. [defId] is what the
/// slot was built for — a change means a different part wearing the same
/// instance id, which needs a new slot rather than a new child.
class _PartSlot {
  _PartSlot(this.defId);

  final String defId;

  final fs.Node node = fs.Node();

  /// The realized bake, once it has landed. Null while the stand-in is showing.
  fs.Node? modelNode;

  /// The sync generation that last saw this slot's part in the design.
  int seen = -1;
}

/// One translucent preview's slot.
///
/// Same two-level split as [_PartSlot] for the same reason: [node] carries the
/// placement, so moving a four-way symmetry set is four matrix writes and the
/// mesh below is only rebuilt when the held part itself changes. [material] is
/// owned per ghost, so recolouring one on an invalid mate cannot touch its
/// siblings.
///
/// [attached] is tracked rather than inferred because `fs.Node.remove` throws on
/// a child it does not hold, so a pool that guessed would crash the frame after
/// a preview shrank.
class _GhostSlot {
  final fs.Node node = fs.Node();

  final DepthSafeUnlitMaterial material = DepthSafeUnlitMaterial()
    ..alphaMode = fs.AlphaMode.blend;

  fs.Node? meshNode;

  String? defId;

  /// Null until the first sync, so the material is always coloured once.
  bool? valid;

  bool attached = false;
}
