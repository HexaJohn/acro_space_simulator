// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/craft/craft_balance.dart';
import 'package:acro_space_simulator/domain/craft/craft_design.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/parts/attach_node.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/domain/parts/vessel_assembler.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_parts.dart';

/// [CraftBalance] is what an editor draws over a craft — the centre of mass, the
/// thrust line, the framing box, the staging groups — and every one of those is
/// a claim about the vehicle that will actually fly.
///
/// The load-bearing test here is the ANTI-DRIFT one: [CraftBalance.partMass] is
/// a re-derivation of `VesselAssembler`'s private `_partMass`, so this suite
/// pins the two equal. A VAB whose centre of mass disagrees with the craft the
/// simulation baked is worse than a VAB with no marker at all, and nothing else
/// in the build would notice the day they diverged.
void main() {
  const assembler = VesselAssembler();
  final catalog = PartCatalog.standard();
  PartDef part(String id) =>
      catalog.byId(id) ??
      fail('the shipped catalog has no part "$id" — the LM roster moved');

  Vessel bake(CraftDesign d) => assembler.assemble(
        id: 'balance',
        name: d.name,
        ownerId: 'crew',
        parts: d.parts,
        state: const StateVector(
            position: Vector3(1837400, 0, 0), velocity: Vector3(0, 1633, 0)),
        dominantBody: const BodyId('moon'),
      );

  /// Pod on top, tank under it, engine under that: the smallest craft with
  /// mass, propellant, thrust and a real stack of joints.
  CraftDesign podTankEngine() {
    final d = CraftDesign(name: 'Stack');
    d.addPart(def: testPod, instanceId: 'pod');
    d.attachPart(
      def: testTank(),
      instanceId: 'tank',
      toInstanceId: 'pod',
      parentNode: 'bottom',
      childNode: 'top',
    );
    d.attachPart(
      def: testEngine(),
      instanceId: 'engine',
      toInstanceId: 'tank',
      parentNode: 'bottom',
      childNode: 'top',
    );
    return d;
  }

  /// The Eagle as flown, built entirely out of ring mates.
  CraftDesign eagle() {
    final d = CraftDesign(name: 'Eagle');
    d.addPart(def: part('eagle-command-pod'), instanceId: 'ascent');
    d.attachPart(
      def: part('eagle-fuel-tank'),
      instanceId: 'descent',
      toInstanceId: 'ascent',
      parentNode: 'stage-bottom',
      childNode: 'deck-top',
    );
    d.attachPart(
      def: part('eagle-thruster'),
      instanceId: 'dps',
      toInstanceId: 'descent',
      parentNode: 'engine-mount',
      childNode: 'mount',
    );
    for (var i = 1; i <= 4; i++) {
      d.attachPart(
        def: part('eagle-legs'),
        instanceId: 'gear-$i',
        toInstanceId: 'descent',
        parentNode: 'leg-$i',
        childNode: 'outrigger',
      );
      d.attachPart(
        def: part('eagle-rcs-block'),
        instanceId: 'rcs-$i',
        toInstanceId: 'ascent',
        parentNode: 'quad-$i',
        childNode: 'mount',
      );
    }
    return d;
  }

  group('part mass', () {
    test('is dry mass plus everything in the tanks', () {
      expect(CraftBalance.partMass(testPod), 800);
      // 300 kg dry, 400 units of fuel and 440 of oxidiser at 5 kg each.
      expect(CraftBalance.partMass(testTank()), closeTo(300 + 4200, 1e-9));
    });

    test('totals what the assembler bakes, for the whole LM', () {
      final d = eagle();
      final byHand =
          d.parts.fold(0.0, (s, p) => s + CraftBalance.partMass(p.def));
      expect(byHand, closeTo(bake(d).mass, 1e-9),
          reason: 'partMass re-derives the assembler private one; if this ever '
              'fails, the editor and the simulation are weighing two different '
              'craft and the fix belongs in whichever of them is wrong');
      // Sanity on the absolute number: the flown Apollo 11 LM was 15,103 kg at
      // launch, and the gap is crew and consumables, which are not parts.
      expect(byHand, closeTo(15025, 1e-6));
    });
  });

  group('centre of mass', () {
    test('a two-part stack balances where the arithmetic says', () {
      final d = CraftDesign(name: 'Two');
      d.addPart(def: testPod, instanceId: 'pod');
      d.attachPart(
        def: testTank(),
        instanceId: 'tank',
        toInstanceId: 'pod',
        parentNode: 'bottom',
        childNode: 'top',
      );
      // The pod's bottom node is at z = -0.7 and the tank's top node at
      // z = +1.0, so the tank's origin lands at -1.7.
      expect(d.partById('tank')!.position.z, closeTo(-1.7, 1e-12));

      // 800 kg at z = 0 against 4,500 kg at z = -1.7.
      const expected = -1.7 * 4500 / (800 + 4500);
      final com = CraftBalance.centreOfMass(d);
      expect(com.x, closeTo(0, 1e-12));
      expect(com.y, closeTo(0, 1e-12));
      expect(com.z, closeTo(expected, 1e-12));

      // Empty, the 300 kg tank barely moves the pod.
      const dryExpected = -1.7 * 300 / (800 + 300);
      expect(CraftBalance.dryCentreOfMass(d).z, closeTo(dryExpected, 1e-12));
      expect(CraftBalance.dryCentreOfMass(d).z, greaterThan(com.z),
          reason: 'the craft balances higher at burnout, and the travel between '
              'the two is what makes a craft flip when it stages');
    });

    test('agrees with the baked vessel, on the axis, for a symmetric craft',
        () {
      final d = eagle();
      final com = CraftBalance.centreOfMass(d);
      final baked = bake(d).massProperties.centerOfMass;

      expect(com.x, closeTo(baked.x, 1e-9));
      expect(com.y, closeTo(baked.y, 1e-9));
      expect(com.z, closeTo(baked.z, 1e-9));

      // Four legs and four quads at 90 degrees cancel; everything else is on
      // the axis. This is the visible confirmation that ring symmetry is real:
      // a scattered ring shows up here as a centre of mass off the centreline,
      // and a lander like that torques itself over on every descent burn.
      expect(com.x, closeTo(0, 1e-9), reason: 'centre of mass $com');
      expect(com.y, closeTo(0, 1e-9), reason: 'centre of mass $com');
    });

    test('an empty design reports the origin rather than a NaN', () {
      final empty = CraftDesign(name: 'Empty');
      expect(CraftBalance.centreOfMass(empty), Vector3.zero);
      expect(CraftBalance.dryCentreOfMass(empty), Vector3.zero);
      expect(CraftBalance.bounds(empty), isNull);
      expect(CraftBalance.thrust(empty), isNull);
    });
  });

  group('thrust', () {
    test('an unrotated engine fires aft, from its own seat', () {
      final d = podTankEngine();
      final t = CraftBalance.thrust(d)!;
      expect(t.thrustN, closeTo(200000, 1e-6));
      expect(t.direction.x, closeTo(0, 1e-12));
      expect(t.direction.y, closeTo(0, 1e-12));
      expect(t.direction.z, closeTo(-1, 1e-12),
          reason: 'the nose is +Z, so the exhaust axis is -Z and the reaction '
              'on the craft is the opposite');
      // The engine's top node is at +0.5 and the tank's bottom at -1.0, which
      // puts the engine origin 2.7 m below the pod.
      expect(t.origin.z, closeTo(d.partById('engine')!.position.z, 1e-12));
    });

    test('a rotated engine carries its axis with it', () {
      final d = CraftDesign(name: 'Sideways');
      // A quarter turn about +Y takes local +Z onto +X, so the exhaust leaves
      // along -X.
      d.addPart(
        def: testEngine(),
        instanceId: 'engine',
        position: const Vector3(0, 0, -3),
        rotation: Quaternion.axisAngle(Vector3.unitY, math.pi / 2),
      );
      final t = CraftBalance.thrust(d)!;
      expect(t.direction.x, closeTo(-1, 1e-12));
      expect(t.direction.y, closeTo(0, 1e-12));
      expect(t.direction.z, closeTo(0, 1e-12));
      expect(t.thrustN, closeTo(200000, 1e-6));
      expect(t.origin, const Vector3(0, 0, -3));
    });

    test('two engines report the thrust the craft actually gets', () {
      final d = CraftDesign(name: 'Pair');
      d.addPart(
          def: testEngine(),
          instanceId: 'a',
          position: const Vector3(-2, 0, -1));
      d.addPart(
          def: testEngine(), instanceId: 'b', position: const Vector3(2, 0, -1));
      final both = CraftBalance.thrust(d)!;
      expect(both.thrustN, closeTo(400000, 1e-6));
      expect(both.origin.x, closeTo(0, 1e-12),
          reason: 'thrust-weighted mean of the two seats');
      expect(both.direction.z, closeTo(-1, 1e-12));

      // Turn one nozzle end for end and the pair cancels. Reporting the sum of
      // the labels here would tell the player they have 400 kN of thrust and no
      // way to use it.
      d.rotateTo('b', Quaternion.axisAngle(Vector3.unitY, math.pi));
      final opposed = CraftBalance.thrust(d)!;
      expect(opposed.thrustN, closeTo(0, 1e-9));
      expect(opposed.direction.z, closeTo(-1, 1e-12),
          reason: 'no measured axis, so it falls back to the nominal one');
    });

    test('a craft with no rocket engine has no thrust line', () {
      final d = CraftDesign(name: 'Glider')
        ..addPart(def: testPod, instanceId: 'pod');
      expect(CraftBalance.thrust(d), isNull);
    });
  });

  group('bounds', () {
    test('a known stack measures its own boxes, not its origins', () {
      final d = podTankEngine();
      final b = CraftBalance.bounds(d)!;

      // Pod 1.25 x 1.25 x 1.4 at the origin; tank 1.25 x 1.25 x 2 at z = -1.7;
      // engine 1.25 x 1.25 x 1 at z = -3.2.
      expect(b.max.z, closeTo(0.7, 1e-12));
      expect(b.min.z, closeTo(-3.7, 1e-12));
      expect(b.min.x, closeTo(-0.625, 1e-12));
      expect(b.max.x, closeTo(0.625, 1e-12));
      expect(b.min.y, closeTo(-0.625, 1e-12));
      expect(b.max.y, closeTo(0.625, 1e-12));
    });

    test('a rotated part sweeps the corners its rotation puts outside', () {
      final d = CraftDesign(name: 'Turned');
      // 45 degrees about +Z turns the 2 m square hull into a 2*sqrt(2) diagonal.
      d.addPart(
        def: testHull,
        instanceId: 'hull',
        rotation: Quaternion.axisAngle(Vector3.unitZ, math.pi / 4),
      );
      final b = CraftBalance.bounds(d)!;
      expect(b.max.x, closeTo(math.sqrt2, 1e-12));
      expect(b.min.x, closeTo(-math.sqrt2, 1e-12));
      expect(b.max.z, closeTo(1.0, 1e-12), reason: 'the spin axis is unchanged');
    });

    test('the LM box reaches out to the footpads', () {
      final b = CraftBalance.bounds(eagle())!;
      // The gear stands 9.30 m across, so the box has to be at least that wide
      // or a camera framed on it would cut the legs off.
      expect(b.max.x - b.min.x, greaterThan(9.0));
      expect(b.max.y - b.min.y, greaterThan(9.0));
    });
  });

  group('auto staging', () {
    test('a pod, a tank and the engine it feeds are ONE stage', () {
      final d = podTankEngine();
      CraftBalance.autoStage(d);

      expect(d.stages, [0],
          reason: 'deltaVCapacity sums propellant over the active stage only, '
              'so splitting the tank off the engine it feeds would report a '
              'stage with thrust and no fuel');
      expect(bake(d).deltaVCapacity(), greaterThan(0));
    });

    test('a decoupler opens a stage, and the deeper group fires first', () {
      // pod -> tank -> decoupler -> tank -> engine. The upper tank keeps its
      // own engine off the chain deliberately: [testEngine] authors no bottom
      // node, so nothing can hang under one, and the engine-boundary half of
      // the rule is pinned on the real LM below.
      final d = CraftDesign(name: 'Two stage');
      d.addPart(def: testPod, instanceId: 'pod');
      d.attachPart(
        def: testTank(),
        instanceId: 'tank1',
        toInstanceId: 'pod',
        parentNode: 'bottom',
        childNode: 'top',
      );
      d.attachPart(
        def: _decoupler,
        instanceId: 'sep',
        toInstanceId: 'tank1',
        parentNode: 'bottom',
        childNode: 'top',
      );
      d.attachPart(
        def: testTank(),
        instanceId: 'tank2',
        toInstanceId: 'sep',
        parentNode: 'bottom',
        childNode: 'top',
      );
      d.attachPart(
        def: testEngine(),
        instanceId: 'engine2',
        toInstanceId: 'tank2',
        parentNode: 'bottom',
        childNode: 'top',
      );
      CraftBalance.autoStage(d);

      expect(d.stages, [0, 1]);
      expect(_stageOf(d, ['pod', 'tank1']), {0});
      expect(_stageOf(d, ['sep', 'tank2', 'engine2']), {1},
          reason: 'the booster is farthest from the root, so it carries the '
              'highest index — Vessel.activeStage is stages.last and '
              'separateStage() drops the last, so that is the group that '
              'burns and separates first');

      final v = bake(d);
      expect(v.activeStage!.parts.map((p) => p.id.value).toSet(),
          {'sep', 'tank2', 'engine2'});
      expect(v.separateStage(), isTrue);
      expect(v.activeStage!.parts.map((p) => p.id.value).toSet(),
          {'pod', 'tank1'},
          reason: 'dropping the booster must leave the craft that was carrying '
              'it, not the other way round');
    });

    test('a surface mount rides its host instead of opening a stage', () {
      final d = podTankEngine();
      d.attachPart(
        def: testBlock,
        instanceId: 'rcs',
        toInstanceId: 'tank',
        parentNode: 'skin',
        childNode: 'mount',
      );
      CraftBalance.autoStage(d);
      expect(d.stages, [0]);
    });

    test('the LM lands its gear with the descent stage and its quads with the '
        'cabin', () {
      final d = eagle();
      CraftBalance.autoStage(d);

      expect(d.stages, [0, 1]);
      expect(_stageOf(d, ['ascent', 'rcs-1', 'rcs-2', 'rcs-3', 'rcs-4']), {0},
          reason: 'the quads fly home: they are SURFACE-mounted to the ascent '
              'stage, and only a stack mate under an engine opens a group — '
              'without that qualifier the ascent stage carrying its own APS '
              'would push its own thrusters into the stage below and leave '
              'them on the Moon');
      expect(
          _stageOf(d, ['descent', 'dps', 'gear-1', 'gear-2', 'gear-3', 'gear-4']),
          {1},
          reason: 'the descent stage is stack-mated under an engine-bearing '
              'part, so it opens the group that fires and separates first');

      final v = bake(d);
      expect(v.activeStage!.index, 1);
      expect(v.activeStage!.engines.map((p) => p.defId).toList(),
          ['eagle-thruster'],
          reason: 'the DPS is what lands the vehicle, so it must be the engine '
              'the active stage fires');
      expect(v.deltaVCapacity(), closeTo(2407, 1),
          reason: 'the flown descent budget was roughly 2,470 m/s');
    });

    test('re-running it is idempotent and leaves no holes', () {
      final d = eagle();
      CraftBalance.autoStage(d);
      final once = {for (final p in d.parts) p.instanceId: p.stage};
      CraftBalance.autoStage(d);
      expect({for (final p in d.parts) p.instanceId: p.stage}, once);

      // And it repairs hand-made holes rather than preserving them.
      d.assignStage('ascent', 7);
      CraftBalance.autoStage(d);
      expect(d.stages, [0, 1]);
    });

    test('a loose part is its own root and lands in the first group', () {
      final d = podTankEngine();
      d.addPart(
          def: testHull, instanceId: 'loose', position: const Vector3(8, 0, 0));
      CraftBalance.autoStage(d);
      expect(d.partById('loose')!.stage, 0);
      expect(d.stages, [0]);
    });
  });
}

/// The distinct stage numbers [ids] ended up in — a set, so a group that split
/// reads as more than one element.
Set<int> _stageOf(CraftDesign d, List<String> ids) =>
    {for (final id in ids) d.partById(id)!.stage};

/// A 1.25 m stack decoupler with the two opposed nodes the stock roster does not
/// carry yet. Local to this suite: [CraftBalance.autoStage] keys off
/// [PartCategory.decoupler] and nothing else in the fixtures is one.
const PartDef _decoupler = PartDef(
  id: 'test-decoupler',
  name: 'Test Decoupler',
  category: PartCategory.decoupler,
  dryMass: 50,
  size: Vector3(1.25, 1.25, 0.2),
  attachNodes: [
    AttachNode(name: 'top', position: Vector3(0, 0, 0.1)),
    AttachNode(
        name: 'bottom',
        position: Vector3(0, 0, -0.1),
        direction: Vector3(0, 0, -1)),
  ],
);
