import '../vessel/resource_container.dart';
import 'mining_rig.dart';

/// Binds a vessel's [MiningRig] to a deposit and a target resource. Carried by
/// the vessel aggregate so the subsystem tick knows what (if anything) the
/// vessel is mining. Value-ish entity (the rig mutates active state).
class MiningOperation {
  final MiningRig rig;
  final String depositId;
  final ResourceType targetType;

  MiningOperation({
    required this.rig,
    required this.depositId,
    required this.targetType,
  });
}
