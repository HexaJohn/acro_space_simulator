import '../shared/vector3.dart';
import '../vessel/docking_port.dart';
import '../vessel/propulsion.dart';
import '../vessel/resource_container.dart';
import 'jet_engine.dart';
import 'lifting_surface.dart';
import 'part_def.dart';

/// The roster of available parts, grounded in real launch vehicles and
/// aircraft. Reference data; the [VesselAssembler] picks from it.
class PartCatalog {
  final Map<String, PartDef> _byId;

  PartCatalog(Iterable<PartDef> parts)
      : _byId = {for (final p in parts) p.id: p};

  Iterable<PartDef> get all => _byId.values;
  PartDef? byId(String id) => _byId[id];
  Iterable<PartDef> inCategory(PartCategory c) =>
      _byId.values.where((p) => p.category == c);

  /// The standard catalog: a cross-section of real rocket and aircraft parts.
  factory PartCatalog.standard() => PartCatalog([
        // ---------------- Command ----------------
        const PartDef(
          id: 'mk1-capsule',
          name: 'Mk1 Command Capsule',
          category: PartCategory.commandPod,
          dryMass: 840,
          size: Vector3(1.25, 1.25, 1.4),
          crewCapacity: 1,
          maxTemperature: 2400,
          crossSectionArea: 1.2,
        ),
        const PartDef(
          id: 'cockpit-mk1',
          name: 'Mk1 Aircraft Cockpit',
          category: PartCategory.commandPod,
          dryMass: 1000,
          size: Vector3(1.25, 1.25, 3.0),
          crewCapacity: 1,
          dragCoefficient: 0.08,
          crossSectionArea: 1.0,
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
        ),

        // ---------------- Intakes ----------------
        const PartDef(
          id: 'ram-intake',
          name: 'Ram Air Intake',
          category: PartCategory.intake,
          dryMass: 70,
          dragCoefficient: 0.1,
          intakeArea: 0.8,
        ),

        // ---------------- Wings / control surfaces ----------------
        const PartDef(
          id: 'swept-wing',
          name: 'Swept Wing',
          category: PartCategory.wing,
          dryMass: 200,
          dragCoefficient: 0.02,
          wing: LiftingSurface(
            name: 'Swept Wing',
            area: 12.0,
            liftCurveSlope: 5.5,
            stallAngle: 0.26,
            dragCoefficient: 0.02,
          ),
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
        ),

        // ---------------- Utility ----------------
        const PartDef(
          id: 'tr-18a-decoupler',
          name: 'TR-18A Stack Decoupler',
          category: PartCategory.decoupler,
          dryMass: 50,
        ),
        const PartDef(
          id: 'landing-gear',
          name: 'Retractable Landing Gear',
          category: PartCategory.landingGear,
          dryMass: 60,
          dragCoefficient: 0.05,
        ),
        const PartDef(
          id: 'mk16-chute',
          name: 'Mk16 Parachute',
          category: PartCategory.parachute,
          dryMass: 100,
        ),
        const PartDef(
          id: 'heat-shield-1',
          name: 'Heat Shield (1.25m)',
          category: PartCategory.heatShield,
          dryMass: 300,
          ablator: 200,
          maxTemperature: 3300,
        ),
        const PartDef(
          id: 'thermometer',
          name: 'Thermometer',
          category: PartCategory.science,
          dryMass: 5,
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
        ),
        PartDef(
          id: 'docking-port-std',
          name: 'Standard Docking Port',
          category: PartCategory.structural,
          dryMass: 50,
          dockingPort: DockingPort(
            id: 'port',
            position: Vector3.zero,
            facing: Vector3.unitZ,
          ),
        ),
      ]);
}
