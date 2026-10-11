// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Platform binding for targets WITHOUT `dart:isolate` (the web): samples run
/// inline. See `ground_sample_pool.dart` for the seam.
library;

import 'ground_sample_pool.dart';

class PlatformGroundSamplePool extends SyncGroundSamplePool {}
