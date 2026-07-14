// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../vessel/vessel.dart';

/// Binds a chaser vessel to a docking target. Carried by the vessel aggregate
/// so the docking updater knows which target to close on and which ports to
/// latch. The [DockingSolver] computes guidance from the relative state each
/// tick; this just records intent + which ports.
class DockingApproach {
  final VesselId target;
  final String chaserPortId;
  final String targetPortId;

  /// Set true once latched, so the updater stops issuing guidance.
  bool docked;

  DockingApproach({
    required this.target,
    required this.chaserPortId,
    required this.targetPortId,
    this.docked = false,
  });
}
