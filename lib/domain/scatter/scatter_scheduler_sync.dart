// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Platform binding for targets WITHOUT `dart:isolate` (web): generation runs
/// inline. See `scatter_scheduler.dart` for the seam.
library;

import 'scatter_scheduler.dart';

/// On this platform the sync scheduler IS the platform scheduler.
class PlatformScatterScheduler extends SyncScatterScheduler {}
