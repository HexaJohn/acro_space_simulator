// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

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
