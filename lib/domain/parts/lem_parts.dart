// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import '../shared/quaternion.dart';
import '../shared/vector3.dart';
import '../vessel/docking_port.dart';
import '../vessel/propulsion.dart';
import '../vessel/resource_container.dart';
import 'attach_node.dart';
import 'part_def.dart';

/// The Apollo Lunar Module ("Eagle") part family: seven [PartDef]s that compose
/// into a complete LM, sized and massed from the flown vehicle.
///
/// ## Why these seven
///
/// The art is seven separate exports cut from ONE source model (see
/// `mesh_src/LEM Parts/`, all siblings of `mesh_src/lander.glb`). Each export is
/// a real sub-assembly of the vehicle, so each gets one part rather than being
/// force-fitted into the generic catalog:
///
/// | catalog id                | real hardware                            |
/// |---------------------------|------------------------------------------|
/// | `eagle-command-pod`       | ascent stage (cabin, midsection, APS)    |
/// | `eagle-fuel-tank`         | descent stage octagon + its four tanks   |
/// | `eagle-thruster`          | descent engine (DPS/TRW LMDE) bell       |
/// | `eagle-legs`              | ONE landing gear leg (four per vehicle)  |
/// | `eagle-rcs-block`         | ONE four-thruster RCS quad (four per LM) |
/// | `eagle-rcs-solo`          | a single R-4D thruster                   |
/// | `eagle-rcs-blast-flute`   | an RCS plume deflector                   |
///
/// Assembled as flown — pod + tankage + engine + 4 legs + 4 quads — the roster
/// totals 15,025 kg against the 15,103 kg Apollo 11 LM at launch. The 78 kg gap
/// is crew, PLSS/consumables and stowed payload, none of which are parts. Keep
/// that invariant in mind before editing any mass below.
///
/// ## Frames and units
///
/// Everything here is METRES in the PART-LOCAL frame: Z-up, nose on +Z, origin
/// at the part's geometric centre. [AttachNode.direction] points OUT of the
/// part, so a surface-mount node (legs, RCS) points at the hull it will sit on.
/// Node positions were derived from the source model's real proportions and
/// cross-checked against published LM dimensions, so a stack assembled by
/// snapping nodes reproduces the flown geometry: footpads 4.65 m from the
/// centreline (flown 4.7 m) and the descent engine bell 0.39 m above the footpad
/// plane (flown clearance was similarly slim — Apollo 15 damaged its bell on
/// touchdown).
///
/// ## Model scale calibration
///
/// [modelUnitToMetres] is NOT eyeballed. It was measured off the `POSITION`
/// accessor bounds in the .glb files and solved against four published LM
/// dimensions. The seven part exports were written without the parent model's
/// 1.6502 root scale, so features measured on `lander.glb` convert to part-export
/// units by dividing by 1.6502:
///
/// | anchor                            | real     | model units | m/unit |
/// |-----------------------------------|----------|-------------|--------|
/// | RCS quad span across ascent stage | 4.29 m   | 1.7766      | 2.415  |
/// | landing gear footpad span         | 9.40 m   | 3.9181      | 2.399  |
/// | DPS nozzle exit diameter          | 1.50 m   | 0.6047      | 2.478  |
/// | footpad to top of antenna         | 7.04 m   | 3.0356      | 2.319  |
///
/// The four agree to within +/-3.3%, which is the accuracy of a hand-built
/// display model — so the family takes their mean, 2.40, and every part uses it.
///
/// ## Confirming a calibration against the render
///
/// [modelUnitToMetres] is a claim about the ART, so only the render can confirm
/// it. Put ONE part on screen and turn on the body-frame axis gizmo
/// (`ext.acro.camera?axes=true`), which draws X/Y/Z shafts ticked at every metre
/// from the craft origin. The value is right when the part measures its own
/// [PartDef.size] against those ticks — and those sizes are the flown vehicle's
/// dimensions, so the ruler, this catalog and the real hardware agree or none of
/// them do.
///
/// The second check needs no ruler and catches what a single part cannot: bolt
/// the whole LM together and look at the joints. Attach nodes are in METRES, so
/// a wrong `modelScale` shows up as meshes floating out of their mates by
/// exactly the ratio of the error — while the craft still flies correctly,
/// because physics never reads the art. Legs that miss their outriggers or an
/// engine bell sunk into the descent stage are a scale bug, not a node bug.
///
/// Sweep before committing anything. The flutter_scene renderer recomputes every
/// part transform each frame, so the live calibration knobs on the
/// `ext.acro.camera` dev extension move the drawn scale, orientation and offset
/// on the next frame with no rebuild. Put one part on the ruler with
/// `lib/main_part_calibration_dev.dart` and sweep it:
///
/// ```
/// ext.acro.bench?show=eagle-legs                     one part, on the origin
/// ext.acro.camera?axes=true&rangeM=9&azimuthDeg=0    the 1-metre ruler
/// ext.acro.camera?part=eagle-legs&partScale=2.4      -> modelScale
/// ext.acro.camera?part=eagle-legs&partRotDeg=90,0,90 -> modelRotation
/// ext.acro.camera?part=eagle-legs&partOffsetM=-1.26,0,0.59  -> modelOffset
/// ext.acro.camera?partScaleAll=1.1                   every part at once
/// ext.acro.camera?partReset=true                     drop every override
/// ext.acro.screenshot?path=test_out/part_calibration/legs.png
/// ```
///
/// `part=` takes any spelling of a catalog id. A value left unnamed keeps
/// whatever is in force, so scale, orientation and offset sweep independently
/// and accumulate. `partRotDeg` is DEGREES about the part's fixed X, then Y,
/// then Z — the three lines above are the ones that produced this file's
/// landing-gear entry, and 90,0,90 composes to exactly the
/// `Quaternion(0.5, 0.5, 0.5, 0.5)` recorded on [_landingLeg].
///
/// Only `lib/main_part_calibration_dev.dart` serves `ext.acro.bench`, which is
/// what puts a single part ON the origin — the axis ruler is drawn at the CRAFT
/// origin, so a part measured anywhere else is measured against nothing.
/// `main_scene_dev.dart` carries the same `part*` knobs for checking a part in
/// an assembled craft, where the ruler no longer lines up with it.
///
/// Every `ext.acro.camera` reply carries `partCalibration`: what each override
/// would have to say HERE to keep the pose being drawn, as pasteable Dart. The
/// sweep is finished when those lines are in this file and that map is empty
/// again. Treat the knobs as a MEASURING INSTRUMENT, never as a setting: a
/// sweep that settles anywhere but the value below has found a wrong number in
/// THIS file, and the correction belongs here. The render-side registry is
/// SEEDED from these [PartDef]s and deliberately restates none of them, so a
/// correction parked in the renderer puts one length in two places — and the
/// copy the physics uses (attach nodes, [PartDef.size], the inertia box) is
/// this one, which is why the catalog wins every disagreement.
///
/// The whole-craft `ext.acro.camera?glbScale=` knob does NOT reach these parts.
/// It rescales a single baked craft model, and a craft whose parts carry their
/// own art is drawn PER PART instead — a different branch that never reads it.
///
/// If ONE export turns out to be off, replace that part's
/// `modelScale: modelUnitToMetres` with a literal — a one-number edit that
/// leaves the family constant right for the other six. No export has needed
/// that: measured against the ruler the descent engine's bell is 1.49 m across
/// (published exit diameter 1.50 m) and a landing leg's box is
/// 2.68 x 2.34 x 3.29 m against the 2.54 x 2.37 x 3.22 m below.
///
/// ## What the exports disagree about
///
/// [PartDef.modelRotation] corrects the EXPORT's authored axis and nothing
/// else: it is applied in the part-local frame on top of the standard glTF
/// Y-up -> body Z-up fix, so it says which way the mesh was modelled, not which
/// way this copy of the part faces on a particular craft — that is the
/// assembly's rotation, decided when the part is placed.
///
/// Five of the seven are authored consistently and need no correction at all:
/// the pod, the descent stage, the descent engine, the single thruster, and
/// (as far as anything states) the deflector. Two do not. The RCS quad is a
/// quarter turn out about X. The landing leg is a full axis CYCLE out
/// (X->Y->Z->X), which is why it draws reaching upward and sideways until it is
/// turned back. Both corrections are recorded on the part.
///
/// Every export is also authored off its own origin — the pod by 1.4 m, the
/// descent stage by 1.12 m, the leg by 1.4 m diagonally, the engine 0.37 m the
/// other way — so [PartDef.modelOffset] seats each mesh back on the part origin
/// its attach nodes and inertia box are measured from. That value is ART ONLY:
/// nothing in the mass model or the editor reads it. See
/// `docs/plans/lem_part_calibration.md` for the frames the numbers were read
/// off and the images that justify them.
class LemParts {
  const LemParts._();

  /// Model units -> METRES for every export in `mesh_src/LEM Parts/`. See the
  /// calibration table in the class doc for the derivation.
  static const double modelUnitToMetres = 2.40;

  /// Mating diameter class (m) of the ascent/descent interface. Not a physical
  /// dimension — [AttachNode.size] only has to agree between the two nodes that
  /// mate, and no generic catalog part is meant to bolt to an LM stage.
  static const double _lmStackClass = 4.2;

  /// Oxidiser units per fuel unit for Aerozine 50 / N2O4, the hypergolic pair
  /// both LM engines burned. The flown mixture ratio was 1.6:1 BY MASS and the
  /// catalog gives fuel and oxidiser the same 5 kg/unit, so the mass ratio is
  /// also the unit ratio.
  ///
  /// Note the thrust model currently draws only [Engine.propellant] (the fuel
  /// container) and ignores this — it is carried for fidelity and for the day
  /// the oxidiser draw lands.
  static const double _hypergolicOxRatio = 1.6;

  /// kg per resource unit, matching the rest of [PartCatalog] so an LM part and
  /// a stock tank price fuel the same way.
  static const double _propellantUnitMass = 5.0;
  static const double _monopropUnitMass = 4.0;

  /// The roster: REFERENCE DATA, to be treated as read-only by everything that
  /// reads it.
  ///
  /// [ResourceContainer.amount] is mutable, so the tanks below would be shared
  /// state if anything handed them to a craft directly. Nothing does:
  /// `VesselAssembler` copies every container as it stamps a [PartDef] into a
  /// part, which is what gives each craft — and each of two identical tanks on
  /// one craft — its own propellant. Anything else that bakes a def into
  /// per-craft state owes the same copy.
  ///
  /// A getter rather than a static field only because these are cheap to build
  /// and nothing benefits from interning them; freshness here is NOT what makes
  /// the tanks safe. `PartCatalog.standard` calls this once and keeps the
  /// result, so two craft off one catalog see the same [PartDef] objects no
  /// matter how fresh this getter is — per-craft isolation can only be
  /// established where a definition becomes a part.
  static List<PartDef> get all => [
        _ascentStage(),
        _descentStage(),
        _descentEngine(),
        _landingLeg(),
        _rcsQuad(),
        _rcsSingle(),
        _plumeDeflector(),
      ];

  /// Ids of the LM family, for a catalog filter. Derived from [all] so it can
  /// never drift from the roster.
  static final Set<String> ids = all.map((p) => p.id).toSet();

  // ---------------- Ascent stage ----------------

  /// The crewed half of the vehicle: cabin, midsection, the ascent propulsion
  /// system and its two propellant spheres. The export also carries the
  /// antennas, the hatch and the ladder, but not the RCS quads — those are
  /// [_rcsQuad], mounted through the four `quad-*` nodes.
  ///
  /// Mass: the flown ascent stage was 2,150 kg dry. The four RCS quads are
  /// separate parts here, so their ~90 kg of hardware is deducted to keep the
  /// assembled vehicle honest — bolt the four quads back on and the stage is
  /// 2,150 kg again.
  ///
  /// Propellant: 2,353 kg of Aerozine 50 / N2O4 at 1.6:1, i.e. 905 kg fuel and
  /// 1,448 kg oxidiser. Burning all of it against a 2,150 kg burnout mass gives
  /// 2,256 m/s, which is the flown ascent stage's ~2,220 m/s budget.
  ///
  /// The APS is modelled on the part that carries its tanks deliberately: the
  /// thrust model draws propellant only from containers in the SAME stage, so
  /// an ascent stage staged on its own still has something to burn.
  static PartDef _ascentStage() => PartDef(
        id: 'eagle-command-pod',
        name: 'Eagle Ascent Stage',
        category: PartCategory.commandPod,
        dryMass: 2060, // 2,150 kg flown, less ~90 kg of RCS quads
        // 3.46 m is the structural height measured off the export at the
        // calibrated scale. The published 3.76 m overall height includes the
        // rendezvous radar above the cabin roof: envelope, but no mating face.
        size: const Vector3(4.2, 4.2, 3.46),
        crewCapacity: 2, // commander and lunar module pilot
        // Aluminium and mylar with no thermal protection whatsoever. The LM
        // could not survive an entry and this number should keep saying so.
        maxTemperature: 700,
        dragCoefficient: 1.2, // bluff body; it never flew in an atmosphere
        crossSectionArea: 11.0, // m^2, plan area of the boxy ascent structure
        rocketEngine: const Engine(
          name: 'APS (Bell/Rocketdyne)',
          maxThrustVacuum: 15600, // N, 3,500 lbf, the engine's only rating
          // Pressure-fed with a 45:1 nozzle: at sea level it would separate
          // badly. These two are modelling stand-ins for an engine that was
          // never meant to see ambient pressure.
          maxThrustSeaLevel: 13000,
          ispVacuum: 311,
          ispSeaLevel: 205,
          oxidizerRatio: _hypergolicOxRatio,
          gimbalRange: 0, // fixed nozzle; attitude came from the RCS alone
        ),
        resources: [
          ResourceContainer(
            type: ResourceType.liquidFuel,
            capacity: 181.0, // 905 kg of Aerozine 50
            amount: 181.0,
            unitMass: _propellantUnitMass,
          ),
          ResourceContainer(
            type: ResourceType.oxidizer,
            capacity: 289.6, // 1,448 kg of N2O4
            amount: 289.6,
            unitMass: _propellantUnitMass,
          ),
        ],
        // The flown interface was Apollo probe-and-drogue through the overhead
        // tunnel. Modelled in the 0.81 m BORE class — the flown 32-inch hatch,
        // not the catalog's 1.25 m structural stack class — which the generic
        // docking port carries too, so LM and CSM parts can actually mate
        // in-game.
        dockingPort: DockingPort(
          id: 'lm-tunnel',
          position: const Vector3(0, 0, 1.73),
          facing: Vector3.unitZ,
        ),
        modelAsset: 'assets/mesh/eagle_command_pod.fsceneb',
        modelScale: modelUnitToMetres,
        // Export authored nose-up: the standard Y-up fix alone lands the
        // docking tunnel on +Z and the hatch on the crew's forward axis.
        // The mesh sits 1.4 m high of the part origin, which puts the base
        // skirt on [stage-bottom] to within 0.02 m once corrected.
        modelOffset: const Vector3(0, 0, -1.4),
        attachNodes: [
          // Overhead docking tunnel: 0.81 m, the flown 32-inch hatch bore.
          const AttachNode(
            name: 'dock-top',
            position: Vector3(0, 0, 1.73),
            direction: Vector3.unitZ,
            size: 0.81,
          ),
          // Seats on the descent stage deck.
          const AttachNode(
            name: 'stage-bottom',
            position: Vector3(0, 0, -1.73),
            direction: Vector3(0, 0, -1),
            size: _lmStackClass,
          ),
          // Four RCS quads at the ascent stage's corners, 45 degrees off the
          // crew's forward axis, which is why the flown vehicle measured
          // 4.29 m across the quads while the structure is narrower.
          ..._ring(
            prefix: 'quad',
            radius: 1.80,
            height: 0.0,
            startAzimuth: math.pi / 4,
            size: 0.25,
          ),
        ],
      );

  // ---------------- Descent stage ----------------

  /// The descent stage: the octagonal structure and the four propellant tanks
  /// inside it. The engine and the landing gear are separate parts, so this is
  /// tankage plus primary structure only.
  ///
  /// Mass: 2,034 kg flown dry for the whole stage, less the 180 kg engine and
  /// the 480 kg of landing gear that live in [_descentEngine] and [_landingLeg]
  /// — 1,374 kg here. That apportionment is the honest weak point of this file:
  /// the engine figure is published, the gear figure is an estimate (see
  /// [_landingLeg]), and this part absorbs whatever is left over.
  ///
  /// Propellant: 8,200 kg at 1.6:1, i.e. 3,154 kg fuel and 5,046 kg oxidiser,
  /// spread across four 1.68 m tanks on the real vehicle and pooled into one
  /// pair of containers here because the sim draws per-part, not per-tank.
  /// Burning all of it from a 15,025 kg full LM yields 2,407 m/s against the
  /// flown descent budget of roughly 2,470 m/s.
  static PartDef _descentStage() => PartDef(
        id: 'eagle-fuel-tank',
        name: 'Eagle Descent Stage',
        category: PartCategory.fuelTank,
        dryMass: 1374, // 2,034 kg stage dry, less engine (180) and gear (480)
        // 4.22 m across the flats is published; 2.30 m deep is measured off the
        // export at the calibrated scale (base heat shield to deck).
        size: const Vector3(4.22, 4.22, 2.30),
        maxTemperature: 700, // aluminium structure, no entry protection
        dragCoefficient: 1.2,
        // Regular octagon of width D has area 0.8284*D^2 = 14.8 m^2.
        crossSectionArea: 14.8,
        resources: [
          ResourceContainer(
            type: ResourceType.liquidFuel,
            capacity: 630.8, // 3,154 kg of Aerozine 50
            amount: 630.8,
            unitMass: _propellantUnitMass,
          ),
          ResourceContainer(
            type: ResourceType.oxidizer,
            capacity: 1009.2, // 5,046 kg of N2O4
            amount: 1009.2,
            unitMass: _propellantUnitMass,
          ),
        ],
        modelAsset: 'assets/mesh/eagle_fuel_tank.fsceneb',
        modelScale: modelUnitToMetres,
        // Export authored deck-up: with the standard Y-up fix alone a nadir
        // view frames the octagon face-on, so no further correction. The mesh
        // rides 1.12 m high of the part origin.
        modelOffset: const Vector3(0, 0, -1.12),
        attachNodes: [
          // The ascent stage seat sits 0.34 m BELOW the deck's top face: the
          // ascent stage's base skirt nests down into the descent stage rather
          // than resting on it. Snapping to the bounding-box face instead would
          // float the ascent stage half a metre high.
          const AttachNode(
            name: 'deck-top',
            position: Vector3(0, 0, 0.81),
            direction: Vector3.unitZ,
            size: _lmStackClass,
          ),
          // Descent engine, on the base plane. Only the bell hangs below.
          const AttachNode(
            name: 'engine-mount',
            position: Vector3(0, 0, -1.15),
            direction: Vector3(0, 0, -1),
            size: 1.5,
          ),
          // Four landing gear outriggers on the stage's forward/aft/left/right
          // axes — the front leg is the one under the hatch that carries the
          // ladder, which is why the gear is NOT on the diagonals like the RCS.
          // 0.90 m up from the stage's centre is where the primary strut picks
          // up, a little below the deck.
          ..._ring(
            prefix: 'leg',
            radius: 2.11,
            height: 0.90,
            startAzimuth: 0,
            size: 0.30,
          ),
          // Plume deflectors sit on the diagonals under each RCS quad, which is
          // the geometry that makes them work: they shield the descent stage
          // from the down-firing thrusters directly above them.
          ..._ring(
            prefix: 'deflector',
            radius: 2.05,
            height: 0.60,
            startAzimuth: math.pi / 4,
            size: 0.40,
          ),
        ],
      );

  // ---------------- Descent engine ----------------

  /// The descent engine bell (TRW LM Descent Engine, the DPS).
  ///
  /// Mass 180 kg is the published 394 lb dry weight of the LMDE.
  ///
  /// [size] is the EXPOSED bell — 1.5 m exit diameter by 0.78 m — not the
  /// engine's 2.18 m overall length, because the chamber and gimbal ring were
  /// recessed into the descent stage's centre bay and only the nozzle protruded.
  /// Modelling the exposed part keeps the mate at the stage's base plane and
  /// puts the bell exit where the art puts it; the 0.7 m error it introduces in
  /// where the 180 kg sits moves a 15 t vehicle's centre of mass by ~8 mm.
  ///
  /// Not modelled: the deep-throttle band. The real engine ran 10-60% of rated
  /// thrust continuously (plus a fixed full-thrust setting) and was the only
  /// throttleable engine flown in the programme, but [Engine] has no throttle
  /// limits, so it takes any throttle from 0 to 1 here.
  static PartDef _descentEngine() => const PartDef(
        id: 'eagle-thruster',
        name: 'Eagle Descent Engine (DPS)',
        category: PartCategory.rocketEngine,
        dryMass: 180,
        size: Vector3(1.5, 1.5, 0.78),
        maxTemperature: 2400, // ablatively cooled chamber liner
        dragCoefficient: 0.8,
        crossSectionArea: 1.77, // m^2, the 1.5 m bell mouth
        rocketEngine: Engine(
          name: 'LMDE (TRW)',
          maxThrustVacuum: 45040, // N, 10,125 lbf at full thrust
          // Vacuum engine with a 47:1 nozzle; the sea level pair are stand-ins
          // for a regime it was never rated in.
          maxThrustSeaLevel: 33000,
          ispVacuum: 311,
          ispSeaLevel: 200,
          oxidizerRatio: _hypergolicOxRatio,
          gimbalRange: 0.105, // rad, the flown +/-6 degrees of trim authority
        ),
        modelAsset: 'assets/mesh/eagle_thruster.fsceneb',
        modelScale: modelUnitToMetres,
        // Export authored throat-up: the standard Y-up fix alone points the
        // bell mouth aft (-Z), which is where the exhaust has to go. The mesh
        // hangs 0.37 m BELOW the part origin — the only export of the seven
        // that sits low rather than high.
        modelOffset: Vector3(0, 0, 0.37),
        attachNodes: [
          // Mates at the top of the bell; the descent stage's 'engine-mount'
          // node is the other half.
          AttachNode(
            name: 'mount',
            position: Vector3(0, 0, 0.39),
            direction: Vector3.unitZ,
            size: 1.5,
          ),
        ],
      );

  // ---------------- Landing gear ----------------

  /// ONE landing gear leg — primary strut, secondary struts, footpad and the
  /// crushable honeycomb that absorbed touchdown. The vehicle takes four,
  /// through the descent stage's `leg-*` nodes.
  ///
  /// Mass 120 kg per leg is an ESTIMATE, not a citation. Published gear-assembly
  /// totals land in the 450-550 kg range, so the family apportions 480 kg — a
  /// little under a quarter of the descent stage's 2,034 kg dry mass — and
  /// splits it four ways. If a hard per-leg figure turns up, correct it here and
  /// move the difference into [_descentStage] so the stage total stays 2,034 kg.
  ///
  /// Local frame: +X points radially OUT from the hull, +Z up, so the leg
  /// reaches down and away from its mount with no rotation applied. Mounted at
  /// radius 2.11 m the footpad lands 4.65 m off the centreline, giving a 9.30 m
  /// stance against the flown 9.4 m.
  static PartDef _landingLeg() => const PartDef(
        id: 'eagle-legs',
        name: 'Eagle Landing Gear Leg',
        category: PartCategory.landingGear,
        dryMass: 120,
        // Measured off the export at the calibrated scale: 2.54 m of radial
        // reach, 2.37 m across the secondary struts, 3.22 m from the outrigger
        // pickup down to the footpad.
        size: Vector3(2.54, 2.37, 3.22),
        maxTemperature: 700,
        dragCoefficient: 0.9, // open truss
        crossSectionArea: 0.6,
        modelAsset: 'assets/mesh/eagle_legs.fsceneb',
        modelScale: modelUnitToMetres,
        // The one export whose authored axes are a CYCLE of the part frame,
        // not a quarter turn: (0.5, 0.5, 0.5, 0.5) is the 120-degree rotation
        // about (1,1,1) that sends X->Y->Z->X. Left uncorrected the leg
        // reaches UP and sideways. With it the drawn box measures
        // 2.68 x 2.34 x 3.29 m against the 2.54 x 2.37 x 3.22 m declared in
        // [size] — the closest agreement any of the seven reaches, which is
        // why this part is the family's scale witness.
        modelRotation: Quaternion(0.5, 0.5, 0.5, 0.5),
        // Centres that box on the part origin, landing the strut's inboard
        // top corner within 0.11 m of the [outrigger] node.
        modelOffset: Vector3(-1.26, 0, 0.59),
        attachNodes: [
          // Outrigger pickup: the inboard top corner. Direction points back
          // into the hull, so the editor seats the leg against the skin.
          AttachNode(
            name: 'outrigger',
            position: Vector3(-1.27, 0, 1.61),
            direction: Vector3(-1, 0, 0),
            size: 0.30,
            kind: AttachKind.surface,
          ),
        ],
      );

  // ---------------- Reaction control ----------------

  /// One RCS quad: four R-4D thrusters on a cluster, 445 N each. Four quads
  /// gave the LM its 16 thrusters.
  ///
  /// Mass 22.5 kg is four R-4Ds at the published 3.63 kg each plus ~8 kg of
  /// cluster housing, valves and insulation — an estimate on the housing. This
  /// is the mass deducted from [_ascentStage] so the two together still come to
  /// the flown 2,150 kg.
  ///
  /// Propellant: the flown system was BIPROPELLANT, N2O4/Aerozine 50 fed from
  /// its own tanks with an interconnect to the ascent stage. This sim has no
  /// bipropellant RCS, so the quad's 72 kg share of the 287 kg total is carried
  /// as monopropellant — the mass is right, the plumbing is not.
  ///
  /// No [PartDef.rocketEngine]: an [Engine] on any part of the active stage is
  /// fired as a main engine along +Z at full throttle, which is emphatically not
  /// what a 445 N attitude thruster does. The real numbers are recorded here for
  /// whenever an RCS-specific thrust model lands: 445 N per thruster, Isp 290 s.
  static PartDef _rcsQuad() => PartDef(
        id: 'eagle-rcs-block',
        name: 'Eagle RCS Quad (4 x R-4D)',
        category: PartCategory.rcsThruster,
        dryMass: 22.5,
        // Measured: 1.00 m between the up- and down-firing nozzles, 0.52 m
        // across the lateral pair, 0.29 m of standoff from the hull.
        size: const Vector3(0.29, 0.52, 1.00),
        maxTemperature: 2400, // ablative chambers
        dragCoefficient: 1.0,
        crossSectionArea: 0.15,
        resources: [
          ResourceContainer(
            type: ResourceType.monopropellant,
            capacity: 18.0, // 72 kg, a quarter of the LM's 287 kg RCS load
            amount: 18.0,
            unitMass: _monopropUnitMass,
          ),
        ],
        modelAsset: 'assets/mesh/rcs_block.fsceneb',
        modelScale: modelUnitToMetres,
        // Authored a quarter turn out about X: uncorrected, the up/down
        // thruster pair lies along the part's Y. Turned back, the two bells
        // sit at +/-0.51 m on Z against the 1.00 m [size] declares for that
        // pair, and the cluster needs no offset — it is already centred.
        //
        // What this does NOT settle is the remaining spin about Z, i.e. which
        // way the two HORIZONTAL bells face relative to the hull. Nothing in
        // this file states it and the render cannot infer it from one part in
        // isolation; check it on an assembled ascent stage, where a bell
        // firing into the skin is unmistakable.
        modelRotation: Quaternion.axisAngle(Vector3.unitX, math.pi / 2),
        attachNodes: [
          // Local frame: +X out from the hull, +Z along the up/down thruster
          // pair, so an unrotated quad mounts on a vertical skin the way the
          // flown ones did.
          const AttachNode(
            name: 'mount',
            position: Vector3(-0.145, 0, 0),
            direction: Vector3(-1, 0, 0),
            size: 0.25,
            kind: AttachKind.surface,
          ),
        ],
      );

  /// A single R-4D thruster, for trimming a craft that does not want a whole
  /// quad. 445 N, Isp 290 s, 3.63 kg — 4 kg here with its mount.
  ///
  /// Carries no propellant, which is the truth about the hardware: an R-4D has
  /// no tank of its own and feeds off whatever the vehicle plumbs to it. Put a
  /// monopropellant store somewhere else on the craft or these fire dry.
  static PartDef _rcsSingle() => const PartDef(
        id: 'eagle-rcs-solo',
        name: 'R-4D Thruster',
        category: PartCategory.rcsThruster,
        dryMass: 4,
        // Measured: 0.22 m from mount face to nozzle exit, 0.15 m exit bell.
        size: Vector3(0.15, 0.15, 0.22),
        maxTemperature: 2400,
        dragCoefficient: 1.0,
        crossSectionArea: 0.02,
        modelAsset: 'assets/mesh/rcs_solo.fsceneb',
        modelScale: modelUnitToMetres,
        // Export authored throat-down: the standard Y-up fix alone puts the
        // exit bell on +Z and the mount neck on -Z, as this part's local frame
        // requires. The mesh stands wholly ABOVE the origin, so half its
        // 0.22 m length brings it back onto the mount face.
        modelOffset: Vector3(0, 0, -0.11),
        attachNodes: [
          // Local frame: the nozzle points +Z and the mount face is the -Z end,
          // so the node sits on that face looking back into the hull.
          AttachNode(
            name: 'mount',
            position: Vector3(0, 0, -0.11),
            direction: Vector3(0, 0, -1),
            size: 0.15,
            kind: AttachKind.surface,
          ),
        ],
      );

  /// An RCS plume deflector: the shield that kept a down-firing quad from
  /// blasting the structure below it. Structural, no propellant, no thrust.
  ///
  /// LOWEST CONFIDENCE PART IN THE FILE. The export is cut from the source
  /// model's "antennas side" group and the 9 kg is a guess at a sheet Inconel
  /// shield of this area; the flown deflectors are also smaller than the 1.65 m
  /// this export measures. Treat the identification as provisional — if the
  /// bake turns out to be an antenna, this becomes an antenna part.
  static PartDef _plumeDeflector() => const PartDef(
        id: 'eagle-rcs-blast-flute',
        name: 'Eagle RCS Plume Deflector',
        category: PartCategory.structural,
        dryMass: 9,
        // Measured off the export at the calibrated scale.
        size: Vector3(0.60, 1.65, 1.35),
        maxTemperature: 1400, // it exists to eat plume heat
        dragCoefficient: 1.1,
        crossSectionArea: 0.4,
        modelAsset: 'assets/mesh/rcs_blast_flute.fsceneb',
        modelScale: modelUnitToMetres,
        // The only export of the seven left UNSETTLED, and deliberately so.
        // On screen it is a curved shell carried on a two-leg truss, and the
        // truss feet do land on -X with the shell standing off at +X and up,
        // which is what this part's local frame asks for. But the drawn box is
        // 1.75 x 1.55 x 0.78 m and [size] below declares 0.60 x 1.65 x 1.35 —
        // no permutation of the axes reconciles those, so there is no frame to
        // rotate the mesh INTO yet. Settle what this part is first (see the
        // identification warning above); the orientation follows from that,
        // not the other way round.
        attachNodes: [
          // Local frame matches the quad's: +X out from the hull.
          AttachNode(
            name: 'mount',
            position: Vector3(-0.30, 0, 0),
            direction: Vector3(-1, 0, 0),
            size: 0.40,
            kind: AttachKind.surface,
          ),
        ],
      );

  // ---------------- Helpers ----------------

  /// Four surface nodes evenly spaced around a hull: `<prefix>-1` through
  /// `<prefix>-4`, at [radius] metres from the part's axis and [height] metres
  /// along part-local Z, the first at [startAzimuth] radians measured from +X
  /// toward +Y.
  ///
  /// Each node's direction is the outward radial normal, which is what makes a
  /// [AttachKind.surface] mate spin the child to face back into the hull. Built
  /// from trig rather than written out so the ring cannot drift out of round —
  /// a hand-typed 0.7071 in the wrong column puts a landing leg through the
  /// tankage.
  static List<AttachNode> _ring({
    required String prefix,
    required double radius,
    required double height,
    required double startAzimuth,
    required double size,
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
