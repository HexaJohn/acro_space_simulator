import '../dynamics/state_vector.dart';
import '../lifesupport/crew.dart';
import '../shared/vector3.dart';
import 'jet_engine.dart';
import '../thermal/thermal_state.dart';
import '../universe/celestial_body.dart';
import '../vessel/part.dart';
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
///   * rocket engines / resources / docking ports -> stamped onto [Part]s;
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
        dryMass: def.dryMass,
        positionInVessel: pp.position,
        inertiaContribution: inertia,
        engine: def.rocketEngine,
        resources: def.resources,
        dockingPort: def.dockingPort,
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
