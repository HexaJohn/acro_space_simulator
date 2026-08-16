// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/domain/parts/attach_node.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/vessel/propulsion.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';

// Synthetic part defs for the craft-design suite.
//
// Deliberately not catalog parts. The suites that use these exercise the
// GEOMETRY of mating — where the solver puts a child, which mates it refuses,
// what a symmetry op does to an orientation — and that is easiest to check
// against round numbers a failure can be read off by eye: the 1.25 m stack
// parts are 2 m tall with nodes at +/-1.0, and the hull's surface nodes sit
// exactly on a 1 m radius. Real parts carry node coordinates derived from their
// art, which would turn every expected value here into an opaque constant and
// couple a pure solver test to a model calibration.
//
// Assemblies of REAL parts belong in lem_assembly_test.dart, which builds from
// [PartCatalog] so that renaming or moving a shipped attach node fails there.
//
// Body convention throughout: metres, Z-up, nose on +Z. Attach node directions
// point OUT of the part.

const Vector3 _down = Vector3(0, 0, -1);
const Vector3 _up = Vector3(0, 0, 1);

/// 1.25 m command pod. One stack node underneath, one surface node on the +X
/// skin at a 0.6 m radius.
///
/// The smallest thing a design can be rooted on: crew aboard, one axial mate,
/// one radial mate.
const PartDef testPod = PartDef(
  id: 'test-pod',
  name: 'Test Pod',
  category: PartCategory.commandPod,
  dryMass: 800,
  size: Vector3(1.25, 1.25, 1.4),
  crewCapacity: 2,
  attachNodes: [
    AttachNode(name: 'bottom', position: Vector3(0, 0, -0.7), direction: _down),
    AttachNode(
      name: 'skin',
      position: Vector3(0.6, 0, 0),
      direction: Vector3.unitX,
      size: 0.6,
      kind: AttachKind.surface,
    ),
  ],
);

/// 1.25 m structural spacer, 2 m tall: stack nodes at +/-1.0, surface nodes on
/// the +X and +Y skin at a 1 m radius.
///
/// The workhorse. Two opposed stack nodes and two skin nodes 90 degrees apart
/// are the minimum that can show a mate landing on the wrong node or facing the
/// wrong way, and every coordinate on it is a whole or half metre.
const PartDef testHull = PartDef(
  id: 'test-hull',
  name: 'Test Hull',
  category: PartCategory.structural,
  dryMass: 400,
  size: Vector3(2, 2, 2),
  attachNodes: [
    AttachNode(name: 'top', position: Vector3(0, 0, 1), direction: _up),
    AttachNode(name: 'bottom', position: Vector3(0, 0, -1), direction: _down),
    AttachNode(
      name: 'skinX',
      position: Vector3(1, 0, 0),
      direction: Vector3.unitX,
      size: 1.0,
      kind: AttachKind.surface,
    ),
    AttachNode(
      name: 'skinY',
      position: Vector3(0, 1, 0),
      direction: Vector3.unitY,
      size: 1.0,
      kind: AttachKind.surface,
    ),
  ],
);

/// Same hull in the 2.5 m class — used to prove a stack size mismatch is
/// refused rather than quietly adapted.
const PartDef testHullWide = PartDef(
  id: 'test-hull-wide',
  name: 'Test Hull (2.5m)',
  category: PartCategory.structural,
  dryMass: 900,
  size: Vector3(2.5, 2.5, 2),
  attachNodes: [
    AttachNode(
        name: 'top', position: Vector3(0, 0, 1), direction: _up, size: 2.5),
    AttachNode(
        name: 'bottom', position: Vector3(0, 0, -1), direction: _down, size: 2.5),
  ],
);

/// Radial block whose mount face is on its -X side, so the block itself sticks
/// out along its local +X. Surface-mount only.
///
/// Carries exactly one node, and a surface one, so it is also what proves a
/// surface node is refused by a stack node instead of quietly mated.
const PartDef testBlock = PartDef(
  id: 'test-block',
  name: 'Test Radial Block',
  category: PartCategory.rcsThruster,
  dryMass: 50,
  size: Vector3(0.3, 0.3, 0.3),
  attachNodes: [
    AttachNode(
      name: 'mount',
      position: Vector3(-0.1, 0, 0),
      direction: Vector3(-1, 0, 0),
      size: 0.3,
      kind: AttachKind.surface,
    ),
  ],
);

/// 1.25 m engine, stack node on top at +0.5. The only fixture with an [Engine],
/// so a baked design has something that can report thrust and delta-v.
PartDef testEngine() => const PartDef(
      id: 'test-engine',
      name: 'Test Engine',
      category: PartCategory.rocketEngine,
      dryMass: 500,
      size: Vector3(1.25, 1.25, 1),
      rocketEngine: Engine(
        name: 'Test',
        maxThrustVacuum: 200000,
        maxThrustSeaLevel: 180000,
        ispVacuum: 320,
        ispSeaLevel: 280,
      ),
      attachNodes: [
        AttachNode(name: 'top', position: Vector3(0, 0, 0.5), direction: _up),
      ],
    );

/// 1.25 m tank, 2 m tall, with propellant. Not const: [ResourceContainer]
/// carries a mutable amount, so each call hands back fresh tankage instead of
/// letting two placed parts drain one shared container.
PartDef testTank() => PartDef(
      id: 'test-tank',
      name: 'Test Tank',
      category: PartCategory.fuelTank,
      dryMass: 300,
      size: const Vector3(1.25, 1.25, 2),
      resources: [
        ResourceContainer(
            type: ResourceType.liquidFuel,
            capacity: 400,
            amount: 400,
            unitMass: 5),
        ResourceContainer(
            type: ResourceType.oxidizer,
            capacity: 440,
            amount: 440,
            unitMass: 5),
      ],
      attachNodes: const [
        AttachNode(name: 'top', position: Vector3(0, 0, 1), direction: _up),
        AttachNode(name: 'bottom', position: Vector3(0, 0, -1), direction: _down),
        AttachNode(
          name: 'skin',
          position: Vector3(0.625, 0, 0),
          direction: Vector3.unitX,
          size: 0.6,
          kind: AttachKind.surface,
        ),
      ],
    );

/// Every fixture def in one catalog, so the codec can resolve a saved design's
/// def ids back to specs. Fresh per call for the same reason [testTank] is.
PartCatalog testCatalog() => PartCatalog([
      testPod,
      testHull,
      testHullWide,
      testBlock,
      testEngine(),
      testTank(),
    ]);
