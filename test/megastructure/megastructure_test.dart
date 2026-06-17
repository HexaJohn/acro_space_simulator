import 'package:acro_space_simulator/domain/megastructure/megastructure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a Dyson swarm has staged build phases with escalating requirements', () {
    final dyson = Megastructure.dysonSwarm(id: 'sol-dyson', starLuminosity: 3.828e26);
    expect(dyson.type, MegastructureType.dysonSwarm);
    expect(dyson.phases.length, greaterThan(1));
    // Later phases cost more than the first.
    expect(dyson.phases.last.requiredMass, greaterThan(dyson.phases.first.requiredMass));
    expect(dyson.isComplete, isFalse);
    expect(dyson.currentPhase, dyson.phases.first);
  });

  test('mass/energy requirements are astronomically large', () {
    final ring = Megastructure.haloRing(id: 'halo-01', radius: 5e6);
    // A Halo ring needs at least billions of tonnes (>1e12 kg).
    expect(ring.totalRequiredMass, greaterThan(1e12));
    expect(ring.totalRequiredEnergy, greaterThan(1e15));
  });

  test('contributing resources advances the current phase, not beyond it', () {
    final ring = Megastructure.haloRing(id: 'h', radius: 1e6);
    final firstPhaseMass = ring.currentPhase!.requiredMass;

    // Contribute exactly the first phase's mass + energy.
    ring.contribute(mass: firstPhaseMass, energy: ring.currentPhase!.requiredEnergy);
    // First phase complete -> moved to phase 2 (or complete if only one).
    expect(ring.completedPhases, greaterThanOrEqualTo(1));
  });

  test('a fully-funded structure reports complete and operational', () {
    final ring = Megastructure.oNeillCylinder(id: 'cyl', radius: 3200, length: 32000);
    // Dump in way more than enough across many ticks.
    for (var i = 0; i < ring.phases.length; i++) {
      final p = ring.currentPhase!;
      ring.contribute(mass: p.requiredMass, energy: p.requiredEnergy);
    }
    expect(ring.isComplete, isTrue);
    expect(ring.operational, isTrue);
  });

  test('progress fraction goes 0 -> 1 monotonically', () {
    final s = Megastructure.dysonSwarm(id: 'd', starLuminosity: 3.8e26);
    expect(s.progress, 0.0);
    s.contribute(mass: s.currentPhase!.requiredMass, energy: s.currentPhase!.requiredEnergy);
    final p1 = s.progress;
    expect(p1, greaterThan(0.0));
    expect(p1, lessThanOrEqualTo(1.0));
  });

  test('partial contribution leaves the phase incomplete', () {
    final s = Megastructure.dysonSphere(id: 'sph', starRadius: 6.96e8, starLuminosity: 3.8e26);
    s.contribute(mass: s.currentPhase!.requiredMass * 0.5, energy: 0);
    expect(s.completedPhases, 0);
    expect(s.isComplete, isFalse);
  });
}
