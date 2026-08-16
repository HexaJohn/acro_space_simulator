// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/craft/attach_solver.dart';
import 'package:acro_space_simulator/domain/craft/attach_targets.dart';
import 'package:acro_space_simulator/domain/craft/craft_design.dart';
import 'package:acro_space_simulator/domain/parts/attach_node.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/infrastructure/flutter_scene/part_model_library.dart';
import 'package:flutter_test/flutter_test.dart';

/// The catalog's attach-node data, checked as GEOMETRY and as MATES, plus the
/// one seam where the catalog's numbers are copied into a second registry.
///
/// Three different failures live here and none of them is visible in review.
///
/// The first is node data. The editor places parts by naming a node on each
/// end of a joint, so a part with no nodes is a part nobody can build with, and
/// a node in the wrong place is a part that assembles into a craft with a hole
/// in it. Both look completely fine in the source — `Vector3(0, 0, 0.7)` reads
/// as plausible whatever the part's real half-height is — so the assertions
/// below re-derive every seat from [PartDef.size] and the node's own outward
/// normal rather than restating the literals.
///
/// The second is a part whose nodes are individually perfect and collectively
/// cannot express the mate the part exists for. [AttachSolver.kindsCompatible]
/// is `a.kind == b.kind`, so an omitted `kind:` is a stack seat, and a stack
/// seat never meets a hull however close it is put; [AttachSolver.sizesCompatible]
/// then rejects a stack pair whose classes disagree by more than 5%. Both
/// failures are SILENT — the part appears in the editor, draws its markers, and
/// simply never snaps to the thing it is for, which is indistinguishable from
/// the player aiming badly. The 'mates the roster exists for' group therefore
/// states the intent as data and checks it through
/// [AttachTargets.pairingsFor] and [CraftDesign.attachPart], the same path the
/// editor takes, so a comment that promises a mate the data forbids fails the
/// suite instead of being believed.
///
/// The third is the model-scale seam. [PartDef.modelScale] and
/// [PartModelLibrary] describe the same bakes, and a length written down twice
/// eventually becomes two lengths: the craft still flies correctly and simply
/// draws at a different size in the editor than in flight, with parts floating
/// out of their joints by the ratio between the two numbers. The library seeds
/// itself from the catalog precisely so that cannot happen, and the last group
/// here is what keeps that true — a future hand-written entry fails the suite
/// instead of shipping.
void main() {
  final catalog = PartCatalog.standard();

  PartDef need(String id) =>
      catalog.byId(id) ??
      fail('the shipped catalog has no part "$id" — the roster moved');

  /// The mating classes (m) the whole catalog is allowed to use.
  ///
  /// A closed set on purpose. [AttachNode.size] is what
  /// `AttachSolver.sizesCompatible` matches stack mates on, within 5% of the
  /// larger, so a part that invents 1.3 where it meant 1.25 still passes every
  /// other check in this file and simply refuses to bolt to anything — the
  /// hardest kind of data bug to see, because the part looks present and
  /// correct and just never snaps.
  final sanctionedClasses = <double>{
    0.15, // a single R-4D thruster, a boom instrument
    0.25, // an RCS quad
    0.30, // a landing leg, light radial hardware
    0.40, // a plume deflector
    0.81, // the Apollo docking tunnel's 32-inch bore
    1.25, // the stock stack class, used end to end by the generic roster
    1.5, // the LM descent engine interface
    4.2, // the LM ascent/descent structural interface
  };

  double longestSide(Vector3 s) => math.max(s.x, math.max(s.y, s.z));

  /// Half-extent of [def]'s bounding box on each axis, metres.
  Vector3 halfSize(PartDef def) => def.size * 0.5;

  /// [a] folded into (-pi, pi].
  double wrapPi(double a) {
    var v = a;
    while (v > math.pi) {
      v -= 2 * math.pi;
    }
    while (v <= -math.pi) {
      v += 2 * math.pi;
    }
    return v;
  }

  final ringMember = RegExp(r'^(.+)-(\d+)$');

  /// [def]'s nodes grouped into `<prefix>-1`..`<prefix>-n` rings, each group in
  /// ascending index order.
  ///
  /// A LOCAL detector, deliberately: this suite must be able to say whether the
  /// data is round without depending on the editor code that consumes it, or a
  /// bug in the detector and a bug in the data would cancel out. Only groups
  /// whose indices run 1..n unbroken count — anything else is a set of
  /// unrelated names that happens to end in a digit.
  Map<String, List<AttachNode>> ringsOf(PartDef def) {
    final byPrefix = <String, Map<int, AttachNode>>{};
    for (final n in def.attachNodes) {
      final m = ringMember.firstMatch(n.name);
      if (m == null) continue;
      final i = int.tryParse(m.group(2)!);
      if (i == null) continue;
      (byPrefix[m.group(1)!] ??= <int, AttachNode>{})[i] = n;
    }
    final out = <String, List<AttachNode>>{};
    for (final e in byPrefix.entries) {
      final idx = e.value.keys.toList()..sort();
      if (idx.length < 2) continue;
      if (idx.first != 1 || idx.last != idx.length) continue;
      out[e.key] = [for (final i in idx) e.value[i]!];
    }
    return out;
  }

  group('every part in the catalog can be built with', () {
    test('every part carries at least one attach node', () {
      // The stock roster shipped with none at all, which made every part except
      // the LM family unusable in an editor that places by naming nodes: the
      // catalog offered eighteen parts and none of them could be attached to
      // anything, including each other.
      for (final def in catalog.all) {
        expect(def.attachNodes, isNotEmpty,
            reason: '${def.id} cannot be built with: no attach nodes');
      }
    });

    test('node names are unique within a part', () {
      // [PartAttachment] records a node by NAME, and `PartDef.node()` returns
      // the first match. A duplicate name therefore makes a saved design
      // ambiguous: it reloads onto whichever of the two the linear scan reaches
      // first, which is a silently different craft.
      for (final def in catalog.all) {
        final seen = <String>{};
        for (final n in def.attachNodes) {
          expect(seen.add(n.name), isTrue,
              reason: '${def.id} has two nodes named "${n.name}"');
        }
      }
    });

    test('every direction is a unit vector', () {
      // `AttachSolver.solveMate` throws on a zero normal and normalises
      // everything else, so a short direction does not fail loudly — it just
      // means the authored number was not the normal it claimed to be.
      for (final def in catalog.all) {
        for (final n in def.attachNodes) {
          expect(n.direction.length, closeTo(1.0, 1e-9),
              reason: '${def.id}.${n.name} direction is not unit length');
        }
      }
    });

    test('every direction points OUT of the part', () {
      // The whole mate rule is "the two outward normals end up anti-parallel".
      // An inward normal therefore does not fail; it seats the child on the far
      // side of the part, buried in the hull. Away-from-origin is the check
      // that catches a flipped sign, and every seat in the catalog is off the
      // origin, so it applies to all of them.
      for (final def in catalog.all) {
        for (final n in def.attachNodes) {
          expect(n.position.lengthSquared, greaterThan(1e-12),
              reason: '${def.id}.${n.name} sits on the part origin, where '
                  '"outward" has no meaning');
          expect(n.direction.dot(n.position), greaterThan(0),
              reason: '${def.id}.${n.name} faces back into the part');
        }
      }
    });

    test('every seat lies on or inside the part bounding box', () {
      // [PartDef.size] is the box the inertia model and the editor's pick test
      // both use. A seat outside it puts the joint somewhere the part visibly
      // is not, and the 5 cm slack is for authored rounding only — every value
      // in the catalog today lands exactly on or inside the face.
      const slack = 0.05;
      for (final def in catalog.all) {
        final h = halfSize(def);
        for (final n in def.attachNodes) {
          final where = '${def.id}.${n.name}';
          expect(n.position.x.abs(), lessThanOrEqualTo(h.x + slack),
              reason: '$where is outside the ${def.size.x} m X envelope');
          expect(n.position.y.abs(), lessThanOrEqualTo(h.y + slack),
              reason: '$where is outside the ${def.size.y} m Y envelope');
          expect(n.position.z.abs(), lessThanOrEqualTo(h.z + slack),
              reason: '$where is outside the ${def.size.z} m Z envelope');
        }
      }
    });

    test('stack seats are axial', () {
      // A stack mate lines two parts up nose-to-tail, so its normal is the
      // craft axis. A stack node tilted off Z produces a stack that walks
      // sideways as it grows, one joint at a time, which reads as a modelling
      // error in the ART long before anyone suspects the node.
      for (final def in catalog.all) {
        for (final n in def.attachNodes) {
          if (n.kind != AttachKind.stack) continue;
          expect(n.direction.z.abs(), closeTo(1.0, 1e-9),
              reason: '${def.id}.${n.name} is a stack seat off the part axis');
        }
      }
    });

    test('a stack seat sits on the axial face its part declares', () {
      // The catalog's own placement rule, re-derived rather than restated: a
      // stack seat belongs on the part's axis at `size.z / 2`, because that is
      // the only offset at which two snapped boxes meet instead of overlapping
      // or floating. A seat at a plausible-looking literal that happens not to
      // be the half-height still mates — the joint is legal — and simply leaves
      // a visible gap or an interpenetration in every stack it appears in, so
      // nothing but this arithmetic catches it.
      const offFace = <String, String>{
        'eagle-fuel-tank.deck-top':
            'the ascent stage nests 0.34 m down into the deck rather than '
                'resting on its top face',
      };
      for (final def in catalog.all) {
        for (final n in def.attachNodes) {
          if (n.kind != AttachKind.stack) continue;
          final where = '${def.id}.${n.name}';
          if (offFace.containsKey(where)) continue;
          expect(n.position.x.abs(), lessThan(1e-9),
              reason: '$where is a stack seat off the part axis');
          expect(n.position.y.abs(), lessThan(1e-9),
              reason: '$where is a stack seat off the part axis');
          expect(n.position.z.abs(), closeTo(def.size.z / 2, 0.05),
              reason: '$where sits ${n.position.z} m up a part whose declared '
                  '${def.size.z} m length puts its face at '
                  '${def.size.z / 2} m');
        }
      }
    });

    test('no two stack seats on one part face the same way', () {
      // Stack seats come in opposable pairs — a forward face and an aft one.
      // Two facing the same way means one of them was copied and its sign
      // never flipped, and the symptom is a part that swallows its neighbour
      // instead of sitting on it.
      for (final def in catalog.all) {
        final stack = def.attachNodes
            .where((n) => n.kind == AttachKind.stack)
            .toList();
        for (var i = 0; i < stack.length; i++) {
          for (var j = i + 1; j < stack.length; j++) {
            expect(stack[i].direction.dot(stack[j].direction), lessThan(0.999),
                reason: '${def.id}: "${stack[i].name}" and "${stack[j].name}" '
                    'are both on the same face');
          }
        }
      }
    });

    test('every mating size is a sanctioned class', () {
      for (final def in catalog.all) {
        for (final n in def.attachNodes) {
          expect(sanctionedClasses, contains(n.size),
              reason: '${def.id}.${n.name} declares an unknown ${n.size} m '
                  'mating class; add it to the set here and to the catalog '
                  'doc, or use one that exists');
        }
      }
    });
  });

  group('the mates the roster exists for', () {
    const solver = AttachSolver.standard;

    /// True when [a] and [b] could be the two ends of one joint: the same kind,
    /// and — for a stack pair — the same diameter class. Exactly the test
    /// [AttachTargets.pairingsFor] and [CraftDesign.attachPart] both apply, so
    /// a "yes" here is a mate the editor will really offer.
    bool couldMate(AttachNode a, AttachNode b) =>
        solver.kindsCompatible(a, b) && solver.sizesCompatible(a, b);

    test('no node is the only end of its joint', () {
      // A mating class with nothing to mate to is the purest form of this bug:
      // the part is present, its node is present, its geometry is right, and
      // there is no second part in the whole roster it can legally meet. It
      // looks exactly like a finished part in review, and it is a part that can
      // never be attached.
      //
      // A counterpart on a DIFFERENT part is what is required. Matching only
      // another copy of oneself is how a one-ended joint disguises itself —
      // every stack node trivially matches its own twin — so that does not
      // count as the roster shipping both ends.
      final parts = catalog.all.toList();
      for (final def in parts) {
        for (final n in def.attachNodes) {
          final counterpart = parts
              .where((other) => other.id != def.id)
              .expand((other) => other.attachNodes.map((m) => (other.id, m)))
              .where((e) => couldMate(n, e.$2))
              .map((e) => e.$1)
              .toSet();
          expect(counterpart, isNotEmpty,
              reason: '${def.id}.${n.name} is a ${n.kind.name} seat of the '
                  '${n.size} m class and no OTHER part in the catalog carries '
                  'anything it can mate with, so it can never be used');
        }
      }
    });

    test('a docking port is axial by its node data too', () {
      // [PartDef.dockingPort] already states that the part mates along
      // [DockingPort.facing]. The editor cannot read that field — it places
      // parts by attach nodes alone — so a port whose seats disagree with its
      // own facing is a part that docks in flight and cannot be built pointing
      // the right way, or (with only surface seats) cannot be put on a nose at
      // all. Requiring a stack seat ON the port plane keeps the two statements
      // one statement.
      for (final def in catalog.all) {
        final port = def.dockingPort;
        if (port == null) continue;
        final facing = port.facing.normalized;
        final seats = def.attachNodes
            .where((n) => n.kind == AttachKind.stack)
            .where((n) => n.direction.normalized.dot(facing) > 0.999)
            .toList();
        expect(seats, isNotEmpty,
            reason: '${def.id} carries a docking port facing ${port.facing} '
                'but no stack seat on that face, so nothing can be docked or '
                'stacked where it docks');
        expect((seats.first.position - port.position).length, lessThan(0.05),
            reason: '${def.id}.${seats.first.name} is at '
                '${seats.first.position} while the port latches at '
                '${port.position}; the seat and the latch plane are the same '
                'surface of the same part');
      }
    });

    test('a part carries a seat of every kind its category is built with', () {
      // The kind is the half of a node that reads as absent rather than wrong:
      // `kind:` omitted defaults to [AttachKind.stack], so a part authored for
      // a hull with the line left off silently becomes an inline-only part.
      // Categories are the cheapest honest statement of which kinds a part
      // needs, and they generalise — a NEW jet or a NEW parachute is held to
      // the same rule without anyone remembering to list it.
      const needsSurface = <PartCategory, String>{
        PartCategory.intake: 'an intake is flush-mounted on a fuselage',
        PartCategory.wing: 'a wing roots into the side of a body',
        PartCategory.controlSurface: 'a control surface hinges off an edge',
        PartCategory.landingGear: 'gear bolts to a hull, never into a stack',
        PartCategory.science: 'an instrument is strapped to whatever is handy',
        PartCategory.rcsThruster: 'a thruster block sits on the skin',
        PartCategory.commandPod: 'a pod is where the first RCS block and the '
            'first instrument go, and both are surface parts',
        PartCategory.fuelTank: 'a tank hull is where the radial hardware of a '
            'real vehicle lives — boosters, gear, science',
        PartCategory.jetEngine: 'a jet is normally podded under a wing',
      };
      const needsStack = <PartCategory, String>{
        PartCategory.rocketEngine: 'an engine bolts under a tank',
        PartCategory.parachute: 'a chute goes on the nose of what it recovers',
        PartCategory.commandPod: 'a pod is part of a stack',
        PartCategory.fuelTank: 'a tank is part of a stack',
        PartCategory.decoupler: 'a decoupler IS a stack joint',
        PartCategory.heatShield: 'a shield is sandwiched into a stack',
        PartCategory.jetEngine: 'a jet also buries in the tail of a fuselage',
      };

      for (final def in catalog.all) {
        final kinds = def.attachNodes.map((n) => n.kind).toSet();
        final surfaceWhy = needsSurface[def.category];
        if (surfaceWhy != null) {
          expect(kinds, contains(AttachKind.surface),
              reason: '${def.id} has no surface seat: $surfaceWhy');
        }
        final stackWhy = needsStack[def.category];
        if (stackWhy != null) {
          expect(kinds, contains(AttachKind.stack),
              reason: '${def.id} has no stack seat: $stackWhy');
        }
      }
    });

    /// The specific joints the roster is written around, each named by the part
    /// on each end.
    ///
    /// [parentNode] pins the seat when only one of the parent's seats is the
    /// point of the entry — a chute belongs on a capsule's forward face, and an
    /// entry that accepted the aft one would pass while the part was still
    /// unusable. It is left null where any seat of that kind is a real answer.
    final joints = <
        ({
          String child,
          String parent,
          String? parentNode,
          AttachKind kind,
          String why,
        })>[
      (
        child: 'turbojet-j85',
        parent: 'jet-fuel-tank',
        parentNode: null,
        kind: AttachKind.surface,
        why: 'a jet nacelle hung under a wing is the whole point of the part',
      ),
      (
        child: 'ramjet-sr71',
        parent: 'jet-fuel-tank',
        parentNode: null,
        kind: AttachKind.surface,
        why: 'the SR-71 carried its two J58s in wing nacelles',
      ),
      (
        child: 'turbojet-j85',
        parent: 'cockpit-mk1',
        parentNode: 'bottom',
        kind: AttachKind.stack,
        why: 'the other jet installation: buried in the tail of a fuselage',
      ),
      (
        child: 'mk16-chute',
        parent: 'mk1-capsule',
        parentNode: 'top',
        kind: AttachKind.stack,
        why: 'a capsule with no recoverable chute cannot be landed',
      ),
      (
        child: 'docking-port-std',
        parent: 'mk1-capsule',
        parentNode: 'top',
        kind: AttachKind.stack,
        why: 'a nose docking port is the standard rendezvous fit',
      ),
      (
        child: 'docking-port-std',
        parent: 'eagle-command-pod',
        parentNode: 'dock-top',
        kind: AttachKind.stack,
        why: 'the LM overhead tunnel needs a counterpart to dock to, which is '
            'what its 0.81 m bore class is for',
      ),
      (
        child: 'merlin-1d',
        parent: 'fl-t400',
        parentNode: 'bottom',
        kind: AttachKind.stack,
        why: 'tank plus engine is the first rocket anyone builds',
      ),
      (
        child: 'heat-shield-1',
        parent: 'mk1-capsule',
        parentNode: 'bottom',
        kind: AttachKind.stack,
        why: 'a capsule re-enters behind its shield',
      ),
      (
        child: 'swept-wing',
        parent: 'cockpit-mk1',
        parentNode: null,
        kind: AttachKind.surface,
        why: 'an aeroplane is a fuselage with wings on it',
      ),
      (
        child: 'ram-intake',
        parent: 'cockpit-mk1',
        parentNode: null,
        kind: AttachKind.surface,
        why: 'a jet with no intake makes no thrust, and the fuselage is where '
            'the intake goes',
      ),
      (
        child: 'ram-intake',
        parent: 'cockpit-mk1',
        parentNode: 'top',
        kind: AttachKind.stack,
        why: 'a pitot inlet capping the nose is the canonical intake fit, and '
            'the nose of a stack is a stack joint',
      ),
      (
        child: 'elevon',
        parent: 'jet-fuel-tank',
        parentNode: null,
        kind: AttachKind.surface,
        why: 'an aircraft has to be trimmed by something',
      ),
      (
        child: 'elevon',
        parent: 'swept-wing',
        parentNode: 'trailing',
        kind: AttachKind.surface,
        why: 'a control surface hinges off a wing trailing edge; a wing with '
            'nowhere to hang one is a wing nobody can trim',
      ),
      (
        child: 'turbojet-j85',
        parent: 'swept-wing',
        parentNode: 'pod',
        kind: AttachKind.surface,
        why: 'the podded installation the jet carries a `pylon` seat FOR is '
            'under a wing, and the wing is the other end of that joint',
      ),
      (
        child: 'landing-gear',
        parent: 'swept-wing',
        parentNode: 'pod',
        kind: AttachKind.surface,
        why: 'main gear retracts into the wing, not into the fuselage',
      ),
      (
        child: 'landing-gear',
        parent: 'fl-t400',
        parentNode: null,
        kind: AttachKind.surface,
        why: 'gear hangs off the hull it lands on',
      ),
      (
        child: 'rcs-block',
        parent: 'mk1-capsule',
        parentNode: null,
        kind: AttachKind.surface,
        why: 'attitude control on the pod is the first thing a player adds',
      ),
      (
        child: 'thermometer',
        parent: 'mk1-capsule',
        parentNode: null,
        kind: AttachKind.surface,
        why: 'the first science part goes on the first part',
      ),
      (
        child: 'eagle-thruster',
        parent: 'eagle-fuel-tank',
        parentNode: 'engine-mount',
        kind: AttachKind.stack,
        why: 'the descent stage without its descent engine is not an LM',
      ),
      (
        child: 'eagle-legs',
        parent: 'eagle-fuel-tank',
        parentNode: null,
        kind: AttachKind.surface,
        why: 'four legs on the leg ring is the LM assembly flow',
      ),
    ];

    for (final j in joints) {
      final seat = j.parentNode ?? 'a ${j.kind.name} seat';
      test('${j.child} mounts on ${j.parent}.$seat', () {
        final design = CraftDesign(name: 'roster audit');
        design.addPart(def: need(j.parent), instanceId: 'parent');
        final childDef = need(j.child);

        final offered = AttachTargets.pairingsFor(design, childDef)
            .where((p) => p.target.kind == j.kind)
            .where((p) =>
                j.parentNode == null || p.target.nodeName == j.parentNode)
            .toList();
        expect(offered, isNotEmpty,
            reason: 'the editor offers no way to put ${j.child} on '
                '${j.parent}.$seat, and ${j.why}');

        // Offered is not the same as accepted: the design re-checks legality
        // and occupancy when the mate is actually made, so walk the last step
        // too rather than trusting the offer.
        final chosen = offered.first;
        design.attachPart(
          def: childDef,
          instanceId: 'child',
          toInstanceId: 'parent',
          parentNode: chosen.target.nodeName,
          childNode: chosen.childNodeName,
        );
        expect(design.partById('child')?.attachment?.parentNode,
            chosen.target.nodeName);
      });
    }

    test('a podded jet keeps its thrust on the craft axis', () {
      // Legality is only half of it. This is why the jet's podded seat is its
      // own node on the -X face rather than the forward `mount` re-kinded to
      // surface: a surface mate turns the child until its seat faces back into
      // the hull, so mating the FORWARD face to a tank would swing the nacelle
      // a quarter turn and fire it sideways into the tank it is bolted to.
      // Through the -X seat the nacelle lands unrotated and +Z — the thrust
      // axis every propulsion model reads — still points at the nose.
      //
      // Nothing downstream objects to a sideways engine: the craft assembles,
      // validates, saves and flies, just badly. Only this arithmetic says so.
      final design = CraftDesign(name: 'podded jet');
      design.addPart(def: need('jet-fuel-tank'), instanceId: 'tank');
      final jet = design.attachPart(
        def: need('turbojet-j85'),
        instanceId: 'jet',
        toInstanceId: 'tank',
        parentNode: 'srf-1',
        childNode: 'pylon',
      );

      final thrustAxis = jet.rotation.rotate(Vector3.unitZ);
      expect(thrustAxis.z, closeTo(1.0, 1e-9),
          reason: 'a podded nacelle thrusts along the craft axis, not into '
              'the wing it hangs from');
      // srf-1 is on the tank's +X hull at the 0.5 m radius, and the nacelle's
      // own 0.5 m half-width puts its centre one radius further out.
      expect(jet.position.x, closeTo(1.0, 1e-9));
      expect(jet.position.y, closeTo(0.0, 1e-9));
      expect(jet.position.z, closeTo(0.0, 1e-9));
    });

    test('a nose chute lands exactly on the capsule face', () {
      // The seat is at the part's own half-height for this reason and no other:
      // mated to a capsule whose forward face is 0.7 m up, a 1 m canister must
      // come to rest spanning 0.7 to 1.7 m. A seat at any other offset still
      // makes a legal joint and simply floats the chute above the hatch or
      // sinks it into the crew compartment.
      final design = CraftDesign(name: 'recovery');
      final capsuleDef = need('mk1-capsule');
      design.addPart(def: capsuleDef, instanceId: 'pod');
      final chuteDef = need('mk16-chute');
      final chute = design.attachPart(
        def: chuteDef,
        instanceId: 'chute',
        toInstanceId: 'pod',
        parentNode: 'top',
        childNode: 'bottom',
      );

      expect(chute.rotation.rotate(Vector3.unitZ).z, closeTo(1.0, 1e-9),
          reason: 'a nose chute deploys along the stack axis');
      final aftFace = chute.position.z - chuteDef.size.z / 2;
      expect(aftFace, closeTo(capsuleDef.size.z / 2, 1e-9),
          reason: 'the canister sits ON the hatch, not above or inside it');
    });

    test('a nose inlet caps the fuselage face, duct into the airstream', () {
      // The intake's axial seat is on its AFT face for the same reason the
      // chute's is: mated to a 3 m fuselage whose nose is 1.5 m up, a 1 m
      // inlet must come to rest spanning 1.5 to 2.5 m. And the mate must leave
      // the duct pointing FORWARD — an inlet turned by its own joint is a
      // scoop facing the tail, which nothing downstream objects to because
      // [PartDef.intakeArea] is a scalar the air model reads without asking
      // which way the part is facing.
      final design = CraftDesign(name: 'nose inlet');
      final bodyDef = need('cockpit-mk1');
      design.addPart(def: bodyDef, instanceId: 'fuselage');
      final inletDef = need('ram-intake');
      final inlet = design.attachPart(
        def: inletDef,
        instanceId: 'inlet',
        toInstanceId: 'fuselage',
        parentNode: 'top',
        childNode: 'bottom',
      );

      expect(inlet.rotation.rotate(Vector3.unitZ).z, closeTo(1.0, 1e-9),
          reason: 'the duct faces the airstream, not the exhaust');
      expect(inlet.position.z - inletDef.size.z / 2,
          closeTo(bodyDef.size.z / 2, 1e-9),
          reason: 'the lip sits ON the nose, not floating ahead of it');
    });
  });

  group('a wing is a mounting base as well as a lifting surface', () {
    // Three numbers nothing else in the suite states. A wing whose box does not
    // match its authored area, or whose seats do not match its box, produces a
    // craft that assembles, validates, saves and flies — with the panel
    // half-buried in the fuselage, the elevon floating in the wake, and the
    // nacelle inside the wing box. Only arithmetic against [PartDef.size] says
    // so, and the box is also what the inertia model integrates.
    final wingDef = catalog.byId('swept-wing')!;

    /// A fuselage carrying one wing panel on its +X hull seat.
    ({CraftDesign design, PlacedPart wing}) planeWithWing() {
      final design = CraftDesign(name: 'wing bench');
      design.addPart(def: need('cockpit-mk1'), instanceId: 'fuselage');
      final wing = design.attachPart(
        def: wingDef,
        instanceId: 'wing',
        toInstanceId: 'fuselage',
        parentNode: 'srf-1',
        childNode: 'mount',
      );
      return (design: design, wing: wing);
    }

    test('the panel matches the area it claims to fly on', () {
      // [LiftingSurface.area] is what the aerodynamics integrates and
      // [PartDef.size] is what everything else does, and nothing forces them to
      // agree: the part shipped with 12 m^2 of lift on a 1 m cube. Span x chord
      // is the planform the box describes, so this is the one line that keeps
      // the picture and the physics the same wing.
      final area = wingDef.wing!.area;
      expect(wingDef.size.x * wingDef.size.z, closeTo(area, 0.05),
          reason: 'the ${wingDef.size.x} x ${wingDef.size.z} m planform of the '
              'box is not the $area m^2 the lifting surface claims');
      // Thickness is what makes an underside seat expressible at all, and a
      // wing thicker than it is long is a block.
      expect(wingDef.size.y, lessThan(wingDef.size.z * 0.2),
          reason: 'a wing is a thin section, not a slab');
    });

    test('a panel roots on the hull and reaches outboard', () {
      final w = planeWithWing().wing;
      final hullRadius = need('cockpit-mk1').size.x / 2;

      expect(w.rotation.rotate(Vector3.unitZ).z, closeTo(1.0, 1e-9),
          reason: 'the chord lies along the craft axis, not across it');
      expect(w.position.x - wingDef.size.x / 2, closeTo(hullRadius, 1e-9),
          reason: 'the root rib meets the skin: a seat anywhere but the -X face '
              'at half the span buries the panel in the fuselage or floats it '
              'off the side');
      expect(w.position.x + wingDef.size.x / 2,
          closeTo(hullRadius + wingDef.size.x, 1e-9),
          reason: 'the tip stands one full span outboard of the hull');
      expect(w.position.y, closeTo(0, 1e-9));
      expect(w.position.z, closeTo(0, 1e-9));
    });

    test('an elevon butts onto the trailing edge', () {
      final bench = planeWithWing();
      final elevonDef = need('elevon');
      final elevon = bench.design.attachPart(
        def: elevonDef,
        instanceId: 'elevon',
        toInstanceId: 'wing',
        parentNode: 'trailing',
        childNode: 'mount',
      );

      final trailingEdgeZ = bench.wing.position.z - wingDef.size.z / 2;
      expect(elevon.position.z + elevonDef.size.z / 2,
          closeTo(trailingEdgeZ, 1e-9),
          reason: 'the hinge line is the trailing edge; a seat at any other '
              'chord station sinks the surface into the wing box or leaves it '
              'hanging in the wake');
      expect(elevon.position.x, closeTo(bench.wing.position.x, 1e-9),
          reason: 'the seat is at mid-span, so the surface stays on the panel');
    });

    test('a jet podded under the wing thrusts along the craft axis', () {
      // The same failure the tank's `srf-*` seats are tested for, one joint
      // further out: a nacelle mated through the wrong face is turned by its
      // own joint and fires sideways into the structure carrying it. Nothing
      // downstream objects — the craft assembles and flies, just badly.
      final bench = planeWithWing();
      final jetDef = need('turbojet-j85');
      final jet = bench.design.attachPart(
        def: jetDef,
        instanceId: 'jet',
        toInstanceId: 'wing',
        parentNode: 'pod',
        childNode: 'pylon',
      );

      expect(jet.rotation.rotate(Vector3.unitZ).z, closeTo(1.0, 1e-9),
          reason: 'a podded nacelle thrusts at the nose, not into the wing it '
              'hangs from');
      final underside = bench.wing.position.y - wingDef.size.y / 2;
      expect(jet.position.y + jetDef.size.y / 2, closeTo(underside, 1e-9),
          reason: 'the nacelle hangs UNDER the wing, not inside it');
      expect(jet.position.x, closeTo(bench.wing.position.x, 1e-9));
    });
  });

  group('every part in the roster reaches a mate', () {
    // The reachability invariant, and the one that generalises: a part that can
    // never be attached to anything is a finished-looking entry in the catalog
    // and a part the editor will never place. The suite already checks that no
    // NODE is the only end of its joint; this asks the harder question one level
    // up, through the editor's own offer path — given a craft made of one other
    // catalog part, does the editor offer this part a seat, and does the design
    // accept it when taken?
    //
    // Four shipped parts failed some form of this: a jet with no wing to pod
    // under, a chute and a docking port that could not reach a capsule's axial
    // top, an intake with no way to cap a nose, and a wing nothing could hang
    // off. Each looked complete in review.

    /// Every mate the editor would offer [def] against a craft consisting of
    /// exactly one OTHER catalog part, optionally restricted to [kind].
    ///
    /// Goes through [AttachTargets.pairingsFor] rather than comparing nodes
    /// here: legality is the editor's to decide, and a mate this suite worked
    /// out for itself could be one no player is ever shown. Another part, never
    /// a second copy of the same one — every stack node trivially matches its
    /// own twin, which is how a one-ended joint disguises itself.
    List<({String parent, String parentNode, String childNode})> matesFor(
      PartDef def, {
      AttachKind? kind,
    }) {
      final out = <({String parent, String parentNode, String childNode})>[];
      for (final other in catalog.all) {
        if (other.id == def.id) continue;
        final design = CraftDesign(name: 'reachability');
        design.addPart(def: other, instanceId: 'parent');
        for (final p in AttachTargets.pairingsFor(design, def)) {
          if (kind != null && p.target.kind != kind) continue;
          out.add((
            parent: other.id,
            parentNode: p.target.nodeName,
            childNode: p.childNodeName,
          ));
        }
      }
      return out;
    }

    test('every part can be seated on some other part', () {
      for (final def in catalog.all) {
        final mates = matesFor(def);
        expect(mates, isNotEmpty,
            reason: '${def.id} (${def.category.name}) cannot be attached to '
                'ANY other part in the catalog, so nothing a player builds can '
                'ever contain it');

        // Offered is not accepted: walk the last step through the design, which
        // re-checks legality and occupancy when the mate is really made.
        final first = mates.first;
        final design = CraftDesign(name: 'reachability');
        design.addPart(def: need(first.parent), instanceId: 'parent');
        design.attachPart(
          def: def,
          instanceId: 'child',
          toInstanceId: 'parent',
          parentNode: first.parentNode,
          childNode: first.childNode,
        );
        expect(design.partById('child')?.attachment?.parentNode,
            first.parentNode);
      }
    });

    test('a part with an axial role reaches its mate through a STACK seat', () {
      // Stronger than 'a part carries a seat of every kind its category is
      // built with', and for a reason that bit twice: a part can carry a
      // perfectly good stack seat in a diameter class no other part offers, or
      // carry only surface seats in a role that is inherently axial. Both leave
      // the part present, marked up and unmatable, and only asking for a real
      // counterpart in the shipped roster tells them apart.
      //
      // The categories here are the ones whose hardware mates END TO END: it
      // caps a nose, sits in a stack, or joins two vehicles. Anything else is
      // free to be radial-only.
      const axialRole = <PartCategory, String>{
        PartCategory.parachute: 'a chute goes on the nose of what it recovers',
        PartCategory.intake: 'a pitot inlet caps a nose',
        PartCategory.heatShield: 'a shield is sandwiched into a stack',
        PartCategory.decoupler: 'a decoupler IS a stack joint',
        PartCategory.rocketEngine: 'an engine bolts under a tank',
        PartCategory.jetEngine: 'a jet buries in the tail of a fuselage',
      };

      for (final def in catalog.all) {
        final why = axialRole[def.category] ??
            (def.dockingPort == null
                ? null
                : 'two craft meet hatch to hatch along the port axis');
        if (why == null) continue;

        final mates = matesFor(def, kind: AttachKind.stack);
        expect(mates, isNotEmpty,
            reason: '${def.id} has no STACK mate anywhere in the catalog, and '
                '$why. A surface-only part of this kind is one that can be '
                'strapped to a flank and never installed');
      }
    });

    test('a part hardware bolts onto offers a seat away from its own root', () {
      // What "nothing can attach to the wing" looks like as an invariant. A
      // part's own root seat is legal to mate to — a surface node hosts many —
      // so the editor cheerfully offers it, and a child mated there is placed
      // exactly where the root is: inside the hull the part is bolted to. A
      // mounting base therefore needs a seat somewhere ELSE on its box, and a
      // part carrying one node cannot have one however correct that node is.
      const carriesHardware = <PartCategory, String>{
        PartCategory.wing: 'control surfaces, engine pods and gear all hang off '
            'a wing',
        PartCategory.fuelTank: 'a tank hull is where the radial hardware of a '
            'real vehicle lives',
        PartCategory.commandPod: 'a pod is where the first RCS block and the '
            'first instrument go',
      };
      // Two seats closer together than this are one seat as far as a player
      // aiming at a marker is concerned.
      const apartM = 0.05;

      for (final def in catalog.all) {
        final why = carriesHardware[def.category];
        if (why == null) continue;
        for (final root in def.attachNodes) {
          final elsewhere = def.attachNodes
              .where((n) => (n.position - root.position).length > apartM)
              .map((n) => n.name)
              .toList();
          expect(elsewhere, isNotEmpty,
              reason: '${def.id} mated through "${root.name}" has no other '
                  'seat to offer, and $why');
        }
      }
    });
  });

  group('the rings radial symmetry is built out of', () {
    test('every detected ring is round', () {
      // Symmetry x4 is four ordinary mates to four REAL nodes, so the ring IS
      // the geometry — nothing downstream re-spaces it. One radius, one height,
      // even azimuths, each normal radial. Authored with trig for exactly this
      // reason, and 1e-6 is far tighter than any hand-typed constant survives.
      for (final def in catalog.all) {
        for (final e in ringsOf(def).entries) {
          final ring = e.value;
          final where = '${def.id} ring "${e.key}"';
          final step = 2 * math.pi / ring.length;

          double radiusOf(AttachNode n) =>
              math.sqrt(n.position.x * n.position.x +
                  n.position.y * n.position.y);
          double azimuthOf(AttachNode n) =>
              math.atan2(n.position.y, n.position.x);

          final r0 = radiusOf(ring.first);
          final h0 = ring.first.position.z;
          final az0 = azimuthOf(ring.first);
          expect(r0, greaterThan(0),
              reason: '$where sits on the axis, so it has no azimuths');

          for (var i = 0; i < ring.length; i++) {
            final n = ring[i];
            expect(n.kind, AttachKind.surface,
                reason: '$where member "${n.name}" is a stack seat; a stack '
                    'mate is single-occupancy and cannot carry a ring');
            expect(radiusOf(n), closeTo(r0, 1e-6),
                reason: '$where member "${n.name}" is off the ring radius');
            expect(n.position.z, closeTo(h0, 1e-6),
                reason: '$where member "${n.name}" is off the ring height');
            expect(wrapPi(azimuthOf(n) - (az0 + i * step)), closeTo(0, 1e-6),
                reason: '$where member "${n.name}" is unevenly spaced');

            final az = azimuthOf(n);
            expect(n.direction.x, closeTo(math.cos(az), 1e-9),
                reason: '$where member "${n.name}" does not face radially out');
            expect(n.direction.y, closeTo(math.sin(az), 1e-9),
                reason: '$where member "${n.name}" does not face radially out');
            expect(n.direction.z, closeTo(0, 1e-9),
                reason: '$where member "${n.name}" is tilted off the hull');
          }
        }
      }
    });

    test('the parts that must offer radial symmetry do', () {
      // Named explicitly because a ring can only be LOST silently: rename one
      // member and the group stops being 1..n, the detector stops seeing a
      // ring, and the editor quietly drops that part's x2/x4 chips with no
      // error anywhere. These four are the ones the flows depend on.
      final want = {
        'eagle-command-pod': {'quad': 4},
        'eagle-fuel-tank': {'leg': 4, 'deflector': 4},
        'fl-t400': {'srf': 4},
        'jet-fuel-tank': {'srf': 4},
        // The two pods carry rings rather than a lone surface seat because the
        // hardware that goes on them is hardware you want an even number of:
        // the x2 subset of a 4-ring is a pair of opposite seats, which is a
        // balanced RCS fit on a capsule and a left/right wing set on a
        // fuselage. One seat would place all of it down one side.
        'mk1-capsule': {'srf': 4},
        'cockpit-mk1': {'srf': 4},
      };
      for (final e in want.entries) {
        final def = catalog.byId(e.key);
        expect(def, isNotNull, reason: e.key);
        final got = ringsOf(def!).map((k, v) => MapEntry(k, v.length));
        expect(got, e.value, reason: '${e.key} rings');
      }
    });
  });

  group('the catalog and the render registry agree about model scale', () {
    test('every part with art is registered, at the catalog values', () {
      // [PartModelLibrary] seeds itself from these [PartDef]s and restates
      // nothing. This is the assertion that keeps it that way: a hand-written
      // entry, or a "temporary" tweak parked in the renderer, shows up here as
      // a mismatch rather than as a craft that is one size in the editor and
      // another in flight.
      final withArt = catalog.all.where((d) => d.modelAsset != null).toList();
      expect(withArt, isNotEmpty,
          reason: 'the LM family carries the only part bakes in the project');

      for (final d in withArt) {
        final m = PartModelLibrary.lookup(d.id);
        expect(m, isNotNull, reason: '${d.id} has art but is not registered');
        expect(m!.asset, d.modelAsset, reason: '${d.id} asset');
        expect(m.scale, d.modelScale, reason: '${d.id} modelScale');
        expect(m.rotation.w, d.modelRotation.w, reason: '${d.id} rotation w');
        expect(m.rotation.x, d.modelRotation.x, reason: '${d.id} rotation x');
        expect(m.rotation.y, d.modelRotation.y, reason: '${d.id} rotation y');
        expect(m.rotation.z, d.modelRotation.z, reason: '${d.id} rotation z');
        expect(m.offset, d.modelOffset, reason: '${d.id} modelOffset');
        expect(m.fallbackSizeM, closeTo(longestSide(d.size), 1e-12),
            reason: '${d.id} stand-in size');
      }

      // No extra registrations either: a key with no catalog part behind it is
      // art the editor can never show, because the editor draws from the
      // catalog.
      expect(PartModelLibrary.keys.length, withArt.length,
          reason: 'the registry holds art for parts the catalog does not have');
    });

    test('a part with no art is registered as having none, at its real size',
        () {
      // Knowing how big a part is must not make the renderer believe it has
      // art: that decision picks how the WHOLE craft is drawn.
      for (final d in catalog.all.where((d) => d.modelAsset == null)) {
        expect(PartModelLibrary.lookup(d.id), isNull, reason: d.id);
        expect(PartModelLibrary.has(d.id), isFalse, reason: d.id);
        expect(PartModelLibrary.fallbackSizeM(d.id),
            closeTo(longestSide(d.size), 1e-12),
            reason: '${d.id} stand-in size');
      }
    });

    test('no two catalog ids collapse to one render key', () {
      // The registry matches on a normalised key (case-folded, `-`/`_`/space
      // runs collapsed), which is what lets a kebab-case catalog id find an
      // underscore-named bake. The cost is that two ids CAN collide, and the
      // loser simply vanishes from the map — the part draws a grey stand-in
      // and nothing says why. 'rcs-block' and 'eagle-rcs-block' are the near
      // miss this guards.
      final byKey = <String, String>{};
      for (final d in catalog.all) {
        final k = PartModelLibrary.normalizeKey(d.id);
        final prev = byKey[k];
        expect(prev, isNull,
            reason: '"${d.id}" and "$prev" both normalise to "$k"');
        byKey[k] = d.id;
      }
    });
  });
}
