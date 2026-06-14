import 'package:acro_space_simulator/domain/parts/part_catalog.dart';
import 'package:acro_space_simulator/domain/parts/part_def.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final catalog = PartCatalog.standard();

  test('catalog contains rocket and aircraft parts across categories', () {
    final cats = catalog.all.map((p) => p.category).toSet();
    expect(cats, contains(PartCategory.commandPod));
    expect(cats, contains(PartCategory.fuelTank));
    expect(cats, contains(PartCategory.rocketEngine));
    expect(cats, contains(PartCategory.jetEngine));
    expect(cats, contains(PartCategory.wing));
    expect(cats, contains(PartCategory.intake));
    expect(cats, contains(PartCategory.landingGear));
    expect(cats, contains(PartCategory.decoupler));
  });

  test('a known real-world-grounded rocket engine is present', () {
    final merlin = catalog.byId('merlin-1d');
    expect(merlin, isNotNull);
    expect(merlin!.category, PartCategory.rocketEngine);
    expect(merlin.rocketEngine, isNotNull);
    // Merlin 1D ~845 kN sea level.
    expect(merlin.rocketEngine!.maxThrustSeaLevel, greaterThan(700000));
  });

  test('a jet engine part carries a JetEngine definition', () {
    final jet = catalog.all.firstWhere((p) => p.category == PartCategory.jetEngine);
    expect(jet.jetEngine, isNotNull);
    expect(jet.rocketEngine, isNull);
  });

  test('a wing part carries a lifting surface', () {
    final wing = catalog.all.firstWhere((p) => p.category == PartCategory.wing);
    expect(wing.wing, isNotNull);
    expect(wing.wing!.area, greaterThan(0));
  });

  test('a fuel tank carries resource capacity', () {
    final tank = catalog.all.firstWhere((p) => p.category == PartCategory.fuelTank);
    expect(tank.resources, isNotEmpty);
  });

  test('every part has a positive dry mass and a unique id', () {
    final ids = <String>{};
    for (final p in catalog.all) {
      expect(p.dryMass, greaterThan(0), reason: '${p.id} dry mass');
      expect(ids.add(p.id), isTrue, reason: 'duplicate id ${p.id}');
    }
  });
}
