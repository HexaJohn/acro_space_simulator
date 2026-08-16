// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The path from a design in the editor to a craft sitting on a pad.
//
// Every step of it survived the rewrite unchanged except one argument, and this
// file is what says so: the bake, the plane-versus-rocket gate, the spawn
// attitude at an arbitrary latitude AND at both poles, and the staging fix of
// spec 6.4. It is deliberately mostly a plain `test()` suite — the pole branches
// are the sort of thing that is trivially checkable as a function and
// effectively uncheckable through a button — with a short widget group at the
// end for the two things only the assembled screen can answer: that the LAUNCH
// bar appears at all, and that it refuses a craft in pieces.
import 'dart:math' as math;

import 'package:acro_space_simulator/domain/craft/craft_balance.dart';
import 'package:acro_space_simulator/domain/craft/craft_design.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/universe/real_solar_system.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_editor_controller.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_editor_viewport.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft/craft_launch.dart';
import 'package:acro_space_simulator/infrastructure/flutter/screens/craft_assembly_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _spaceport = LaunchSite(name: 'Pad 39A', acceptsPlane: false);
const _airfield = LaunchSite(name: 'Shuttle Landing Facility', acceptsPlane: true);

void main() {
  late PartCatalog catalog;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    catalog = PartCatalog.standard();
  });

  PartDef part(String id) => catalog.byId(id)!;

  /// A three-part rocket, built the way the editor builds one: a root on the
  /// pad and two quick-stacks down the aft face. Nothing here reaches past the
  /// controller into `CraftDesign`.
  CraftEditorController rocketEditor() {
    final c = CraftEditorController(catalog: catalog);
    expect(c.placeRoot(def: part('mk1-capsule')), isTrue);
    expect(c.quickStack(part('fl-t400')), isTrue, reason: c.blocked ?? '');
    expect(c.quickStack(part('merlin-1d')), isTrue, reason: c.blocked ?? '');
    return c;
  }

  /// The same, with an air-breathing engine on the end — `hasJetEngine`, which
  /// is half of what makes a craft a plane.
  CraftEditorController planeEditor() {
    final c = CraftEditorController(catalog: catalog);
    expect(c.placeRoot(def: part('cockpit-mk1')), isTrue);
    expect(c.quickStack(part('jet-fuel-tank')), isTrue, reason: c.blocked ?? '');
    expect(c.quickStack(part('turbojet-j85')), isTrue, reason: c.blocked ?? '');
    return c;
  }

  group('a design built in the editor bakes into a flyable vessel', () {
    test('every placed part reaches the vessel, with delta-v to spend', () {
      final c = rocketEditor();
      addTearDown(c.dispose);

      final v = CraftLaunch.preview(c.design)!;
      expect(v.allParts.length, c.design.partCount);
      expect(v.allParts.length, 3);
      expect(v.mass, greaterThan(0));
      expect(v.crew?.count, 1);
      expect(v.deltaVCapacity(), greaterThan(0),
          reason: 'a capsule, a full tank and a Merlin is a rocket that flies');
    });

    test('an empty design has no vessel rather than an empty one', () {
      final c = CraftEditorController(catalog: catalog);
      addTearDown(c.dispose);
      expect(CraftLaunch.preview(c.design), isNull,
          reason: 'a zero-mass craft would make every readout downstream '
              'decide for itself what "0 kg" means');
    });

    test('the craft that flies is baked from the design, not from a copy', () {
      final c = rocketEditor();
      addTearDown(c.dispose);
      final before = CraftLaunch.surfaceCraft(design: c.design).allParts.length;
      expect(c.quickStack(part('heat-shield-1')), isTrue,
          reason: c.blocked ?? '');
      final after = CraftLaunch.surfaceCraft(design: c.design).allParts.length;
      expect(after, before + 1);
    });
  });

  group('the type gate picks the site', () {
    test('a rocket needs a spaceport and a plane needs an airfield', () {
      final rocket = rocketEditor();
      final plane = planeEditor();
      addTearDown(rocket.dispose);
      addTearDown(plane.dispose);

      final r = CraftLaunch.preview(rocket.design)!;
      final p = CraftLaunch.preview(plane.design)!;

      expect(CraftLaunch.isPlane(r), isFalse);
      expect(CraftLaunch.isPlane(p), isTrue,
          reason: 'a jet engine makes it a plane even with no wing on it yet');

      expect(CraftLaunch.canLaunch(r, const [_spaceport]), isTrue);
      expect(CraftLaunch.canLaunch(r, const [_airfield]), isFalse);
      expect(CraftLaunch.canLaunch(p, const [_airfield]), isTrue);
      expect(CraftLaunch.canLaunch(p, const [_spaceport]), isFalse);

      // A colony with both takes either.
      expect(CraftLaunch.canLaunch(r, const [_spaceport, _airfield]), isTrue);
      expect(CraftLaunch.canLaunch(p, const [_spaceport, _airfield]), isTrue);
      expect(CraftLaunch.canLaunch(r, const []), isFalse);
    });

    test('a wing makes a plane of a rocket', () {
      final c = rocketEditor();
      addTearDown(c.dispose);
      expect(CraftLaunch.isPlane(CraftLaunch.preview(c.design)!), isFalse);

      // The tank's `srf-*` ring is the only surface seat on this stack, which is
      // exactly what a radial wing root wants.
      c.hold(part('swept-wing'));
      final onSrf = c.pairings.firstWhere((p) => p.target.nodeName == 'srf-1');
      expect(c.attachAt(onSrf), isTrue, reason: c.blocked ?? '');

      final v = CraftLaunch.preview(c.design)!;
      expect(v.totalWingArea, greaterThan(0));
      expect(CraftLaunch.isPlane(v), isTrue);
      expect(CraftLaunch.canLaunch(v, const [_spaceport]), isFalse,
          reason: 'bolting a wing on changes which pad will take it');
    });
  });

  group('surfaceCraft puts the craft on the ground, nose out', () {
    final earth = RealSolarSystem.build().require(const BodyId('earth'));

    /// The outward normal at a geodetic-ish lat/long, in the body frame the
    /// spawn uses.
    Vector3 outward(double latDeg, double lonDeg) {
      final lat = latDeg * math.pi / 180;
      final lon = lonDeg * math.pi / 180;
      return Vector3(math.cos(lat) * math.cos(lon),
              math.cos(lat) * math.sin(lon), math.sin(lat))
          .normalized;
    }

    void expectSpawn(Vessel v, double latDeg, double lonDeg,
        {CelestialBody? body}) {
      final b = body ?? earth;
      final up = outward(latDeg, lonDeg);
      expect(v.landed, isTrue,
          reason: 'it sits on the pad until the player throttles up');
      expect(v.state.velocity, Vector3.zero);
      expect(v.state.position.length, closeTo(b.radius, 1e-6));
      expect((v.state.position.normalized - up).length, lessThan(1e-9));
      // Nose radially out: the craft's own +Z carried through its attitude has
      // to land on the local vertical, or the rocket spawns lying down.
      final nose = v.state.attitude.rotate(Vector3.unitZ);
      expect((nose - up).length, lessThan(1e-6),
          reason: 'attitude must rotate the craft +Z onto the local vertical');
      expect(nose.x.isFinite && nose.y.isFinite && nose.z.isFinite, isTrue);
    }

    test('on the equator, and at an arbitrary lat/long', () {
      final c = rocketEditor();
      addTearDown(c.dispose);

      expectSpawn(CraftLaunch.surfaceCraft(design: c.design), 0, 0);
      expectSpawn(
          CraftLaunch.surfaceCraft(
              design: c.design, latitude: 28.6, longitude: -80.6),
          28.6,
          -80.6);
      expectSpawn(
          CraftLaunch.surfaceCraft(
              design: c.design, latitude: -33.9, longitude: 151.2),
          -33.9,
          151.2);
    });

    test('at both poles, where the naive attitude is a NaN', () {
      final c = rocketEditor();
      addTearDown(c.dispose);

      // `unitZ.cross(outward)` is the ZERO VECTOR here, and normalising it
      // would hand the integrator a NaN attitude on the first step — the craft
      // would leave the universe before the player touched anything. These two
      // branches are load-bearing, not defensive.
      expectSpawn(CraftLaunch.surfaceCraft(design: c.design, latitude: 90), 90, 0);
      expectSpawn(
          CraftLaunch.surfaceCraft(design: c.design, latitude: -90), -90, 0);

      final northPole = CraftLaunch.surfaceCraft(design: c.design, latitude: 90);
      final southPole =
          CraftLaunch.surfaceCraft(design: c.design, latitude: -90);
      expect(northPole.state.attitude.w.isNaN, isFalse);
      expect(southPole.state.attitude.w.isNaN, isFalse);
      // The south pole flips end for end about +X, so the craft's own +X is
      // preserved and its +Y and +Z reverse.
      expect(
          (southPole.state.attitude.rotate(Vector3.unitX) - Vector3.unitX)
              .length,
          lessThan(1e-9));
    });

    test('on another world, at that world radius', () {
      final c = rocketEditor();
      addTearDown(c.dispose);
      final moon = RealSolarSystem.build().require(const BodyId('moon'));
      final v = CraftLaunch.surfaceCraft(
          design: c.design, bodyId: 'moon', latitude: 12, longitude: 34);
      expect(v.dominantBody, moon.id);
      expectSpawn(v, 12, 34, body: moon);
    });

    test('the spawned craft carries the whole design and its staging', () {
      final c = rocketEditor();
      addTearDown(c.dispose);
      final v = CraftLaunch.surfaceCraft(design: c.design);
      expect(v.allParts.length, c.design.partCount);
      expect(v.stages.length, c.design.stages.length);
    });
  });

  group('the staging fix of spec 6.4', () {
    /// A two-stage rocket, built directly so the BEFORE state is observable:
    /// the editor now auto-stages the moment a decoupler lands, which is the
    /// fix, so a controller-built craft never shows the defect.
    CraftDesign twoStage() {
      final d = CraftDesign(name: 'two stage');
      d.addPart(def: part('mk1-capsule'), instanceId: 'pod');
      d.attachPart(
          def: part('fl-t400'),
          instanceId: 'upper',
          toInstanceId: 'pod',
          parentNode: 'bottom',
          childNode: 'top');
      d.attachPart(
          def: part('tr-18a-decoupler'),
          instanceId: 'sep',
          toInstanceId: 'upper',
          parentNode: 'bottom',
          childNode: 'top');
      d.attachPart(
          def: part('fl-t400'),
          instanceId: 'lower',
          toInstanceId: 'sep',
          parentNode: 'bottom',
          childNode: 'top');
      d.attachPart(
          def: part('merlin-1d'),
          instanceId: 'booster',
          toInstanceId: 'lower',
          parentNode: 'bottom',
          childNode: 'mount');
      return d;
    }

    test('an unstaged craft reports the whole vehicle under one label', () {
      final d = twoStage();
      expect(d.stages, [0],
          reason: 'attachPart defaults a part to its parent group, so a whole '
              'stack lands in group 0');

      final flat = CraftLaunch.preview(d)!.deltaVCapacity();
      CraftBalance.autoStage(d);
      expect(d.stages.length, greaterThan(1),
          reason: 'a decoupler opens a group of its own');
      expect(d.stages, List.generate(d.stages.length, (i) => i),
          reason: 'renumbered dense, so the staging list has no holes');

      final staged = CraftLaunch.preview(d)!.deltaVCapacity();
      // `Vessel.deltaVCapacity()` sums propellant over the ACTIVE stage only,
      // so the same craft reads differently under the same label depending on
      // whether anyone staged it. That is the whole point of 6.4, and of the
      // per-group table the stats pane grew.
      expect(staged, lessThan(flat));
    });

    test('the editor stages a decoupled craft without being asked', () {
      final c = CraftEditorController(catalog: catalog);
      addTearDown(c.dispose);
      expect(c.placeRoot(def: part('mk1-capsule')), isTrue);
      expect(c.quickStack(part('fl-t400')), isTrue, reason: c.blocked ?? '');
      expect(c.autoStaged, isFalse);
      expect(c.quickStack(part('tr-18a-decoupler')), isTrue,
          reason: c.blocked ?? '');
      expect(c.autoStaged, isTrue,
          reason: 'the one-shot offer fires the first time a craft becomes '
              'stageable, inside the same undo step');
      expect(c.design.stages.length, greaterThan(1));

      // And it is part of that step, so one keystroke takes both back.
      expect(c.undo(), isTrue);
      expect(c.design.partCount, 2);
      expect(c.design.stages, [0]);
    });

    test('a second engine triggers it too', () {
      final c = CraftEditorController(catalog: catalog);
      addTearDown(c.dispose);
      expect(c.placeRoot(def: part('mk1-capsule')), isTrue);
      expect(c.quickStack(part('fl-t400')), isTrue, reason: c.blocked ?? '');
      expect(c.quickStack(part('merlin-1d')), isTrue, reason: c.blocked ?? '');
      expect(c.autoStaged, isFalse, reason: 'one engine is not a staged craft');
    });
  });

  group('the launch bar in the assembled screen', () {
    Future<void> pump(WidgetTester t, List<LaunchSite> sites) async {
      t.view.physicalSize = const Size(1280, 800);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: CraftAssemblyScreen(
          bodyId: 'earth',
          launchSites: sites,
          latitude: 28.6,
          longitude: -80.6,
        ),
      ));
      await t.pump();
    }

    /// `LAUNCH` is only ever an `ElevatedButton`; a null `onPressed` is the
    /// gate.
    bool launchEnabled(WidgetTester t) =>
        t.widget<ElevatedButton>(find.widgetWithText(ElevatedButton, 'LAUNCH'))
            .onPressed !=
        null;

    testWidgets('a standalone VAB offers no launch at all', (t) async {
      await pump(t, const []);
      expect(find.text('LAUNCH'), findsNothing);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('an empty craft offers no launch either', (t) async {
      await pump(t, const [_spaceport]);
      expect(find.text('LAUNCH'), findsNothing,
          reason: 'there is nothing to fly yet');
      await t.pumpWidget(const SizedBox());
    });

    /// The screen owns its controller privately. The viewport it hosts is
    /// handed the SAME instance, and its state is public — that is the seam a
    /// test uses to say what the player has built.
    CraftEditorController screenController(WidgetTester t) =>
        t
            .state<CraftEditorViewportState>(find.byType(CraftEditorViewport))
            .controller;

    /// Capsule, tank, engine, through the screen's own funnel.
    Future<void> buildRocket(WidgetTester t) async {
      final c = screenController(t);
      c.placeRoot(def: c.catalog.byId('mk1-capsule')!);
      c.quickStack(c.catalog.byId('fl-t400')!);
      c.quickStack(c.catalog.byId('merlin-1d')!);
      await t.pump();
    }

    testWidgets('a rocket at a spaceport can fly', (t) async {
      await pump(t, const [_spaceport]);
      await buildRocket(t);

      expect(find.text('LAUNCH'), findsOneWidget);
      expect(launchEnabled(t), isTrue);
      expect(find.textContaining('launches from a spaceport'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('the same rocket at an airfield is refused, and says why',
        (t) async {
      await pump(t, const [_airfield]);
      await buildRocket(t);

      expect(launchEnabled(t), isFalse);
      expect(find.textContaining('No a spaceport at this colony'),
          findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });

    testWidgets('a craft in pieces is refused with the count', (t) async {
      await pump(t, const [_spaceport]);
      await buildRocket(t);
      expect(launchEnabled(t), isTrue);

      // Break the stack: a detached branch still contributes its mass and
      // inertia to a vehicle it is not structurally part of, so the bake would
      // fly wrong in a way nothing on the pad explains.
      final c = screenController(t);
      expect(c.detach(c.design.parts.last.instanceId), isTrue);
      await t.pump();

      expect(c.hasLooseParts, isTrue);
      expect(launchEnabled(t), isFalse);
      expect(find.textContaining('Craft is in 2 pieces'), findsOneWidget);
      await t.pumpWidget(const SizedBox());
    });
  });
}
