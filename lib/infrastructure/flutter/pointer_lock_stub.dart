// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Platform binding for targets WITHOUT `dart:ffi` (web): nothing to capture
/// with. See `pointer_lock.dart` for the seam.
library;

import 'pointer_lock.dart';

/// On this platform the lock is always unsupported.
class PlatformPointerLock extends UnsupportedPointerLock {
  PlatformPointerLock();
}
