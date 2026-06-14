import 'package:acro_space_simulator/domain/dynamics/state_vector.dart';
import 'package:acro_space_simulator/domain/mining/mining_operation.dart';
import 'package:acro_space_simulator/domain/mining/mining_rig.dart';
import 'package:acro_space_simulator/domain/mining/resource_deposit.dart';
import 'package:acro_space_simulator/domain/shared/vector3.dart';
import 'package:acro_space_simulator/domain/simulation/domain_event.dart';
import 'package:acro_space_simulator/domain/subsystems/vessel_mining_updater.dart';
import 'package:acro_space_simulator/domain/universe/celestial_body.dart';
import 'package:acro_space_simulator/domain/vessel/part.dart';
import 'package:acro_space_simulator/domain/vessel/resource_container.dart';
import 'package:acro_space_simulator/domain/vessel/stage.dart';
import 'package:acro_space_simulator/domain/vessel/vessel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const updater = VesselMiningUpdater();

  ({Vessel vessel, ResourceContainer ore, ResourceContainer power, ResourceDeposit deposit})
      setup({required bool landed, required bool rigActive}) {
    final ore = ResourceContainer(
        type: ResourceType.ore, capacity: 100, amount: 0, unitMass: 1);
    final power = ResourceContainer(
        type: ResourceType.electricCharge, capacity: 1000, amount: 1000, unitMass: 0);
    final drill = Part(
      id: const PartId('drill'),
      name: 'Drill',
      dryMass: 500,
      resources: [ore, power],
    );
    final deposit = ResourceDeposit(
      id: 'ore-field',
      body: const BodyId('kerbin'),
      latitude: 0,
      longitude: 0,
      resource: ResourceType.ore,
      concentration: 0.8,
      reserves: 1000,
    );
    final vessel = Vessel(
      id: const VesselId('miner'),
      name: 'Miner',
      ownerId: 'p',
      state: const StateVector(position: Vector3(600000, 0, 0), velocity: Vector3.zero),
      dominantBody: const BodyId('kerbin'),
      stages: [Stage(index: 0, parts: [drill])],
      landed: landed,
    );
    vessel.mining = MiningOperation(
      rig: MiningRig(id: 'rig', baseRate: 10, powerDraw: 5, active: rigActive),
      depositId: 'ore-field',
      targetType: ResourceType.ore,
    );
    return (vessel: vessel, ore: ore, power: power, deposit: deposit);
  }

  test('landed active rig extracts ore into the container and draws power', () {
    final s = setup(landed: true, rigActive: true);
    updater.update(s.vessel, deposit: s.deposit, dt: 1.0);

    expect(s.ore.amount, greaterThan(0));
    expect(s.power.amount, lessThan(1000));
    expect(s.deposit.reserves, lessThan(1000));
    expect(s.vessel.drainEvents().whereType<ResourceMined>().isNotEmpty, isTrue);
  });

  test('rig does nothing when not landed', () {
    final s = setup(landed: false, rigActive: true);
    updater.update(s.vessel, deposit: s.deposit, dt: 1.0);
    expect(s.ore.amount, 0);
  });

  test('rig does nothing when inactive', () {
    final s = setup(landed: true, rigActive: false);
    updater.update(s.vessel, deposit: s.deposit, dt: 1.0);
    expect(s.ore.amount, 0);
  });
}
