import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/lifesupport/crew.dart';
import 'package:acro_space_simulator/domain/lifesupport/life_support_service.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/domain_event.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/part.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:acro_space_simulator/domain/vessel/stage.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = LifeSupportService();

  Vessel crewed({required int crew, required double food, required double oxygen}) {
    final foodC = ResourceContainer(
        type: ResourceType.food, capacity: 1000, amount: food, unitMass: 1);
    final oxyC = ResourceContainer(
        type: ResourceType.oxygen, capacity: 1000, amount: oxygen, unitMass: 1);
    final cabin = Part(
      id: const PartId('cabin'),
      name: 'Cabin',
      dryMass: 1000,
      resources: [foodC, oxyC],
    );
    final v = Vessel(
      id: const VesselId('crewed'),
      name: 'Crewed',
      ownerId: 'p',
      state: const StateVector(position: Vector3(700000, 0, 0), velocity: Vector3.zero),
      dominantBody: const BodyId('kerbin'),
      stages: [Stage(index: 0, parts: [cabin])],
    );
    v.crew = CrewModule(
      count: crew,
      foodPerCrewPerSecond: 0.01,
      oxygenPerCrewPerSecond: 0.02,
    );
    return v;
  }

  test('crew consume food and oxygen from onboard stores over time', () {
    final v = crewed(crew: 3, food: 100, oxygen: 100);
    service.update(v, dt: 10);
    final food = v.allParts.expand((p) => p.resources).firstWhere((r) => r.type == ResourceType.food);
    final oxy = v.allParts.expand((p) => p.resources).firstWhere((r) => r.type == ResourceType.oxygen);
    // 3 crew * 0.01 * 10 = 0.3 food; 3 * 0.02 * 10 = 0.6 oxygen.
    expect(food.amount, closeTo(100 - 0.3, 1e-6));
    expect(oxy.amount, closeTo(100 - 0.6, 1e-6));
  });

  test('running out of oxygen kills the crew and raises CrewLost', () {
    final v = crewed(crew: 2, food: 100, oxygen: 0.01); // almost no oxygen
    service.update(v, dt: 100); // demand far exceeds supply
    expect(v.crew!.count, 0);
    expect(v.drainEvents().whereType<CrewLost>().isNotEmpty, isTrue);
  });

  test('an uncrewed vessel consumes nothing', () {
    final v = crewed(crew: 0, food: 100, oxygen: 100);
    v.crew = null;
    service.update(v, dt: 100);
    final food = v.allParts.expand((p) => p.resources).firstWhere((r) => r.type == ResourceType.food);
    expect(food.amount, 100);
  });

  test('crew survive as long as supplies last', () {
    final v = crewed(crew: 1, food: 1000, oxygen: 1000);
    for (var i = 0; i < 100; i++) {
      service.update(v, dt: 1);
    }
    expect(v.crew!.count, 1);
  });
}
