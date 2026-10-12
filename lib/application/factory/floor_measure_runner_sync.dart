// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Platform binding for targets WITHOUT `dart:isolate` (the web): floors are
/// measured inline. See `floor_measure_runner.dart` for the seam.
library;

import 'floor_measure_runner.dart';

class PlatformFloorMeasureRunner extends SyncFloorMeasureRunner {
  PlatformFloorMeasureRunner(super.build, {super.setup});
}
