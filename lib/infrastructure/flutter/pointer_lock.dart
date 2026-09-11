// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Pointer capture for first-person mouse look.
///
/// Flutter has no pointer-lock API on desktop, and hover deltas alone are not
/// enough: the OS cursor still travels, so looking around stops dead the
/// moment the (hidden) cursor reaches the edge of the screen. The standard
/// fix — the one every PC shooter uses under the hood — is to leave the cursor
/// where capture began and, each frame, read how far it has moved since, then
/// warp it back. The deltas are the look; the cursor never gets anywhere.
///
/// That needs two OS calls, so this is a seam: Windows binds them over FFI
/// (`pointer_lock_native.dart`), and every other platform reports itself
/// unsupported, where the view keeps its click-and-drag look. Hiding the
/// cursor is NOT done here — Flutter's own `SystemMouseCursors.none` does that
/// portably, from the widget tree.
library;

import 'pointer_lock_stub.dart'
    if (dart.library.ffi) 'pointer_lock_native.dart' as platform;

/// Captures the mouse for relative, first-person look.
abstract interface class PointerLock {
  /// The best implementation for this platform. Tests replace [create].
  factory PointerLock.platform() = platform.PlatformPointerLock;

  /// How the view gets its lock. Swapped for a fake in widget tests — a real
  /// one would move the developer's actual cursor.
  static PointerLock Function() create = PointerLock.platform;

  /// Whether this platform can capture at all. False means "keep using
  /// click-and-drag", not an error.
  bool get supported;

  /// Whether the mouse is captured right now.
  bool get captured;

  /// Start capturing: the cursor is pinned where it is now.
  void capture();

  /// Stop capturing. The cursor is left where it was pinned.
  void release();

  /// Mouse movement since the last call, in physical pixels, and the cursor
  /// warped back to its pin. (0, 0) whenever not captured.
  (double, double) takeDelta();

  /// Free anything native. The lock is unusable afterwards.
  void dispose();
}

/// A platform with nothing to capture with. The view falls back to
/// click-and-drag look.
class UnsupportedPointerLock implements PointerLock {
  const UnsupportedPointerLock();

  @override
  bool get supported => false;

  @override
  bool get captured => false;

  @override
  void capture() {}

  @override
  void release() {}

  @override
  (double, double) takeDelta() => (0, 0);

  @override
  void dispose() {}
}
