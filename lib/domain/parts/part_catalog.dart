// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../shared/vector3.dart';
import '../vessel/docking_port.dart';
import '../vessel/propulsion.dart';
import '../vessel/resource_container.dart';
import 'attach_node.dart';
import 'jet_engine.dart';
import 'lem_parts.dart';
import 'lifting_surface.dart';
import 'part_def.dart';

/// The roster of available parts, grounded in real launch vehicles and
/// aircraft. Reference data; the [VesselAssembler] picks from it.
///
/// ## Attach nodes
///
/// Every part below carries [PartDef.attachNodes], and that is not decoration.
/// The editor places a part by NAMING a node on each end of the joint, so a
/// part with an empty node list cannot be built with at all; and a design that
/// ever recorded a node name its part does not own fails `CraftDesign`'s
/// load-time validation outright, which makes the saved craft unopenable. Nodes
/// are authored data with the same standing as mass and size.
///
/// Frame and units, matching [LemParts]: METRES in the PART-LOCAL frame, Z-up
/// with the nose on +Z, and [AttachNode.direction] the OUTWARD unit normal at
/// the seat — pointing away from the material, so two mating nodes face each
/// other.
///
/// The stock roster follows three placement rules, chosen so a snapped stack
/// reproduces the geometry [PartDef.size] already claims:
///
/// * a stack seat sits on the axial face, at `size.z / 2`, so two stacked parts'
///   boxes meet exactly rather than overlapping or floating;
/// * a radial seat sits on the -X face at `size.x / 2`, so an unrotated surface
///   part hangs off the +X side of its parent and the mate's roll is the only
///   thing that has to move it;
/// * a tank's radial seats form a four-member ring at the hull radius and
///   mid-height, built from trig exactly as [LemParts] builds its rings, so the
///   editor's ring detection sees the same shape on a stock tank as on the LM.
///
/// [AttachNode.size] is a MATING CLASS, not a dimension. Every stock STRUCTURAL
/// stack node is the same 1.25 m class so any stock part bolts to any other:
/// `AttachSolver.sizesCompatible` enforces the class on stack mates and exempts
/// surface mates entirely, which is what lets a 0.15 m thermometer sit on a 4 m
/// hull. The one departure is a docking BORE, which is sized by the hatch on
/// the other craft rather than by the stack under it — see [_apolloBoreClass].
/// The classes in use across the whole catalog are 0.15, 0.25, 0.30, 0.40,
/// 0.81, 1.25, 1.5 and 4.2; `test/parts/attach_node_data_test.dart` pins that
/// list, so introducing a new one is a deliberate edit in two places instead of
/// a typo that quietly makes a part unmatable.
///
/// [AttachNode.kind] decides as much as the position does, and it is the half
/// that reads as absent rather than wrong: omit `kind:` and the seat is a STACK
/// seat, silently. `AttachSolver.kindsCompatible` is `a.kind == b.kind`, so the
/// two kinds never meet however close they are put — a part with only stack
/// seats can never hang off a hull, and a part with only surface seats can
/// never sit on the nose of a stack. Three consequences are authored into the
/// roster below rather than left to luck:
///
/// * a part with two real installations carries one seat of EACH kind (a jet
///   has an inline `mount` and a podded `pylon`; a chute and an intake each
///   have an axial `bottom` and a flank `mount`);
/// * a hull that radial hardware belongs on carries surface seats of its own,
///   even though it is itself a stack part — that is why the command pods have
///   `srf-*` rings and not just a top and a bottom;
/// * a part that hardware bolts ONTO carries a seat away from its own root. A
///   part whose only node is the one it hangs from can host nothing, because a
///   child mated there lands where the root lands, inside the parent — which is
///   why the wing has a `trailing` and a `pod` as well as a `mount`;
/// * a joint needs BOTH ends present in the roster. A class with only one end
///   authored is a node that can never be used, and it looks finished.
///
/// None of that is visible in review, so `attach_node_data_test.dart` states the
/// mates the roster exists for as data and checks them through the editor's own
/// `AttachTargets.pairingsFor`. A comment here that promises a mate the data
/// forbids fails that suite instead of being believed.
class PartCatalog {
  final Map<String, PartDef> _byId;

  PartCatalog(Iterable<PartDef> parts)
      : _byId = {for (final p in parts) p.id: p};

  Iterable<PartDef> get all => _byId.values;
  PartDef? byId(String id) => _byId[id];
  Iterable<PartDef> inCategory(PartCategory c) =>
      _byId.values.where((p) => p.category == c);

  /// Just the Apollo Lunar Module family, in roster order, for an editor filter
  /// that wants to offer "build an Eagle" without the generic parts. Filters the
  /// catalog rather than returning [LemParts.all] directly so it reflects what
  /// this catalog actually holds.
  Iterable<PartDef> get lem =>
      _byId.values.where((p) => LemParts.ids.contains(p.id));

  /// The one STRUCTURAL stack mating class (m) the stock roster uses end to end.
  ///
  /// Deliberately a single value rather than one per part diameter: with the
  /// whole roster in one class, any stock capsule, tank, decoupler, shield or
  /// engine bolts to any other, and `AttachSolver.sizesCompatible` never has to
  /// reject a pairing the player has no adapter for. Introducing a second class
  /// is a gameplay decision (it makes adapters necessary), not a bookkeeping
  /// one, so it does not happen by a part quietly declaring its own number.
  static const double _stockStackClass = 1.25;

  /// Docking BORE class (m): the Apollo probe-and-drogue tunnel's 32-inch hatch,
  /// which is the class [LemParts] gives the LM's overhead port.
  ///
  /// The one stack class outside [_stockStackClass], and it does not weaken that
  /// rule — a bore is not a structural joint. Two craft meet through the hatch
  /// they both carry, so this number has to match the OTHER vehicle rather than
  /// the stack it is bolted onto, and the port therefore carries both: a bore on
  /// its forward face and an ordinary 1.25 m structural seat on its aft one.
  /// Shared with the LM deliberately — a docking port that cannot dock to the
  /// only other docking interface in the catalog is a part with nothing to do.
  static const double _apolloBoreClass = 0.81;

  /// Radial mounting class (m) for the light hardware that bolts to a hull:
  /// gear, intakes, chutes, control surfaces. Matches the LM landing gear's
  /// 0.30 so a marker for one reads the same size as a marker for the other.
  /// Surface mates ignore the class for compatibility; it only sizes what the
  /// editor draws.
  static const double _stockSurfaceClass = 0.30;

  /// The standard catalog: a cross-section of real rocket and aircraft parts.
  factory PartCatalog.standard() => PartCatalog([
        // ---------------- Command ----------------
        PartDef(
          id: 'mk1-capsule',
          name: 'Mk1 Command Capsule',
          category: PartCategory.commandPod,
          dryMass: 840,
          size: const Vector3(1.25, 1.25, 1.4),
          crewCapacity: 1,
          maxTemperature: 2400,
          crossSectionArea: 1.2,
          attachNodes: [
            // A capsule is the top of a stack but not the end of one: the
            // parachute, the docking port and the escape tower all go above it,
            // so it keeps a forward seat as well as the aft one.
            const AttachNode(
              name: 'top',
              position: Vector3(0, 0, 0.7),
              direction: Vector3.unitZ,
              size: _stockStackClass,
            ),
            const AttachNode(
              name: 'bottom',
              position: Vector3(0, 0, -0.7),
              direction: Vector3(0, 0, -1),
              size: _stockStackClass,
            ),
            // The capsule is also where the first RCS block and the first
            // instrument go, and both of those are surface parts — a stack seat
            // cannot take either. A ring rather than a lone seat because the
            // hardware wants to be even: the x2 subset of a 4-ring is a pair of
            // OPPOSITE seats, so two thrusters balance instead of yawing the
            // craft. 0.625 m is the hull radius of the 1.25 m body and
            // mid-height is the one height that clears both stack joints.
            ..._ring(
              prefix: 'srf',
              radius: 0.625,
              height: 0.0,
              size: _stockSurfaceClass,
            ),
          ],
        ),
        PartDef(
          id: 'cockpit-mk1',
          name: 'Mk1 Aircraft Cockpit',
          category: PartCategory.commandPod,
          dryMass: 1000,
          size: const Vector3(1.25, 1.25, 3.0),
          crewCapacity: 1,
          dragCoefficient: 0.08,
          crossSectionArea: 1.0,
          attachNodes: [
            // 3 m long, so the seats are 1.5 m off the origin: an aircraft
            // fuselage is built nose-to-tail out of these and a half-height
            // taken from the 1.25 m cross-section would telescope them.
            const AttachNode(
              name: 'top',
              position: Vector3(0, 0, 1.5),
              direction: Vector3.unitZ,
              size: _stockStackClass,
            ),
            const AttachNode(
              name: 'bottom',
              position: Vector3(0, 0, -1.5),
              direction: Vector3(0, 0, -1),
              size: _stockStackClass,
            ),
            // A fuselage is what an aeroplane is built OUT of, and every part
            // that makes it an aeroplane — wings, intakes, elevons, gear — is a
            // surface part. Without these seats the only stock hull those could
            // reach is a fuel tank. Same 0.625 m hull radius as the capsule; the
            // ring's x2 subset is the pair of opposite seats a left/right wing
            // set wants, which is why the wing flow starts here.
            ..._ring(
              prefix: 'srf',
              radius: 0.625,
              height: 0.0,
              size: _stockSurfaceClass,
            ),
          ],
        ),

        // ---------------- Fuel tanks ----------------
        PartDef(
          id: 'fl-t400',
          name: 'FL-T400 Fuel Tank',
          category: PartCategory.fuelTank,
          dryMass: 250,
          size: const Vector3(1.25, 1.25, 1.9),
          crossSectionArea: 1.2,
          resources: [
            ResourceContainer(
                type: ResourceType.liquidFuel, capacity: 180, amount: 180, unitMass: 5),
            ResourceContainer(
                type: ResourceType.oxidizer, capacity: 220, amount: 220, unitMass: 5),
          ],
          attachNodes: [
            const AttachNode(
              name: 'top',
              position: Vector3(0, 0, 0.95),
              direction: Vector3.unitZ,
              size: _stockStackClass,
            ),
            const AttachNode(
              name: 'bottom',
              position: Vector3(0, 0, -0.95),
              direction: Vector3(0, 0, -1),
              size: _stockStackClass,
            ),
            // A tank is where the radial hardware goes on a real vehicle:
            // boosters, RCS, gear, science. The ring is at the hull radius
            // (0.625 m, half of the 1.25 m body) and mid-height, which is the
            // one height that never puts a mounted part through the joint at
            // either end.
            ..._ring(
              prefix: 'srf',
              radius: 0.625,
              height: 0.0,
              size: _stockSurfaceClass,
            ),
          ],
        ),
        PartDef(
          id: 'jet-fuel-tank',
          name: 'Wing Fuel Tank (Jet)',
          category: PartCategory.fuelTank,
          dryMass: 150,
          resources: [
            ResourceContainer(
                type: ResourceType.liquidFuel, capacity: 400, amount: 400, unitMass: 5),
          ],
          attachNodes: [
            // This part declares no [PartDef.size], so it is the default 1 m
            // cube: the seats are on the 0.5 m faces and the ring is at the
            // 0.5 m radius. The mating CLASS stays 1.25 regardless — a class is
            // what two nodes have to agree on, not how wide the part is, and
            // holding it lets a wing tank sit inline in a stock stack.
            const AttachNode(
              name: 'top',
              position: Vector3(0, 0, 0.5),
              direction: Vector3.unitZ,
              size: _stockStackClass,
            ),
            const AttachNode(
              name: 'bottom',
              position: Vector3(0, 0, -0.5),
              direction: Vector3(0, 0, -1),
              size: _stockStackClass,
            ),
            ..._ring(
              prefix: 'srf',
              radius: 0.5,
              height: 0.0,
              size: _stockSurfaceClass,
            ),
          ],
        ),

        // ---------------- Rocket engines ----------------
        const PartDef(
          id: 'merlin-1d',
          name: 'Merlin 1D (Falcon 9)',
          category: PartCategory.rocketEngine,
          dryMass: 470,
          size: Vector3(1.0, 1.0, 2.9),
          rocketEngine: Engine(
            name: 'Merlin 1D',
            maxThrustVacuum: 981000, // N
            maxThrustSeaLevel: 845000,
            ispVacuum: 311,
            ispSeaLevel: 282,
            gimbalRange: 0.087, // ~5 deg
          ),
          // An engine mates by its FORWARD face and hangs everything below it,
          // so it gets one seat at +Z and none aft: a node under a nozzle would
          // let a player bolt a tank into the exhaust. 1.45 m is half of the
          // 2.9 m the Merlin's [PartDef.size] declares, powerhead to bell exit.
          attachNodes: [
            AttachNode(
              name: 'mount',
              position: Vector3(0, 0, 1.45),
              direction: Vector3.unitZ,
              size: _stockStackClass,
            ),
          ],
        ),
        const PartDef(
          id: 'rl10',
          name: 'RL10 (Centaur, vacuum)',
          category: PartCategory.rocketEngine,
          dryMass: 277,
          rocketEngine: Engine(
            name: 'RL10',
            maxThrustVacuum: 110000,
            maxThrustSeaLevel: 50000,
            ispVacuum: 465, // hydrolox, very efficient
            ispSeaLevel: 200,
            gimbalRange: 0.07,
          ),
          attachNodes: [
            AttachNode(
              name: 'mount',
              position: Vector3(0, 0, 0.5),
              direction: Vector3.unitZ,
              size: _stockStackClass,
            ),
          ],
        ),

        // ---------------- Air-breathing engines ----------------
        const PartDef(
          id: 'turbojet-j85',
          name: 'J85 Turbojet',
          category: PartCategory.jetEngine,
          dryMass: 270,
          jetEngine: JetEngine(
            name: 'J85',
            maxStaticThrust: 18000,
            optimalMach: 1.5,
            machThrustMultiplier: 1.8,
            intakeAreaRequired: 0.3,
          ),
          // A jet is installed two ways and the two kinds never mate, so it
          // takes one seat of each. This part declares no [PartDef.size], so
          // both sit on the 0.5 m faces of the default 1 m cube.
          //
          // `mount` is the rocket-engine rule — forward face only, no aft seat,
          // so nothing can be bolted into the exhaust — and it is the jet buried
          // in the tail of a fuselage.
          //
          // `pylon` is the far more common podded installation, under a wing or
          // a wing tank. It is a separate seat rather than a re-kinded `mount`
          // because of where the thrust ends up: seated on a hull through the
          // -X face the nacelle sits UNROTATED, so its +Z and therefore its
          // thrust stay parallel to the craft axis. Surface-mating the forward
          // face instead would turn the engine to fire sideways into the hull
          // it is bolted to.
          attachNodes: [
            AttachNode(
              name: 'mount',
              position: Vector3(0, 0, 0.5),
              direction: Vector3.unitZ,
              size: _stockStackClass,
            ),
            AttachNode(
              name: 'pylon',
              position: Vector3(-0.5, 0, 0),
              direction: Vector3(-1, 0, 0),
              // The light-hardware class, matching the `srf-*` rings this seat
              // is meant to meet, so a nacelle's marker and the seat it is
              // aiming at draw the same size. Surface mates ignore the class
              // for legality; it only sizes what the editor draws.
              size: _stockSurfaceClass,
              kind: AttachKind.surface,
            ),
          ],
        ),
        const PartDef(
          id: 'ramjet-sr71',
          name: 'J58 Hybrid Ramjet (SR-71)',
          category: PartCategory.jetEngine,
          dryMass: 2700,
          jetEngine: JetEngine(
            name: 'J58',
            maxStaticThrust: 145000,
            optimalMach: 3.2,
            machThrustMultiplier: 2.6,
            intakeAreaRequired: 0.6,
          ),
          // Both seats, for the same reasons as the J85 above. The SR-71 flew
          // its two J58s in wing nacelles, which is the `pylon` installation.
          attachNodes: [
            AttachNode(
              name: 'mount',
              position: Vector3(0, 0, 0.5),
              direction: Vector3.unitZ,
              size: _stockStackClass,
            ),
            AttachNode(
              name: 'pylon',
              position: Vector3(-0.5, 0, 0),
              direction: Vector3(-1, 0, 0),
              size: _stockSurfaceClass,
              kind: AttachKind.surface,
            ),
          ],
        ),

        // ---------------- Intakes ----------------
        const PartDef(
          id: 'ram-intake',
          name: 'Ram Air Intake',
          category: PartCategory.intake,
          dryMass: 70,
          dragCoefficient: 0.1,
          intakeArea: 0.8,
          // An inlet is installed two ways and the two kinds never mate, so it
          // takes one seat of each, both on the default 1 m cube's 0.5 m faces.
          //
          // `bottom` is the NOSE inlet, and it is the canonical one: a pitot
          // intake capping the front of a fuselage or a nacelle, mated to that
          // part's `top`. Axial, in the stock stack class, because the nose of a
          // stack is a stack joint — expressed as a surface seat it could only
          // ever be strapped to a flank. Deliberately no forward seat: nothing
          // is stacked ahead of an inlet lip, exactly as nothing is stacked
          // above a canopy.
          //
          // `mount` is the flush side inlet, facing back into the hull it
          // presses against. Unrotated, that puts the intake on its parent's
          // +X side with its duct pointing outward, which is the orientation
          // every other surface part in this file also assumes.
          attachNodes: [
            AttachNode(
              name: 'bottom',
              position: Vector3(0, 0, -0.5),
              direction: Vector3(0, 0, -1),
              size: _stockStackClass,
            ),
            AttachNode(
              name: 'mount',
              position: Vector3(-0.5, 0, 0),
              direction: Vector3(-1, 0, 0),
              size: _stockSurfaceClass,
              kind: AttachKind.surface,
            ),
          ],
        ),

        // ---------------- Wings / control surfaces ----------------
        const PartDef(
          id: 'swept-wing',
          name: 'Swept Wing',
          category: PartCategory.wing,
          dryMass: 200,
          dragCoefficient: 0.02,
          // ONE panel, not a pair: an aeroplane takes two of these off a
          // fuselage's opposite `srf-*` seats, so [LiftingSurface.area] below is
          // this panel's own planform and a two-wing craft flies on 24 m^2.
          //
          // The box is DERIVED from that area rather than left at the default
          // 1 m cube, because the box is what the inertia model integrates, what
          // the editor picks against, and what every attach seat is measured
          // from — a wing whose box is shorter than its own chord has no
          // trailing edge and no underside to seat anything against. 4.8 m of
          // span by 2.5 m of chord is 12.0 m^2 exactly and gives the PAIR an
          // aspect ratio of (9.6 m)^2 / 24 m^2 = 3.84, which is the swept
          // transonic planform this part is named for (an F-86's is 4.8, an
          // F-4's 2.8) rather than the 6-8 of a straight-winged trainer. The
          // 0.3 m thickness is 12% of chord, the usual t/c for a wing that has
          // to hold fuel and a gear bay.
          //
          // Frame: X is span (outboard once mounted), Z is chord (+Z toward the
          // nose, as everywhere in this file), Y is thickness.
          size: Vector3(4.8, 0.3, 2.5),
          wing: LiftingSurface(
            name: 'Swept Wing',
            area: 12.0,
            liftCurveSlope: 5.5,
            stallAngle: 0.26,
            dragCoefficient: 0.02,
          ),
          // Three seats: the one the wing hangs FROM, and two the wing offers.
          // A part whose only node is its own root can host nothing — a child
          // mated there lands exactly where the root lands, buried in the hull
          // the wing is bolted to — and that reads in the source as a finished
          // part, because the one node it does have is correct.
          attachNodes: [
            // The wing ROOT: the -X face at half the 4.8 m span, so the panel
            // reaches outboard along +X and its tip lands a full span from the
            // hull. Given the stack class rather than the small-hardware class
            // because the marker stands for a structural joint carrying 12 m^2
            // of lift, and the editor sizes markers off this number.
            AttachNode(
              name: 'mount',
              position: Vector3(-2.4, 0, 0),
              direction: Vector3(-1, 0, 0),
              size: _stockStackClass,
              kind: AttachKind.surface,
            ),
            // Trailing edge at mid-span, where an elevon hinges. 1.25 m aft is
            // half the 2.5 m chord, which butts the control surface's own box
            // onto the edge instead of sinking it into the wing. The
            // light-hardware class, matching the elevon's own `mount` so the
            // seat and the marker aiming at it draw the same size.
            AttachNode(
              name: 'trailing',
              position: Vector3(0, 0, -1.25),
              direction: Vector3(0, 0, -1),
              size: _stockSurfaceClass,
              kind: AttachKind.surface,
            ),
            // Underwing hardpoint at mid-span, on the -Y face at half the 0.3 m
            // thickness: an engine nacelle, a gear pod, a drop tank. A jet
            // seated here through its `pylon` lands unrotated about the chord,
            // so its +Z — the thrust axis every propulsion model reads — stays
            // parallel to the wing's +Z and therefore to the craft axis.
            //
            // -Y is the panel's UNDERSIDE by declaration; the box is symmetric
            // about it, so nothing but this line can decide which face is which.
            // A surface mate is a rotation and a rotation cannot reflect, so a
            // panel seated on a hull's opposite seat comes out spun half a turn
            // about Z and carries this seat to the craft's other side. Rolling
            // it half a turn about the mate axis brings the pod back under and
            // takes the trailing edge forward with it: the two cannot both be
            // right from a rotation. See [AttachSolver.mirrorMate] — handedness
            // is a job for a mirrored MESH, not for geometry.
            AttachNode(
              name: 'pod',
              position: Vector3(0, -0.15, 0),
              direction: Vector3(0, -1, 0),
              size: _stockSurfaceClass,
              kind: AttachKind.surface,
            ),
          ],
        ),
        const PartDef(
          id: 'elevon',
          name: 'Elevon (Control Surface)',
          category: PartCategory.controlSurface,
          dryMass: 40,
          dragCoefficient: 0.01,
          wing: LiftingSurface(
            name: 'Elevon',
            area: 1.5,
            liftCurveSlope: 5.0,
            stallAngle: 0.30,
          ),
          // Hinges off a trailing edge, so it seats radially like the gear
          // rather than stacking. Its hinge line is the mate axis, which is
          // why the editor's roll about that axis is what trims an elevon in.
          attachNodes: [
            AttachNode(
              name: 'mount',
              position: Vector3(-0.5, 0, 0),
              direction: Vector3(-1, 0, 0),
              size: _stockSurfaceClass,
              kind: AttachKind.surface,
            ),
          ],
        ),

        // ---------------- Utility ----------------
        const PartDef(
          id: 'tr-18a-decoupler',
          name: 'TR-18A Stack Decoupler',
          category: PartCategory.decoupler,
          dryMass: 50,
          // Both seats, and both consumed in normal use: a decoupler exists to
          // be the joint between two stages, so it is the one stock part whose
          // whole purpose is to have something on each face.
          attachNodes: [
            AttachNode(
              name: 'top',
              position: Vector3(0, 0, 0.5),
              direction: Vector3.unitZ,
              size: _stockStackClass,
            ),
            AttachNode(
              name: 'bottom',
              position: Vector3(0, 0, -0.5),
              direction: Vector3(0, 0, -1),
              size: _stockStackClass,
            ),
          ],
        ),
        const PartDef(
          id: 'landing-gear',
          name: 'Retractable Landing Gear',
          category: PartCategory.landingGear,
          dryMass: 60,
          dragCoefficient: 0.05,
          // Same 0.30 m class as the LM's landing leg, so gear markers read
          // identically whichever family the player is building in.
          attachNodes: [
            AttachNode(
              name: 'mount',
              position: Vector3(-0.5, 0, 0),
              direction: Vector3(-1, 0, 0),
              size: _stockSurfaceClass,
              kind: AttachKind.surface,
            ),
          ],
        ),
        const PartDef(
          id: 'mk16-chute',
          name: 'Mk16 Parachute',
          category: PartCategory.parachute,
          dryMass: 100,
          // Two installations, one seat each, on the default 1 m cube.
          //
          // `bottom` is the one that matters: a chute goes on the NOSE of what
          // it recovers, which means an axial seat on its own aft face mated to
          // a capsule's or a tank's `top`. It is the stock 1.25 m class because
          // that is the only class a stock capsule offers, and there is
          // deliberately no forward seat — nothing is ever stacked above a
          // canopy.
          //
          // `mount` is the radial pack strapped to a booster's flank, a
          // different fit that needs the other kind.
          attachNodes: [
            AttachNode(
              name: 'bottom',
              position: Vector3(0, 0, -0.5),
              direction: Vector3(0, 0, -1),
              size: _stockStackClass,
            ),
            AttachNode(
              name: 'mount',
              position: Vector3(-0.5, 0, 0),
              direction: Vector3(-1, 0, 0),
              size: _stockSurfaceClass,
              kind: AttachKind.surface,
            ),
          ],
        ),
        const PartDef(
          id: 'heat-shield-1',
          name: 'Heat Shield (1.25m)',
          category: PartCategory.heatShield,
          dryMass: 300,
          ablator: 200,
          maxTemperature: 3300,
          // A shield is a stack sandwich: it takes the capsule on its forward
          // face and whatever it is protecting the stack from on its aft one.
          attachNodes: [
            AttachNode(
              name: 'top',
              position: Vector3(0, 0, 0.5),
              direction: Vector3.unitZ,
              size: _stockStackClass,
            ),
            AttachNode(
              name: 'bottom',
              position: Vector3(0, 0, -0.5),
              direction: Vector3(0, 0, -1),
              size: _stockStackClass,
            ),
          ],
        ),
        const PartDef(
          id: 'thermometer',
          name: 'Thermometer',
          category: PartCategory.science,
          dryMass: 5,
          // The smallest class in the catalog, matching the single R-4D: an
          // instrument this size must not draw a marker that hides the hull
          // feature the player is trying to aim at.
          attachNodes: [
            AttachNode(
              name: 'mount',
              position: Vector3(-0.5, 0, 0),
              direction: Vector3(-1, 0, 0),
              size: 0.15,
              kind: AttachKind.surface,
            ),
          ],
        ),
        PartDef(
          id: 'rcs-block',
          name: 'RCS Thruster Block',
          category: PartCategory.rcsThruster,
          dryMass: 50,
          resources: [
            ResourceContainer(
                type: ResourceType.monopropellant,
                capacity: 60,
                amount: 60,
                unitMass: 4),
          ],
          // 0.25 m, the class the LM's RCS quad uses, for the same reason: the
          // two are interchangeable hardware and should read as one family in
          // the editor even though they are different parts.
          attachNodes: const [
            AttachNode(
              name: 'mount',
              position: Vector3(-0.5, 0, 0),
              direction: Vector3(-1, 0, 0),
              size: 0.25,
              kind: AttachKind.surface,
            ),
          ],
        ),
        PartDef(
          id: 'docking-port-std',
          name: 'Standard Docking Port',
          category: PartCategory.structural,
          dryMass: 50,
          // The latch plane is the part's forward face, not its origin: a port
          // recorded on the origin would capture half a metre inside the hull,
          // and `dock-top` below is the same surface expressed as a seat.
          dockingPort: DockingPort(
            id: 'port',
            position: Vector3(0, 0, 0.5),
            facing: Vector3.unitZ,
          ),
          // Axial by its own [DockingPort.facing], so its seats are axial too —
          // the editor places parts by attach nodes alone and never reads that
          // field, so the two have to say the same thing. Three seats on the
          // default 1 m cube:
          //
          // * `dock-top` IS the bore, in the Apollo tunnel's class, so this
          //   part is the counterpart the LM's overhead hatch has been waiting
          //   for — and two of these dock to each other, which is the point of
          //   a docking port;
          // * `bottom` is the structural seat that bolts the port onto the nose
          //   of a stock capsule or tank, so it is the ordinary stock class;
          // * `mount` hangs the port off a hull for a station's side berth.
          attachNodes: const [
            AttachNode(
              name: 'dock-top',
              position: Vector3(0, 0, 0.5),
              direction: Vector3.unitZ,
              size: _apolloBoreClass,
            ),
            AttachNode(
              name: 'bottom',
              position: Vector3(0, 0, -0.5),
              direction: Vector3(0, 0, -1),
              size: _stockStackClass,
            ),
            AttachNode(
              name: 'mount',
              position: Vector3(-0.5, 0, 0),
              direction: Vector3(-1, 0, 0),
              size: _stockStackClass,
              kind: AttachKind.surface,
            ),
          ],
        ),

        // ---------------- Apollo Lunar Module ----------------
        // A self-contained family with its own ids (all 'eagle-' prefixed, so
        // 'eagle-rcs-block' does not collide with the generic 'rcs-block'
        // above and silently replace it in the id map). See [LemParts].
        ...LemParts.all,
      ]);

  // ---------------- Attach node helpers ----------------

  /// Four surface nodes evenly spaced around a hull: `<prefix>-1` through
  /// `<prefix>-4`, at [radius] metres from the part's axis and [height] metres
  /// along part-local Z, the first on +X and the rest a quarter turn apart
  /// toward +Y. Each node's direction is the outward radial normal.
  ///
  /// Deliberately the same shape, and built the same way, as `LemParts._ring`:
  /// the editor detects a symmetry ring GEOMETRICALLY (one radius, one height,
  /// evenly spaced azimuths) as well as by name, so a stock tank offers x2 and
  /// x4 radial symmetry only if its seats are as round as the LM's. Trig rather
  /// than four hand-typed pairs for the reason that file gives — a 0.7071 in
  /// the wrong column puts a booster through the tank, and it looks right in
  /// review.
  ///
  /// Duplicated rather than shared because `LemParts._ring` is private to a
  /// file that is reference data and must not grow a dependency on this one.
  static List<AttachNode> _ring({
    required String prefix,
    required double radius,
    required double height,
    required double size,
    double startAzimuth = 0,
  }) =>
      [
        for (var i = 0; i < 4; i++)
          _radial(
            name: '$prefix-${i + 1}',
            azimuth: startAzimuth + i * math.pi / 2,
            radius: radius,
            height: height,
            size: size,
          ),
      ];

  /// One surface node on the hull at [azimuth] radians from +X toward +Y,
  /// [radius] metres out and [height] metres along part-local Z, facing
  /// outward.
  static AttachNode _radial({
    required String name,
    required double azimuth,
    required double radius,
    required double height,
    required double size,
  }) {
    final outward = Vector3(math.cos(azimuth), math.sin(azimuth), 0);
    return AttachNode(
      name: name,
      position: outward * radius + Vector3(0, 0, height),
      direction: outward,
      size: size,
      kind: AttachKind.surface,
    );
  }
}
