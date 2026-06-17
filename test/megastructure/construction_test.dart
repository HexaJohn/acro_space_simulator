import 'package:acro_space_simulator/domain/megastructure/megastructure.dart';
import 'package:acro_space_simulator/domain/megastructure/megastructure_construction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const construction = MegastructureConstruction();

  test('delivered material + on-site energy advance the project', () {
    final ring = Megastructure.haloRing(id: 'h', radius: 1e5);
    final before = ring.progress;
    ring.deliverMaterial(ring.currentPhase!.requiredMass);
    ring.deliverEnergy(ring.currentPhase!.requiredEnergy);

    construction.advance(ring, dt: 100);
    expect(ring.progress, greaterThan(before));
  });

  test('no material on-site -> no phase can complete (delivery is mandatory)', () {
    final ring = Megastructure.haloRing(id: 'h', radius: 1e5);
    ring.deliverEnergy(1e30); // unlimited energy, but nothing delivered
    construction.advance(ring, dt: 1e6);
    expect(ring.completedPhases, 0);
    expect(ring.currentPhase!.contributedMass, 0);
  });

  test('completing a phase raises a phase-complete event', () {
    final ring = Megastructure.oNeillCylinder(id: 'cyl', radius: 100, length: 200);
    ring.deliverMaterial(ring.currentPhase!.requiredMass);
    ring.deliverEnergy(ring.currentPhase!.requiredEnergy);
    final events = construction.advance(ring, dt: 1e6);
    expect(events.any((e) => e.contains('phase')), isTrue);
  });

  test('finishing all phases marks the structure operational + complete event', () {
    final ring = Megastructure.oNeillCylinder(id: 'cyl', radius: 100, length: 200);
    var sawComplete = false;
    for (var i = 0; i < 10 && !ring.isComplete; i++) {
      // Keep delivering material + energy each tick (sustained logistics).
      final p = ring.currentPhase;
      if (p != null) {
        ring.deliverMaterial(p.requiredMass);
        ring.deliverEnergy(p.requiredEnergy);
      }
      final ev = construction.advance(ring, dt: 1e7);
      if (ev.any((e) => e.contains('complete') && !e.contains('phase'))) {
        sawComplete = true;
      }
    }
    expect(ring.isComplete, isTrue);
    expect(ring.operational, isTrue);
    expect(sawComplete, isTrue);
  });
}
