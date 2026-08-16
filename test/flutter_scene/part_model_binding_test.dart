// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:io';

import 'package:acro_space_simulator/application/snapshot/world_snapshot.dart';
import 'package:acro_space_simulator/domain/craft/craft_design.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/parts/lem_parts.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/vessel_assembler.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/part.dart';
import 'package:acro_space_simulator/domain/vessel/stage.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/part_model_library.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/vessel_nodes.dart';
import 'package:acro_space_simulator/infrastructure/sample_world.dart';
import 'package:flutter_test/flutter_test.dart';

/// The seam between the catalog and the renderer, which has no other guard.
///
/// A craft binds to its art by ONE key: the catalog `PartDef.id` travels as
/// `Part.defId`, then as `PartSnapshot.type`, and is finally looked up in
/// [PartModelLibrary]. Every hop is a string, none of them is type-checked, and
/// a break anywhere along it is silent — the craft flies correctly and simply
/// renders as grey boxes, which is indistinguishable from "the bakes aren't
/// downloaded yet". These tests are what make that break loud.
void main() {
  final catalog = PartCatalog.standard();

  group('catalog is the single source of truth for render bindings', () {
    test('every part that declares art resolves to exactly that art', () {
      final declared = catalog.all.where((d) => d.modelAsset != null).toList();
      expect(declared, isNotEmpty, reason: 'the LM family declares modelAsset');

      for (final def in declared) {
        expect(PartModelLibrary.has(def.id), isTrue,
            reason: '${def.id} declares ${def.modelAsset} but the renderer '
                'cannot find art for it — the craft would draw as stand-ins');
        final model = PartModelLibrary.lookup(def.id)!;
        expect(model.asset, def.modelAsset, reason: def.id);
        // Scale drift is the silent form of this break: art measured at one
        // number and attach nodes authored at another puts every joint
        // visibly apart while every behavioural test still passes.
        expect(model.scale, def.modelScale, reason: '${def.id} model scale');
        expect(model.fallbackSizeM, greaterThan(0), reason: def.id);
      }
    });

    test('a part with no art registered is not classified as having art', () {
      // `has` decides whether a BAKE is worth starting, and a part the catalog
      // never gave a model must answer false or the loader chases an asset
      // that does not exist. It is deliberately NOT the question "how is this
      // craft drawn?" — see `isCatalogPart` below.
      expect(catalog.byId('mk1-capsule')!.modelAsset, isNull);
      expect(PartModelLibrary.has('mk1-capsule'), isFalse);
      expect(PartModelLibrary.assetFor('mk1-capsule'), isNull);
      // ...while everything needed to DRAW it is still known, so its stand-in
      // is the right shape at the right size rather than a 1 m blob.
      expect(PartModelLibrary.isCatalogPart('mk1-capsule'), isTrue);
      final shipped = catalog.byId('mk1-capsule')!;
      final rendered = PartModelLibrary.defFor('mk1-capsule')!;
      expect(rendered.id, shipped.id);
      // The two fields a stand-in is built out of. The library seeds itself
      // from its own `PartCatalog.standard()` build, so these are separate
      // instances of the same authored part — and if they ever stop agreeing,
      // the craft in the VAB and the craft in flight are different sizes.
      expect(rendered.size, shipped.size);
      expect(rendered.category, shipped.category);
      expect(PartModelLibrary.fallbackSizeM('mk1-capsule'), shipped.size.z);
    });

    test('provenance and art are separate questions about the same key', () {
      // Conflating them is the defect this seam exists to prevent: a craft
      // assembled from a roster that has no bakes yet is still that craft.
      for (final def in catalog.all) {
        expect(PartModelLibrary.isCatalogPart(def.id), isTrue, reason: def.id);
        expect(PartModelLibrary.has(def.id), def.modelAsset != null,
            reason: def.id);
      }
      // Nothing the catalog has not heard of is a catalog part, whichever way
      // it is spelled.
      for (final alien in const ['Raptor', 'Core', 'Test mass', '']) {
        expect(PartModelLibrary.isCatalogPart(alien), isFalse, reason: alien);
        expect(PartModelLibrary.defFor(alien), isNull, reason: alien);
      }
    });

    test('id spelling cannot break the binding', () {
      // The ids are kebab-case and the bakes are underscored basenames; the two
      // are authored by different hands and must not have to agree.
      for (final spelling in const [
        'eagle-rcs-block',
        'eagle_rcs_block',
        'Eagle RCS Block',
      ]) {
        expect(PartModelLibrary.assetFor(spelling),
            'assets/mesh/rcs_block.fsceneb',
            reason: spelling);
      }
    });
  });

  group('declared bakes exist', () {
    // The bakes are gitignored (licensed art), so a fresh clone legitimately
    // has none and this must not fail there. It checks the checkout that
    // actually carries art, which is where a typo'd path would otherwise hide
    // until someone looked at the screen.
    final dir = Directory('assets/mesh');
    final baked = dir.existsSync()
        ? dir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.fsceneb'))
            .toList()
        : <File>[];

    test('every declared modelAsset is a real file', () {
      for (final def in catalog.all.where((d) => d.modelAsset != null)) {
        final asset = def.modelAsset!;
        expect(asset, startsWith('assets/mesh/'), reason: def.id);
        expect(asset, endsWith('.fsceneb'), reason: def.id);
        expect(File(asset).existsSync(), isTrue,
            reason: '${def.id} points at $asset, which is not on disk');
        expect(File(asset).lengthSync(), greaterThan(0), reason: asset);
      }
    }, skip: baked.isEmpty ? 'no bakes in this checkout (licensed art)' : null);
  });

  group('defId travels from the catalog to the renderer', () {
    const assembler = VesselAssembler();

    /// The real Eagle, built only from attach operations against the real
    /// catalog — the same path the VAB takes.
    CraftDesign buildEagle() {
      final d = CraftDesign(name: 'Eagle');
      final pod = catalog.byId('eagle-command-pod')!;
      d.addPart(def: pod, instanceId: 'cabin', stage: 1);
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
        d.attachPart(
          def: catalog.byId('eagle-rcs-block')!,
          instanceId: 'quad-$i',
          toInstanceId: 'cabin',
          parentNode: 'quad-$i',
          childNode: 'mount',
        );
      }
      return d;
    }

    Vessel bake(CraftDesign d) => assembler.assemble(
          id: 'lm-5',
          name: d.name,
          ownerId: 'crew',
          parts: d.parts,
          state: const StateVector(
              position: Vector3(1837400, 0, 0), velocity: Vector3(0, 1633, 0)),
          dominantBody: const BodyId('moon'),
        );

    test('the assembler stamps the catalog id onto every baked part', () {
      final v = bake(buildEagle());
      final parts = v.allParts.toList();
      expect(parts.length, 11, reason: 'pod, descent, DPS, 4 legs, 4 quads');
      for (final p in parts) {
        expect(p.defId, isNotEmpty,
            reason: '${p.name} lost its catalog id in the bake');
        expect(catalog.byId(p.defId), isNotNull, reason: p.defId);
        // assetKey is the one rule the snapshot uses; for a catalog part it
        // must be the id, NOT the display name.
        expect(p.assetKey, p.defId);
      }
    });

    test('the snapshot carries ids the renderer can bind art to', () {
      final snap = VesselSnapshot.of(bake(buildEagle()));
      expect(snap.parts, hasLength(11));
      for (final p in snap.parts) {
        expect(catalog.byId(p.type), isNotNull,
            reason: '${p.type} is not a catalog id — the renderer will find '
                'no art and silently draw a stand-in');
        expect(PartModelLibrary.has(p.type), isTrue, reason: p.type);
        expect(PartModelLibrary.assetFor(p.type), isNotNull, reason: p.type);
      }
      // All seven family members share one calibration; if a part ever needs
      // its own, this is the test that should be relaxed deliberately.
      final scales = {
        for (final p in snap.parts) PartModelLibrary.lookup(p.type)!.scale,
      };
      expect(scales, {LemParts.modelUnitToMetres});
    });

    test('the renderer puts an Eagle on the per-part path', () {
      // The closest thing to "the models appear" that runs without a GPU:
      // fs.SceneView needs a real Impeller surface, so nothing under
      // test/screenshots (all software TopDownPainter) can draw a kitbash
      // craft. What IS checkable is the branch — isKitbash decides between
      // drawing the part list and drawing one whole-craft model, and a false
      // here is exactly the bug where an Eagle renders as an Apollo CSM.
      expect(VesselNodes.isKitbash(VesselSnapshot.of(bake(buildEagle()))),
          isTrue);
    });

    test('a craft of unmodelled CATALOG parts still draws from its parts', () {
      // Art is not what decides the path — provenance is. A craft the player
      // assembled from catalog parts is drawn as the stack they assembled
      // whether or not any of those parts has a bake yet; the stand-ins are the
      // first frame of that stack, not a different craft.
      final d = CraftDesign(name: 'Stock')
        ..addPart(def: catalog.byId('mk1-capsule')!, instanceId: 'pod');
      final snap = VesselSnapshot.of(bake(d));
      expect(PartModelLibrary.has('mk1-capsule'), isFalse,
          reason: 'no stock part declares a bake');
      expect(VesselNodes.isKitbash(snap), isTrue);
    });

    test('every hand-built vessel is drawn as ONE whole-craft model', () {
      // The invariant the render-path branch exists to protect. These craft
      // were authored AS the whole-craft model and calibrated against its
      // silhouette — [VesselNodes.fallbackAftM] and
      // [ExhaustNodes.defaultNozzleZM] are both measured off it — so drawing
      // any of them from its part list would put the wrong ship on screen with
      // its plume in the wrong place.
      //
      // What keeps them there is that nothing hand-built is a catalog part.
      // `PartSnapshot.type` is `Part.assetKey`, which falls back to the DISPLAY
      // NAME when `defId` is empty, and every part below is built by hand with
      // no defId. A display name that happened to normalise onto a catalog id
      // ('Core' meeting a part called `core`) would silently move an unrelated
      // craft onto the per-part path, so the collision is asserted directly
      // rather than left to the two rosters never overlapping by luck.
      //
      // This is the FULL menu-reachable fleet: every route from the main menu
      // into a flight spawns one of these.
      final earth = SampleWorld.realSystem().require(const BodyId('earth'));
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
      ]) {
        for (final p in v.allParts) {
          expect(p.defId, isEmpty, reason: '${v.name}/${p.name} is hand-built');
        }
        final snap = VesselSnapshot.of(v);
        expect(snap.parts, isNotEmpty, reason: v.name);
        for (final p in snap.parts) {
          expect(PartModelLibrary.isCatalogPart(p.type), isFalse,
              reason: '${v.name}/${p.type} normalises onto a catalog id, so '
                  'this craft would be drawn from its parts instead of as the '
                  'model it was authored as');
          expect(PartModelLibrary.defFor(p.type), isNull, reason: p.type);
          expect(PartModelLibrary.has(p.type), isFalse,
              reason: '${v.name}/${p.type} has art it was never meant to draw');
        }
        expect(VesselNodes.isKitbash(snap), isFalse, reason: v.name);
      }
    });

    test('a vessel spawned outside the sample world is hand-built too', () {
      // `SimulationView`'s debug panel spawns a bare impactor: one Part with a
      // display name, no defId, built inline rather than through
      // `SampleWorld`. It is therefore the one craft the game can put in the
      // world that the fleet loop above cannot reach, and it must land on the
      // same side of the render branch — a test mass drawn as a stack of
      // primitives is a different object on screen.
      final impactor = Vessel(
        id: const VesselId('impactor-1'),
        name: 'Impactor 1',
        ownerId: 'p',
        state: const StateVector(
            position: Vector3(6371030, 0, 0), velocity: Vector3(-200, 0, 0)),
        dominantBody: const BodyId('earth'),
        stages: [
          Stage(index: 0, parts: [
            Part(
              id: const PartId('impactor-1-hull'),
              name: 'Test mass',
              dryMass: 500,
              crossSectionArea: 4,
            ),
          ]),
        ],
      );
      final snap = VesselSnapshot.of(impactor);
      expect(snap.parts, hasLength(1));
      expect(snap.parts.first.type, 'Test mass');
      expect(PartModelLibrary.isCatalogPart('Test mass'), isFalse);
      expect(VesselNodes.isKitbash(snap), isFalse);
    });

    test('the assembler is the only thing in the app that stamps a defId', () {
      // The safety argument for keying the render path off provenance, stated
      // as a property of the source rather than as a list of craft that happen
      // to pass today. A new hand-built vessel added to `sample_world` is
      // covered by it whether or not anyone remembers to add it above; a NEW
      // writer of `Part.defId` is what would need thinking about, and this
      // fails the moment one appears.
      //
      // The two legitimate writers are `VesselAssembler` (the VAB's bake) and
      // `GameStateCodec` (which round-trips what the assembler wrote), plus the
      // part-calibration dev harness, whose whole purpose is to put catalog
      // parts on screen.
      final writers = <String>[];
      for (final f in Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))) {
        if (RegExp(r'^\s*defId:', multiLine: true)
            .hasMatch(f.readAsStringSync())) {
          writers.add(f.path.replaceAll(r'\', '/'));
        }
      }
      expect(
          writers.toSet(),
          {
            'lib/domain/parts/vessel_assembler.dart',
            'lib/application/persistence/game_state_codec.dart',
            'lib/main_part_calibration_dev.dart',
          },
          reason: 'a new writer of Part.defId puts a new population of craft '
              'on the per-part render path. That is fine when the parts really '
              'do come from the catalog — add the file here — and a bug when '
              'they do not, because the craft will be drawn as a stack of '
              'primitives instead of as the model it was authored as.');
    });

    test('a hand-built part still reports something, and it is not an id', () {
      // Sample vessels are built as bare Parts with display names and no
      // defId. They must keep falling back to the name — and must NOT
      // accidentally collide with a catalog id, which would give an unrelated
      // craft LM art.
      final p = Part(id: const PartId('p1'), name: 'Core', dryMass: 100);
      expect(p.defId, isEmpty);
      expect(p.assetKey, 'Core');
      expect(PartModelLibrary.has(p.assetKey), isFalse);
    });
  });
}
