// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Whether a vessel is over the battle (docs/plans/combat.md §7E; ref
/// §10A.12): pure geometry on two body-centred inertial points.
///
/// At or above a positive elevation a sphere cannot occlude the line, so no
/// occlusion test is needed; terrain is negligible from 10° up.
library;

import '../../shared/vector3.dart';

/// sin 30°: a strike needs the vessel at least 30° above the horizon.
const double kStrikeElevationSin = 0.5;

/// sin 10°: recon sees from 10° up.
const double kReconElevationSin = 0.1736;

/// The longest slant a strike is fired across, m.
const double kStrikeMaxSlantM = 2.5e6;

class Overhead {
  const Overhead({this.strike = false, this.recon = false, this.slantM = 0});

  /// Up 30° or more, and within the strike range.
  final bool strike;

  /// Up 10° or more.
  final bool recon;

  /// Straight-line distance from the battle, m.
  final double slantM;

  static const Overhead none = Overhead();
}

/// [vessel] seen from the ground point [ground], both body-centred inertial.
Overhead overheadOf(Vector3 vessel, Vector3 ground) {
  final d = vessel - ground;
  final dl = d.length;
  final gl = ground.length;
  if (dl <= 0 || gl <= 0) return Overhead.none;
  final up = d.dot(ground) / gl; // |d|·sin(elevation)
  return Overhead(
    strike: up >= kStrikeElevationSin * dl && dl <= kStrikeMaxSlantM,
    recon: up >= kReconElevationSin * dl,
    slantM: dl,
  );
}
