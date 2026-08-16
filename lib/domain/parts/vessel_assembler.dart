// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../dynamics/state_vector.dart';
import '../lifesupport/crew.dart';
import '../shared/vector3.dart';
import 'jet_engine.dart';
import '../thermal/thermal_state.dart';
import '../universe/celestial_body.dart';
import '../vessel/docking_port.dart';
import '../vessel/part.dart';
import '../vessel/resource_container.dart';
import '../vessel/stage.dart';
import '../vessel/vessel.dart';
import 'part_def.dart';

/// Bakes a set of [PlacedPart]s into a SINGLE rigid-body [Vessel].
///
/// "Baked phys object": the assembled craft is collapsed into one rigid body —
/// the parts no longer move relative to each other, so the simulation treats it
/// as a single mass with one combined centre of mass and inertia tensor. This
/// is the standard approach for a flyable craft (vs a soft part-joint sim).
///
/// What it aggregates:
///   * mass = sum of dry + resource masses;
///   * centre of mass = mass-weighted average of part positions;
///   * inertia = each part's own inertia plus the parallel-axis term m*d^2 about
///     the combined CoM (so off-axis parts add rotational inertia);
///   * rocket engines -> stamped onto [Part]s by reference (immutable specs);
///   * resources / docking ports -> COPIED onto [Part]s, because they carry
///     mutable per-craft state and the [PartDef] they come from is a shared
///     template;
///   * wings -> total lift area + averaged lift slope on the vessel;
///   * jet engines + intakes -> air-breathing aggregate on the vessel;
///   * crew capacity -> a [CrewModule];
///   * heat-shield ablator + part temp limits -> per-part [PartThermalState].
///
/// Staging groups (by [PlacedPart.stage]) become ordered [Stage]s.
class VesselAssembler {
  const VesselAssembler();

  Vessel assemble({
    required String id,
    required String name,
    required String ownerId,
    required List<PlacedPart> parts,
    required StateVector state,
    required BodyId dominantBody,
    bool landed = false,
  }) {
    // 1. Combined centre of mass (mass-weighted over placed positions).
    var totalMass = 0.0;
    var weighted = Vector3.zero;
    for (final pp in parts) {
      final m = _partMass(pp.def);
      totalMass += m;
      weighted = weighted + pp.position * m;
    }
    final com = totalMass > 0 ? weighted / totalMass : Vector3.zero;

    // 2. Bake each placed part into a Part, grouping by stage. Inertia uses the
    // parallel-axis theorem about the combined CoM.
    final byStage = <int, List<Part>>{};
    final thermal = <PartThermalState>[];
    var wingArea = 0.0;
    var wingSlopeSum = 0.0;
    var wingCount = 0;
    var intakeArea = 0.0;
    var crewCount = 0;
    final jets = <JetEngine>[];

    for (final pp in parts) {
      final def = pp.def;
      final m = _partMass(def);
      final offset = pp.position - com;
      final d2 = offset.lengthSquared;
      // Parallel-axis: own box inertia + m*d^2 about the combined CoM.
      final inertia = _selfInertia(def, m) + Vector3(m * d2, m * d2, m * d2);

      final part = Part(
        id: PartId(pp.instanceId),
        name: def.name,
        // The catalog id survives the bake because it is the only stable key
        // the renderer can bind art to; the display name is free to change.
        defId: def.id,
        dryMass: def.dryMass,
        positionInVessel: pp.position,
        // Carried for render/structure only. The craft is baked rigid and the
        // self-inertia box above is axis-aligned, so rotating a part does not
        // change the aggregate — deliberately NOT fed into the tensor.
        rotationInVessel: pp.rotation,
        inertiaContribution: inertia,
        engine: def.rocketEngine,
        // Fresh containers per instance — see [_ownContainers].
        resources: _ownContainers(def),
        dockingPort: _portInBody(def.dockingPort, pp),
        maxTemperature: def.maxTemperature,
        dragCoefficient: def.dragCoefficient,
        crossSectionArea: def.crossSectionArea,
      );
      byStage.putIfAbsent(pp.stage, () => []).add(part);

      // Thermal state for heat-shielded / heat-limited parts.
      if (def.ablator > 0 || def.category == PartCategory.heatShield) {
        thermal.add(PartThermalState(
          part: PartId(pp.instanceId),
          temperature: 290,
          heatCapacity: m * 800, // ~specific heat of metal
          maxTemperature: def.maxTemperature,
          surfaceArea: def.crossSectionArea * 2,
          ablator: def.ablator,
          ablationHeatPerUnit: 5000,
        ));
      }

      // Aircraft aggregates.
      if (def.wing != null) {
        wingArea += def.wing!.area;
        wingSlopeSum += def.wing!.liftCurveSlope;
        wingCount++;
      }
      intakeArea += def.intakeArea;
      crewCount += def.crewCapacity;
      if (def.jetEngine != null) jets.add(def.jetEngine!);
    }

    final stages = (byStage.keys.toList()..sort())
        .map((idx) => Stage(index: idx, parts: byStage[idx]!))
        .toList();

    final vessel = Vessel(
      id: VesselId(id),
      name: name,
      ownerId: ownerId,
      state: state,
      dominantBody: dominantBody,
      stages: stages.isEmpty ? [const Stage(index: 0, parts: [])] : stages,
      landed: landed,
      thermal: thermal,
    );

    // Aircraft aero aggregates.
    vessel.totalWingArea = wingArea;
    vessel.wingLiftSlope = wingCount > 0 ? wingSlopeSum / wingCount : 5.5;
    vessel.totalIntakeArea = intakeArea;
    vessel.jetEngines.addAll(jets);

    if (crewCount > 0) {
      vessel.crew = CrewModule(
        count: crewCount,
        foodPerCrewPerSecond: 0.0001,
        oxygenPerCrewPerSecond: 0.0002,
      );
    }

    return vessel;
  }

  /// This part's OWN resource containers, copied off the [PartDef].
  ///
  /// A [PartDef] is a long-lived template — [PartCatalog.standard] builds each
  /// def once and hands the same instance to every craft ever assembled — while
  /// [ResourceContainer.amount] is mutable per-part state. Handing the def's
  /// containers straight to the [Part] would make two tanks off one def a
  /// single tank shared between them (and shared with the catalog itself, so
  /// the next craft would launch with whatever the last one left).
  List<ResourceContainer> _ownContainers(PartDef def) =>
      def.resources.isEmpty
          ? const []
          : [for (final r in def.resources) r.copy()];

  /// This part's OWN docking port, moved from the part-local frame the def
  /// authors it in into the CRAFT body frame [DockingPort] is defined in.
  ///
  /// Two reasons this cannot be the def's instance: [DockingPort.latchedTo] is
  /// mutable, so a shared port would report every craft carrying that part as
  /// docked the moment any one of them latched; and the def's position/facing
  /// are relative to the PART, so a port on a part placed 3 m up the stack has
  /// to be translated and turned by that placement before the docking solver
  /// can aim at it.
  ///
  /// [DockingPort.id] is carried through unchanged: it is the def author's
  /// name for the port ('lm-tunnel'), which is what a [DockingApproach] refers
  /// to. Two instances of one port def on a single craft therefore share an id
  /// and only the first is reachable — mount distinct port defs until the id
  /// scheme grows an instance qualifier.
  DockingPort? _portInBody(DockingPort? port, PlacedPart pp) => port == null
      ? null
      : DockingPort(
          id: port.id,
          position: pp.position + pp.rotation.rotate(port.position),
          facing: pp.rotation.rotate(port.facing),
          sizeClass: port.sizeClass,
          latchedTo: port.latchedTo,
        );

  double _partMass(PartDef def) =>
      def.dryMass + def.resources.fold(0.0, (s, r) => s + r.mass);

  /// Crude self-inertia of a part from its bounding box (solid box about its
  /// own centre). Diagonal tensor.
  Vector3 _selfInertia(PartDef def, double m) {
    final s = def.size;
    final ixx = (1 / 12) * m * (s.y * s.y + s.z * s.z);
    final iyy = (1 / 12) * m * (s.x * s.x + s.z * s.z);
    final izz = (1 / 12) * m * (s.x * s.x + s.y * s.y);
    return Vector3(ixx, iyy, izz);
  }
}
