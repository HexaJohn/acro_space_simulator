// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import '../../domain/scatter/prop_catalog.dart';
import '../../domain/scatter/prop_model.dart';

/// Programmatic control of the live [ScatterLabScreen], for the dev harness.
///
/// Same shape and purpose as [SimViewControl]: the screen registers its
/// setters on mount, and `main_scatter_dev.dart` exposes them over the VM
/// service. Checking a change across twelve species and four detail levels is
/// forty-eight states; driving them from a script and diffing the captures is
/// the difference between verifying that and spot-checking one.
class ScatterLabControl {
  ScatterLabControl._();

  static final ScatterLabControl instance = ScatterLabControl._();

  /// Set by the live screen while mounted; null when no lab is on screen.
  void Function({
    PropKind? kind,
    int? seed,
    int? gridSide,
    PropLod? lod,
    bool? autoLod,
    bool? varySeeds,
    double? azimuth,
    double? elevation,
    double? distanceM,
    double? sunAzimuth,
    bool? frame,
  })? apply;

  /// Current state, for assertions and for reading back what a capture shows.
  Map<String, Object?> Function()? status;
}
