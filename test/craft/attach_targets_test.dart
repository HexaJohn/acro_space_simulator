// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:convert';
import 'dart:math' as math;

import 'package:acro_space_simulator/domain/craft/attach_targets.dart';
import 'package:acro_space_simulator/domain/craft/craft_design.dart';
import 'package:acro_space_simulator/domain/craft/craft_design_codec.dart';
import 'package:acro_space_simulator/domain/parts/attach_node.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_parts.dart';

/// [AttachTargets] is the whole editor's view of what a craft will accept, so
/// everything downstream of it — the markers, the picker, the symmetry chips,
/// the roll widget — inherits whatever this file lets through.
///
/// Two properties matter more than the rest and are asserted against the SHIPPED
/// LM roster rather than fixtures, so moving or renaming a real node fails here:
///
///   * an offered target is one the design will actually accept, and
///   * a ring is only a ring when the GEOMETRY says so, not when the names do.
///
/// The second is what keeps symmetry honest. Ring-based symmetry places one
/// ordinary mate per member, each naming its own real node, which is the reason
/// a symmetric craft survives `CraftDesign` validation and the codec. A ring
/// detected from names alone would let a mistyped constant scatter four landing
/// legs while the save file still looked structurally valid.
void main() {
  final catalog = PartCatalog.standard();
  PartDef part(String id) =>
      catalog.byId(id) ??
      fail('the shipped catalog has no part "$id" — the LM roster moved');

  final ascentDef = part('eagle-command-pod');
  final descentDef = part('eagle-fuel-tank');
  final quadDef = part('eagle-rcs-block');
  final tankDef = part('fl-t400');
  final engineDef = part('merlin-1d');

  /// Ascent stage with the descent stage nested under it: the smallest design
  /// that has a stack node spent from EACH direction plus all twelve of the LM's
  /// surface seats open.
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

  /// `owner.node` for every target, for set comparisons that read like the craft.
  Set<String> names(Iterable<AttachTarget> targets) =>
      {for (final t in targets) '${t.ownerInstanceId}.${t.nodeName}'};

  group('open nodes', () {
    test('a spent stack node disappears from BOTH ends of the joint', () {
      final d = twoStage();
      final open = names(AttachTargets.openNodes(d));

      expect(open, isNot(contains('ascent.stage-bottom')),
          reason: 'spent downward — the descent stage hangs off it');
      expect(open, isNot(contains('descent.deck-top')),
          reason: 'spent upward — it is the node the descent stage hangs FROM, '
              'and a node counted only by its children would look free here and '
              'let a second part be bolted inside the ascent stage');

      expect(open, contains('ascent.dock-top'),
          reason: 'the CSM tunnel is free until something docks to it');
      expect(open, contains('descent.engine-mount'),
          reason: 'the descent stage holds a mate above AND below without '
              'blocking itself');
    });

    test('a surface node is never spent, however many parts sit on it', () {
      final d = twoStage();
      // Three of the four quad seats taken; the shared 'quad-1' would be the
      // first casualty of treating surface nodes as single-occupancy.
      for (var i = 1; i <= 3; i++) {
        d.attachPart(
          def: quadDef,
          instanceId: 'rcs-$i',
          toInstanceId: 'ascent',
          parentNode: 'quad-$i',
          childNode: 'mount',
        );
      }
      final open = names(AttachTargets.openNodes(d));
      for (var i = 1; i <= 4; i++) {
        expect(open, contains('ascent.quad-$i'),
            reason: 'quad-$i must stay offered: a hull hosts many radial '
                'mounts, which is what lets four copies share one skin');
      }
      // And the parts now on the hull bring their own seats.
      expect(open, contains('rcs-1.mount'));
    });

    test('the kind filter is what lights only the chevrons', () {
      final d = twoStage();
      final surface = AttachTargets.openNodes(d, kind: AttachKind.surface);
      expect(surface.every((t) => t.kind == AttachKind.surface), isTrue);
      expect(names(surface), {
        for (var i = 1; i <= 4; i++) 'ascent.quad-$i',
        for (var i = 1; i <= 4; i++) 'descent.leg-$i',
        for (var i = 1; i <= 4; i++) 'descent.deflector-$i',
      });

      final stack = AttachTargets.openNodes(d, kind: AttachKind.stack);
      expect(names(stack), {'ascent.dock-top', 'descent.engine-mount'});
    });

    test('a target carries the seat in CRAFT metres, not part metres', () {
      final d = twoStage();
      final descent = d.partById('descent')!;
      final leg = AttachTargets.openNodes(d)
          .firstWhere((t) => t.nodeName == 'leg-1');

      final authored = descentDef.node('leg-1')!;
      expect(leg.positionInCraft.x, closeTo(authored.position.x, 1e-12));
      expect(leg.positionInCraft.z,
          closeTo(descent.position.z + authored.position.z, 1e-12),
          reason: 'the descent stage sits below the craft origin, so a target '
              'quoting part-local Z would draw its marker inside the cabin');
      expect(leg.directionInCraft.length, closeTo(1.0, 1e-12));
      expect(leg.size, 0.30);
    });
  });

  group('pairings', () {
    test('a surface-only part is offered every skin seat and no stack node', () {
      final d = twoStage();
      final pairings = AttachTargets.pairingsFor(d, quadDef);

      expect(pairings.every((p) => p.childNodeName == 'mount'), isTrue,
          reason: 'the quad authors exactly one node');
      expect(pairings.every((p) => p.target.kind == AttachKind.surface), isTrue,
          reason: 'a surface mount cannot bolt to a stack ring; that is a '
              'modelling error, not a near miss');
      expect(names(pairings.map((p) => p.target)), {
        for (var i = 1; i <= 4; i++) 'ascent.quad-$i',
        for (var i = 1; i <= 4; i++) 'descent.leg-$i',
        for (var i = 1; i <= 4; i++) 'descent.deflector-$i',
      });
      expect(pairings, hasLength(12));
    });

    test('size class decides which stack node the descent stage may use', () {
      final d = CraftDesign(name: 'Eagle')
        ..addPart(def: ascentDef, instanceId: 'ascent');
      final stackPairs = AttachTargets.pairingsFor(d, descentDef)
          .where((p) => p.target.kind == AttachKind.stack)
          .map((p) => '${p.target.nodeName}<-${p.childNodeName}')
          .toSet();

      expect(stackPairs, {'stage-bottom<-deck-top'},
          reason: 'the 4.2 m seat takes the 4.2 m deck and nothing else: '
              'dock-top is 0.81 m and engine-mount is 1.5 m, and an editor that '
              'offered either would bolt an ascent stage through a hatch');

      // Every offered pairing is one the design will actually accept.
      for (final p in AttachTargets.pairingsFor(d, descentDef)) {
        final probe = CraftDesign(name: 'probe')
          ..addPart(def: ascentDef, instanceId: 'ascent');
        expect(
            () => probe.attachPart(
                  def: descentDef,
                  instanceId: 'x',
                  toInstanceId: p.target.ownerInstanceId,
                  parentNode: p.target.nodeName,
                  childNode: p.childNodeName,
                ),
            returnsNormally,
            reason: '${p.target.nodeName} <- ${p.childNodeName} was offered');
      }
    });

    test('an excluded subtree stops offering itself a mate', () {
      final d = twoStage();
      final without =
          AttachTargets.pairingsFor(d, quadDef, exclude: {'descent'});
      expect(without.map((p) => p.target.ownerInstanceId).toSet(), {'ascent'});
    });
  });

  group('pairings for a part already on the craft', () {
    /// tank -> tank -> engine. The middle tank is the interesting one: its
    /// 'bottom' is spent by the engine hanging off it, and its 'top' is spent
    /// only by the joint a move would replace.
    CraftDesign stack() {
      final d = CraftDesign(name: 'Falcon')
        ..addPart(def: tankDef, instanceId: 'tank-0');
      d.attachPart(
        def: tankDef,
        instanceId: 'tank-1',
        toInstanceId: 'tank-0',
        parentNode: 'bottom',
        childNode: 'top',
      );
      d.attachPart(
        def: engineDef,
        instanceId: 'engine-2',
        toInstanceId: 'tank-1',
        parentNode: 'bottom',
        childNode: 'mount',
      );
      return d;
    }

    String label(TargetPairing p) => '${p.target.ownerInstanceId}.'
        '${p.target.nodeName}<-${p.childNodeName}';

    test('the mover cannot seat itself on a node its own children hold', () {
      final offers =
          AttachTargets.pairingsFor(stack(), tankDef, movingInstanceId: 'tank-1');

      expect(offers.map(label), isNot(contains('tank-0.top<-bottom')),
          reason: 'the engine already holds tank-1.bottom, so mate refuses '
              'this outright — and a marker drawn for it makes the refusal '
              'look like the player aimed badly');
      expect(offers.map(label), contains('tank-0.top<-top'),
          reason: 'the joint a move REPLACES must not disqualify its own node, '
              'or a stacked part could never be re-seated at all');
    });

    test('every offered move is one mate accepts', () {
      // The property the instance above is one case of. Occupancy is a
      // two-sided rule and only a two-sided offer set can satisfy it.
      final offers =
          AttachTargets.pairingsFor(stack(), tankDef, movingInstanceId: 'tank-1');
      expect(offers, isNotEmpty);

      for (final p in offers) {
        final probe = stack();
        expect(
            () => probe.mate(
                  instanceId: 'tank-1',
                  toInstanceId: p.target.ownerInstanceId,
                  parentNode: p.target.nodeName,
                  childNode: p.childNodeName,
                ),
            returnsNormally,
            reason: '${label(p)} was offered');
      }
    });

    test('a surface node the mover already hosts stays offered', () {
      // Surface seats are shared by design, so a quad on the mover's skin must
      // not cost it the node that seats it somewhere else.
      final d = stack();
      d.attachPart(
        def: quadDef,
        instanceId: 'rcs',
        toInstanceId: 'tank-1',
        parentNode: 'srf-1',
        childNode: 'mount',
      );
      final offers =
          AttachTargets.pairingsFor(d, tankDef, movingInstanceId: 'tank-1');
      expect(offers.map((p) => p.childNodeName), contains('srf-1'));
    });

    test('the mover is never offered a seat on its own branch', () {
      final offers =
          AttachTargets.pairingsFor(stack(), tankDef, movingInstanceId: 'tank-1');
      expect(offers.map((p) => p.target.ownerInstanceId).toSet(), {'tank-0'},
          reason: 'tank-1 and the engine under it are the branch being moved; '
              'mating to either builds a cycle');
    });
  });

  group('rings', () {
    test('the descent stage carries two rings and they do not merge', () {
      final rings = AttachTargets.ringsOf(descentDef);
      expect(rings.map((r) => r.prefix).toList(), ['leg', 'deflector'],
          reason: 'authored order; a merged eight-node ring would be neither '
              'round nor evenly spaced and must not be detected');

      expect(rings[0].count, 4);
      expect(rings[0].radius, closeTo(2.11, 1e-9));
      expect(rings[0].height, closeTo(0.90, 1e-9));
      expect(rings[1].count, 4);
      expect(rings[1].radius, closeTo(2.05, 1e-9));
      expect(rings[1].height, closeTo(0.60, 1e-9));
    });

    test('members come back in ascending azimuth, matching the authored ring',
        () {
      final legs = AttachTargets.ringContaining(descentDef, 'leg-3')!;
      expect(legs.nodeNames, ['leg-1', 'leg-2', 'leg-3', 'leg-4']);
      expect(legs.indexOf('leg-3'), 2);
      expect(legs.indexOf('nope'), -1);

      // The gear sits on the vehicle's axes, the quads on the diagonals: the
      // ordering has to follow the geometry, not the suffix.
      final quads = AttachTargets.ringsOf(ascentDef).single;
      expect(quads.prefix, 'quad');
      expect(quads.nodeNames, ['quad-1', 'quad-2', 'quad-3', 'quad-4']);
      expect(quads.radius, closeTo(1.80, 1e-9));
      expect(quads.height, closeTo(0.0, 1e-9));
    });

    test('a ring needs the geometry, not just the names', () {
      // One member 6 cm out of round: name-only detection would accept this and
      // put a landing leg through the tankage.
      expect(AttachTargets.ringsOf(_ringWithRadii(const [2.0, 2.0, 2.06, 2.0])),
          isEmpty);
      // One member 5 cm high of the others.
      expect(AttachTargets.ringsOf(_ringAtHeights(const [0.5, 0.5, 0.55, 0.5])),
          isEmpty);
      // Evenly named, unevenly spaced: 0, 90, 100, 270 degrees.
      expect(AttachTargets.ringsOf(_ringAtAzimuths(const [0, 90, 100, 270])),
          isEmpty);
      // Round, level and even: this one is a ring.
      final ok = AttachTargets.ringsOf(_ringAtAzimuths(const [0, 90, 180, 270]));
      expect(ok.single.count, 4);
    });

    test('a stack node family is never a ring', () {
      expect(AttachTargets.ringsOf(_stackRing), isEmpty,
          reason: 'a ring exists to be mated many times over and a stack node '
              'mates exactly once');
    });

    test('a lone member and an unringed node produce nothing', () {
      expect(AttachTargets.ringContaining(quadDef, 'mount'), isNull);
      expect(AttachTargets.ringsOf(quadDef), isEmpty);
      expect(AttachTargets.ringsOf(testBlock), isEmpty);
    });
  });

  group('symmetry counts and subsets', () {
    test('a four-ring offers 1, 2 and 4 and nothing else', () {
      final quads = AttachTargets.ringsOf(ascentDef).single;
      expect(AttachTargets.symmetryCountsFor(quads), [1, 2, 4]);
      expect(AttachTargets.symmetryCountsFor(null), [1],
          reason: 'a part with no ring offers x1 only, and the UI greys the '
              'rest with that as the reason');
      final three =
          AttachTargets.ringsOf(_ringAtAzimuths(const [0, 120, 240])).single;
      expect(AttachTargets.symmetryCountsFor(three), [1, 3]);
    });

    test('x2 means diametrically opposite, not "the first two"', () {
      final quads = AttachTargets.ringsOf(ascentDef).single;
      expect(quads.subset(2, 0), ['quad-1', 'quad-3']);
      expect(quads.subset(2, 1), ['quad-2', 'quad-4']);
      expect(quads.subset(2, 3), ['quad-4', 'quad-2'],
          reason: 'the walk wraps, so the seed is always first');
      expect(quads.subset(4, 2), ['quad-3', 'quad-4', 'quad-1', 'quad-2']);
      expect(quads.subset(1, 2), ['quad-3']);
    });

    test('a count the ring cannot express falls back to the seed alone', () {
      final quads = AttachTargets.ringsOf(ascentDef).single;
      expect(quads.subset(3, 0), ['quad-1'],
          reason: 'three copies on a four-ring have nowhere even to sit');
      expect(quads.subset(8, 0), ['quad-1']);
      expect(quads.subset(0, 0), ['quad-1']);
      expect(() => quads.subset(2, 4), throwsRangeError);
    });

    test('a mirror pair reflects, and refuses when the seat is on the plane',
        () {
      final quads = AttachTargets.ringsOf(ascentDef).single;
      // The quads sit on the diagonals, so the YZ plane swaps 45 with 135.
      expect(quads.mirrorPair(0, Vector3.unitX, ascentDef),
          ['quad-1', 'quad-2']);
      expect(quads.mirrorPair(2, Vector3.unitX, ascentDef),
          ['quad-3', 'quad-4']);

      final legs = AttachTargets.ringsOf(descentDef).first;
      expect(legs.mirrorPair(0, Vector3.unitX, descentDef), ['leg-1', 'leg-3'],
          reason: 'the fore leg reflects onto the aft leg');
      expect(legs.mirrorPair(1, Vector3.unitX, descentDef), ['leg-2'],
          reason: 'the port leg lies ON the YZ plane; its reflection is itself, '
              'and a second copy there would sit inside the first');
    });
  });

  group('symmetry groups', () {
    /// Four quads, one per authored seat, exactly as the editor places them.
    CraftDesign quadRing() {
      final d = twoStage();
      final ring = AttachTargets.ringContaining(ascentDef, 'quad-1')!;
      for (final node in ring.subset(4, ring.indexOf('quad-1'))) {
        d.attachPart(
          def: quadDef,
          instanceId: 'rcs@$node',
          toInstanceId: 'ascent',
          parentNode: node,
          childNode: 'mount',
        );
      }
      return d;
    }

    test('the group is four ids, derived from geometry with nothing stored',
        () {
      final d = quadRing();
      expect(AttachTargets.symmetryGroupOf(d, 'rcs@quad-1'), {
        'rcs@quad-1',
        'rcs@quad-2',
        'rcs@quad-3',
        'rcs@quad-4',
      });
      // Selecting any member selects them all.
      for (final id in ['rcs@quad-2', 'rcs@quad-4']) {
        expect(AttachTargets.symmetryGroupOf(d, id), hasLength(4));
      }
    });

    test('the group survives an encode/decode round trip', () {
      const codec = CraftDesignCodec();
      final file = jsonDecode(jsonEncode(codec.encode(quadRing())))
          as Map<String, dynamic>;
      // Decoding validates the whole forest: four parts each naming their own
      // real node is what makes that pass.
      final restored = codec.decode(file, catalog: PartCatalog.standard());

      expect(AttachTargets.symmetryGroupOf(restored, 'rcs@quad-1'), {
        'rcs@quad-1',
        'rcs@quad-2',
        'rcs@quad-3',
        'rcs@quad-4',
      }, reason: 'the group is re-derived from the reloaded geometry, so a '
          'fresh catalog handing out different PartDef instances must not '
          'break it');
    });

    test('a different def, stage or child node is a different group', () {
      final d = quadRing();
      // Same seats, different part: a solo thruster on quad-2 is not a sibling
      // of the quads.
      d.remove('rcs@quad-2');
      d.attachPart(
        def: part('eagle-rcs-solo'),
        instanceId: 'solo',
        toInstanceId: 'ascent',
        parentNode: 'quad-2',
        childNode: 'mount',
      );
      expect(AttachTargets.symmetryGroupOf(d, 'rcs@quad-1'),
          {'rcs@quad-1', 'rcs@quad-3', 'rcs@quad-4'});
      expect(AttachTargets.symmetryGroupOf(d, 'solo'), {'solo'});

      // Staging one member out breaks the group, because staging is part of
      // what makes copies interchangeable.
      d.assignStage('rcs@quad-3', 2);
      expect(AttachTargets.symmetryGroupOf(d, 'rcs@quad-1'),
          {'rcs@quad-1', 'rcs@quad-4'});
    });

    test('a root, an unringed mate and an unknown id are their own answers', () {
      final d = twoStage();
      expect(AttachTargets.symmetryGroupOf(d, 'ascent'), {'ascent'},
          reason: 'a free part is a group of one');
      expect(AttachTargets.symmetryGroupOf(d, 'descent'), {'descent'},
          reason: 'stage-bottom is a stack node and belongs to no ring');
      expect(AttachTargets.symmetryGroupOf(d, 'nobody'), isEmpty);
    });
  });

  group('current roll', () {
    // Half a turn each way plus the pi endpoint, where a roll recovered from
    // acos(w) would lose most of its precision.
    const rolls = <double>[
      0.0,
      math.pi / 4,
      -math.pi / 4,
      math.pi / 2,
      -math.pi / 2,
      math.pi,
    ];

    test('a stack mate reports back the roll it was built with', () {
      for (final roll in rolls) {
        final d = CraftDesign(name: 'Eagle')
          ..addPart(def: ascentDef, instanceId: 'ascent');
        d.attachPart(
          def: descentDef,
          instanceId: 'descent',
          toInstanceId: 'ascent',
          parentNode: 'stage-bottom',
          childNode: 'deck-top',
          roll: roll,
        );
        expect(AttachTargets.currentRoll(d, 'descent'), closeTo(roll, 1e-9),
            reason: 'roll $roll');
      }
    });

    test('a surface mate whose alignment is NOT identity reports it too', () {
      // leg-2 faces +Y and the outrigger faces -X, so the alignment rotation is
      // a real quarter turn that has to cancel exactly before the roll is left.
      for (final roll in rolls) {
        final d = CraftDesign(name: 'Eagle')
          ..addPart(def: descentDef, instanceId: 'descent');
        d.attachPart(
          def: part('eagle-legs'),
          instanceId: 'gear',
          toInstanceId: 'descent',
          parentNode: 'leg-2',
          childNode: 'outrigger',
          roll: roll,
        );
        expect(AttachTargets.currentRoll(d, 'gear'), closeTo(roll, 1e-9),
            reason: 'roll $roll');
      }
    });

    test('re-mating in place is how the editor rolls a placed part', () {
      final d = twoStage();
      expect(AttachTargets.currentRoll(d, 'descent'), closeTo(0, 1e-12));

      // The joint being replaced is the one thing that cannot block the move,
      // so Q/E is an ordinary mate back onto the same node.
      d.mate(
        instanceId: 'descent',
        toInstanceId: 'ascent',
        parentNode: 'stage-bottom',
        childNode: 'deck-top',
        roll: math.pi / 6,
      );
      expect(AttachTargets.currentRoll(d, 'descent'),
          closeTo(math.pi / 6, 1e-9));
    });

    test('a free part has no mate axis and reports zero', () {
      final d = twoStage();
      expect(AttachTargets.currentRoll(d, 'ascent'), 0.0);
      expect(AttachTargets.currentRoll(d, 'nobody'), 0.0);
    });
  });

  group('what a pane pays to ask', () {
    // The panes read these queries per ROW, on every controller notification,
    // so their cost is multiplied by the part count of the craft on screen.
    // Counting the reads is the only way to keep that honest: a ring scan that
    // got slower would still pass every behavioural test in this file.

    test('ring detection is answered once per def, not once per caller', () {
      final def = _CountingDef(_ringAtAzimuths(const [0, 90, 180, 270]));
      for (var i = 0; i < 500; i++) {
        expect(AttachTargets.ringsOf(def), hasLength(1));
      }
      expect(def.reads, 1,
          reason: '500 asks of an immutable def must cost one scan of its '
              'nodes, one regex pass per node and one sort');
      expect(identical(AttachTargets.ringsOf(def), AttachTargets.ringsOf(def)),
          isTrue,
          reason: 'and no list is allocated to answer the second one');
    });

    test('a 40-row tree walk costs one ring scan for the whole craft', () {
      final hull = _CountingDef(_ringAtAzimuths(const [0, 90, 180, 270]));
      final d = CraftDesign(name: 'wide')
        ..addPart(def: hull, instanceId: 'hull');
      for (var i = 0; i < 39; i++) {
        d.attachPart(
          def: quadDef,
          instanceId: 'q$i',
          toInstanceId: 'hull',
          parentNode: 'srf-${i % 4 + 1}',
          childNode: 'mount',
        );
      }
      expect(d.partCount, 40);

      // The tree pane's own loop: one symmetry group per row.
      final before = hull.reads;
      for (final p in d.parts) {
        AttachTargets.symmetryGroupOf(d, p.instanceId);
      }
      expect(hull.reads - before, 1,
          reason: '39 mated rows must not each re-derive the hull ring; the '
              'def cannot have changed between two rows of one frame');
    });
  });

  group('value semantics', () {
    test('a target compares equal only while the node has not moved', () {
      final a = AttachTargets.openNodes(twoStage());
      final b = AttachTargets.openNodes(twoStage());
      expect(a, equals(b));
      expect(a.first.hashCode, b.first.hashCode);

      final moved = twoStage()..mate(
          instanceId: 'descent',
          toInstanceId: 'ascent',
          parentNode: 'stage-bottom',
          childNode: 'deck-top',
          roll: math.pi / 2);
      final legBefore =
          a.firstWhere((t) => t.nodeName == 'leg-1');
      final legAfter = AttachTargets.openNodes(moved)
          .firstWhere((t) => t.nodeName == 'leg-1');
      expect(legAfter, isNot(equals(legBefore)),
          reason: 'the marker is no longer where it was drawn, so an editor '
              'comparing hover state must see a different target');
    });

    test('pairings compare by target and child node', () {
      final d = twoStage();
      expect(AttachTargets.pairingsFor(d, quadDef),
          equals(AttachTargets.pairingsFor(twoStage(), quadDef)));
    });
  });
}

// ---------------- ring fixtures ----------------
//
// Deliberately synthetic. Ring DETECTION has to be shown failing, and the only
// honest way to do that is to author rings that are wrong on purpose — which
// nothing in the shipped catalog is, and nothing in it should become.

PartDef _ringOf(List<AttachNode> nodes) => PartDef(
      id: 'ring-fixture',
      name: 'Ring Fixture',
      category: PartCategory.structural,
      dryMass: 10,
      attachNodes: nodes,
    );

AttachNode _radial(String name, double azimuthDeg, double radius, double height,
    {AttachKind kind = AttachKind.surface}) {
  final a = azimuthDeg * math.pi / 180;
  final outward = Vector3(math.cos(a), math.sin(a), 0);
  return AttachNode(
    name: name,
    position: outward * radius + Vector3(0, 0, height),
    direction: outward,
    size: 0.3,
    kind: kind,
  );
}

PartDef _ringWithRadii(List<double> radii) => _ringOf([
      for (var i = 0; i < radii.length; i++)
        _radial('srf-${i + 1}', i * 90.0, radii[i], 0.5),
    ]);

PartDef _ringAtHeights(List<double> heights) => _ringOf([
      for (var i = 0; i < heights.length; i++)
        _radial('srf-${i + 1}', i * 90.0, 2.0, heights[i]),
    ]);

PartDef _ringAtAzimuths(List<double> azimuthsDeg) => _ringOf([
      for (var i = 0; i < azimuthsDeg.length; i++)
        _radial('srf-${i + 1}', azimuthsDeg[i], 2.0, 0.5),
    ]);

final PartDef _stackRing = _ringOf([
  for (var i = 0; i < 4; i++)
    _radial('ring-${i + 1}', i * 90.0, 2.0, 0.5, kind: AttachKind.stack),
]);

/// A def that reports how often its authored geometry was read.
///
/// Ring detection is a scan of [PartDef.attachNodes], so counting the reads
/// counts the scans — a measurement, where "the panes feel fine" is not one.
/// The override is the only way in: [PartDef] exposes its nodes as a field and
/// a test cannot hook a field without becoming the object that owns it.
class _CountingDef extends PartDef {
  _CountingDef(PartDef base)
      : super(
          id: base.id,
          name: base.name,
          category: base.category,
          dryMass: base.dryMass,
          size: base.size,
          attachNodes: base.attachNodes,
        );

  int reads = 0;

  @override
  List<AttachNode> get attachNodes {
    reads++;
    return super.attachNodes;
  }
}
