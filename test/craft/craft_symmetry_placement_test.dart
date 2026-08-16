// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
import 'dart:math' as math;

import 'package:acro_space_simulator/domain/craft/attach_targets.dart';
import 'package:acro_space_simulator/domain/craft/craft_balance.dart';
import 'package:acro_space_simulator/domain/craft/craft_design.dart';
import 'package:acro_space_simulator/domain/craft/craft_design_codec.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

/// The regression suite for the editor's symmetry model.
///
/// Symmetry x4 is FOUR ORDINARY MATES, one per member of the target node's
/// ring, each naming its OWN authored node. That is not a style preference; it
/// is the only scheme in which every `PartAttachment` names a node that exists,
/// which is what `CraftDesign.fromParts` validates on EVERY load. A design whose
/// attachments name synthesised or shared nodes is one the codec writes happily
/// and can never read back, and the parts it would lose are exactly the ones a
/// player spent the most clicks on: the RCS quads and the landing gear.
///
/// So each test below ends where it has to end — at an encode, a decode, and a
/// craft that is still the craft.
void main() {
  final catalog = PartCatalog.standard();
  PartDef part(String id) =>
      catalog.byId(id) ??
      fail('the shipped catalog has no part "$id" — the LM roster moved');

  final ascentDef = part('eagle-command-pod');
  final descentDef = part('eagle-fuel-tank');

  CraftDesign twoStage() {
    final d = CraftDesign(name: 'Eagle');
    d.addPart(def: ascentDef, instanceId: 'ascent');
    d.attachPart(
      def: descentDef,
      instanceId: 'descent',
      toInstanceId: 'ascent',
      parentNode: 'stage-bottom',
      childNode: 'deck-top',
    );
    return d;
  }

  /// The editor's placement op, verbatim: resolve the ring, take [count] evenly
  /// spaced members from the seed, and mate one copy to EACH of them. One edit,
  /// [count] parts, one undo step.
  List<String> placeRing(
    CraftDesign design, {
    required PartDef def,
    required String idPrefix,
    required String toInstanceId,
    required String seedNode,
    required String childNode,
    required int count,
    double roll = 0,
  }) {
    final parent = design.partById(toInstanceId)!;
    final ring = AttachTargets.ringContaining(parent.def, seedNode)!;
    final ids = <String>[];
    for (final node in ring.subset(count, ring.indexOf(seedNode))) {
      design.attachPart(
        def: def,
        instanceId: '$idPrefix@$node',
        toInstanceId: toInstanceId,
        parentNode: node,
        childNode: childNode,
        roll: roll,
      );
      ids.add('$idPrefix@$node');
    }
    return ids;
  }

  /// Compass bearing about the craft axis, whole degrees from +X toward +Y.
  int azimuthDeg(PlacedPart p) {
    final deg = math.atan2(p.position.y, p.position.x) * 180 / math.pi;
    return ((deg.round() % 360) + 360) % 360;
  }

  /// Every copy must seat on the node the model authors for it: same point,
  /// facing back along that node's outward normal. Symmetry reproduces the
  /// authored ring; it does not get to invent one.
  void expectSeatedOnAuthoredNodes(
    CraftDesign d, {
    required String hullId,
    required List<String> ids,
    required String childNode,
  }) {
    final hull = d.partById(hullId)!;
    for (final id in ids) {
      final child = d.partById(id)!;
      final nodeName = child.attachment!.parentNode;
      final node = hull.nodeInBody(nodeName)!;

      final seat = child.def.node(childNode)!;
      final seatInBody = child.position + child.rotation.rotate(seat.position);
      expect((seatInBody - node.position).length, lessThan(1e-9),
          reason: '$id seats at $seatInBody but $nodeName is at '
              '${node.position}');

      final facing = child.rotation.rotate(seat.direction);
      expect((facing + node.direction).length, lessThan(1e-9),
          reason: '$id faces $facing; the hull normal at $nodeName is '
              '${node.direction}, and a mount facing anywhere else is floating '
              'off the skin');
    }
  }

  group('x4 on a ring', () {
    test('four quads land on the four authored nodes, each naming its own', () {
      final d = twoStage();
      final ids = placeRing(
        d,
        def: part('eagle-rcs-block'),
        idPrefix: 'rcs',
        toInstanceId: 'ascent',
        seedNode: 'quad-1',
        childNode: 'mount',
        count: 4,
      );
      expect(ids, [
        'rcs@quad-1',
        'rcs@quad-2',
        'rcs@quad-3',
        'rcs@quad-4',
      ]);

      expectSeatedOnAuthoredNodes(d,
          hullId: 'ascent', ids: ids, childNode: 'mount');

      // THE point of the scheme: four distinct parent nodes, not one node
      // claimed four times. A shared node is what makes a saved craft
      // unloadable, and it is invisible until the load.
      final parentNodes =
          ids.map((id) => d.partById(id)!.attachment!.parentNode).toList();
      expect(parentNodes.toSet(), hasLength(4));
      expect(parentNodes, ['quad-1', 'quad-2', 'quad-3', 'quad-4']);

      // The quads sit on the diagonals, 45 degrees off the crew's forward axis,
      // which is why the flown vehicle measured 4.29 m across them.
      expect(ids.map((id) => azimuthDeg(d.partById(id)!)).toList(),
          [45, 135, 225, 315]);
    });

    test('four legs land on the axes and reach the flown stance', () {
      final d = twoStage();
      final ids = placeRing(
        d,
        def: part('eagle-legs'),
        idPrefix: 'gear',
        toInstanceId: 'descent',
        seedNode: 'leg-1',
        childNode: 'outrigger',
        count: 4,
      );
      expectSeatedOnAuthoredNodes(d,
          hullId: 'descent', ids: ids, childNode: 'outrigger');
      expect(ids.map((id) => azimuthDeg(d.partById(id)!)).toList(),
          [0, 90, 180, 270],
          reason: 'the front leg is the one under the hatch that carries the '
              'ladder, so the gear is NOT on the diagonals like the RCS');

      // Footpad: the outboard, bottom corner of the leg's own box.
      for (final id in ids) {
        final leg = d.partById(id)!;
        final pad = leg.position +
            leg.rotation
                .rotate(Vector3(leg.def.size.x / 2, 0, -leg.def.size.z / 2));
        expect(math.sqrt(pad.x * pad.x + pad.y * pad.y), closeTo(4.65, 1e-9),
            reason: '$id footpad at $pad');
      }
    });

    test('x2 puts the pair diametrically opposite', () {
      final d = twoStage();
      final ids = placeRing(
        d,
        def: part('eagle-rcs-block'),
        idPrefix: 'rcs',
        toInstanceId: 'ascent',
        seedNode: 'quad-2',
        childNode: 'mount',
        count: 2,
      );
      expect(ids, ['rcs@quad-2', 'rcs@quad-4']);
      final bearings = ids.map((id) => azimuthDeg(d.partById(id)!)).toList();
      expect((bearings[1] - bearings[0]).abs(), 180);
      expect(AttachTargets.symmetryGroupOf(d, ids.first).length, 2);
    });

    test('a roll applies to the whole group and stays readable afterwards', () {
      final d = twoStage();
      final ids = placeRing(
        d,
        def: part('eagle-rcs-block'),
        idPrefix: 'rcs',
        toInstanceId: 'ascent',
        seedNode: 'quad-1',
        childNode: 'mount',
        count: 4,
        roll: math.pi / 3,
      );
      for (final id in ids) {
        expect(AttachTargets.currentRoll(d, id), closeTo(math.pi / 3, 1e-9),
            reason: '$id — roll is derived from geometry, so the group has to '
                'read back the same angle it was placed at, on every member');
      }
      // A rolled copy is still bolted to its own node.
      expectSeatedOnAuthoredNodes(d,
          hullId: 'ascent', ids: ids, childNode: 'mount');
    });
  });

  group('the whole vehicle', () {
    /// The Eagle, built the way the editor builds it: two stack mates, an
    /// engine, and two ring placements.
    CraftDesign eagle() {
      final d = twoStage();
      d.attachPart(
        def: part('eagle-thruster'),
        instanceId: 'dps',
        toInstanceId: 'descent',
        parentNode: 'engine-mount',
        childNode: 'mount',
      );
      placeRing(d,
          def: part('eagle-legs'),
          idPrefix: 'gear',
          toInstanceId: 'descent',
          seedNode: 'leg-1',
          childNode: 'outrigger',
          count: 4);
      placeRing(d,
          def: part('eagle-rcs-block'),
          idPrefix: 'rcs',
          toInstanceId: 'ascent',
          seedNode: 'quad-1',
          childNode: 'mount',
          count: 4);
      return d;
    }

    test('eleven parts, and the centre of mass sits on the axis', () {
      final d = eagle();
      expect(d.partCount, 11, reason: 'ascent, descent, DPS, 4 legs, 4 quads');

      final com = CraftBalance.centreOfMass(d);
      expect(com.x, closeTo(0, 1e-9), reason: 'centre of mass $com');
      expect(com.y, closeTo(0, 1e-9), reason: 'centre of mass $com');
      expect(com.z, closeTo(-1.7712, 1e-3),
          reason: 'fully loaded, 9.6 t of the 15 t is descent propellant, so '
              'the balance point rides inside the descent stage');
    });

    test('a x4 craft encodes, decodes and validates', () {
      final original = eagle();
      const codec = CraftDesignCodec();
      final file =
          jsonDecode(jsonEncode(codec.encode(original))) as Map<String, dynamic>;

      // The assertion IS the call: decode goes through CraftDesign.fromParts,
      // which validates the whole forest and throws on the first attachment
      // naming a node that does not exist. A synthesised or shared node name
      // makes every LM ever saved permanently unloadable, and this is the line
      // that would say so.
      final restored = codec.decode(file, catalog: PartCatalog.standard());

      expect(restored.partCount, original.partCount);
      expect(restored.rootId, original.rootId);
      for (final p in restored.parts) {
        final was = original.partById(p.instanceId)!;
        expect(p.def.id, was.def.id, reason: p.instanceId);
        expect(p.stage, was.stage, reason: p.instanceId);
        expect((p.position - was.position).length, lessThan(1e-9),
            reason: p.instanceId);
        expect(p.rotation.w, closeTo(was.rotation.w, 1e-12),
            reason: p.instanceId);
        // Node names are the joint's identity in a save file: a design that
        // came back mated through different nodes would re-solve to different
        // geometry the moment the player dragged anything.
        expect(p.attachment?.parentNode, was.attachment?.parentNode,
            reason: p.instanceId);
        expect(p.attachment?.childNode, was.attachment?.childNode,
            reason: p.instanceId);
      }

      // And the symmetry survives, because nothing about it was written down.
      expect(AttachTargets.symmetryGroupOf(restored, 'rcs@quad-3'), {
        'rcs@quad-1',
        'rcs@quad-2',
        'rcs@quad-3',
        'rcs@quad-4',
      });
      expect(AttachTargets.symmetryGroupOf(restored, 'gear@leg-3'),
          hasLength(4));
      expect(CraftBalance.centreOfMass(restored).x, closeTo(0, 1e-9));
    });

    test('deleting one copy leaves the ring open, not broken', () {
      final d = eagle();
      // The editor deletes the whole group; the domain deletes one part. Either
      // way what is left has to stay loadable.
      expect(d.remove('rcs@quad-2'), ['rcs@quad-2']);
      expect(AttachTargets.symmetryGroupOf(d, 'rcs@quad-1'), hasLength(3));

      final open = AttachTargets.openNodes(d)
          .where((t) => t.ownerInstanceId == 'ascent')
          .map((t) => t.nodeName)
          .toSet();
      expect(open, contains('quad-2'),
          reason: 'a surface node is never spent, so the vacated seat is '
              'offered again immediately');

      const codec = CraftDesignCodec();
      expect(
          () => codec.decode(
                jsonDecode(jsonEncode(codec.encode(d)))
                    as Map<String, dynamic>,
                catalog: PartCatalog.standard(),
              ),
          returnsNormally);
    });
  });

  group('why not attachRadial', () {
    test('it lands the same geometry and records a structure that is a lie',
        () {
      final byRing = twoStage();
      final ids = placeRing(
        byRing,
        def: part('eagle-rcs-block'),
        idPrefix: 'rcs',
        toInstanceId: 'ascent',
        seedNode: 'quad-1',
        childNode: 'mount',
        count: 4,
      );

      final bySpin = twoStage();
      bySpin.attachRadial(
        def: part('eagle-rcs-block'),
        instanceIdPrefix: 'rcs',
        toInstanceId: 'ascent',
        parentNode: 'quad-1',
        childNode: 'mount',
        count: 4,
      );

      // For an ON-AXIS parent the two agree to the last bit, which is exactly
      // why the difference is easy to miss.
      for (var k = 0; k < 4; k++) {
        final a = byRing.partById(ids[k])!;
        final b = bySpin.partById('rcs-$k')!;
        expect((a.position - b.position).length, lessThan(1e-9),
            reason: 'copy $k');
      }

      // The structure is where they part company. Every radial copy is recorded
      // against the SEED's single node, so four parts claim one seat: the ring
      // build is what keeps the save file describing the craft it drew.
      expect(
          {
            for (var k = 0; k < 4; k++)
              bySpin.partById('rcs-$k')!.attachment!.parentNode
          },
          {'quad-1'});
      expect(
          {for (final id in ids) byRing.partById(id)!.attachment!.parentNode},
          {'quad-1', 'quad-2', 'quad-3', 'quad-4'});
    });
  });
}
