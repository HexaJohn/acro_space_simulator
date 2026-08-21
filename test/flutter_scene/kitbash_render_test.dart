// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/craft/attach_targets.dart';
import 'package:acro_space_simulator/domain/craft/craft_design.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/parts/lem_parts.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/vessel_assembler.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/coord_convert.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/exhaust_nodes.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/part_model_library.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/part_primitives_category.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/vessel_nodes.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// The parts of the per-part ("kitbash") render path that can be checked
/// without a GPU: what a part's art transform composes to, which bakes are
/// warmed and in what order, where a plume is anchored, and whether a live
/// calibration reaches the renderer.
///
/// `fs.SceneView` needs a real Impeller surface, so nothing here can draw. Each
/// seam below is therefore a pure function that the render path calls and a
/// test can call too — the alternative is that every one of these is settled by
/// squinting at a screenshot, which is how they were wrong in the first place.
void main() {
  final catalog = PartCatalog.standard();

  /// A part in the vessel body frame at [oz] metres along the craft axis.
  PartSnapshot part(String type, double oz) =>
      PartSnapshot(id: '$type-1', type: type, ox: 0, oy: 0, oz: oz);

  tearDown(() {
    // Both are process-global dev knobs; a test that leaves one set would
    // silently recalibrate every later test in this isolate.
    PartModelLibrary.resetCalibration();
    PartModelLibrary.scaleMultiplier = 1.0;
  });

  group('a part model is placed by scale, then rotation, then offset', () {
    // The composition order is the contract between the catalog author and the
    // renderer: modelOffset is METRES in the part's own corrected frame, so
    // "the mesh sits 0.4 m low" is always Vector3(0, 0, 0.4) whatever units or
    // authored orientation the export happens to have.
    PartModel model({
      double scale = 1.0,
      Quaternion rotation = Quaternion.identity,
      Vector3 offset = Vector3.zero,
    }) =>
        PartModel(
            asset: 'assets/mesh/x.fsceneb',
            scale: scale,
            rotation: rotation,
            offset: offset);

    test('the offset lands in metres, converted to scene units', () {
      final m = VesselNodes.partModelTransform(model(offset: Vector3(0, 0, 0.4)));
      final t = m.getTranslation();
      // Tolerances are float32-sized: vector_math matrices are float32, so a
      // scene-unit value of 4e-4 carries ~5e-11 of representation error.
      expect(t.x, closeTo(0, 1e-10));
      expect(t.y, closeTo(0, 1e-10));
      expect(t.z, closeTo(lengthToScene(0.4), 1e-10),
          reason: 'metres -> scene km, like every other domain length');
    });

    test('the offset is NOT scaled with the mesh', () {
      // If it were, the number would silently mean "model units" and every
      // recalibration of modelScale would move the mesh off the origin again.
      final small = VesselNodes.partModelTransform(
          model(scale: 1.0, offset: Vector3(0, 0, 0.4)));
      final big = VesselNodes.partModelTransform(
          model(scale: 2.40, offset: Vector3(0, 0, 0.4)));
      expect(big.getTranslation().z, closeTo(small.getTranslation().z, 1e-10));
    });

    test('the offset is NOT rotated by the model correction', () {
      // A 180-degree flip is the export correction most likely to be needed;
      // applying the offset before it would send "up" straight down.
      final flipped = VesselNodes.partModelTransform(model(
        rotation: Quaternion.axisAngle(Vector3.unitX, 3.141592653589793),
        offset: Vector3(0, 0, 0.4),
      ));
      expect(flipped.getTranslation().z, closeTo(lengthToScene(0.4), 1e-10));
    });

    test('scale and the glTF Y-up fix still apply to the mesh itself', () {
      // A model-space point 1 unit "up" (glTF +Y) must land on body +Z at
      // scale metres, and then be displaced by the offset.
      final m = VesselNodes.partModelTransform(
          model(scale: 2.40, offset: Vector3(0, 0, 0.4)));
      final p = m.transform3(vm.Vector3(0, 1, 0));
      expect(p.x, closeTo(0, 1e-9));
      expect(p.y, closeTo(0, 1e-9));
      expect(p.z, closeTo(lengthToScene(2.40 + 0.4), 1e-9));
    });

    test('the global multiplier scales the mesh, not the placement', () {
      PartModelLibrary.scaleMultiplier = 2.0;
      final m = VesselNodes.partModelTransform(
          model(scale: 1.0, offset: Vector3(0, 0, 0.4)));
      expect(m.transform3(vm.Vector3(0, 1, 0)).z,
          closeTo(lengthToScene(2.0 + 0.4), 1e-9));
      expect(m.getTranslation().z, closeTo(lengthToScene(0.4), 1e-10));
    });

    test('the offset the renderer draws with is the one the catalog wrote', () {
      // The registry is SEEDED from the catalog and restates nothing, so this
      // is the seam that keeps a calibration settled by screenshot and pasted
      // into a PartDef from having to be pasted a second time into the
      // renderer. Asserting the relation rather than the values means the pass
      // that fills these in cannot make the test stale.
      for (final def in catalog.all.where((d) => d.modelAsset != null)) {
        final model = PartModelLibrary.lookup(def.id)!;
        expect(model.offset, def.modelOffset, reason: def.id);
        expect(model.rotation, def.modelRotation, reason: def.id);
        expect(model.scale, def.modelScale, reason: def.id);
      }
    });

    test('the ascent stage offset seats the export on its own stack node', () {
      // The sign convention, on a real part. The export is authored 1.4 m HIGH
      // of the part origin, so the correction is NEGATIVE — a mesh that sits
      // high moves down. Get that backwards and the mesh doubles its error
      // instead of losing it, which is a 2.8 m miss on this part.
      final def = catalog.byId('eagle-command-pod')!;
      expect(def.modelOffset.z, lessThan(0),
          reason: 'an export authored high is brought back DOWN');
      expect(def.modelOffset, const Vector3(0, 0, -1.4));

      // Corrected, the export straddles the origin, so its base skirt lands on
      // the node the descent stage mates to. That is the whole point of the
      // number: attach nodes are anchored to the part origin and never move,
      // so the art has to come to them.
      expect(-def.size.z / 2, closeTo(def.node('stage-bottom')!.position.z, 0.02),
          reason: 'a centred 3.46 m stage puts its base within 2 cm of the '
              'stage-bottom node at -1.73 m');

      // This part needs no rotation correction, so the placement is a pure
      // translation down the craft axis, in scene units.
      final t = VesselNodes.partModelTransform(
              PartModelLibrary.resolve('eagle-command-pod')!)
          .getTranslation();
      expect(t.x, closeTo(0, 1e-10));
      expect(t.y, closeTo(0, 1e-10));
      expect(t.z, closeTo(lengthToScene(-1.4), 1e-10));
    });

    test('a rotated export reads its offset in the PART frame, not its own', () {
      // The landing leg is the only shipped part with BOTH a non-identity
      // modelRotation and an off-axis modelOffset, so it is the one part that
      // can tell the two frames apart. Its correction is a full axis CYCLE
      // (X->Y->Z->X); if the offset were applied before it, (-1.26, 0, 0.59)
      // would come out as (0.59, -1.26, 0) — the mesh 1.4 m out along the wrong
      // horizontal axis, with the vertical seating lost entirely.
      final def = catalog.byId('eagle-legs')!;
      expect(def.modelRotation, isNot(Quaternion.identity));
      expect(def.modelOffset, const Vector3(-1.26, 0, 0.59));

      final t = VesselNodes.partModelTransform(
              PartModelLibrary.resolve('eagle-legs')!)
          .getTranslation();
      expect(t.x, closeTo(lengthToScene(-1.26), 1e-10));
      expect(t.y, closeTo(0, 1e-10));
      expect(t.z, closeTo(lengthToScene(0.59), 1e-10));

      // The value the cycle WOULD have produced, so this test says what it is
      // ruling out rather than only what it expects.
      final rotated = def.modelRotation.rotate(def.modelOffset);
      expect(rotated.x, closeTo(0.59, 1e-9));
      expect(rotated.y, closeTo(-1.26, 1e-9));
      expect(t.x, isNot(closeTo(lengthToScene(rotated.x), 1e-9)));
    });
  });

  group('the menu prewarms what the menu leads to, and no more', () {
    test('the two whole-craft models, in order, and nothing else', () {
      // FLIGHT and ASCENT spawn hand-built sample craft, which draw the
      // whole-craft model; those are the only bakes a route out of the menu can
      // reach. The loads are serialised, so order is policy: whatever is first
      // is warm first.
      expect(VesselNodes.prewarmAssets(),
          ['assets/mesh/apollo.fsceneb', 'assets/mesh/lander.fsceneb']);
    });

    test('no part bake rides along', () {
      // Seven ~36 MB bakes behind the two the player is waiting on. Each
      // realizer.preload() uploads on the UI isolate, so queueing art no menu
      // route draws buys a run of staggered upload stalls DURING the flight the
      // player entered from this menu. The VAB warms these itself on open
      // (CraftEditorViewportState.initState), which is also the only way to
      // reach a craft that draws one.
      final assets = VesselNodes.prewarmAssets();
      for (final def in catalog.all.where((d) => d.modelAsset != null)) {
        expect(assets, isNot(contains(def.modelAsset)),
            reason: '${def.id} is VAB art; the menu must not pay for it');
      }
    });

    test('nothing is queued twice', () {
      final assets = VesselNodes.prewarmAssets();
      expect(assets.toSet().length, assets.length);
    });
  });

  group('an assembled craft is drawn as the stack that was assembled', () {
    // The invariant behind "what you build is what you fly", in the only form
    // a headless test can hold: a craft made of catalog parts resolves to ONE
    // SLOT PER PART, each at that part's own place, each drawn at that part's
    // own box. Everything below is a number about what the scene contains —
    // the alternative is a screenshot, and a craft rendered as an unrelated
    // whole-craft model passes every other test in this file.
    const assembler = VesselAssembler();

    VesselSnapshot stockStack(int tanks) {
      final d = CraftDesign(name: 'Stock stack')
        ..addPart(def: catalog.byId('mk1-capsule')!, instanceId: 'pod');
      var below = 'pod';
      for (var i = 1; i <= tanks; i++) {
        d.attachPart(
          def: catalog.byId('fl-t400')!,
          instanceId: 'tank-$i',
          toInstanceId: below,
          parentNode: 'bottom',
          childNode: 'top',
        );
        below = 'tank-$i';
      }
      d.attachPart(
        def: catalog.byId('merlin-1d')!,
        instanceId: 'merlin',
        toInstanceId: below,
        parentNode: 'bottom',
        childNode: 'mount',
      );
      return VesselSnapshot.of(assembler.assemble(
        id: 'pad-craft',
        name: d.name,
        ownerId: 'player',
        parts: d.parts,
        state: const StateVector(
            position: Vector3(6371000, 0, 0), velocity: Vector3.zero),
        dominantBody: const BodyId('earth'),
      ));
    }

    test('one slot per part, at the part positions', () {
      final snap = stockStack(2);
      expect(VesselNodes.isKitbash(snap), isTrue,
          reason: 'a craft with no bakes is still the craft that was built');
      expect(snap.parts, hasLength(4), reason: 'pod, 2 tanks, Merlin');

      final drawn = [
        for (final p in snap.parts)
          VesselNodes.partSlotTransform(p).getTranslation()
      ];
      expect(drawn, hasLength(snap.parts.length),
          reason: 'four parts are four slots, not one silhouette');
      // Distinct: a placement bug that collapsed the stack onto the origin
      // would still produce the right COUNT of nodes.
      expect({for (final t in drawn) '${t.x},${t.y},${t.z}'},
          hasLength(snap.parts.length));
      for (var i = 0; i < snap.parts.length; i++) {
        final p = snap.parts.elementAt(i);
        // Float32-sized tolerance: vector_math matrices are float32, so a
        // scene-unit value of ~6e-3 carries ~4e-10 of representation error.
        expect(drawn[i].x, closeTo(lengthToScene(p.ox), 1e-9), reason: p.id);
        expect(drawn[i].y, closeTo(lengthToScene(p.oy), 1e-9), reason: p.id);
        expect(drawn[i].z, closeTo(lengthToScene(p.oz), 1e-9), reason: p.id);
      }
      // The stack the attach solver actually produces, so the numbers above are
      // pinned to real geometry rather than to whatever the solver returns.
      expect({for (final p in snap.parts) p.id: p.oz}, {
        'pod': closeTo(0.0, 1e-9),
        'tank-1': closeTo(-1.65, 1e-9),
        'tank-2': closeTo(-3.55, 1e-9),
        'merlin': closeTo(-5.95, 1e-9),
      });
    });

    test('a slot carries placement only, never scale', () {
      // A slot that scaled would multiply into the bake's own model scale, so a
      // part with art would draw at scale^2 the moment it landed.
      final m = VesselNodes.partSlotTransform(part('fl-t400', -1.65));
      final s = vm.Vector3.zero();
      m.decompose(vm.Vector3.zero(), vm.Quaternion.identity(), s);
      expect(s.x, closeTo(1.0, 1e-6));
      expect(s.y, closeTo(1.0, 1e-6));
      expect(s.z, closeTo(1.0, 1e-6));
    });

    test('a stand-in fills the part\'s own box, not a cube of its longest side',
        () {
      // The failure this rules out is silent and looks deliberate: scaling a
      // silhouette uniformly draws a 1.25 x 1.25 x 1.9 m tank as a 1.9 m cube
      // and a 3.22 m landing leg 0.19 m deep, and both still read as "grey
      // primitive, art not loaded".
      for (final def in catalog.all) {
        final extent = PartPrimitivesByCategory.authoredExtentM(def);
        final scale = VesselNodes.standInScale(def.id);
        // The box the mesh actually occupies once scaled, in scene units.
        expect(scale.x * extent.x, closeTo(lengthToScene(def.size.x), 1e-9),
            reason: '${def.id} X');
        expect(scale.y * extent.y, closeTo(lengthToScene(def.size.y), 1e-9),
            reason: '${def.id} Y');
        expect(scale.z * extent.z, closeTo(lengthToScene(def.size.z), 1e-9),
            reason: '${def.id} Z');
      }
    });

    test('the tank and the leg are the two that prove it', () {
      // Named cases, so the loop above says something concrete when it breaks.
      final tank = catalog.byId('fl-t400')!;
      expect(tank.size, const Vector3(1.25, 1.25, 1.9));
      final tankScale = VesselNodes.standInScale(tank.id);
      expect(tankScale.x, isNot(closeTo(tankScale.z, 1e-9)),
          reason: 'a 1.9 m tall 1.25 m tank is not a cube');

      final leg = catalog.byId('landing-gear')!;
      expect(PartPrimitivesByCategory.shapeFor(leg), PartStandInShape.slab,
          reason: 'the slab is the one primitive that is not a unit cube');
      final legScale = VesselNodes.standInScale(leg.id);
      // The slab is authored 0.06 m deep; drawn without dividing by that, this
      // part would be 6% of its declared depth.
      expect(legScale.z * 0.06, closeTo(lengthToScene(leg.size.z), 1e-9));
    });

    test('a hand-built part keeps the one-number fallback', () {
      // Nothing in the catalog claims a display name, so there is no box to
      // fill and no category to shape it — a uniform 1 m cube is the honest
      // answer, and the craft carrying it is on the whole-craft path anyway.
      expect(PartModelLibrary.defFor('Raptor'), isNull);
      final s = VesselNodes.standInScale('Raptor');
      expect(s.x, closeTo(lengthToScene(1.0), 1e-10));
      expect(s.y, closeTo(s.x, 1e-10));
      expect(s.z, closeTo(s.x, 1e-10));
    });
  });

  group('a part knows its own size whether or not it has art', () {
    test('the size is the catalog box, measured once', () {
      // Art and no-art parts read from different tables; both must answer with
      // the part's longest side, or a stand-in draws at the wrong size.
      expect(PartModelLibrary.fallbackSizeM('eagle-legs'), 3.22);
      expect(PartModelLibrary.lookup('eagle-legs')!.fallbackSizeM, 3.22);
      expect(PartModelLibrary.fallbackSizeM('mk1-capsule'), 1.4);
      for (final def in catalog.all) {
        final longest = [def.size.x, def.size.y, def.size.z].reduce((a, b) => a > b ? a : b);
        expect(PartModelLibrary.fallbackSizeM(def.id), longest, reason: def.id);
      }
    });

    test('an unknown key is 1 m, not a crash', () {
      expect(PartModelLibrary.fallbackSizeM('not-a-part'), 1.0);
    });
  });

  group('the plume finds the engine by capability, not by spelling', () {
    test('a full Eagle vents from the descent engine', () {
      // Neither 'eagle-thruster' nor 'eagle-command-pod' contains the word
      // "engine", so a plume that looked for one by spelling would find no
      // engine on this craft, fall back to the whole-craft default and hang
      // 1.2 m off the bell.
      final z = ExhaustNodes.nozzleZM([
        part('eagle-command-pod', 1.73),
        part('eagle-fuel-tank', -1.15),
        part('eagle-thruster', -2.70),
        part('eagle-legs', -2.00),
      ]);
      expect(z, closeTo(-2.70 - 1.25, 1e-12));
      expect(z, isNot(closeTo(ExhaustNodes.defaultNozzleZM, 1e-9)));
    });

    test('the AFT-MOST engine wins, not the first in the list', () {
      // The Eagle's ascent stage carries the APS high on the vehicle; taking
      // the first engine would vent the plume out of the cabin.
      expect(
        ExhaustNodes.nozzleZM(
            [part('eagle-command-pod', 1.73), part('eagle-thruster', -2.70)]),
        closeTo(-3.95, 1e-12),
      );
    });

    test('an engine above the origin still vents aft', () {
      // A part with ART, so the craft is on the per-part path and the part list
      // is what is drawn. The same engine on a craft drawn as a whole-craft
      // model is the case below.
      expect(ExhaustNodes.nozzleZM([part('eagle-thruster', 4.0)]),
          closeTo(-1.25, 1e-12));
    });

    test('a hand-built craft keeps the calibrated tail offset', () {
      // Sample vessels report display names and draw the whole-craft model, so
      // the default is the right answer for them — not an accident.
      expect(ExhaustNodes.nozzleZM([part('Raptor', 0), part('Booster', -3)]),
          ExhaustNodes.defaultNozzleZM);
      expect(ExhaustNodes.nozzleZM(const []), ExhaustNodes.defaultNozzleZM);
    });

    test('a stock stack vents from its own Merlin, art or no art', () {
      // A stock craft carries no bakes and is still drawn from its part list,
      // so the tail the plume measures against is the Merlin's, not the
      // whole-craft default.
      expect(PartModelLibrary.isEngine('merlin-1d'), isTrue);
      expect(
        ExhaustNodes.nozzleZM([
          part('mk1-capsule', 0),
          part('fl-t400', -1.65),
          part('merlin-1d', -3.55),
        ]),
        closeTo(-3.55 - ExhaustNodes.bellStandoffM, 1e-12),
      );
    });

    test('engine-ness comes from the catalog', () {
      expect(PartModelLibrary.isEngine('merlin-1d'), isTrue);
      expect(PartModelLibrary.isEngine('turbojet-j85'), isTrue, reason: 'jet');
      expect(PartModelLibrary.isEngine('eagle-thruster'), isTrue);
      expect(PartModelLibrary.isEngine('Eagle Thruster'), isTrue,
          reason: 'same normalisation as every other lookup');
      expect(PartModelLibrary.isEngine('fl-t400'), isFalse);
      expect(PartModelLibrary.isEngine('eagle-legs'), isFalse);
      expect(PartModelLibrary.isEngine('Raptor'), isFalse,
          reason: 'a display name is not a catalog id');
    });
  });

  group('the plume ignites on the craft that is DRAWN', () {
    // The invariant nothing asserted before, and the one the plume can break
    // silently: the anchor is derived from the PART LIST while the craft may be
    // drawn as a single whole-craft model, and the two only agree if something
    // makes them. Every number below is metres on the body Z axis.
    const assembler = VesselAssembler();

    Vessel bake(CraftDesign d) => assembler.assemble(
          id: 'pad-craft',
          name: d.name,
          ownerId: 'player',
          parts: d.parts,
          state: const StateVector(
              position: Vector3(6371000, 0, 0), velocity: Vector3.zero),
          dominantBody: const BodyId('earth'),
        );

    /// Aft-most surface of the silhouette [v] actually puts on screen.
    ///
    /// Per the path [VesselNodes.isKitbash] picks. Drawn from its parts: the
    /// aft face of the aft-most part's own box — a stand-in is scaled to fill
    /// exactly [PartDef.size] ([VesselNodes.standInScale]), and the bake that
    /// replaces it is calibrated to the same box, so the Z half-extent is
    /// `size.z / 2` on either. A hand-built part welded onto such a craft has
    /// no declared box, so it falls back to its longest known side. Drawn as
    /// one model: [VesselNodes.silhouetteAftM], which is the exit plane of the
    /// CSM's engine bell for most craft and the footpad plane for a lander —
    /// two hulls 3 m apart, and asking per craft is what keeps the LM's plume
    /// measured against the LM.
    double halfDepthM(String type) =>
        (PartModelLibrary.defFor(type)?.size.z ??
            PartModelLibrary.fallbackSizeM(type)) /
        2;

    double drawnAftM(VesselSnapshot v) => VesselNodes.isKitbash(v)
        ? v.parts.map((p) => p.oz - halfDepthM(p.type)).reduce(math.min)
        : VesselNodes.silhouetteAftM(v.id);

    /// THE INVARIANT. The plume vents aft of the craft origin and starts no
    /// further back than one nozzle-exit clearance
    /// ([ExhaustNodes.bellStandoffM]) beyond the aft-most thing drawn.
    /// Anything outside that band is a flame burning in empty space, which is
    /// exactly how a plume anchored to the wrong body looks.
    void expectPlumeOnTheHull(VesselSnapshot v, String what) {
      final z = ExhaustNodes.nozzleZM(v.parts);
      final aft = drawnAftM(v);
      expect(z, lessThanOrEqualTo(0.0),
          reason: '$what vents out of its own nose (plume at ${z}m)');
      expect(z, greaterThanOrEqualTo(aft - ExhaustNodes.bellStandoffM),
          reason: '$what: plume at ${z}m, but the craft on screen ends at '
              '${aft}m — the flame is detached from the hull by '
              '${(aft - z).toStringAsFixed(2)}m');
    }

    test('a stock stack built in the VAB', () {
      // The craft this invariant exists for. Node snapping puts the Merlin
      // 9.75 m below the pod, so a plume measured against anything but this
      // craft's own parts — an 11 m whole-craft silhouette, say — hangs metres
      // clear of the engine, and the gap grows with every tank added.
      final d = CraftDesign(name: 'Stock stack')
        ..addPart(def: catalog.byId('mk1-capsule')!, instanceId: 'pod');
      var below = 'pod';
      var belowNode = 'bottom';
      for (var i = 1; i <= 4; i++) {
        d.attachPart(
          def: catalog.byId('fl-t400')!,
          instanceId: 'tank-$i',
          toInstanceId: below,
          parentNode: belowNode,
          childNode: 'top',
        );
        below = 'tank-$i';
        belowNode = 'bottom';
      }
      d.attachPart(
        def: catalog.byId('merlin-1d')!,
        instanceId: 'merlin',
        toInstanceId: 'tank-4',
        parentNode: 'bottom',
        childNode: 'mount',
      );

      final snap = VesselSnapshot.of(bake(d));
      // The stack the solver actually produces, so a change to the attach
      // geometry shows up here rather than silently moving the goalposts.
      expect({for (final p in snap.parts) p.id: p.oz}, {
        'pod': closeTo(0.0, 1e-9),
        'tank-1': closeTo(-1.65, 1e-9),
        'tank-2': closeTo(-3.55, 1e-9),
        'tank-3': closeTo(-5.45, 1e-9),
        'tank-4': closeTo(-7.35, 1e-9),
        'merlin': closeTo(-9.75, 1e-9),
      });
      expect(VesselNodes.isKitbash(snap), isTrue,
          reason: 'the craft on screen is this part list');
      expect(ExhaustNodes.nozzleZM(snap.parts),
          closeTo(-9.75 - ExhaustNodes.bellStandoffM, 1e-9),
          reason: 'just aft of the Merlin, not aft of a silhouette');
      expectPlumeOnTheHull(snap, 'a stock VAB stack');
    });

    test('a stock stack of any length', () {
      // The gap grew with every tank, so the shape of the failure was "longer
      // craft, worse miss". One tank and six must both hold.
      for (final tanks in const [1, 2, 3, 6]) {
        final d = CraftDesign(name: 'Stack of $tanks')
          ..addPart(def: catalog.byId('mk1-capsule')!, instanceId: 'pod');
        var below = 'pod';
        for (var i = 1; i <= tanks; i++) {
          d.attachPart(
            def: catalog.byId('fl-t400')!,
            instanceId: 'tank-$i',
            toInstanceId: below,
            parentNode: 'bottom',
            childNode: 'top',
          );
          below = 'tank-$i';
        }
        d.attachPart(
          def: catalog.byId('merlin-1d')!,
          instanceId: 'merlin',
          toInstanceId: below,
          parentNode: 'bottom',
          childNode: 'mount',
        );
        expectPlumeOnTheHull(
            VesselSnapshot.of(bake(d)), 'a stock stack of $tanks tanks');
      }
    });

    test('a full Eagle, which is drawn from its parts', () {
      final d = CraftDesign(name: 'Eagle');
      d.addPart(
          def: catalog.byId('eagle-command-pod')!,
          instanceId: 'cabin',
          stage: 1);
      d.attachPart(
        def: catalog.byId('eagle-fuel-tank')!,
        instanceId: 'descent',
        toInstanceId: 'cabin',
        parentNode: 'stage-bottom',
        childNode: 'deck-top',
        stage: 0,
      );
      d.attachPart(
        def: catalog.byId('eagle-thruster')!,
        instanceId: 'dps',
        toInstanceId: 'descent',
        parentNode: 'engine-mount',
        childNode: 'mount',
      );
      for (var i = 1; i <= 4; i++) {
        d.attachPart(
          def: catalog.byId('eagle-legs')!,
          instanceId: 'leg-$i',
          toInstanceId: 'descent',
          parentNode: 'leg-$i',
          childNode: 'outrigger',
        );
      }
      final snap = VesselSnapshot.of(bake(d));
      expect(VesselNodes.isKitbash(snap), isTrue);
      expectPlumeOnTheHull(snap, 'an Eagle');
    });

    test('the hand-built craft the menu itself flies', () {
      // FLIGHT spawns exactly these two. They carry display names, not catalog
      // ids, so they take the whole-craft path and defaultNozzleZM is the
      // number calibrated for them.
      for (final v in [
        SampleWorld.buildLunarOrbiter(id: 'moon-lander', name: 'Lunar Module'),
        SampleWorld.buildLunarOrbiter(
            id: 'csm', name: 'Service Module', alongTrackM: 14),
        SampleWorld.buildSurfaceCraft(
            SampleWorld.realSystem().require(const BodyId('earth')),
            name: 'Ascent Vehicle'),
      ]) {
        final snap = VesselSnapshot.of(v);
        expect(VesselNodes.isKitbash(snap), isFalse, reason: v.name);
        expect(ExhaustNodes.nozzleZM(snap.parts), ExhaustNodes.defaultNozzleZM,
            reason: v.name);
        expectPlumeOnTheHull(snap, v.name);
      }
    });

    test('every hand-built craft the game can spawn', () {
      // The whole-craft side of the branch, over the whole population rather
      // than over the three the menu happens to reach. Each of these draws an
      // ~11 m silhouette ending at [VesselNodes.fallbackAftM] and must keep
      // the anchor calibrated against it; a craft that slipped onto the
      // per-part path would anchor to a part list that describes no hull on
      // screen, and nothing else in the suite would notice.
      final earth = SampleWorld.realSystem().require(const BodyId('earth'));
      final fleet = <String, Iterable<PartSnapshot>>{
        for (final v in [
          SampleWorld.buildVessel(),
          SampleWorld.buildMiner(),
          SampleWorld.buildFreighter(),
          SampleWorld.buildEarthOrbiter(),
          SampleWorld.buildEarthFreighter(),
          SampleWorld.buildSurfaceCraft(earth),
          SampleWorld.buildTrafficVessel(earth, id: 't1', name: 'Shuttle'),
          SampleWorld.buildLunarOrbiter(id: 'moon-lander', name: 'Lunar Module'),
          SampleWorld.buildLunarOrbiter(id: 'csm', name: 'Service Module'),
        ])
          v.name: VesselSnapshot.of(v).parts,
        // `SimulationView`'s debug-panel impactor, which is built inline and so
        // is the one spawnable craft `SampleWorld` cannot produce.
        'Impactor': [part('Test mass', 0)],
      };
      expect(fleet, hasLength(10));
      fleet.forEach((name, parts) {
        expect(VesselNodes.partsDrawThemselves(parts), isFalse, reason: name);
        expect(ExhaustNodes.nozzleZM(parts), ExhaustNodes.defaultNozzleZM,
            reason: '$name is drawn as one whole-craft model, so the anchor '
                'calibrated against that model is the only one on its hull');
      });
      // The band itself, stated once in numbers: the calibrated anchor sits
      // between the tail of the drawn silhouette (less one bell clearance) and
      // the craft origin — on BOTH whole-craft silhouettes, since one constant
      // serves them both. The LM is the binding one: its hull ends 3 m nearer
      // the origin than the CSM's, so a value that only cleared the CSM would
      // burn below the lander's footpads.
      expect(
          ExhaustNodes.defaultNozzleZM,
          inInclusiveRange(
              VesselNodes.fallbackAftM - ExhaustNodes.bellStandoffM, 0.0));
      expect(
          ExhaustNodes.defaultNozzleZM,
          inInclusiveRange(
              VesselNodes.landerAftM - ExhaustNodes.bellStandoffM, 0.0));
      expect(VesselNodes.silhouetteAftM('moon-lander'), VesselNodes.landerAftM,
          reason: 'the LM draws the LM silhouette');
      expect(VesselNodes.silhouetteAftM('csm'), VesselNodes.fallbackAftM,
          reason: 'everything else draws the CSM silhouette');
    });

    test('every catalog part, standing alone, anchors on itself', () {
      // The per-part side of the branch over its whole population. A one-part
      // craft is the smallest thing the VAB can launch and it exercises both
      // arms of [ExhaustNodes.nozzleZM]: an engine placed as root takes the
      // engine arm, everything else takes the aft-most-origin arm. Sweeping
      // the roster is what makes this a property of the catalog rather than of
      // the handful of parts someone thought to name.
      var engines = 0;
      for (final def in catalog.all) {
        final snap = VesselSnapshot.of(bake(
            CraftDesign(name: def.id)..addPart(def: def, instanceId: 'root')));
        expect(VesselNodes.isKitbash(snap), isTrue, reason: def.id);
        if (PartModelLibrary.isEngine(def.id)) engines++;
        expectPlumeOnTheHull(snap, 'a lone ${def.id}');
      }
      expect(catalog.all, hasLength(38));
      expect(engines, greaterThanOrEqualTo(4),
          reason: 'the engine arm has to be exercised, not just the other one');
    });

    test('every engine in the catalog, mounted under a pod', () {
      // The engine arm on a real stack, so the anchor is measured against a
      // hull that extends beyond the engine rather than one the engine IS.
      final pod = catalog.byId('mk1-capsule')!;
      final mounted = <String>[];
      for (final def in catalog.all.where((d) => d.isEngine)) {
        final d = CraftDesign(name: def.id)
          ..addPart(def: pod, instanceId: 'pod');
        // The editor's OWN offer, so this only ever builds a craft the VAB
        // would let a player build; an engine with no seat under the pod is
        // the roster's business, not the plume's.
        final seat = AttachTargets.pairingsFor(d, def)
            .where((p) => p.target.nodeName == 'bottom')
            .firstOrNull;
        if (seat == null) continue;
        d.attachPart(
          def: def,
          instanceId: 'engine',
          toInstanceId: 'pod',
          parentNode: seat.target.nodeName,
          childNode: seat.childNodeName,
        );
        mounted.add(def.id);
        final snap = VesselSnapshot.of(bake(d));
        final engineZ = snap.parts.firstWhere((p) => p.id == 'engine').oz;
        expect(ExhaustNodes.nozzleZM(snap.parts),
            closeTo(engineZ - ExhaustNodes.bellStandoffM, 1e-9),
            reason: '${def.id} vents from its own bell, not from the pod');
        expectPlumeOnTheHull(snap, '${def.id} under a pod');
      }
      expect(mounted, isNotEmpty,
          reason: 'no stock engine stacks under a pod, which would mean the '
              'roster cannot build the simplest craft there is');
    });

    test('a craft drawn from its parts with no engine anchors to its own tail',
        () {
      // A descent stage assembled without its DPS is buildable, and a craft
      // that stages its last engine away reaches the same state in flight —
      // the throttle still moves either way. Falling back to defaultNozzleZM
      // there would hang the flame off the tail of an Apollo CSM, which is not
      // the craft on screen.
      final d = CraftDesign(name: 'Descent stage')
        ..addPart(def: catalog.byId('eagle-fuel-tank')!, instanceId: 'descent');
      for (var i = 1; i <= 4; i++) {
        d.attachPart(
          def: catalog.byId('eagle-legs')!,
          instanceId: 'leg-$i',
          toInstanceId: 'descent',
          parentNode: 'leg-$i',
          childNode: 'outrigger',
        );
      }
      final snap = VesselSnapshot.of(bake(d));
      expect(VesselNodes.isKitbash(snap), isTrue);
      expect(snap.parts.any((p) => PartModelLibrary.isEngine(p.type)), isFalse);

      final aftMostPart =
          snap.parts.map((p) => math.min(p.oz, 0.0)).reduce(math.min);
      expect(ExhaustNodes.nozzleZM(snap.parts), closeTo(aftMostPart, 1e-12),
          reason: 'the aft-most part origin is inside that part by '
              'construction; the whole-craft default is not on this craft');
      expect(ExhaustNodes.nozzleZM(snap.parts),
          isNot(closeTo(ExhaustNodes.defaultNozzleZM, 1e-6)));
      expectPlumeOnTheHull(snap, 'an engineless descent stage');
    });
  });

  group('live calibration reaches the renderer', () {
    test('an override changes what is drawn, not what the catalog says', () {
      final catalogScale = PartModelLibrary.lookup('eagle-legs')!.scale;
      expect(catalogScale, LemParts.modelUnitToMetres);

      PartModelLibrary.calibrate('eagle-legs', scale: 3.0);
      expect(PartModelLibrary.resolve('eagle-legs')!.scale, 3.0);
      expect(PartModelLibrary.lookup('eagle-legs')!.scale, catalogScale,
          reason: 'lookup is the catalog; resolve is what to draw with');
      // Measure the scale as a LENGTH: a model-space unit vector comes out at
      // `scale` metres whichever way the part's own modelRotation turns it, and
      // subtracting the translation drops the offset. Reading a single
      // component instead would pin this test to whatever axis the leg's
      // correction happens to send +Y down this week.
      final m =
          VesselNodes.partModelTransform(PartModelLibrary.resolve('eagle-legs')!);
      final unit = m.transform3(vm.Vector3(0, 1, 0)) - m.getTranslation();
      expect(unit.length, closeTo(lengthToScene(3.0), 1e-9));
    });

    test('a rotation and an offset sweep independently, and accumulate', () {
      PartModelLibrary.calibrate('eagle-rcs-block',
          rotation: Quaternion.axisAngle(Vector3.unitX, 1.5707963267948966));
      PartModelLibrary.calibrate('eagle-rcs-block', offset: Vector3(0, 0, 0.4));
      final m = PartModelLibrary.resolve('eagle-rcs-block')!;
      expect(m.offset, const Vector3(0, 0, 0.4));
      expect(m.rotation.x, closeTo(0.7071067811865476, 1e-12),
          reason: 'the earlier rotation survives a later offset call');
      expect(m.scale, LemParts.modelUnitToMetres,
          reason: 'an unnamed value keeps whatever is in force');
      expect(m.asset, 'assets/mesh/rcs_block.fsceneb',
          reason: 'calibration never repoints a part at other art');
    });

    test('calibrating a part with no art is a no-op, not a crash', () {
      PartModelLibrary.calibrate('mk1-capsule', scale: 9.0);
      expect(PartModelLibrary.resolve('mk1-capsule'), isNull);
      expect(PartModelLibrary.calibrationSource(), isEmpty);
    });

    test('the sweep reports itself as pasteable catalog source', () {
      expect(PartModelLibrary.calibrationSource(), isEmpty,
          reason: 'nothing calibrated = nothing to paste back');
      // All three named, so what is printed is decided by this test and not by
      // whatever the catalog currently ships — a settled sweep names all three
      // anyway, since that is what gets pasted.
      PartModelLibrary.calibrate('eagle-legs',
          scale: 2.5,
          rotation: Quaternion.identity,
          offset: Vector3(0, 0, 0.4));
      expect(PartModelLibrary.calibrationSource(), {
        'eagle_legs': {
          'modelScale': '2.5',
          'modelRotation': 'Quaternion(1.0, 0.0, 0.0, 0.0)',
          'modelOffset': 'Vector3(0.0, 0.0, 0.4)',
        }
      });
    });

    test('an unswept value is reported as the catalog value, not as identity',
        () {
      // Half a sweep still has to print something pasteable, and the honest
      // thing to print for a field nobody touched is what the part already
      // ships — paste the lot back and the part is unchanged.
      final def = catalog.byId('eagle-rcs-block')!;
      expect(def.modelRotation, isNot(Quaternion.identity),
          reason: 'the RCS quad is the witness because it ships a correction');

      PartModelLibrary.calibrate('eagle-rcs-block', scale: 2.5);
      final printed = PartModelLibrary.calibrationSource()['eagle_rcs_block']!;
      expect(printed['modelScale'], '2.5');
      expect(printed['modelRotation'], isNot('Quaternion(1.0, 0.0, 0.0, 0.0)'),
          reason: 'printing identity would silently undo the correction of any '
              'part whose rotation the sweep did not revisit');

      // The literals have to survive being pasted, so read the four numbers
      // back out and compare them to what the catalog holds.
      final n = RegExp(r'-?\d+\.?\d*')
          .allMatches(printed['modelRotation']!)
          .map((m) => double.parse(m[0]!))
          .toList();
      expect(n, hasLength(4));
      expect(n[0], closeTo(def.modelRotation.w, 1e-6));
      expect(n[1], closeTo(def.modelRotation.x, 1e-6));
      expect(n[2], closeTo(def.modelRotation.y, 1e-6));
      expect(n[3], closeTo(def.modelRotation.z, 1e-6));
    });

    test('a reset restores the catalog', () {
      PartModelLibrary.calibrate('eagle-legs', scale: 3.0);
      PartModelLibrary.resetCalibration();
      expect(PartModelLibrary.resolve('eagle-legs')!.scale,
          LemParts.modelUnitToMetres);
      expect(PartModelLibrary.calibrationSource(), isEmpty);
    });
  });
}
