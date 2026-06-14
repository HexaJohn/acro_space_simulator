import '../mining/resource_deposit.dart';
import '../simulation/domain_event.dart';
import '../vessel/resource_container.dart';
import '../vessel/vessel.dart';

/// Subsystem updater: runs a landed vessel's [MiningOperation] for one tick,
/// pulling resource from the [ResourceDeposit] into the vessel's matching
/// container while drawing electric charge. Raises [ResourceMined] when ore is
/// produced. Domain service.
///
/// Invariants enforced (via the rig/container/deposit): no mining unless
/// landed + active, no negative reserves, power gates throughput.
class VesselMiningUpdater {
  const VesselMiningUpdater();

  void update(
    Vessel vessel, {
    required ResourceDeposit deposit,
    required double dt,
  }) {
    final op = vessel.mining;
    if (op == null || !vessel.landed || !op.rig.active) return;
    if (op.depositId != deposit.id) return;

    final target = _findContainer(vessel, op.targetType);
    final power = _findContainer(vessel, ResourceType.electricCharge);
    if (target == null || power == null) return;

    final mined = op.rig.mine(
      deposit: deposit,
      target: target,
      powerSource: power,
      dt: dt,
    );
    if (mined > 0) {
      vessel.raise(ResourceMined(vessel.id, deposit.id, mined));
    }
  }

  ResourceContainer? _findContainer(Vessel vessel, ResourceType type) {
    for (final p in vessel.allParts) {
      for (final r in p.resources) {
        if (r.type == type) return r;
      }
    }
    return null;
  }
}
