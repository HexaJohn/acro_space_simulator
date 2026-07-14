// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International License.
// To view a copy of this license, visit http://creativecommons.org/licenses/by-nc-sa/4.0/ or send a letter to
// Creative Commons, PO Box 1866, Mountain View, CA 94042, USA.

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
