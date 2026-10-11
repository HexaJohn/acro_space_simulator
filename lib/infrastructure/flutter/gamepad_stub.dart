// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Platform binding for targets WITHOUT `dart:ffi` (web): no pad. See
/// `gamepad.dart` for the seam.
library;

import 'gamepad.dart';

class PlatformGamepad implements Gamepad {
  @override
  GamepadState? read() => null;
}
