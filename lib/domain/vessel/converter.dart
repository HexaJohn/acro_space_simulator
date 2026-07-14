// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'resource_container.dart';

/// An in-situ resource converter (ISRU): a recipe that turns input resources
/// into output resources at a rate. Real-world grounded — like a Sabatier
/// reactor (CO2+H2 -> methane) or electrolysis (water -> H2+O2), abstracted as
/// ore/water -> fuel/oxygen. Value object carried by a vessel.
class Converter {
  final String id;
  final Map<ResourceType, double> inputsPerSecond;
  final Map<ResourceType, double> outputsPerSecond;

  /// 0..1 — how hard it's running (set by the player/automation).
  final double throttle;

  const Converter({
    required this.id,
    required this.inputsPerSecond,
    required this.outputsPerSecond,
    this.throttle = 1.0,
  });
}
