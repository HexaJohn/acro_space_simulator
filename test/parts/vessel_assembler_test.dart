// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:math' as math;

import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:acro_space_simulator/domain/parts/vessel_assembler.dart';
import 'package:acro_space_simulator/domain/shared/quaternion.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/docking_port.dart';
import 'package:acro_space_simulator/domain/vessel/part.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final catalog = PartCatalog.standard();
  const assembler = VesselAssembler();

  PlacedPart place(String id, String inst, Vector3 pos,
          {int stage = 0, Quaternion rotation = Quaternion.identity}) =>
      PlacedPart(
        def: catalog.byId(id)!,
        instanceId: inst,
        position: pos,
        stage: stage,
        rotation: rotation,
      );

  test('baked vessel total mass equals the sum of part masses', () {
    final parts = [
      place('mk1-capsule', 'pod', Vector3.zero),
      place('fl-t400', 'tank', const Vector3(0, 0, -2)),
      place('merlin-1d', 'eng', const Vector3(0, 0, -4)),
    ];
    final v = assembler.assemble(
      id: 'rocket-1',
      name: 'Test Rocket',
      ownerId: 'p',
      parts: parts,
      state: const StateVector(position: Vector3(700000, 0, 0), velocity: Vector3.zero),
      dominantBody: const BodyId('earth'),
    );
    final expected = parts.fold(0.0, (s, p) => s + p.def.dryMass) +
        catalog.byId('fl-t400')!.resources.fold(0.0, (s, r) => s + r.mass);
    expect(v.mass, closeTo(expected, 1.0));
  });

  test('baked into a SINGLE rigid body — one stage collapses to one part list', () {
    final parts = [
      place('mk1-capsule', 'pod', Vector3.zero),
      place('fl-t400', 'tank', const Vector3(0, 0, -2)),
    ];
    final v = assembler.assemble(
      id: 'r',
      name: 'r',
      ownerId: 'p',
      parts: parts,
      state: const StateVector(position: Vector3(700000, 0, 0), velocity: Vector3.zero),
      dominantBody: const BodyId('earth'),
    );
    // All same-stage parts end up in one stage.
    expect(v.stages.length, 1);
  });

  test('centre of mass is the mass-weighted average of part positions', () {
    // Two equal-mass structural parts at +Z=1 and -Z=1 -> CoM at z=0.
    final parts = [
      place('tr-18a-decoupler', 'a', const Vector3(0, 0, 1)),
      place('tr-18a-decoupler', 'b', const Vector3(0, 0, -1)),
    ];
    final v = assembler.assemble(
      id: 'r',
      name: 'r',
      ownerId: 'p',
      parts: parts,
      state: const StateVector(position: Vector3(700000, 0, 0), velocity: Vector3.zero),
      dominantBody: const BodyId('earth'),
    );
    expect(v.massProperties.centerOfMass.z, closeTo(0, 1e-6));
  });

  test('a crewed pod gives the vessel crew', () {
    final v = assembler.assemble(
      id: 'r',
      name: 'r',
      ownerId: 'p',
      parts: [place('mk1-capsule', 'pod', Vector3.zero)],
      state: const StateVector(position: Vector3(700000, 0, 0), velocity: Vector3.zero),
      dominantBody: const BodyId('earth'),
    );
    expect(v.crew, isNotNull);
    expect(v.crew!.count, 1);
  });

  test('an aircraft with wings + jet assembles with lift area and a jet engine', () {
    final v = assembler.assemble(
      id: 'plane',
      name: 'Plane',
      ownerId: 'p',
      parts: [
        place('cockpit-mk1', 'cockpit', Vector3.zero),
        place('swept-wing', 'wingL', const Vector3(-2, 0, 0)),
        place('swept-wing', 'wingR', const Vector3(2, 0, 0)),
        place('ram-intake', 'intake', const Vector3(0, 0, 1)),
        place('turbojet-j85', 'jet', const Vector3(0, 0, -2)),
        place('jet-fuel-tank', 'tank', const Vector3(0, 0, -1)),
      ],
      state: const StateVector(position: Vector3(6771000, 0, 0), velocity: Vector3.zero),
      dominantBody: const BodyId('earth'),
    );
    // Aggregated lift area from the two wings.
    expect(v.totalWingArea, closeTo(24.0, 1e-6));
    // Has an air-breathing engine and intake air.
    expect(v.hasJetEngine, isTrue);
    expect(v.totalIntakeArea, greaterThan(0));
  });

  test('a part turns about the box it declares, not about a default cube', () {
    // [PartDef.size] is not only art: it is the box the inertia model
    // integrates, so editing a part's dimensions silently re-tunes how the
    // craft carrying it handles. Nothing else asserts a number about that, and
    // an aeroplane whose roll inertia is wrong by an order of magnitude still
    // takes off, still burns fuel and still passes an "it accelerated" test.
    //
    // Stated as the closed form the assembler uses (a solid cuboid about its
    // own centre, plus the parallel-axis term for where it sits), so this
    // tracks a deliberate size change instead of going stale on one.
    final wing = catalog.byId('swept-wing')!;
    const armM = 2.0;
    final v = assembler.assemble(
      id: 'plane',
      name: 'Plane',
      ownerId: 'p',
      parts: [
        place('cockpit-mk1', 'cockpit', Vector3.zero),
        place('swept-wing', 'wingL', const Vector3(-armM, 0, 0)),
        place('swept-wing', 'wingR', const Vector3(armM, 0, 0)),
      ],
      state: const StateVector(
          position: Vector3(6771000, 0, 0), velocity: Vector3.zero),
      dominantBody: const BodyId('earth'),
    );

    final m = wing.dryMass;
    final s = wing.size;
    final d2 = armM * armM; // the assembler's parallel-axis term is isotropic
    final panel = v.allParts.firstWhere((p) => p.id.value == 'wingL');
    expect(panel.inertiaContribution.x,
        closeTo(m * (s.y * s.y + s.z * s.z) / 12 + m * d2, 1e-6));
    expect(panel.inertiaContribution.y,
        closeTo(m * (s.x * s.x + s.z * s.z) / 12 + m * d2, 1e-6));
    expect(panel.inertiaContribution.z,
        closeTo(m * (s.x * s.x + s.y * s.y) / 12 + m * d2, 1e-6));

    // ...and the shape of the answer, which is what makes it a wing rather
    // than a block. The parallel-axis term the assembler adds is the same on
    // all three axes, so it is subtracted off here to leave the part's own
    // tensor: a panel is long in span (X) and thin in thickness (Y), so about
    // its own centre it resists pitch and yaw several times more than roll. A
    // cube resists all three equally, and that is exactly the reading a
    // part left at the default 1 m box gives.
    final self = panel.inertiaContribution - Vector3(m * d2, m * d2, m * d2);
    expect(self.y, greaterThan(self.x * 3),
        reason: 'a ${s.x} m span against a ${s.y} m thickness');
    expect(self.z, greaterThan(self.x * 3));
  });

  test('staging groups become ordered stages', () {
    final parts = [
      place('mk1-capsule', 'pod', Vector3.zero, stage: 2),
      place('merlin-1d', 'upper', const Vector3(0, 0, -4), stage: 1),
      place('merlin-1d', 'booster', const Vector3(0, 0, -8), stage: 0),
    ];
    final v = assembler.assemble(
      id: 'r',
      name: 'r',
      ownerId: 'p',
      parts: parts,
      state: const StateVector(position: Vector3(700000, 0, 0), velocity: Vector3.zero),
      dominantBody: const BodyId('earth'),
    );
    expect(v.stages.length, 3);
    // Active stage = the last one fired (highest index in this model).
    expect(v.activeStage, isNotNull);
  });

  // ---------------- Template independence ----------------
  // A catalog [PartDef] is a shared, long-lived template: PartCatalog.standard()
  // builds each def once and hands the same instance to every craft. Anything
  // MUTABLE hanging off a def must therefore be copied as it is stamped into a
  // Part, or two parts become one part wearing two hats.

  group('parts stamped from one catalog def do not share mutable state', () {
    ({Vessel vessel, Part a, Part b}) twoTanks() {
      final v = assembler.assemble(
        id: 'r',
        name: 'r',
        ownerId: 'p',
        parts: [
          place('fl-t400', 'tankA', const Vector3(0, 0, -2)),
          place('fl-t400', 'tankB', const Vector3(0, 0, -4)),
        ],
        state: const StateVector(position: Vector3(700000, 0, 0), velocity: Vector3.zero),
        dominantBody: const BodyId('earth'),
      );
      final parts = v.allParts.toList();
      return (
        vessel: v,
        a: parts.firstWhere((p) => p.id == const PartId('tankA')),
        b: parts.firstWhere((p) => p.id == const PartId('tankB')),
      );
    }

    test('two identical tanks carry TWO tanks worth of propellant', () {
      final t = twoTanks();
      final def = catalog.byId('fl-t400')!;
      final perTank = def.dryMass + def.resources.fold(0.0, (s, r) => s + r.mass);
      expect(t.vessel.mass, closeTo(2 * perTank, 1e-6));
      expect(identical(t.a.resources, t.b.resources), isFalse,
          reason: 'the two parts must own separate container lists');
    });

    test('draining one tank leaves its twin full', () {
      final t = twoTanks();
      final before = t.vessel.mass;

      final drawn = t.a.containerFor(ResourceType.liquidFuel)!.draw(180);
      expect(drawn, closeTo(180, 1e-9));
      // A is dry: containerFor skips empty containers.
      expect(t.a.containerFor(ResourceType.liquidFuel), isNull);
      // B never touched.
      expect(t.b.containerFor(ResourceType.liquidFuel)!.amount, closeTo(180, 1e-9));
      // The craft lost exactly the propellant that was burned, not twice it.
      expect(before - t.vessel.mass, closeTo(180 * 5, 1e-6));
    });

    test('draining a baked tank does not drain the catalog template', () {
      final t = twoTanks();
      t.a.containerFor(ResourceType.liquidFuel)!.draw(50);
      final template = catalog
          .byId('fl-t400')!
          .resources
          .firstWhere((r) => r.type == ResourceType.liquidFuel);
      expect(template.amount, closeTo(180, 1e-9),
          reason: 'the next craft off the catalog must launch with full tanks');
    });

    test('a real burn empties one tank, then the next', () {
      // The end-to-end shape of the aliasing bug, driven through the force
      // model rather than by calling draw() by hand: _ThrustForce picks the
      // FIRST non-empty container in the stage and draws from it, so a correct
      // craft runs tank A dry before it touches tank B. Two parts sharing one
      // container instead drain together at half the rate each while the mass
      // model still counts both tanks — the craft loses twice the propellant it
      // burned, and every delta-v the player is shown is wrong.
      const fuel = ResourceType.liquidFuel;
      final v = assembler.assemble(
        id: 'twin',
        name: 'twin',
        ownerId: 'p',
        parts: [
          place('mk1-capsule', 'pod', Vector3.zero),
          place('fl-t400', 'tankA', const Vector3(0, 0, -2)),
          place('fl-t400', 'tankB', const Vector3(0, 0, -4)),
          place('merlin-1d', 'eng', const Vector3(0, 0, -6)),
        ],
        state: const StateVector(
            position: Vector3(700000, 0, 0), velocity: Vector3.zero),
        dominantBody: const BodyId('earth'),
      );

      Part partOf(String id) =>
          v.allParts.firstWhere((p) => p.id == PartId(id));
      // Read off `resources` directly, not containerFor: an empty container is
      // exactly what this test needs to observe, and containerFor hides it.
      double fuelIn(String id) =>
          partOf(id).resources.firstWhere((r) => r.type == fuel).amount;

      expect(
          identical(partOf('tankA').resources.first,
              partOf('tankB').resources.first),
          isFalse,
          reason: 'each tank must own its own container');

      final tankUnits = catalog
          .byId('fl-t400')!
          .resources
          .firstWhere((r) => r.type == fuel)
          .amount;
      final unitMass = partOf('tankA').resources.first.unitMass;
      final massBefore = v.mass;
      v.setThrottle(1.0);

      /// One integration tick of vacuum thrust, drawing propellant.
      void burn(double dt) {
        final t = v.thrustContributor(pressureFraction: 0, dt: dt);
        expect(t, isNotNull, reason: 'the stage still has propellant');
        t!.evaluate(v.state, v.massProperties);
      }

      // Tank A alone supplies the burn until it is dry. A shared container
      // fails on the very first tick: B reads whatever A was drawn down to.
      burn(1.0);
      expect(fuelIn('tankA'), lessThan(tankUnits));
      expect(fuelIn('tankB'), closeTo(tankUnits, 1e-9),
          reason: 'tank B has not been plumbed in yet');

      var ticks = 1;
      while (fuelIn('tankA') > 0 && ticks < 100) {
        burn(1.0);
        ticks++;
        expect(fuelIn('tankB'), closeTo(tankUnits, 1e-9),
            reason: 'tank B drained while tank A still had propellant');
      }
      expect(fuelIn('tankA'), 0, reason: 'tank A ran dry within $ticks s');

      // Only now does the engine reach across to the second tank.
      burn(1.0);
      expect(fuelIn('tankB'), lessThan(tankUnits));
      expect(fuelIn('tankA'), 0);

      // The craft is lighter by exactly what was burned. Under aliasing the
      // two tanks report one shared level, so the mass model debits both.
      final burned = 2 * tankUnits - fuelIn('tankA') - fuelIn('tankB');
      expect(massBefore - v.mass, closeTo(burned * unitMass, 1e-6));
    });

    test('two craft do not share one docking port latch', () {
      DockingPort build() {
        final v = assembler.assemble(
          id: 'r',
          name: 'r',
          ownerId: 'p',
          parts: [place('docking-port-std', 'port1', Vector3.zero)],
          state: const StateVector(position: Vector3(700000, 0, 0), velocity: Vector3.zero),
          dominantBody: const BodyId('earth'),
        );
        return v.allParts.first.dockingPort!;
      }

      final chaser = build();
      final target = build();
      expect(identical(chaser, target), isFalse);

      chaser.latchedTo = 'somebody-else';
      expect(target.isDocked, isFalse,
          reason: 'docking one craft must not mark every other craft docked');
    });
  });

  test('a docking port is reported in the CRAFT body frame, not part-local', () {
    // The LM tunnel sits 1.73 m up the ascent stage; put the stage 3 m up the
    // craft and the port must read 4.73 m, and turn the stage over and the port
    // must face the other way.
    final v = assembler.assemble(
      id: 'lm',
      name: 'lm',
      ownerId: 'p',
      parts: [
        place('eagle-command-pod', 'pod', const Vector3(0, 0, 3)),
        place('eagle-command-pod', 'inverted', const Vector3(0, 0, -3),
            rotation: Quaternion.axisAngle(Vector3.unitX, math.pi)),
      ],
      state: const StateVector(position: Vector3(700000, 0, 0), velocity: Vector3.zero),
      dominantBody: const BodyId('earth'),
    );
    final parts = v.allParts.toList();
    final upright = parts.firstWhere((p) => p.id == const PartId('pod')).dockingPort!;
    final inverted = parts.firstWhere((p) => p.id == const PartId('inverted')).dockingPort!;

    expect(upright.position.z, closeTo(4.73, 1e-9));
    expect(upright.facing.z, closeTo(1, 1e-9));
    // Flipped part: the tunnel hangs below the mount and points -Z.
    expect(inverted.position.z, closeTo(-4.73, 1e-9));
    expect(inverted.facing.z, closeTo(-1, 1e-9));
  });
}
