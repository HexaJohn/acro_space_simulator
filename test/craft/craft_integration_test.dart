// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
import 'dart:math' as math;

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/craft/attach_targets.dart';
import 'package:acro_space_simulator/domain/craft/craft_design_codec.dart';
import 'package:acro_space_simulator/domain/parts/attach_node.dart';
import 'package:acro_space_simulator/domain/parts/lem_parts.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_editor_controller.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_launch.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/coord_convert.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/craft/craft_editor_nodes.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/part_model_library.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/part_primitives_category.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/vessel_nodes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_math/vector_math.dart' as vm;

/// The seams BETWEEN the craft editor's layers, which each layer's own suite
/// cannot see.
///
/// Every hop from the part catalog to a scene node is a separate agreement:
/// authored node data has to be the shape the ring detector looks for, a
/// symmetry set has to survive the save codec, a baked vessel has to carry the
/// catalog id the renderer binds art by. Each of those is checked at one end by
/// the file that owns it, and NOWHERE end to end — which is how a craft comes to
/// be buildable, savable, flyable and invisible.
///
/// Units are METRES in the craft body frame (right-handed, Z-up, +Z = nose)
/// until the last hop, which converts to scene kilometres.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final catalog = PartCatalog.standard();
  const codec = CraftDesignCodec();

  PartDef part(String id) =>
      catalog.byId(id) ??
      fail('the shipped catalog has no part "$id" — the roster moved');

  group('the authored node data is the shape the ring detector looks for', () {
    test('the stock tank ring is round, and it is the ring that is found', () {
      // Checked against the closed form rather than against the catalog's own
      // helper: both sides of this seam were written from the same sentence in
      // the spec, so re-deriving the seats from trig here is the only way the
      // test can disagree with either of them.
      final tank = part('fl-t400');
      const r = 0.625; // half the 1.25 m body
      final seats = <String, Vector3>{
        'srf-1': const Vector3(r, 0, 0),
        'srf-2': const Vector3(0, r, 0),
        'srf-3': const Vector3(-r, 0, 0),
        'srf-4': const Vector3(0, -r, 0),
      };
      for (final e in seats.entries) {
        final node = tank.node(e.key) ?? fail('fl-t400 has no ${e.key}');
        expect(node.kind, AttachKind.surface, reason: e.key);
        expect(node.position.x, closeTo(e.value.x, 1e-12), reason: e.key);
        expect(node.position.y, closeTo(e.value.y, 1e-12), reason: e.key);
        expect(node.position.z, closeTo(0, 1e-12), reason: e.key);
        // Outward radial normal: a seat facing inward mounts a booster INSIDE
        // the tank, and the ring would still look perfectly round.
        expect(node.direction.dot(e.value.normalized), closeTo(1, 1e-12),
            reason: e.key);
      }

      final rings = AttachTargets.ringsOf(tank);
      expect(rings, hasLength(1),
          reason: 'one surface family on this part, so exactly one ring');
      final ring = rings.single;
      expect(ring.prefix, 'srf');
      expect(ring.nodeNames, ['srf-1', 'srf-2', 'srf-3', 'srf-4'],
          reason: 'ascending azimuth from +X, which for this part is also the '
              'authored order');
      expect(ring.radius, closeTo(r, 1e-12));
      expect(ring.height, closeTo(0, 1e-12));
      expect(AttachTargets.symmetryCountsFor(ring), [1, 2, 4]);

      // x2 must be DIAMETRICALLY opposite, or a two-copy placement puts both
      // boosters on the same side and the craft yaws off the pad.
      final pair = ring.subset(2, ring.indexOf('srf-1'));
      expect(pair, ['srf-1', 'srf-3']);
      final a = tank.node(pair[0])!.position;
      final b = tank.node(pair[1])!.position;
      expect(a.dot(b), closeTo(-r * r, 1e-12),
          reason: 'antiparallel at equal radius');
    });

    test('a ring authored at a quarter-turn phase is still round', () {
      // The LM's quad and deflector rings start at pi/4 while the stock rings
      // start at 0. A detector that measured spacing from azimuth 0 instead of
      // from its own first member would find the stock rings and silently drop
      // every LM one — and the LM is the craft the editor was built for.
      final pod = part('eagle-command-pod');
      final ring = AttachTargets.ringContaining(pod, 'quad-1') ??
          fail('quad-1 is not detected as a ring member');
      expect(ring.count, 4);
      final first = pod.node(ring.nodeNames.first)!.position;
      expect(math.atan2(first.y, first.x), closeTo(math.pi / 4, 1e-9),
          reason: 'the first member by azimuth sits on the diagonal');
      expect(ring.subset(4, ring.indexOf('quad-1')).toSet(),
          {'quad-1', 'quad-2', 'quad-3', 'quad-4'});
    });

    test('every named surface family in the catalog is a detected ring', () {
      // The failure this rules out is silent in both directions: a family the
      // detector drops offers no symmetry and says nothing about why, and a
      // family it accepts on the name alone would scatter four legs.
      final member = RegExp(r'^(.+)-(\d+)$');
      for (final def in catalog.all) {
        final authored = <String, int>{};
        for (final node in def.attachNodes) {
          if (node.kind != AttachKind.surface) continue;
          final match = member.firstMatch(node.name);
          if (match == null) continue;
          final prefix = match.group(1)!;
          authored[prefix] = (authored[prefix] ?? 0) + 1;
        }
        final detected = {
          for (final ring in AttachTargets.ringsOf(def)) ring.prefix: ring.count
        };
        for (final family in authored.entries) {
          if (family.value < 2) continue;
          expect(detected[family.key], family.value,
              reason: '${def.id} authors ${family.value} "${family.key}-N" '
                  'surface seats but the detector found '
                  '${detected[family.key] ?? 'no ring'}');
        }
      }
    });
  });

  group('the catalog and the renderer agree about model scale', () {
    test('every part with art renders at the size its PartDef declares', () {
      // Spec risk R3. The two registries are no longer independent — the
      // library is SEEDED from the catalog — so this asserts the seeding rather
      // than a coincidence: it fails the day someone hand-writes an entry or
      // parks a calibration in the renderer instead of in the part.
      final withArt = catalog.all.where((d) => d.modelAsset != null).toList();
      expect(withArt, hasLength(7), reason: 'the LM family');
      for (final def in withArt) {
        final model = PartModelLibrary.lookup(def.id) ??
            fail('${def.id} declares ${def.modelAsset} and the renderer has '
                'no binding for it');
        expect(model.asset, def.modelAsset, reason: def.id);
        expect(model.scale, def.modelScale, reason: def.id);
        expect(model.rotation, def.modelRotation, reason: def.id);
        expect(model.offset, def.modelOffset, reason: def.id);
        expect(model.scale, LemParts.modelUnitToMetres,
            reason: '${def.id} is calibrated with the rest of its family');
      }
    });

    test('the editor and the flight view draw the same stand-in', () {
      // The part of "what you build is what you fly" that holds BEFORE any art
      // exists, and the part that is easiest to lose: the two renderers reach
      // the silhouette table from opposite ends — the editor holds the
      // [PartDef], the flight view has only a type key off the snapshot — so
      // nothing but this makes them agree. A stock stack that resolved through
      // the type-key registry instead would draw a cone on five grey cubes in
      // flight and the real shapes in the VAB.
      for (final def in catalog.all) {
        final editor = CraftEditorNodes.standInScale(def);
        final flight = VesselNodes.standInScale(def.id);
        expect(flight.x, closeTo(editor.x, 1e-12), reason: '${def.id} X');
        expect(flight.y, closeTo(editor.y, 1e-12), reason: '${def.id} Y');
        expect(flight.z, closeTo(editor.z, 1e-12), reason: '${def.id} Z');
      }
    });

    test('the editor and the flight view compose the same art transform', () {
      // The editor places art from the PartDef and the flight view from the
      // model library. Same numbers is necessary but not sufficient: the two
      // also have to COMPOSE them the same way, or a craft changes size or
      // orientation the moment it launches.
      for (final def in catalog.all.where((d) => d.modelAsset != null)) {
        final editor = CraftEditorNodes.partModelTransform(def);
        final flight =
            VesselNodes.partModelTransform(PartModelLibrary.resolve(def.id)!);
        for (var i = 0; i < 16; i++) {
          expect(editor.storage[i], closeTo(flight.storage[i], 1e-9),
              reason: '${def.id} element $i');
        }
      }
    });
  });

  group('a craft built in the editor survives every hop to the renderer', () {
    late CraftEditorController editor;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      editor = CraftEditorController(catalog: catalog, craftName: 'Eagle');
    });
    tearDown(() => editor.dispose());

    /// The pairing for one named seat, taken from the editor's OWN offer, so
    /// the test can only ask for a mate the editor would really present.
    TargetPairing seat(String ownerInstanceId, String nodeName) =>
        editor.pairings.firstWhere(
          (p) =>
              p.target.ownerInstanceId == ownerInstanceId &&
              p.target.nodeName == nodeName,
          orElse: () => fail('no pairing for "$ownerInstanceId.$nodeName" '
              'holding ${editor.held?.def.id}'),
        );

    test('catalog part -> placement -> ring symmetry -> design -> codec -> '
        'vessel -> snapshot -> model library -> scene transform', () {
      // ---- hop 1: the catalog part -------------------------------------
      final pod = part('eagle-command-pod');
      final descent = part('eagle-fuel-tank');
      final quad = part('eagle-rcs-block');
      expect(pod.node('stage-bottom')?.kind, AttachKind.stack);
      expect(quad.node('mount')?.kind, AttachKind.surface);

      // ---- hop 2: editor placement -------------------------------------
      editor.hold(pod);
      expect(editor.placeRoot(), isTrue, reason: editor.blocked ?? '');
      final rootId = editor.design.rootId ?? fail('the root was not recorded');

      editor.hold(descent);
      expect(editor.attachAt(seat(rootId, 'stage-bottom')), isTrue,
          reason: editor.blocked ?? '');
      final descentId = editor.selectedId ?? fail('nothing was selected');
      final descentPart = editor.design.partById(descentId)!;
      expect(descentPart.attachment?.parentInstanceId, rootId);
      expect(descentPart.attachment?.parentNode, 'stage-bottom');
      expect(descentPart.attachment?.childNode, 'deck-top',
          reason: 'the 0.81 m dock-top is rejected against the 4.2 m deck, so '
              'the stack has exactly one legal pairing');

      // ---- hop 3: ring symmetry ----------------------------------------
      editor.hold(quad);
      editor.setSymmetryCount(4);
      final quadSeat = seat(rootId, 'quad-1');
      expect(editor.symmetryCountsAt(quadSeat.target), contains(4),
          reason: 'the pod ring can express x4');
      final seats = editor.seatsFor(quadSeat.target);
      expect(seats.toSet(), {'quad-1', 'quad-2', 'quad-3', 'quad-4'},
          reason: 'the ghost preview and the commit read the same list');
      expect(editor.attachAt(quadSeat), isTrue, reason: editor.blocked ?? '');

      // ---- hop 4: the design -------------------------------------------
      final design = editor.design;
      expect(design.partCount, 6, reason: 'pod + descent stage + 4 quads');
      final quads =
          design.parts.where((p) => p.def.id == quad.id).toList(growable: false);
      expect(quads, hasLength(4));
      expect({for (final q in quads) q.attachment!.parentNode},
          {'quad-1', 'quad-2', 'quad-3', 'quad-4'},
          reason: 'each copy names its OWN authored node — four parts claiming '
              'one node is the shape that will not reload');
      // The ring is still a ring once mated: one radius, one height, four
      // distinct azimuths about the craft axis.
      final radii = [
        for (final q in quads)
          math.sqrt(q.position.x * q.position.x + q.position.y * q.position.y)
      ];
      for (final r in radii) {
        expect(r, closeTo(radii.first, 1e-9));
      }
      for (final q in quads) {
        expect(q.position.z, closeTo(quads.first.position.z, 1e-9));
      }
      expect({for (final q in quads) q.position.toString()}, hasLength(4));

      // ---- hop 5: the save codec ---------------------------------------
      // The regression that killed two rejected designs: a synthesised node
      // name validates on the way out and throws on the way back in, so the
      // craft is unloadable the first time anyone saves it.
      final encoded = json.encode(codec.encode(design));
      final reloaded = codec.decode(
          json.decode(encoded) as Map<String, dynamic>,
          catalog: catalog);
      expect(json.encode(codec.encode(reloaded)), encoded);
      expect(reloaded.partCount, 6);

      // ---- hop 6: the assembler and the vessel --------------------------
      final vessel = CraftLaunch.surfaceCraft(design: reloaded);
      final baked = vessel.allParts.toList(growable: false);
      expect(baked, hasLength(6));
      expect(vessel.landed, isTrue);
      for (final p in baked) {
        final placed = reloaded.partById(p.id.value) ??
            fail('${p.id.value} is not a part of the design it was baked from');
        expect(p.defId, placed.def.id,
            reason: 'the catalog id is the ONLY key the renderer binds art by');
        expect(p.assetKey, placed.def.id);
        expect(p.positionInVessel.x, closeTo(placed.position.x, 1e-12));
        expect(p.positionInVessel.y, closeTo(placed.position.y, 1e-12));
        expect(p.positionInVessel.z, closeTo(placed.position.z, 1e-12));
      }

      // ---- hop 7: the snapshot ------------------------------------------
      final snapshot = VesselSnapshot.of(vessel);
      expect(snapshot.parts, hasLength(6));
      expect({for (final p in snapshot.parts) p.id}, hasLength(6),
          reason: 'four quads are four parts, not one drawn four times');
      for (final p in snapshot.parts) {
        final placed = reloaded.partById(p.id) ?? fail('${p.id} is not in the design');
        expect(p.type, placed.def.id, reason: p.id);
        expect(p.oz, closeTo(placed.position.z, 1e-12), reason: p.id);
      }

      // ---- hop 8: the wire ----------------------------------------------
      // Multiplayer and save both re-read the snapshot from JSON; a type key
      // lost here draws the remote player's craft as an unrelated silhouette.
      final wire = VesselSnapshot.fromJson(
          json.decode(json.encode(snapshot.toJson())) as Map<String, dynamic>);
      expect([for (final p in wire.parts) p.type],
          [for (final p in snapshot.parts) p.type]);

      // ---- hop 9: the model library -------------------------------------
      for (final p in wire.parts) {
        expect(PartModelLibrary.has(p.type), isTrue,
            reason: '${p.type} has no registered art, so this craft would be '
                'drawn as one whole-craft model instead of as its parts');
        final model = PartModelLibrary.resolve(p.type)!;
        expect(model.scale, catalog.byId(p.type)!.modelScale, reason: p.type);
      }

      // ---- hop 10: the scene node ---------------------------------------
      expect(VesselNodes.isKitbash(wire), isTrue,
          reason: 'a VAB craft draws from its PART LIST; false here is the bug '
              'where an Eagle renders as an Apollo CSM');
      for (final p in wire.parts) {
        final m = VesselNodes.partModelTransform(PartModelLibrary.resolve(p.type)!);
        // A model-space unit vector comes out at `modelScale` metres, whichever
        // way this part's own correction turns it.
        final unit = m.transform3(vm.Vector3(0, 1, 0)) - m.getTranslation();
        expect(unit.length,
            closeTo(lengthToScene(catalog.byId(p.type)!.modelScale), 1e-9),
            reason: p.type);
      }
    });

    test('a stock craft flies as the stack it was built as, art or no art', () {
      // The end of the chain for the roster that has NO bakes, which is the
      // whole stock catalog. Everything the flight renderer needs is recovered
      // from the type key alone: which part it is, what shape it draws as, and
      // how big. Art only decides what fills a slot, never how many slots there
      // are — so the stack below is three nodes at three places whether or not
      // a single `.fsceneb` ever ships for it.
      editor.hold(part('mk1-capsule'));
      expect(editor.placeRoot(), isTrue, reason: editor.blocked ?? '');
      expect(editor.quickStack(part('fl-t400')), isTrue,
          reason: editor.blocked ?? '');
      expect(editor.quickStack(part('merlin-1d')), isTrue,
          reason: editor.blocked ?? '');

      final snapshot = VesselSnapshot.of(CraftLaunch.surfaceCraft(
          design: editor.design));
      expect(snapshot.parts, hasLength(3));
      expect(VesselNodes.isKitbash(snapshot), isTrue,
          reason: 'the craft the player assembled is the craft that flies');

      for (final p in snapshot.parts) {
        final def = catalog.byId(p.type) ??
            fail('${p.type} must still be a catalog id');
        expect(PartModelLibrary.has(p.type), isFalse,
            reason: 'no stock part declares a bake yet');
        final rendered = PartModelLibrary.defFor(p.type) ??
            fail('${p.type} is how the renderer recovers its shape and size');
        expect(rendered.size, def.size, reason: p.type);
        expect(rendered.category, def.category, reason: p.type);
        // The DRAWN box, in scene units: the stand-in's authored extent times
        // the scale it is given. Three different parts, three different boxes.
        final extent = PartPrimitivesByCategory.shapeFor(def).authoredExtentM;
        final scale = VesselNodes.standInScale(p.type);
        expect(scale.z * extent.z, closeTo(lengthToScene(def.size.z), 1e-9),
            reason: p.type);
      }

      // One slot per part, each at the place the design put it — the assertion
      // that a whole-craft silhouette cannot pass.
      final placed = {
        for (final p in editor.design.parts) p.instanceId: p.position
      };
      expect(placed, hasLength(3));
      for (final p in snapshot.parts) {
        final want = placed[p.id] ?? fail('${p.id} is not in the design');
        final t = VesselNodes.partSlotTransform(p).getTranslation();
        expect(t.z, closeTo(lengthToScene(want.z), 1e-9), reason: p.id);
      }
      expect({for (final p in snapshot.parts) p.oz}, hasLength(3),
          reason: 'a stack, not three parts at the origin');
    });

    test('a design that cannot reload is caught before it is offered', () {
      // Every mate the editor offers is re-run through the codec here, because
      // the editor's own suites assert the mates it MAKES and this asserts the
      // mates it OFFERS. An offer that produces an unloadable design is the one
      // failure that survives every layer's own tests.
      editor.hold(part('eagle-command-pod'));
      expect(editor.placeRoot(), isTrue);
      final podId = editor.design.rootId!;
      editor.hold(part('eagle-fuel-tank'));
      expect(editor.attachAt(seat(podId, 'stage-bottom')), isTrue);

      editor.hold(part('eagle-rcs-block'));
      final offered = editor.pairings;
      expect(offered, hasLength(12),
          reason: 'the quad has one surface node, so it is offered the pod ring '
              '(quad-1..4) and the descent stage rings (leg-1..4, '
              'deflector-1..4) and nothing else');
      for (final pairing in offered) {
        final probe = codec.decode(codec.encode(editor.design), catalog: catalog)
          ..attachPart(
            def: part('eagle-rcs-block'),
            instanceId: 'probe',
            toInstanceId: pairing.target.ownerInstanceId,
            parentNode: pairing.target.nodeName,
            childNode: pairing.childNodeName,
          );
        // The round trip is the assertion: fromParts revalidates the whole
        // attach tree and throws on a node that is not really there.
        expect(codec.decode(codec.encode(probe), catalog: catalog).partCount, 3,
            reason: 'offering ${pairing.target.nodeName} produced a design that '
                'does not reload');
      }
    });
  });
}
