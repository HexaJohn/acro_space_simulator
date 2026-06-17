import 'package:acro_space_simulator/domain/megastructure/megastructure.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Megastructure complete(Megastructure m) {
    for (var i = 0; i < m.phases.length; i++) {
      final p = m.currentPhase!;
      m.contribute(mass: p.requiredMass, energy: p.requiredEnergy);
    }
    return m;
  }

  test('an incomplete Dyson swarm produces no power', () {
    final dyson = Megastructure.dysonSwarm(id: 'd', starLuminosity: 3.828e26);
    expect(dyson.currentPowerOutput, 0);
  });

  test('a completed Dyson swarm captures a fraction of stellar luminosity', () {
    final dyson = complete(
        Megastructure.dysonSwarm(id: 'd', starLuminosity: 3.828e26));
    expect(dyson.operational, isTrue);
    // ~10% of the Sun's 3.828e26 W.
    expect(dyson.currentPowerOutput, closeTo(3.828e25, 1e24));
  });

  test('a completed Dyson sphere outputs vastly more than a swarm', () {
    final swarm = complete(Megastructure.dysonSwarm(id: 's', starLuminosity: 3.828e26));
    final sphere = complete(Megastructure.dysonSphere(
        id: 'sph', starRadius: 6.96e8, starLuminosity: 3.828e26));
    expect(sphere.currentPowerOutput, greaterThan(swarm.currentPowerOutput * 5));
  });

  test('a completed Halo ring exposes habitable area and a population cap', () {
    final ring = complete(Megastructure.haloRing(id: 'h', radius: 5e6));
    expect(ring.currentHabitableArea, greaterThan(0));
    // ~ one person per 200 m^2 of habitable surface.
    expect(ring.populationCapacity, ring.currentHabitableArea ~/ 200);
    expect(ring.populationCapacity, greaterThan(0));
  });

  test('an incomplete ring offers no habitat yet', () {
    final ring = Megastructure.haloRing(id: 'h', radius: 5e6);
    expect(ring.currentHabitableArea, 0);
    expect(ring.populationCapacity, 0);
  });
}
