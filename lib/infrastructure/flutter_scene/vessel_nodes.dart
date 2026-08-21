// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_scene/scene.dart' as fs;
import 'package:vector_math/vector_math.dart' as vm;

import '../../application/snapshot/world_snapshot.dart';
import '../../domain/shared/quaternion.dart';
import '../../domain/shared/vector3.dart';
import 'coord_convert.dart';
import 'depth_materials.dart';
import 'part_bake_cache.dart';
import 'part_model_library.dart';
import 'part_primitives_category.dart';

/// Maintains one scene node per vessel: a parent node placed at the
/// vessel's world position (dominant-body position + body-relative vessel
/// position) carrying the attitude quaternion.
///
/// A vessel is drawn one of two ways, decided per frame by [isKitbash]:
///
///  * KITBASH — at least one part came from the part catalog, so the PART LIST
///    is the model: one child node per part, at the part's body-frame offset
///    and orientation, carrying that part's bake, or the same procedural
///    silhouette the VAB drew it with until/unless that bake loads. Every craft
///    the player assembles takes this path, and it changes shape when it
///    stages.
///  * WHOLE-CRAFT — no part came from the catalog, so the craft is drawn as one
///    baked model chosen from its id ([_assetFor]), with a procedural
///    silhouette OF THAT MODEL — Apollo CSM or Lunar Module — standing in while
///    it decodes, or forever on a clone with no assets. Every hand-built
///    vessel — the sample world's fleet, a spawned test mass — takes this
///    path.
///
/// The predicate is PROVENANCE, not art. What the player assembled must be what
/// the player flies, and that has to hold on the very first stock craft, before
/// any of the roster has a bake: the stand-ins are the first frame of that
/// stack, not a different craft. Art only decides what fills a slot, never how
/// many slots there are.
///
/// The two populations cannot overlap, which is what keeps hand-built vessels
/// on the model they were authored and calibrated for. `PartSnapshot.type` is
/// `Part.assetKey`, and the only writers of a non-empty `Part.defId` in the
/// whole app are [VesselAssembler] — reached only from the VAB's launch — and
/// the save codec that round-trips its output. Everything hand-built reports a
/// display name instead, which the catalog has never heard of.
///
/// Sizes are in METRES (converted); vessel body frame is Z-up with the nose on
/// +Z, like everything else.
class VesselNodes {
  VesselNodes(this._scene);

  final fs.Scene _scene;

  final Map<String, fs.Node> _nodes = {};
  // Part-list fingerprint per vessel; rebuild children only when it changes
  // (staging events), not every frame.
  final Map<String, String> _partsKey = {};

  /// Kitbash slots per vessel, in snapshot part order. Present ONLY for craft
  /// on the per-part path, so its keys double as "this vessel is a kitbash" —
  /// which is how an in-flight whole-craft realize learns it has been
  /// superseded. The list identity is the generation token: a rebuild installs
  /// a NEW list, so a decode that started against the old one bails.
  final Map<String, List<_PartSlot>> _partSlots = {};

  /// Craft model: the Apollo CSM replaces the procedural part composition
  /// once decoded (87 MB — async; primitives show until then). Loaded per
  /// vessel: a Node can't be parented twice.
  ///
  /// `.fsceneb` baked from the licensed .glb by `tool/import_mesh.dart`;
  /// neither format is committed (license bars redistribution), so clones
  /// without the asset stay procedural (see [PartBakeCache.hasFailed]).
  ///
  /// TWO craft models: the Apollo CSM (default) and the Lunar Module. A vessel
  /// whose id contains 'lander' renders the LM export; everything else is the
  /// CSM. Web bundles a SMALLER, lower-res bake per model: the full-res models
  /// break the GitHub Pages server-side build (over an effective size
  /// threshold) and Release assets aren't CORS-enabled to fetch at runtime.
  /// The web bakes are fetched into the Pages build by the release workflow's
  /// web job; absent (e.g. not yet published) the craft stays procedural.
  static const String _apolloModel = 'assets/mesh/apollo.fsceneb';
  static const String _apolloModelWeb = 'assets/mesh/apollo-web.fsceneb';
  static const String _landerModel = 'assets/mesh/lander.fsceneb';
  static const String _landerModelWeb = 'assets/mesh/lander-web.fsceneb';

  /// Whether [vesselId] is a Lunar Module rather than a CSM. The ONE test, used
  /// by both the bake ([_assetFor]) and the silhouette that stands in for it
  /// ([_rebuildParts]): a craft that loaded the LM model but fell back to a CSM
  /// hull would change shape the moment the asset landed.
  static bool _isLander(String vesselId) =>
      vesselId.toLowerCase().contains('lander');

  /// The model asset [vesselId] renders, per platform.
  static String _assetFor(String vesselId) {
    if (_isLander(vesselId)) {
      return kIsWeb ? _landerModelWeb : _landerModel;
    }
    return kIsWeb ? _apolloModelWeb : _apolloModel;
  }

  /// Model-unit -> metre factor. Live-tunable via `ext.acro.camera?glbScale=`
  /// while calibrating a new export; the transform reapplies every frame so
  /// changes land immediately. (apollo.glb calibrated by screenshot: 0.02 ->
  /// ~11 m craft.) The LM export has its own units, so [assetScale] pins a
  /// per-asset override; entries fall back to [glbUnitScale] when unset.
  static double glbUnitScale = 0.02;
  static final Map<String, double> assetScale = {
    // LM export units differ from the CSM's. 1.8 is screenshot-calibrated to
    // render the LM at roughly its real size (~7 m tall) beside the apollo CSM.
    _landerModel: 1.8,
    _landerModelWeb: 1.8,
  };
  static double _scaleFor(String asset) => assetScale[asset] ?? glbUnitScale;
  final Map<String, fs.Node> _glbModels = {};
  final Set<String> _glbLoading = {};
  final Set<String> _glbApplied = {};

  /// Debug reference gizmo at each craft's ORIGIN: three 1-metre-ticked axes
  /// in the vessel body frame (X red, Y green, Z blue = nose) plus an origin
  /// cube. Authored in TRUE metres — NOT glb-scaled — so the ticks are a ruler
  /// against the model, revealing both origin offset and any scale mismatch.
  /// Toggle from the debug panel or `ext.acro.camera?axes=`.
  static bool showAxes = false;
  static const double _axisLenM = 10.0; // axis length + tick count, metres
  final Map<String, fs.Node> _axisNodes = {};

  /// Aft-most surface of the CSM silhouette on the body Z axis, METRES: the
  /// exit plane of the Apollo fallback's SPS bell, and the scale the baked
  /// models are calibrated to match.
  ///
  /// A named constant because it is what anything anchored to the tail is
  /// calibrated AGAINST — [ExhaustNodes.defaultNozzleZM] is the live example —
  /// and a number that exists only as the sum of two literals inside
  /// [_addApolloFallback] cannot be calibrated against at all.
  ///
  /// Not every whole-craft vessel ends here — a lander ends at [landerAftM],
  /// which is 3 m nearer the origin. Ask [silhouetteAftM] rather than reaching
  /// for this constant unless the CSM is specifically what is meant.
  static const double fallbackAftM = -6.5;

  /// Height of that bell, metres. Only [_addApolloFallback] and the constant
  /// above need it.
  static const double _spsBellM = 1.8;

  /// Aft-most surface of the LUNAR MODULE silhouette, METRES: the underside of
  /// its footpads, i.e. the plane the craft stands on. [fallbackAftM]'s
  /// counterpart for the other whole-craft body, and shallower than it by the
  /// whole length of a service module — an LM is a 6.8 m craft that hangs
  /// barely 3.6 m below its origin.
  static const double landerAftM = -3.6;

  /// Exit plane of the LM's descent engine bell, METRES. The plume anchor sits
  /// 0.1 m inside it ([ExhaustNodes.defaultNozzleZM]), which is a flame filling
  /// the bell rather than one lit inside the descent stage or hanging in the
  /// gap above the ground.
  ///
  /// It has to hang well clear of the stage above it for a second reason: the
  /// descent stage is 2.1 m in plan and only 1.65 m deep, so a short bell
  /// disappears behind the octagon's near corner under any wide-angle view
  /// from the side — which is every view of a craft this size.
  static const double _dpsExitM = -2.85;

  /// Footpad centre radius and thickness, METRES — a ~9.1 m stance, which is
  /// the LM's most recognisable dimension and the one a player judging a
  /// landing site is actually reading. Named because [_addLanderFallback]
  /// places the pads, the ladder and [landerAftM] against them.
  static const double _padRadiusM = 4.55;
  static const double _padThicknessM = 0.16;

  /// Aft-most surface of the silhouette drawn for [vesselId], METRES — the
  /// craft-specific answer [fallbackAftM] used to be the only one of.
  ///
  /// For craft on the WHOLE-CRAFT path only; a kitbash craft's tail is its
  /// aft-most part and is read off the part list instead. Exposed so anything
  /// calibrated against the drawn hull ([ExhaustNodes]) can ask which hull that
  /// is, rather than assuming every hand-built vessel is an 11 m CSM.
  static double silhouetteAftM(String vesselId) =>
      _isLander(vesselId) ? landerAftM : fallbackAftM;

  /// Per-vessel eclipse of the sun on the craft (dims its materials when it
  /// is in the body's umbra). Applied HERE, not on the scene's global
  /// directional light, so other bodies stay sunlit. Toggle for A/B.
  static bool eclipseCraft = true;

  /// Original baseColorFactor per craft material, captured on first sight so
  /// the eclipse dim can be re-scaled from the true base every frame rather
  /// than accumulating.
  final Map<fs.PhysicallyBasedMaterial, vm.Vector4> _baseColor = {};

  void update(WorldSnapshot snap, FloatingOrigin origin, {Vector3? starWorld}) {
    final seen = <String>{};
    for (final v in snap.vessels.values) {
      final body = snap.bodies[v.body];
      if (body == null) continue; // body not in snapshot: skip this frame
      seen.add(v.id);

      final world = Vector3(body.px + v.px, body.py + v.py, body.pz + v.pz);
      final pos = origin.worldToScene(world);
      final rot = quatToScene(Quaternion(v.qw, v.qx, v.qy, v.qz));

      final node = _nodes.putIfAbsent(v.id, () {
        final n = fs.Node();
        _scene.add(n);
        return n;
      });
      // Which of the two draw paths this craft is on. Re-evaluated every frame
      // because staging can drop the last catalog part (or, on a craft that
      // docked with one, reveal the first).
      final kitbash = isKitbash(v);
      if (!kitbash) _ensureCraftModel(v.id, node);
      final partsKey = _partsFingerprint(v);
      // Whole-craft: once its model is applied the part list no longer drives
      // anything, so stop rebuilding the silhouette. Kitbash: the part list IS
      // the model, so it always rebuilds on a fingerprint change.
      if (_partsKey[v.id] != partsKey &&
          (kitbash || !_glbApplied.contains(v.id))) {
        _partsKey[v.id] = partsKey;
        if (kitbash) {
          _rebuildKitbash(node, v);
        } else {
          _rebuildParts(node, v);
        }
      }
      node.localTransform = vm.Matrix4.compose(pos, rot, vm.Vector3.all(1.0));
      _applyEclipse(node, _eclipseFactor(body, v, starWorld));

      if (kitbash) {
        // O(parts) matrix writes, no allocation of scene nodes: placement is
        // reapplied per frame for the same reason the whole-craft transform is
        // — so live scale calibration lands immediately.
        _syncPartTransforms(v.id);
      } else {
        // glTF is Y-up; the vessel body frame is Z-up with the nose on +Z.
        // Model units differ per export — [_scaleFor] converts this vessel's
        // model units to METRES (sleuthed by screenshot at a known range), then
        // metres to scene km. Reapplied per frame so live calibration via
        // the dev extension takes effect immediately.
        _glbModels[v.id]?.localTransform = vm.Matrix4.compose(
          vm.Vector3.zero(),
          _noseUp(),
          vm.Vector3.all(lengthToScene(_scaleFor(_assetFor(v.id)))),
        );
      }

      _syncAxisGizmo(v.id, node);
    }

    _nodes.removeWhere((id, node) {
      if (seen.contains(id)) return false;
      _scene.remove(node);
      _partsKey.remove(id);
      _glbApplied.remove(id);
      _glbModels.remove(id);
      // Drops the generation token too: a part bake still decoding for this
      // vessel finds no slot list and discards its realized graph instead of
      // parenting it into a scene the craft has left.
      _partSlots.remove(id);
      _axisNodes.remove(id);
      return true;
    });
  }

  /// Whether [v] draws from its part list. TRUE as soon as ONE part came from
  /// the catalog: an assembled craft is its parts, and a lone hand-built part
  /// welded onto one (a docked test mass, a legacy save) must not demote the
  /// whole stack to an unrelated silhouette.
  ///
  /// FALSE for a craft with no catalog part at all — the hand-built sample
  /// fleet, whose parts carry display names and which were authored AS the
  /// whole-craft model.
  ///
  /// O(parts) map reads, no I/O: called for every vessel every frame.
  static bool isKitbash(VesselSnapshot v) => partsDrawThemselves(v.parts);

  /// [isKitbash] asked of a bare part list.
  ///
  /// Exposed because anything anchored to the craft's GEOMETRY — the exhaust
  /// plume ([ExhaustNodes.nozzleZM]) — has to know WHICH of the two bodies is
  /// on screen before it can measure against it. Deriving a tail position from
  /// the part list of a craft that is drawn as one whole-craft model puts the
  /// anchor on a hull nobody can see.
  static bool partsDrawThemselves(Iterable<PartSnapshot> parts) {
    for (final p in parts) {
      if (PartModelLibrary.isCatalogPart(p.type)) return true;
    }
    return false;
  }

  /// Fingerprint of everything about the part list that changes what is DRAWN:
  /// which parts, where they sit, and how they are turned. Staging changes it;
  /// flying does not. Orientation has to be in here — a part that only rotates
  /// (a leg deploying, an RCS quad re-facing) would otherwise keep the pose it
  /// was built with forever.
  static String _partsFingerprint(VesselSnapshot v) {
    final b = StringBuffer();
    for (final p in v.parts) {
      b.write('${p.type}@${p.ox},${p.oy},${p.oz}');
      if (!p.isUnrotated) b.write('~${p.qw},${p.qx},${p.qy},${p.qz}');
      b.write('|');
    }
    return b.toString();
  }

  /// glTF Y-up -> body Z-up, nose on +Z. Built fresh per call: vector_math
  /// quaternions are mutable, and a shared instance is one careless in-place
  /// op away from rotating the entire fleet.
  static vm.Quaternion _noseUp() =>
      vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), math.pi / 2);

  /// Attach/detach the debug axis gizmo for [vesselId] per [showAxes]. Rebuilt
  /// if a glb reload wiped it from the vessel node's children.
  void _syncAxisGizmo(String vesselId, fs.Node node) {
    final existing = _axisNodes[vesselId];
    if (showAxes) {
      if (existing == null || !node.children.contains(existing)) {
        final gizmo = _buildAxisGizmo();
        node.add(gizmo);
        _axisNodes[vesselId] = gizmo;
      }
    } else if (existing != null) {
      if (node.children.contains(existing)) node.remove(existing);
      _axisNodes.remove(vesselId);
    }
  }

  /// A body-frame axis gizmo: X red / Y green / Z blue (nose) shafts of
  /// [_axisLenM] metres, a crossbar tick at every metre, and a white origin
  /// cube. Geometry is authored in metres; the root's uniform
  /// lengthToScene(1) scale converts to scene units (same convention as
  /// [_addApolloFallback]). Unlit, so the eclipse dim never touches it.
  fs.Node _buildAxisGizmo() {
    final root = fs.Node()
      ..localTransform = vm.Matrix4.compose(
        vm.Vector3.zero(),
        vm.Quaternion.identity(),
        vm.Vector3.all(lengthToScene(1.0)),
      );
    void box(vm.Vector3 posM, vm.Vector3 sizeM, fs.Material mat) {
      root.add(
        fs.Node(mesh: fs.Mesh(fs.CuboidGeometry(sizeM), mat))
          ..localTransform = vm.Matrix4.compose(
            posM,
            vm.Quaternion.identity(),
            vm.Vector3.all(1.0),
          ),
      );
    }

    // Origin marker.
    box(vm.Vector3.zero(), vm.Vector3.all(0.4),
        DepthSafeUnlitMaterial()..baseColorFactor = vm.Vector4(1, 1, 1, 1));

    const w = 0.08; // shaft cross-section, metres
    const len = _axisLenM;
    void axis(int comp, vm.Vector4 color) {
      final mat = DepthSafeUnlitMaterial()..baseColorFactor = color;
      vm.Vector3 along(double s) => comp == 0
          ? vm.Vector3(s, 0, 0)
          : comp == 1
              ? vm.Vector3(0, s, 0)
              : vm.Vector3(0, 0, s);
      // Shaft: thin box spanning 0..len along this axis.
      final shaft = along(len);
      box(along(len / 2),
          vm.Vector3(shaft.x.abs().clamp(w, len), shaft.y.abs().clamp(w, len),
              shaft.z.abs().clamp(w, len)),
          mat);
      // Crossbar tick every metre: wide across the OTHER two axes.
      for (var i = 1; i <= len.floor(); i++) {
        box(along(i.toDouble()),
            vm.Vector3(comp == 0 ? 0.06 : 0.5, comp == 1 ? 0.06 : 0.5,
                comp == 2 ? 0.06 : 0.5),
            mat);
      }
    }

    axis(0, vm.Vector4(1.0, 0.2, 0.2, 1.0)); // X red
    axis(1, vm.Vector4(0.2, 1.0, 0.2, 1.0)); // Y green
    axis(2, vm.Vector4(0.35, 0.5, 1.0, 1.0)); // Z blue (nose)
    return root;
  }

  /// 1 = full sun, 0 = the craft is deep in [body]'s umbra. The sun is at
  /// infinity and the body is near+huge (71 deg radius in low lunar orbit),
  /// so the craft is shadowed whenever the sun direction falls inside the
  /// body's disc as seen from the craft; fades over the last ~3 deg to the
  /// limb (a soft penumbra).
  double _eclipseFactor(BodySnapshot body, VesselSnapshot v, Vector3? star) {
    if (!eclipseCraft || star == null) return 1.0;
    final pv = Vector3(body.px + v.px, body.py + v.py, body.pz + v.pz);
    final toBody = Vector3(body.px, body.py, body.pz) - pv;
    final dist = toBody.length;
    if (dist <= body.radius) return 1.0; // on/inside the surface
    final ang = math.asin((body.radius / dist).clamp(0.0, 1.0));
    final sunAng = math.acos(
        (star - pv).normalized.dot(toBody / dist).clamp(-1.0, 1.0));
    return ((sunAng - ang) / 0.05).clamp(0.0, 1.0);
  }

  /// Scale every PBR material's base colour under [node] by the eclipse
  /// factor (RGB only; alpha kept), re-derived from the captured original so
  /// it never drifts. Floored so a shadowed craft is very dark but not a
  /// pure-black silhouette (a little earthshine/ambient survives). Metallic
  /// hulls lose their sun highlight this way (F0 = base colour); a dielectric
  /// part keeps a faint ~4% highlight, which reads fine.
  void _applyEclipse(fs.Node node, double e) {
    final mesh = node.mesh;
    if (mesh != null) {
      for (final prim in mesh.primitives) {
        final m = prim.material;
        if (m is fs.PhysicallyBasedMaterial) {
          final base = _baseColor.putIfAbsent(m, () => m.baseColorFactor);
          final f = e >= 1.0 ? 1.0 : e.clamp(0.05, 1.0);
          m.baseColorFactor =
              vm.Vector4(base.r * f, base.g * f, base.b * f, base.a);
        }
      }
    }
    for (final child in node.children) {
      _applyEclipse(child, e);
    }
  }

  /// Every bake [prewarm] queues, IN QUEUE ORDER: the two whole-craft models.
  ///
  /// The order is the policy. [PartBakeCache] runs these strictly in sequence,
  /// so whatever is first is warm first, and the Apollo leads because it is
  /// what every craft on the whole-craft path renders EXCEPT a lander.
  ///
  /// Separate from [prewarm] so the policy is assertable without a GPU, a
  /// bundle or a menu.
  static List<String> prewarmAssets() => const [_apolloModel, _landerModel];

  /// Starts loading the whole-craft bakes in the background so a later flight
  /// entry only realizes node graphs from the shared cache (~ms) instead of
  /// paying parse + texture transcode at the moment the scene appears. Call
  /// from the menu.
  ///
  /// POLICY: warm what THIS screen leads to, and nothing else. Every route from
  /// the menu into a flight spawns a hand-built sample craft, which draws a
  /// whole-craft model ([isKitbash] is false for all of them). Part bakes
  /// belong to craft that cannot exist until the player has been through the
  /// VAB, and the VAB warms them itself when it opens
  /// (`CraftEditorViewportState.initState`) — so queueing them here buys
  /// latency for nobody and costs every player who only ever presses FLIGHT
  /// seven extra parses, KTX2 transcodes and UI-isolate texture uploads,
  /// running behind the flight they just entered. Each `realizer.preload()`
  /// uploads on the UI isolate, so that is a run of staggered stalls on the
  /// render thread for art the flight will never draw.
  ///
  /// COST, measured on this checkout: 91 MB (Apollo) + 39 MB (LM) = 130 MB of
  /// parsed document plus preloaded GPU textures, resident for the life of the
  /// process. Both are drawn by the menu's own FLIGHT and ASCENT entries, so
  /// none of it is speculative. (The seven LM part bakes are ~36 MB EACH — 256
  /// MB more — which is as much as a whole vehicle apiece for sub-assemblies
  /// cut from ONE source model, and says the exporter duplicates a shared
  /// texture set. Deduplicating it at bake time is what would make warming them
  /// anywhere cheap.)
  ///
  /// No-op on web — see [PartBakeCache.prewarm] for why prewarming there would
  /// cost the stall it is meant to hide. (Web has no part bakes to warm either,
  /// see [PartModelLibrary.assetFor].)
  static void prewarm() => PartBakeCache.prewarm(prewarmAssets());

  void _ensureCraftModel(String vesselId, fs.Node parent) {
    final asset = _assetFor(vesselId);
    if (PartBakeCache.hasFailed(asset) ||
        _glbApplied.contains(vesselId) ||
        _glbLoading.contains(vesselId)) {
      return;
    }
    _glbLoading.add(vesselId);
    PartBakeCache.realize(asset)
        .then((model) {
          _glbLoading.remove(vesselId);
          final node = _nodes[vesselId];
          if (node == null) return; // vessel vanished while decoding
          // Staging can turn a craft into a kitbash while its whole-craft model
          // is still decoding. Dropping the realized graph here is what stops
          // the two paths from both drawing (this clears ALL children).
          if (_partSlots.containsKey(vesselId)) return;
          for (final child in List.of(node.children)) {
            node.remove(child);
          }
          node.add(model);
          _glbModels[vesselId] = model;
          _glbApplied.add(vesselId);
        })
        .catchError((Object e) {
          _glbLoading.remove(vesselId);
          // Don't hammer this broken/missing bake.
          PartBakeCache.markFailed(asset);
          // ignore: avoid_print
          print('craft model load failed ($asset): $e');
        });
  }

  /// Rebuild a kitbash craft: one SLOT node per part carrying that part's
  /// body-frame placement, holding the part's realized bake once it lands and a
  /// procedural stand-in until then.
  ///
  /// The two-level split (slot = placement, child = asset-space correction) is
  /// what lets the stand-in be swapped for the model without recomputing
  /// placement, and lets [_syncPartTransforms] retune scale without rebuilding.
  ///
  /// Called only on a [_partsFingerprint] change — realizing a bake per part is
  /// milliseconds, not microseconds, and must never be per-frame work.
  void _rebuildKitbash(fs.Node vesselNode, VesselSnapshot v) {
    for (final child in List.of(vesselNode.children)) {
      vesselNode.remove(child);
    }
    // A craft that just became a kitbash drops its whole-craft model with the
    // children above; forget it so [_ensureCraftModel] doesn't think it is
    // still on screen (and so a later flip back re-realizes it).
    _glbApplied.remove(v.id);
    _glbModels.remove(v.id);
    final slots = <_PartSlot>[];
    _partSlots[v.id] = slots;
    for (final p in v.parts) {
      final slot = _PartSlot(p);
      slots.add(slot);
      vesselNode.add(slot.node);
      // Something is on screen from this frame on, whatever happens to the
      // bake — a part must never simply vanish.
      slot.node.add(_standIn(p.type));
      // Null when the part has no art at all, and on web, where no part bake
      // ships — the stand-in above is the whole picture there.
      final asset = PartModelLibrary.assetFor(p.type);
      // A bake that already failed is not retried: [PartBakeCache]'s failure
      // record is per ASSET and process-wide, so one missing part model costs
      // one attempt per process, not one per rebuild.
      if (asset == null || PartBakeCache.hasFailed(asset)) continue;
      _realizePart(v.id, slots, slot, asset);
    }
    // No transform sync here: [update] is the only caller and syncs every
    // kitbash vessel later in the same frame, rebuilt or not.
  }

  /// The procedural stand-in for one part: the shape the VAB drew that part
  /// with, at the size the VAB drew it at.
  ///
  /// It resolves the [PartDef] behind the type key and goes through
  /// [PartPrimitivesByCategory] — the same table the VAB draws with — rather
  /// than through [PartPrimitives.forType], which can only match display words
  /// an id happens to contain. Most of the stock roster contains none of them
  /// and would otherwise be a row of identical grey cubes, so the same craft
  /// would read as two different vehicles either side of the LAUNCH button.
  ///
  /// A part with no [PartDef] behind it keeps the type-key registry: it has no
  /// category to shape it and no declared box to fill.
  fs.Node _standIn(String type) {
    final def = PartModelLibrary.defFor(type);
    return fs.Node(
      mesh: def == null
          ? PartPrimitives.forType(type)
          : PartPrimitivesByCategory.forPart(def),
    )..localTransform = vm.Matrix4.compose(
        vm.Vector3.zero(),
        vm.Quaternion.identity(),
        standInScale(type),
      );
  }

  /// Scale of that stand-in: SCENE units per authored mesh unit, per axis.
  ///
  /// For a catalog part, the factor that makes the DRAWN box equal
  /// [PartDef.size] ([PartPrimitivesByCategory.standInScaleM]) — non-uniform,
  /// because parts are not cubes and the primitives are not all unit cubes.
  /// This is the same number `CraftEditorNodes.standInScale` applies, which is
  /// what makes the craft in the VAB and the craft on the pad one craft.
  ///
  /// For anything else, ONE uniform scale off the longest side the renderer
  /// knows about ([PartModelLibrary.fallbackSizeM], 1 m when it knows nothing):
  /// with no declared box there is nothing per-axis to fill, and a uniform
  /// scale at least never draws a part smaller than it is.
  static vm.Vector3 standInScale(String type) {
    final def = PartModelLibrary.defFor(type);
    if (def == null) {
      return vm.Vector3.all(lengthToScene(PartModelLibrary.fallbackSizeM(type)));
    }
    final f = PartPrimitivesByCategory.standInScaleM(def);
    return vm.Vector3(
        lengthToScene(f.x), lengthToScene(f.y), lengthToScene(f.z));
  }

  /// Realize [asset] into [slot] off the SHARED bake cache. Each part instance
  /// needs its own node graph (a node cannot be parented twice) but shares the
  /// parse and the GPU resources with every other part and vessel using the
  /// same asset.
  void _realizePart(
    String vesselId,
    List<_PartSlot> slots,
    _PartSlot slot,
    String asset,
  ) {
    PartBakeCache.realize(asset)
        .then((model) {
          // The craft may have staged, flipped to whole-craft, or been
          // destroyed while this decoded. The slot list installed by the
          // rebuild that started this load is the generation token: if it is no
          // longer the current one, this graph belongs to a craft that no
          // longer exists and is dropped unparented (no inline dispose — see
          // the web Vertices/ImageShader trap).
          if (!identical(_partSlots[vesselId], slots)) return;
          if (_nodes[vesselId] == null) return;
          for (final child in List.of(slot.node.children)) {
            slot.node.remove(child); // retire the stand-in
          }
          slot.node.add(model);
          slot.modelNode = model;
          _syncPartTransforms(vesselId);
        })
        .catchError((Object e) {
          // Don't hammer this broken/missing bake.
          PartBakeCache.markFailed(asset);
          // ignore: avoid_print
          print('part model load failed ($asset): $e');
        });
  }

  /// Reapply every slot's transform for one kitbash vessel. O(parts) matrix
  /// writes with no allocation beyond the matrices themselves.
  ///
  /// Slot: the part's body-frame offset (METRES -> scene km) and its own
  /// orientation within that frame. Model child: [partModelTransform]. Both are
  /// recomputed per frame, and the binding is re-RESOLVED per frame rather than
  /// read off the slot, so a live calibration ([PartModelLibrary.calibrate],
  /// [PartModelLibrary.scaleMultiplier]) lands on the next frame without a
  /// rebuild.
  void _syncPartTransforms(String vesselId) {
    final slots = _partSlots[vesselId];
    if (slots == null) return;
    for (final slot in slots) {
      final p = slot.part;
      slot.node.localTransform = partSlotTransform(p);
      final modelNode = slot.modelNode;
      if (modelNode == null) continue; // stand-in showing: nothing to correct
      final model = PartModelLibrary.resolve(p.type);
      if (model == null) continue; // unreachable: a bake implies a binding
      modelNode.localTransform = partModelTransform(model);
    }
  }

  /// The transform of ONE part's slot: where that part sits on the craft and
  /// which way it faces, and nothing else.
  ///
  /// `T(offset) * R(orientation)`, with no scale — a slot is a PLACEMENT, and
  /// whatever fills it (a bake through [partModelTransform], a procedural
  /// stand-in through [standInScale]) carries its own asset-space correction.
  /// Keeping the two apart is what lets a bake replace a stand-in without
  /// recomputing where the part is.
  ///
  /// The offset is [PartSnapshot]'s body-frame position in METRES, converted to
  /// scene km; the rotation is the part's own orientation WITHIN the body frame,
  /// so the craft attitude on the parent vessel node still multiplies in from
  /// the left.
  static vm.Matrix4 partSlotTransform(PartSnapshot p) => vm.Matrix4.compose(
        vm.Vector3(
            lengthToScene(p.ox), lengthToScene(p.oy), lengthToScene(p.oz)),
        quatToScene(Quaternion(p.qw, p.qx, p.qy, p.qz)),
        vm.Vector3.all(1.0),
      );

  /// The transform of the model child INSIDE a part slot: everything needed to
  /// take an export's own axes and units into the part frame the slot places.
  ///
  /// `T(offset) * R(rotation * glTF Y-up fix) * S(scale)`, which is exactly what
  /// [vm.Matrix4.compose] builds, and the order is the whole point:
  ///
  ///  * SCALE innermost, so [PartModel.scale] converts model units to metres
  ///    before anything else looks at the mesh;
  ///  * ROTATION next, so [PartModel.rotation] is read in the BODY frame on top
  ///    of the Y-up fix, not in the export's authored axes;
  ///  * OFFSET last, so it is metres along the part's OWN corrected axes. An
  ///    artist who sees the mesh sitting 0.4 m low writes `Vector3(0, 0, 0.4)`
  ///    and it moves up, whatever units the model was authored in and whichever
  ///    way up it was baked. Scaling the offset with the mesh would silently
  ///    redefine it as model units; rotating it would redefine it as authored
  ///    axes. Both make a screenshot-driven calibration unrepeatable.
  ///
  /// The slot's own placement multiplies in from the left, so the full per-part
  /// chain is `T(positionInVessel) * R(rotationInVessel) * this`. The offset
  /// therefore moves ART ONLY: the slot — and with it every attach node, mass
  /// and inertia the domain anchored to the part origin — does not move.
  static vm.Matrix4 partModelTransform(PartModel model) => vm.Matrix4.compose(
        relToScene(model.offset),
        quatToScene(model.rotation) * _noseUp(),
        vm.Vector3.all(
            lengthToScene(model.scale * PartModelLibrary.scaleMultiplier)),
      );

  void _rebuildParts(fs.Node vesselNode, VesselSnapshot v) {
    for (final child in List.of(vesselNode.children)) {
      vesselNode.remove(child);
    }
    // Leaving the kitbash path (staging dropped the last catalog part):
    // forgetting the slots also tells any in-flight part realize to bail.
    _partSlots.remove(v.id);
    // The craft is represented by its baked model ([_assetFor]); the procedural
    // stand-in is a silhouette of THAT model, used wherever it isn't available
    // (no asset — the usual case on a fresh clone, since neither the sources
    // nor the bakes may be redistributed — or the web build before its bake
    // decodes). We don't render the raw part list here — a hand-built part
    // carries a display name and nothing the catalog can size or shape it from,
    // so the silhouette reads as a real ship instead of a cluster of 1 m grey
    // blocks.
    //
    // ONE silhouette per model, picked by the SAME test that picked the model
    // ([_isLander]). Standing a lander in as a CSM is not a rough stand-in but
    // a different vehicle: the shapes share no stage, the tails are 3 m apart
    // ([silhouetteAftM]), and a descent is flown by reading the legs.
    if (_isLander(v.id)) {
      _addLanderFallback(vesselNode);
    } else {
      _addApolloFallback(vesselNode);
    }
  }

  /// A rough Apollo Command + Service Module, nose on +Z: a blunt truncated-
  /// cone Command Module, a cylindrical Service Module, a flared SPS engine
  /// bell, and a stub high-gain antenna dish — ~11 m, the same scale as the
  /// baked model so the two are interchangeable. Stands in wherever the
  /// .fsceneb isn't available (no asset, or the web build before its bake
  /// decodes).
  ///
  /// Its AFT-MOST surface is [fallbackAftM].
  ///
  /// Built from [fs.CylinderGeometry] (outward winding + generated normals):
  /// the hand-rolled cone/cylinder primitives had inward winding (backfaces).
  /// Its axis is +Y — top row = [topRadius], bottom = [bottomRadius] — so the
  /// +90 deg X rotation maps +Y to +Z, putting [topRadius] at the nose and
  /// [bottomRadius] at the aft. Geometry is authored in METRES; the uniform
  /// lengthToScene(1) node scale converts to scene km.
  void _addApolloFallback(fs.Node vesselNode) {
    final noseUp = _noseUp();
    void add({
      required double noseR, // radius at the +Z (forward) end
      required double aftR, //  radius at the -Z (aft) end
      required double height,
      required double z, //     centre along +Z, metres
      required fs.Material mat,
    }) {
      vesselNode.add(
        fs.Node(
          mesh: fs.Mesh(
            fs.CylinderGeometry(
              topRadius: noseR,
              bottomRadius: aftR,
              height: height,
              radialSegments: 28,
            ),
            mat,
          ),
        )..localTransform = vm.Matrix4.compose(
          vm.Vector3(0, 0, lengthToScene(z)),
          noseUp,
          vm.Vector3.all(lengthToScene(1.0)),
        ),
      );
    }

    // Command Module: blunt truncated cone — narrow nose (+Z), wide base
    // mating the SM (-Z).
    add(noseR: 0.7, aftR: 1.95, height: 3.2, z: 3.9, mat: PartPrimitives.hull());
    // Service Module: straight cylinder, CM-base diameter.
    add(noseR: 1.95, aftR: 1.95, height: 7.0, z: -1.3, mat: PartPrimitives.hull());
    // SPS engine bell: narrow throat toward the body (+Z), wide OPENING aft
    // (-Z). Its exit plane is the tail of the whole craft, so it is placed FROM
    // [fallbackAftM] rather than the other way round.
    add(
      noseR: 0.35,
      aftR: 1.2,
      height: _spsBellM,
      z: fallbackAftM + _spsBellM / 2,
      mat: PartPrimitives.dark(),
    );
    // High-gain antenna: a shallow dish (wide rim forward) on a short boom off
    // the aft quarter.
    vesselNode.add(
      fs.Node(
        mesh: fs.Mesh(
          fs.CylinderGeometry(
            topRadius: 0.9,
            bottomRadius: 0.05,
            height: 0.25,
            radialSegments: 20,
          ),
          PartPrimitives.panel(),
        ),
      )..localTransform = vm.Matrix4.compose(
        vm.Vector3(lengthToScene(2.6), 0, lengthToScene(-3.5)),
        noseUp,
        vm.Vector3.all(lengthToScene(1.0)),
      ),
    );
  }

  /// A rough Apollo Lunar Module, cabin facing +X and nose (docking tunnel) on
  /// +Z: a foil-wrapped octagonal descent stage on four splayed legs, the DPS
  /// bell hanging under it, and the ascent stage's blunt cabin, windows, RCS
  /// quads and docking tunnel above. ~6.8 m tall over a ~9 m footpad span, the
  /// same scale as `lander.fsceneb` so the two are interchangeable.
  ///
  /// Stands in for every craft [_isLander] claims, wherever that bake isn't
  /// available (no asset — the usual case on a fresh clone — or the web build
  /// before its bake decodes). Its AFT-MOST surface is [landerAftM].
  ///
  /// The LM is the one craft where the CSM silhouette was actively misleading:
  /// a lander is read by its stance, and a cone-on-a-cylinder gives no hint of
  /// which way is down or how far the legs reach, which is exactly what a
  /// player judging a descent is looking at.
  ///
  /// Authored in METRES under a single root carrying the lengthToScene(1)
  /// conversion, so every number below reads as the real vehicle's dimensions
  /// (same convention as [_buildAxisGizmo]) rather than as scene units.
  void _addLanderFallback(fs.Node vesselNode) {
    final root = fs.Node()
      ..localTransform = vm.Matrix4.compose(
        vm.Vector3.zero(),
        vm.Quaternion.identity(),
        vm.Vector3.all(lengthToScene(1.0)),
      );
    vesselNode.add(root);

    // A body of revolution about the craft's Z axis, spanning [bottomZ]..[topZ]
    // — the octagonal stages (8 segments), the engine bell and the dishes.
    // [azimuthRad] spins the ring: with 8 segments a corner otherwise lands on
    // +X, and the LM wears a FLAT there, because that face is where the front
    // leg's outrigger comes out.
    void revolve({
      required double topR,
      required double bottomR,
      required double topZ,
      required double bottomZ,
      required fs.Material mat,
      int segments = 8,
      double azimuthRad = 0,
    }) {
      root.add(
        fs.Node(
          mesh: fs.Mesh(
            fs.CylinderGeometry(
              topRadius: topR,
              bottomRadius: bottomR,
              height: topZ - bottomZ,
              radialSegments: segments,
            ),
            mat,
          ),
        )..localTransform = vm.Matrix4.compose(
          vm.Vector3(0, 0, (topZ + bottomZ) / 2),
          vm.Quaternion.axisAngle(vm.Vector3(0, 0, 1), azimuthRad) * _noseUp(),
          vm.Vector3.all(1.0),
        ),
      );
    }

    // A tube between two points in the body frame: the landing-gear struts and
    // the RCS outriggers, which are the only pieces here that aren't aligned to
    // an axis. Rotating +Y (the cylinder's own axis) onto the segment is what
    // lets the leg geometry be written as the two ENDS it actually has, rather
    // than as an angle someone has to re-derive after moving a footpad.
    void strut(vm.Vector3 a, vm.Vector3 b, double radius, fs.Material mat) {
      final along = b - a;
      final len = along.length;
      if (len <= 1e-6) return;
      root.add(
        fs.Node(
          mesh: fs.Mesh(
            fs.CylinderGeometry(
              topRadius: radius,
              bottomRadius: radius,
              height: len,
              radialSegments: 6,
            ),
            mat,
          ),
        )..localTransform = vm.Matrix4.compose(
          (a + b) * 0.5,
          vm.Quaternion.fromTwoVectors(vm.Vector3(0, 1, 0), along / len),
          vm.Vector3.all(1.0),
        ),
      );
    }

    // A flat plate: windows, hatches and the porch. [pitchRad] tips it about
    // the body Y axis, which cants the LM's windows down the way the real
    // bulkhead does.
    void plate(vm.Vector3 centre, vm.Vector3 size, fs.Material mat,
        {double pitchRad = 0}) {
      root.add(
        fs.Node(mesh: fs.Mesh(fs.CuboidGeometry(size), mat))
          ..localTransform = vm.Matrix4.compose(
            centre,
            vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), pitchRad),
            vm.Vector3.all(1.0),
          ),
      );
    }

    vm.Vector3 at(double azimuthRad, double radius, double z) => vm.Vector3(
        radius * math.cos(azimuthRad), radius * math.sin(azimuthRad), z);

    // Descent stage: the octagon, 4.2 m across corners and 1.65 m deep, hung
    // below the stage interface (z = 0) so staging the ascent stage away leaves
    // the craft origin where the ascent stage's own model expects it.
    const octantRad = math.pi / 8; // half a segment: puts a flat on +X
    revolve(
      topR: 2.11,
      bottomR: 2.11,
      topZ: 0.0,
      bottomZ: -1.65,
      mat: PartPrimitives.foil(),
      azimuthRad: octantRad,
    );
    // Descent engine bell: narrow throat inside the stage, wide exit aft. Its
    // exit plane is what [ExhaustNodes.defaultNozzleZM] has to sit at or just
    // inside, or the plume burns in the gap between bell and ground.
    revolve(
      topR: 0.26,
      bottomR: 0.78,
      topZ: -1.50,
      bottomZ: _dpsExitM,
      mat: PartPrimitives.dark(),
      segments: 16,
    );

    // Landing gear: one leg on each of +X (the front leg, under the cabin and
    // carrying the porch and ladder), +Y, -X and -Y. The primary strut hangs
    // from the TOP of the descent stage and the two secondaries brace out to
    // its knee from the BOTTOM corners — that A-frame, and not the inverted
    // one, is what makes the stance read as a lander's rather than a tripod's,
    // and it is also what puts the strut's top end under the porch.
    for (var i = 0; i < 4; i++) {
      final az = i * math.pi / 2;
      final hip = at(az, 1.85, -0.30);
      final pad = at(az, _padRadiusM, landerAftM + _padThicknessM / 2);
      strut(hip, pad, 0.11, PartPrimitives.frame());
      final knee = hip + (pad - hip) * 0.55;
      for (final side in const [-0.22, 0.22]) {
        strut(at(az + side, 1.95, -1.55), knee, 0.07, PartPrimitives.frame());
      }
      // Footpad: a shallow foil-covered dish, bottom face on [landerAftM].
      root.add(
        fs.Node(
          mesh: fs.Mesh(
            fs.CylinderGeometry(
              topRadius: 0.47,
              bottomRadius: 0.40,
              height: _padThicknessM,
              radialSegments: 12,
            ),
            PartPrimitives.foil(),
          ),
        )..localTransform = vm.Matrix4.compose(pad, _noseUp(), vm.Vector3.all(1.0)),
      );
    }
    // Porch and ladder on the front leg — the two details that say which face
    // the crew comes out of, and the only asymmetry in the descent stage. The
    // porch sits just under the stage interface, a step below the forward
    // hatch, and the ladder runs from it down the front primary strut, meeting
    // it at the pad.
    plate(vm.Vector3(2.30, 0, -0.12), vm.Vector3(0.80, 0.95, 0.08),
        PartPrimitives.frame());
    strut(at(0, 2.05, -0.05), at(0, _padRadiusM - 0.30, -3.20), 0.14,
        PartPrimitives.frame());

    // Ascent stage: a foil skirt off the stage interface, then the midsection,
    // with the crew cabin bulging forward over the front leg.
    //
    // The midsection is kept NARROWER than the cabin on purpose. Sized the
    // other way the drum vanishes inside it and the whole ascent stage reads as
    // one smooth barrel — which is the CSM's shape, i.e. exactly the confusion
    // this silhouette exists to end. Front-heavy is the LM's proportion.
    revolve(
      topR: 1.25,
      bottomR: 1.55,
      topZ: 0.50,
      bottomZ: 0.0,
      mat: PartPrimitives.foil(),
      azimuthRad: octantRad,
    );
    revolve(
      topR: 1.25,
      bottomR: 1.25,
      topZ: 2.30,
      bottomZ: 0.50,
      mat: PartPrimitives.hull(),
      azimuthRad: octantRad,
    );
    // Crew cabin: a drum lying along +X, so its round face is the LM's face.
    root.add(
      fs.Node(
        mesh: fs.Mesh(
          fs.CylinderGeometry(
            topRadius: 1.15,
            bottomRadius: 1.15,
            height: 1.25,
            radialSegments: 14,
          ),
          PartPrimitives.hull(),
        ),
      )..localTransform = vm.Matrix4.compose(
        vm.Vector3(1.05, 0, 1.40),
        vm.Quaternion.axisAngle(vm.Vector3(0, 0, 1), -math.pi / 2),
        vm.Vector3.all(1.0),
      ),
    );
    // The two forward windows, canted down the way the real bulkhead is (that
    // downward cant is what the LM's face reads as), and the forward hatch the
    // porch leads to.
    for (final y in const [-0.52, 0.52]) {
      plate(vm.Vector3(1.68, y, 1.68), vm.Vector3(0.08, 0.50, 0.46),
          PartPrimitives.dark(), pitchRad: 0.50);
    }
    plate(vm.Vector3(1.70, 0, 0.82), vm.Vector3(0.08, 0.72, 0.80),
        PartPrimitives.dark());

    // RCS quads on their outriggers, at the four corners between the legs.
    for (var i = 0; i < 4; i++) {
      final az = math.pi / 4 + i * math.pi / 2;
      strut(at(az, 1.15, 1.90), at(az, 1.60, 1.90), 0.09,
          PartPrimitives.frame());
      root.add(
        fs.Node(
          mesh: fs.Mesh(
            fs.CuboidGeometry(vm.Vector3(0.42, 0.42, 0.42)),
            PartPrimitives.dark(),
          ),
        )..localTransform = vm.Matrix4.compose(
          at(az, 1.78, 1.90),
          vm.Quaternion.axisAngle(vm.Vector3(0, 0, 1), az),
          vm.Vector3.all(1.0),
        ),
      );
    }

    // Docking tunnel on the nose, and the rendezvous radar dish leaning
    // forward off it — the LM's top-side silhouette from a CSM's window.
    revolve(
      topR: 0.42,
      bottomR: 0.46,
      topZ: 2.82,
      bottomZ: 2.30,
      mat: PartPrimitives.hull(),
      segments: 14,
    );
    root.add(
      fs.Node(
        mesh: fs.Mesh(
          fs.CylinderGeometry(
            topRadius: 0.46,
            bottomRadius: 0.06,
            height: 0.22,
            radialSegments: 16,
          ),
          PartPrimitives.panel(),
        ),
      )..localTransform = vm.Matrix4.compose(
        vm.Vector3(0.62, 0, 2.55),
        vm.Quaternion.axisAngle(vm.Vector3(0, 1, 0), 0.55) * _noseUp(),
        vm.Vector3.all(1.0),
      ),
    );
    // S-band steerable antenna, off the starboard side: the LM is not
    // symmetric, and the one dish that breaks it is worth the node.
    root.add(
      fs.Node(
        mesh: fs.Mesh(
          fs.CylinderGeometry(
            topRadius: 0.38,
            bottomRadius: 0.05,
            height: 0.18,
            radialSegments: 14,
          ),
          PartPrimitives.panel(),
        ),
      )..localTransform = vm.Matrix4.compose(
        vm.Vector3(-0.10, 1.42, 2.15),
        vm.Quaternion.axisAngle(vm.Vector3(1, 0, 0), -0.9) * _noseUp(),
        vm.Vector3.all(1.0),
      ),
    );
  }
}

/// One part of a kitbash craft on screen.
///
/// [node] is the slot: it holds the part's placement in the vessel body frame
/// and NOTHING else, so its single child can be swapped from the procedural
/// stand-in to the realized bake without touching that placement. [part] is the
/// snapshot the slot was built from — it cannot change without changing the
/// parts fingerprint, which rebuilds the slots outright.
class _PartSlot {
  _PartSlot(this.part);

  final PartSnapshot part;

  final fs.Node node = fs.Node();

  /// The realized bake, once it has landed. Null while the stand-in is showing.
  fs.Node? modelNode;
}

/// Procedural primitive meshes for part type keys. All geometry is unit
/// scale (1 m before the node's scale), Z-up, centred on the part origin.
class PartPrimitives {
  static final Map<String, fs.Mesh Function()> _registry = {
    'capsule': () => fs.Mesh(cone(), hull()),
    'pod': () => fs.Mesh(cone(), hull()),
    'fuselage': () => fs.Mesh(cylinder(), hull()),
    'tank': () => fs.Mesh(cylinder(), hull()),
    'engine': () => fs.Mesh(cone(flip: true), dark()),
    // Named separately from 'engine': a thruster reads as an engine but shares
    // no substring with it, and every LM part would otherwise land on the
    // unknown-key cuboid.
    'thruster': () => fs.Mesh(cone(flip: true), dark()),
    'rcs': () => fs.Mesh(fs.CuboidGeometry(vm.Vector3(1.0, 1.0, 1.0)), dark()),
    'leg': () => fs.Mesh(slab(), hull()),
    'wing': () => fs.Mesh(slab(), hull()),
    'panel': () => fs.Mesh(slab(), panel()),
  };

  /// Mesh for a part type key; longest matching registry key wins (so
  /// 'fuselage_mk2' hits 'fuselage'), cuboid placeholder otherwise.
  static fs.Mesh forType(String type) {
    final t = type.toLowerCase();
    for (final e in _registry.entries) {
      if (t.contains(e.key)) return e.value();
    }
    return fs.Mesh(fs.CuboidGeometry(vm.Vector3(1.0, 1.0, 1.0)), hull());
  }

  static fs.Material hull() => fs.PhysicallyBasedMaterial()
    ..baseColorFactor = vm.Vector4(0.75, 0.76, 0.78, 1.0)
    ..roughnessFactor = 0.45
    ..metallicFactor = 0.85;

  static fs.Material dark() => fs.PhysicallyBasedMaterial()
    ..baseColorFactor = vm.Vector4(0.2, 0.2, 0.22, 1.0)
    ..roughnessFactor = 0.6
    ..metallicFactor = 0.9;

  static fs.Material panel() => fs.PhysicallyBasedMaterial()
    ..baseColorFactor = vm.Vector4(0.12, 0.18, 0.45, 1.0)
    ..roughnessFactor = 0.3
    ..metallicFactor = 0.4;

  /// Matte light structure — landing-gear struts, outriggers, a porch.
  ///
  /// [hull] would be the obvious finish and is the wrong one: at 0.85 metallic
  /// its base colour IS its reflectance, so a 0.1 m rod facing anywhere but the
  /// sun reads as black wire. A member thin enough that a viewer sees only one
  /// of its faces needs a mostly-dielectric finish to stay a light structure
  /// under every heading.
  static fs.Material frame() => fs.PhysicallyBasedMaterial()
    ..baseColorFactor = vm.Vector4(0.72, 0.72, 0.70, 1.0)
    ..roughnessFactor = 0.65
    ..metallicFactor = 0.12;

  /// Amber thermal blanket — the gold kapton a descent stage is wrapped in.
  /// Not a part finish: nothing in the catalog resolves to it, and it exists so
  /// [VesselNodes] can tell the LM's two stages apart at a glance from the
  /// range a lander is normally seen at, where the shapes have merged into one
  /// blob but the colours have not.
  static fs.Material foil() => fs.PhysicallyBasedMaterial()
    ..baseColorFactor = vm.Vector4(0.82, 0.60, 0.20, 1.0)
    ..roughnessFactor = 0.35
    ..metallicFactor = 1.0;

  /// Cone: apex +Z (nose), unit height, unit base diameter. [flip] points
  /// the apex -Z (engine bell).
  static fs.MeshGeometry cone({int segments = 12, bool flip = false}) {
    final s = flip ? -1.0 : 1.0;
    final positions = <double>[];
    final indices = <int>[];
    // Apex + base ring + base centre.
    positions.addAll([0, 0, 0.5 * s]);
    for (var i = 0; i < segments; i++) {
      final a = 2 * math.pi * i / segments;
      positions.addAll([0.5 * math.cos(a), 0.5 * math.sin(a), -0.5 * s]);
    }
    positions.addAll([0, 0, -0.5 * s]);
    final centre = segments + 1;
    for (var i = 0; i < segments; i++) {
      final b0 = 1 + i, b1 = 1 + (i + 1) % segments;
      // Side + base cap; winding flips with s so faces stay outward.
      if (flip) {
        indices.addAll([0, b1, b0, centre, b0, b1]);
      } else {
        indices.addAll([0, b0, b1, centre, b1, b0]);
      }
    }
    return fs.MeshGeometry.fromArrays(positions: Float32List.fromList(positions), indices: indices);
  }

  /// Cylinder along Z: unit height, unit diameter.
  static fs.MeshGeometry cylinder({int segments = 12}) {
    final positions = <double>[];
    final indices = <int>[];
    for (var i = 0; i < segments; i++) {
      final a = 2 * math.pi * i / segments;
      final x = 0.5 * math.cos(a), y = 0.5 * math.sin(a);
      positions.addAll([x, y, 0.5]); // top ring: 2i
      positions.addAll([x, y, -0.5]); // bottom ring: 2i+1
    }
    final top = segments * 2, bottom = segments * 2 + 1;
    positions.addAll([0, 0, 0.5]);
    positions.addAll([0, 0, -0.5]);
    for (var i = 0; i < segments; i++) {
      final j = (i + 1) % segments;
      final t0 = 2 * i, b0 = 2 * i + 1, t1 = 2 * j, b1 = 2 * j + 1;
      indices.addAll([t0, b0, t1, t1, b0, b1]); // side quad
      indices.addAll([top, t0, t1]); // top cap
      indices.addAll([bottom, b1, b0]); // bottom cap
    }
    return fs.MeshGeometry.fromArrays(positions: Float32List.fromList(positions), indices: indices);
  }

  /// Thin slab (wing/panel): 1 x 0.4 x 0.06.
  static fs.MeshGeometry slab() {
    // CuboidGeometry is already a MeshGeometry; non-uniform extents.
    return fs.CuboidGeometry(vm.Vector3(1.0, 0.4, 0.06));
  }
}
