import 'package:acro_space_simulator/domain/megastructure/megastructure.dart';
import 'package:acro_space_simulator/domain/megastructure/megastructure_construction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const construction = MegastructureConstruction();

  test('with nothing delivered on-site, construction makes no progress', () {
    final m = Megastructure.oNeillCylinder(id: 'm', radius: 100, length: 200);
    construction.advance(m, dt: 1e7); // no on-site material or energy
    expect(m.completedPhases, 0);
    expect(m.progress, 0.0);
  });

  test('delivered material + on-site energy advance the build', () {
    final m = Megastructure.oNeillCylinder(id: 'm', radius: 100, length: 200);
    final p = m.currentPhase!;
    // Cargo craft delivered material; an on-site reactor generated energy.
    m.deliverMaterial(p.requiredMass);
    m.deliverEnergy(p.requiredEnergy);

    construction.advance(m, dt: 1e7);
    expect(m.completedPhases, greaterThanOrEqualTo(1));
  });

  test('material delivered but no energy -> phase stalls (needs on-site power)', () {
    final m = Megastructure.oNeillCylinder(id: 'm', radius: 100, length: 200);
    m.deliverMaterial(m.currentPhase!.requiredMass);
    // No energy delivered.
    construction.advance(m, dt: 1e7);
    expect(m.completedPhases, 0);
  });

  test('the on-site buffer is consumed as it is used', () {
    final m = Megastructure.oNeillCylinder(id: 'm', radius: 100, length: 200);
    m.deliverMaterial(m.currentPhase!.requiredMass * 2);
    m.deliverEnergy(m.currentPhase!.requiredEnergy * 2);
    final massBefore = m.siteMaterial;
    construction.advance(m, dt: 1e7);
    expect(m.siteMaterial, lessThan(massBefore)); // buffer drawn down
  });
}
