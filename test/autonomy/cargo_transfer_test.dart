import 'package:acro_space_simulator/domain/autonomy/cargo_transfer_service.dart';
import 'package:acro_space_simulator/domain/colony/colony.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/part.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:acro_space_simulator/domain/vessel/stage.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const service = CargoTransferService();

  Vessel freighter({required double cargo}) {
    final hold = ResourceContainer(
      type: ResourceType.water,
      capacity: 500,
      amount: cargo,
      unitMass: 1,
    );
    return Vessel(
      id: const VesselId('freighter'),
      name: 'Freighter',
      ownerId: 'ai',
      state: const StateVector(position: Vector3(6.371e6, 0, 0), velocity: Vector3.zero),
      dominantBody: const BodyId('earth'),
      stages: [
        Stage(index: 0, parts: [
          Part(id: const PartId('hold'), name: 'hold', dryMass: 500, resources: [hold]),
        ]),
      ],
      landed: true,
    );
  }

  Colony colony({double waterAmount = 0, double waterCapacity = 1000}) => Colony(
        id: 'base',
        name: 'Base',
        body: const BodyId('earth'),
        latitude: 0,
        longitude: 0,
        stockpile: {
          ResourceType.water: ResourceContainer(
            type: ResourceType.water,
            capacity: waterCapacity,
            amount: waterAmount,
            unitMass: 1,
          ),
        },
      );

  test('unloads vessel cargo into the colony stockpile', () {
    final v = freighter(cargo: 300);
    final c = colony();
    final moved = service.unload(v, c, ResourceType.water);

    expect(moved, closeTo(300, 1e-9));
    expect(c.stockpile[ResourceType.water]!.amount, closeTo(300, 1e-9));
    // Vessel hold is now empty.
    final hold = v.allParts.expand((p) => p.resources).first;
    expect(hold.amount, closeTo(0, 1e-9));
  });

  test('respects colony storage capacity (overflow stays aboard)', () {
    final v = freighter(cargo: 400);
    final c = colony(waterAmount: 800, waterCapacity: 1000); // only 200 room
    final moved = service.unload(v, c, ResourceType.water);

    expect(moved, closeTo(200, 1e-6));
    expect(c.stockpile[ResourceType.water]!.amount, closeTo(1000, 1e-6));
    final hold = v.allParts.expand((p) => p.resources).first;
    expect(hold.amount, closeTo(200, 1e-6)); // 200 left aboard
  });

  test('no matching stockpile slot -> nothing transferred', () {
    final v = freighter(cargo: 100);
    final c = Colony(
      id: 'b',
      name: 'b',
      body: const BodyId('earth'),
      latitude: 0,
      longitude: 0,
      stockpile: {}, // no water slot
    );
    expect(service.unload(v, c, ResourceType.water), 0);
  });
}
