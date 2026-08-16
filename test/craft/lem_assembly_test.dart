// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
import 'dart:math' as math;

import 'package:acro_space_simulator/domain/craft/craft_design.dart';
import 'package:acro_space_simulator/domain/craft/craft_design_codec.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/parts/lem_parts.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/domain/parts/vessel_assembler.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

/// End to end: an Apollo Lunar Module built ONLY out of attach operations
/// against the SHIPPED catalog must survive the bake and come out flyable.
///
/// Two things are under test here and neither has another guard.
///
/// The first is that the craft-design context and [VesselAssembler] compose:
/// the editor never hand-places a coordinate for the physics to be right.
///
/// The second is that [LemParts]' authored attach nodes are the ones a craft is
/// actually built from. Every mate below names a real node by name and every
/// expected value is computed from real node coordinates, so moving, renaming
/// or deleting a node fails HERE rather than only on screen — a suite that
/// asserted against its own fixture parts would let a whole node ring vanish
/// and stay green.
///
/// The numbers are the published LM dimensions [LemParts] claims to reproduce:
/// 4.65 m from the centreline to a footpad, 0.39 m of bell clearance above the
/// footpad plane, 15,025 kg on the pad, 2,150 kg of ascent-stage burnout mass.
/// They are cross-checks on the geometry and the mass budget, not tolerances to
/// widen when something moves.
void main() {
  const assembler = VesselAssembler();

  /// The vehicle as flown: ascent stage on top, descent stage nested under it,
  /// the DPS in the descent stage's centre bay, four legs and four RCS quads
  /// placed by symmetry. Stage 0 is the descent stage, stage 1 flies home.
  ///
  /// A fresh [PartCatalog] per design deliberately: [ResourceContainer.amount]
  /// is mutable and the bake hands the catalog's containers straight to the
  /// baked part, so two designs off one catalog would share tankage.
  CraftDesign buildEagle() {
    final catalog = PartCatalog.standard();
    PartDef part(String id) =>
        catalog.byId(id) ??
        fail('the shipped catalog has no part "$id" — the LM roster was '
            'renamed or dropped, and every saved craft naming it is now '
            'unloadable');

    final d = CraftDesign(name: 'Eagle');
    d.addPart(def: part('eagle-command-pod'), instanceId: 'ascent', stage: 1);
    d.attachPart(
      def: part('eagle-fuel-tank'),
      instanceId: 'descent',
      toInstanceId: 'ascent',
      parentNode: 'stage-bottom',
      childNode: 'deck-top',
      stage: 0,
    );
    d.attachPart(
      def: part('eagle-thruster'),
      instanceId: 'dps',
      toInstanceId: 'descent',
      parentNode: 'engine-mount',
      childNode: 'mount',
    );
    // Each ring is seeded on its FIRST authored node and completed by symmetry,
    // so the op has to reproduce the other three nodes the model authors. That
    // is what 'radial symmetry lands on the authored node rings' checks.
    d.attachRadial(
      def: part('eagle-legs'),
      instanceIdPrefix: 'gear',
      toInstanceId: 'descent',
      parentNode: 'leg-1',
      childNode: 'outrigger',
      count: 4,
    );
    d.attachRadial(
      def: part('eagle-rcs-block'),
      instanceIdPrefix: 'rcs',
      toInstanceId: 'ascent',
      parentNode: 'quad-1',
      childNode: 'mount',
      count: 4,
    );
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

  /// Compass bearing of a placed part about the craft axis, in whole degrees
  /// measured from +X toward +Y. Rounded before the wrap so a copy that lands a
  /// float hair short of 360 reads as 0 rather than as 359.
  int azimuthDeg(PlacedPart p) {
    final deg = math.atan2(p.position.y, p.position.x) * 180 / math.pi;
    return ((deg.round() % 360) + 360) % 360;
  }

  test('the shipped roster assembles into the flown two-stage vehicle', () {
    final d = buildEagle();
    expect(d.partCount, 11, reason: 'ascent, descent, DPS, 4 legs, 4 quads');
    expect(d.rootId, 'ascent');
    for (final p in d.parts) {
      expect(LemParts.ids, contains(p.def.id),
          reason: '"${p.instanceId}" is built from "${p.def.id}", which the LM '
              'family does not ship');
    }

    final v = bake(d);
    expect(v.allParts.length, 11, reason: 'the bake must not lose a part');

    // Staging decides what stays on the Moon: the gear and the DPS go with the
    // descent stage, the quads fly home with the cabin.
    expect(v.stages.map((s) => s.index).toList(), [0, 1]);
    expect(v.stages[0].parts.map((p) => p.defId).toList(), [
      'eagle-fuel-tank',
      'eagle-thruster',
      ...List.filled(4, 'eagle-legs'),
    ]);
    expect(v.stages[1].parts.map((p) => p.defId).toList(), [
      'eagle-command-pod',
      ...List.filled(4, 'eagle-rcs-block'),
    ]);

    // 15,025 kg against the 15,103 kg Apollo 11 LM at launch; the 78 kg gap is
    // crew, consumables and stowed payload, none of which are parts.
    expect(v.mass, closeTo(15025, 1e-6));
  });

  test('the descent stage holds a mate on each side without blocking itself',
      () {
    // The descent stage is the case stack-node occupancy is easiest to get
    // wrong on a real craft: it hangs UPWARD off its own 'deck-top' and holds
    // the DPS DOWNWARD on 'engine-mount', so both directions are live on one
    // part at once. Counting only children would leave 'deck-top' looking free
    // and let a second part be bolted inside the ascent stage; counting the
    // whole part as spent would make the vehicle unbuildable.
    final d = buildEagle();

    expect(d.isStackNodeOccupied('descent', 'deck-top'), isTrue,
        reason: "spent UPWARD — it is the node 'descent' hangs from");
    expect(d.isStackNodeOccupied('ascent', 'stage-bottom'), isTrue,
        reason: 'spent DOWNWARD — the same joint seen from the parent');
    expect(d.isStackNodeOccupied('descent', 'engine-mount'), isTrue,
        reason: 'spent DOWNWARD by the DPS');
    expect(d.isStackNodeOccupied('dps', 'mount'), isTrue);
    expect(d.isStackNodeOccupied('ascent', 'dock-top'), isFalse,
        reason: 'the CSM tunnel is free until something docks to it');

    // Surface nodes are shared on purpose: four legs seat on four separate
    // 'leg-*' nodes, but nothing about a surface node is ever "spent".
    expect(d.isStackNodeOccupied('descent', 'leg-1'), isFalse);

    // Each spent node refuses a second part, from whichever side it was spent.
    final catalog = PartCatalog.standard();
    void refuse(String parentId, String node, String reason) {
      expect(
          () => d.attachPart(
                def: catalog.byId('eagle-thruster')!,
                instanceId: 'intruder',
                toInstanceId: parentId,
                parentNode: node,
                childNode: 'mount',
              ),
          throwsStateError,
          reason: reason);
    }

    refuse('descent', 'deck-top',
        'a part bolted here would sit inside the ascent stage');
    refuse('descent', 'engine-mount', 'a second DPS in the same bay');
    refuse('ascent', 'stage-bottom', 'a second stage under the cabin');
    expect(d.partCount, 11, reason: 'no refused mate may leave a part behind');

    // And the vehicle is still buildable: 'dock-top' was never spent.
    d.attachPart(
      def: catalog.byId('eagle-command-pod')!,
      instanceId: 'csm-stand-in',
      toInstanceId: 'ascent',
      parentNode: 'dock-top',
      childNode: 'dock-top',
    );
    expect(d.partCount, 12);
  });

  test('mating on the authored nodes reproduces the flown dimensions', () {
    final d = buildEagle();
    final legs = [for (var k = 0; k < 4; k++) d.partById('gear-$k')!];
    final quads = [for (var k = 0; k < 4; k++) d.partById('rcs-$k')!];

    /// The footpad: the outboard, bottom corner of the leg's own box, since the
    /// leg export is measured from its outrigger pickup down to the pad.
    Vector3 footpad(PlacedPart leg) =>
        leg.position +
        leg.rotation
            .rotate(Vector3(leg.def.size.x / 2, 0, -leg.def.size.z / 2));

    for (final leg in legs) {
      final pad = footpad(leg);
      expect(math.sqrt(pad.x * pad.x + pad.y * pad.y), closeTo(4.65, 1e-9),
          reason: 'footpad at $pad; the flown LM stood 4.7 m off the '
              'centreline and the roster is authored to 4.65 m');
    }

    final padPlane = footpad(legs.first).z;
    for (final leg in legs) {
      expect(footpad(leg).z, closeTo(padPlane, 1e-9),
          reason: 'a lander whose pads are not coplanar cannot sit level');
    }

    // The DPS bell hangs below the descent stage's base plane and the gear has
    // to out-reach it. Apollo 15 damaged its bell on touchdown, so this margin
    // is meant to stay slim — but it must stay positive.
    final dps = d.partById('dps')!;
    final bellExit = dps.position.z - dps.def.size.z / 2;
    expect(bellExit - padPlane, closeTo(0.39, 1e-9),
        reason: 'bell exit at $bellExit, footpad plane at $padPlane');

    // The gear sits on the vehicle's axes and the quads on the diagonals: the
    // forward leg is the one carrying the ladder under the hatch. Swapping the
    // two rings would put a strut where the crew climbs down.
    expect(legs.map(azimuthDeg).toList(), [0, 90, 180, 270]);
    expect(quads.map(azimuthDeg).toList(), [45, 135, 225, 315]);
  });

  test('radial symmetry lands on the authored node rings', () {
    final d = buildEagle();

    /// Every copy of a ring must seat on the node the part model authors for
    /// it — same point, facing back along that node's outward normal. The
    /// symmetry op reproduces the ring; it does not get to invent one.
    void ringSeatsOnNodes({
      required String hullId,
      required String nodePrefix,
      required String instancePrefix,
      required String childNode,
    }) {
      final hull = d.partById(hullId)!;
      for (var k = 0; k < 4; k++) {
        final nodeName = '$nodePrefix-${k + 1}';
        final node = hull.nodeInBody(nodeName);
        expect(node, isNotNull,
            reason: '${hull.def.id} has no "$nodeName" node, so the ring the '
                'symmetry op is meant to reproduce is incomplete');

        final child = d.partById('$instancePrefix-$k')!;
        final seat = child.def.node(childNode)!;
        final seatInBody =
            child.position + child.rotation.rotate(seat.position);
        expect((seatInBody - node!.position).length, lessThan(1e-9),
            reason: 'copy $k seats at $seatInBody but $nodeName is at '
                '${node.position}');

        final facing = child.rotation.rotate(seat.direction);
        expect((facing + node.direction).length, lessThan(1e-9),
            reason: 'copy $k faces $facing; the hull normal at $nodeName is '
                '${node.direction}, and a mount facing anywhere else is '
                'floating off the skin');
      }
    }

    ringSeatsOnNodes(
      hullId: 'descent',
      nodePrefix: 'leg',
      instancePrefix: 'gear',
      childNode: 'outrigger',
    );
    ringSeatsOnNodes(
      hullId: 'ascent',
      nodePrefix: 'quad',
      instancePrefix: 'rcs',
      childNode: 'mount',
    );
  });

  test('the loaded lander balances where the descent burn needs it', () {
    final v = bake(buildEagle());
    final com = v.massProperties.centerOfMass;

    // Four legs and four quads at 90 degrees cancel; everything else is on the
    // axis. A CoM that wandered off axis would torque the lander over on every
    // descent burn.
    expect(com.x, closeTo(0, 1e-9), reason: 'CoM $com');
    expect(com.y, closeTo(0, 1e-9), reason: 'CoM $com');

    // Fully loaded, 9.6 t of the 15 t is descent propellant, so the CoM rides
    // inside the descent stage: below the ascent stage's base skirt (z = -1.73)
    // and well above the DPS bell exit (z = -4.47), which is what puts the
    // descent thrust line through the mass it is decelerating.
    expect(com.z, lessThan(-1.73));
    expect(com.z, greaterThan(-4.47));
    expect(com.z, closeTo(-1.7712, 1e-3),
        reason: 'CoM $com — recompute this deliberately if an LM mass or a '
            'stack node moves, do not widen it');
  });

  test('the ascent stage flies home on its own', () {
    // Deleting the descent stage is how the editor weighs the ascent stage
    // alone: remove() takes the whole subtree, so the DPS and the gear go too.
    final d = buildEagle();
    expect(d.remove('descent').toSet(),
        {'descent', 'dps', 'gear-0', 'gear-1', 'gear-2', 'gear-3'});
    expect(d.partCount, 5);

    final v = bake(d);
    expect(v.stages, hasLength(1));
    expect(v.activeStage!.index, 1);
    expect(v.activeStage!.engines.map((p) => p.defId).toList(),
        ['eagle-command-pod'],
        reason: 'the APS is modelled on the part carrying its own tanks, so a '
            'staged ascent stage still has something to burn');
    expect(v.activeStage!.hasActiveEngine, isTrue);
    expect(v.crew!.count, 2, reason: 'commander and lunar module pilot');

    // Burnout mass: 2,060 kg of ascent structure plus four 22.5 kg quads is the
    // flown 2,150 kg exactly. The whole family is apportioned around that
    // figure, so any LM mass edit has to keep it true.
    final dry = v.allParts.fold(0.0, (double s, p) => s + p.dryMass);
    expect(dry, closeTo(2150, 1e-9));
    expect(v.mass, closeTo(4791, 1e-6), reason: '2,150 kg + 2,641 kg aboard');

    // deltaVCapacity treats EVERY resource in the stage as burnable, so this
    // reads high: the quads' 288 kg of monopropellant is counted as if the APS
    // could drink it. On the APS's own 2,353 kg the stage is worth 2,256 m/s,
    // against the flown ascent budget of ~2,220 m/s.
    expect(v.deltaVCapacity(), closeTo(2444, 1));
  });

  test('a saved design reloads out of the shipped catalog', () {
    final original = buildEagle();
    const codec = CraftDesignCodec();
    final file =
        jsonDecode(jsonEncode(codec.encode(original))) as Map<String, dynamic>;

    // Decoding against the SHIPPED catalog is itself the assertion: the codec
    // refuses a def id it cannot resolve, so a craft written out of ids that
    // exist only in a fixture would throw right here.
    final restored = codec.decode(file, catalog: PartCatalog.standard());

    expect(restored.rootId, original.rootId);
    expect(restored.parts.map((p) => p.def.id).toList(),
        original.parts.map((p) => p.def.id).toList());
    for (final p in restored.parts) {
      final was = original.partById(p.instanceId)!;
      expect(p.stage, was.stage, reason: p.instanceId);
      // Node names are the joint's identity in a save file. A design that came
      // back mated through different nodes would re-solve to different
      // geometry the moment the player dragged anything.
      expect(p.attachment?.parentInstanceId, was.attachment?.parentInstanceId,
          reason: p.instanceId);
      expect(p.attachment?.parentNode, was.attachment?.parentNode,
          reason: p.instanceId);
      expect(p.attachment?.childNode, was.attachment?.childNode,
          reason: p.instanceId);
    }

    final a = bake(original), b = bake(restored);
    expect(b.mass, closeTo(a.mass, 1e-9));
    expect(b.massProperties.centerOfMass.z,
        closeTo(a.massProperties.centerOfMass.z, 1e-9));
    expect(b.deltaVCapacity(), closeTo(a.deltaVCapacity(), 1e-9));
  });
}
