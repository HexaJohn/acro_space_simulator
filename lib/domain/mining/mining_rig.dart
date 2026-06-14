import '../vessel/resource_container.dart';
import 'resource_deposit.dart';

/// A drill/extractor on a landed vessel. Domain service-ish entity: given a
/// [ResourceDeposit] it sits on and a target [ResourceContainer], it transfers
/// resource over time, consuming electric charge.
class MiningRig {
  final String id;
  final double baseRate; // units/s at full concentration & power
  final double powerDraw; // electric charge units/s required

  bool active;

  MiningRig({
    required this.id,
    required this.baseRate,
    required this.powerDraw,
    this.active = false,
  });

  /// Run one tick: pull power, extract from [deposit] scaled by concentration,
  /// deposit into [target]. Returns units mined (0 if inactive / unpowered /
  /// depleted / target full).
  double mine({
    required ResourceDeposit deposit,
    required ResourceContainer target,
    required ResourceContainer powerSource,
    required double dt,
  }) {
    if (!active || deposit.isDepleted) return 0;
    if (deposit.resource != target.type) return 0;

    final powerNeeded = powerDraw * dt;
    if (powerSource.draw(powerNeeded) < powerNeeded * 0.999) return 0; // brownout

    final requested = baseRate * deposit.concentration * dt;
    final extracted = deposit.extract(requested);
    final overflow = target.fill(extracted);
    return extracted - overflow;
  }
}
