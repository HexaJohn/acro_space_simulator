// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Platform binding for targets WITHOUT `dart:isolate` (the web): meshing
/// runs inline on the calling thread, a budgeted step at a time. See
/// `city_tile_scheduler.dart` for the seam.
library;

import 'city_tile_scheduler.dart';

/// On this platform the best available scheduler is the inline one.
class PlatformCityTileScheduler extends SyncCityTileScheduler {}
