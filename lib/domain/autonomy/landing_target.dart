// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A pad a vessel is being flown down to.
///
/// The colony's own shuttles have always had one — a [ShuttleRun] naming the lot
/// they are aimed at — and the tick flies them onto it with [LandingGuidance].
/// The player's craft had no equivalent: the only way to "land on a spaceport"
/// was to open the flat map and push a whole second scene that flew a scripted
/// descent. Pointing a real vessel at a real pad needs nothing more than the
/// same target the shuttles carry.
library;

import '../shared/vector3.dart';

/// The pad [vesselId]-agnostic: hung on the vessel itself, so the tick finds it
/// without a lookup table.
class LandingTarget {
  /// Body the pad is on. Guidance stops if the vessel is elsewhere — a target
  /// picked in low orbit must not steer a craft that has since changed SOI.
  final String bodyId;

  /// The pad, in BODY-FIXED metres. Body-fixed because the ground turns: an
  /// inertial point would slide off the pad as the planet rotated under it.
  final Vector3 padBF;

  /// The colony and site that own the pad, for the HUD readout.
  final String colonyId;
  final String site;

  const LandingTarget({
    required this.bodyId,
    required this.padBF,
    required this.colonyId,
    required this.site,
  });
}
