import 'package:acro_space_simulator/domain/autonomy/cargo_transfer_service.dart';
import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/megastructure/megastructure.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/part.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:acro_space_simulator/domain/vessel/stage.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const transfer = CargoTransferService();

  Vessel freighter(double ore) {
    final hold = ResourceContainer(
        type: ResourceType.ore, capacity: 1e6, amount: ore, unitMass: 1);
    return Vessel(
      id: const VesselId('f'),
      name: 'Freighter',
      ownerId: 'p',
      state: const StateVector(position: Vector3(1e7, 0, 0), velocity: Vector3.zero),
      dominantBody: const BodyId('earth'),
      stages: [
        Stage(index: 0, parts: [
          Part(id: const PartId('hold'), name: 'hold', dryMass: 500, resources: [hold]),
        ]),
      ],
    );
  }

  test('a cargo craft delivers its ore to a megastructure build site', () {
    final mega = Megastructure.haloRing(id: 'h', radius: 1e5);
    final f = freighter(1000);
    final kg = transfer.deliverToSite(f, mega, massPerUnit: 1000);

    expect(kg, 1000 * 1000); // 1000 units * 1000 kg/unit
    expect(mega.siteMaterial, kg);
    // The craft's hold is now empty.
    expect(f.allParts.expand((p) => p.resources).first.amount, 0);
  });

  test('an empty craft delivers nothing', () {
    final mega = Megastructure.haloRing(id: 'h', radius: 1e5);
    final f = freighter(0);
    expect(transfer.deliverToSite(f, mega), 0);
    expect(mega.siteMaterial, 0);
  });
}
