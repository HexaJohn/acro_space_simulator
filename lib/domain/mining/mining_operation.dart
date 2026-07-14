// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

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
