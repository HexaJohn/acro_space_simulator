// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Platform binding for targets WITH `dart:ffi`. Windows captures through
/// user32; macOS and Linux report unsupported, and keep click-and-drag look.
/// See `pointer_lock.dart` for the seam and why it warps.
library;

import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart' show calloc;

import 'pointer_lock.dart';

/// Win32 `POINT`: screen coordinates, physical pixels.
final class _Point extends Struct {
  @Int32()
  external int x;

  @Int32()
  external int y;
}

typedef _GetCursorPosC = Int32 Function(Pointer<_Point>);
typedef _GetCursorPosDart = int Function(Pointer<_Point>);
typedef _SetCursorPosC = Int32 Function(Int32, Int32);
typedef _SetCursorPosDart = int Function(int, int);
typedef _GetForegroundWindowC = IntPtr Function();
typedef _GetForegroundWindowDart = int Function();
typedef _GetWindowThreadProcessIdC = Uint32 Function(IntPtr, Pointer<Uint32>);
typedef _GetWindowThreadProcessIdDart = int Function(int, Pointer<Uint32>);
typedef _IsIconicC = Int32 Function(IntPtr);
typedef _IsIconicDart = int Function(int);
typedef _GetCurrentProcessIdC = Uint32 Function();
typedef _GetCurrentProcessIdDart = int Function();

/// The platform's lock: user32 on Windows, unsupported elsewhere.
///
/// A delegating wrapper rather than a factory, because the conditional import
/// in `pointer_lock.dart` names ONE class for every native target and only
/// Windows has something to bind.
class PlatformPointerLock implements PointerLock {
  PlatformPointerLock() : _impl = _open();

  final PointerLock _impl;

  static PointerLock _open() {
    if (!Platform.isWindows) return const UnsupportedPointerLock();
    try {
      return _Win32PointerLock(
        DynamicLibrary.open('user32.dll'),
        DynamicLibrary.open('kernel32.dll'),
      );
    } catch (_) {
      // No user32 (a sandboxed runner, a stripped test host): look by drag.
      return const UnsupportedPointerLock();
    }
  }

  @override
  bool get supported => _impl.supported;

  @override
  bool get captured => _impl.captured;

  @override
  void capture() => _impl.capture();

  @override
  void release() => _impl.release();

  @override
  (double, double) takeDelta() => _impl.takeDelta();

  @override
  void dispose() => _impl.dispose();
}

class _Win32PointerLock implements PointerLock {
  _Win32PointerLock(DynamicLibrary user32, DynamicLibrary kernel32)
      : _getCursorPos = user32
            .lookupFunction<_GetCursorPosC, _GetCursorPosDart>('GetCursorPos'),
        _setCursorPos = user32
            .lookupFunction<_SetCursorPosC, _SetCursorPosDart>('SetCursorPos'),
        _getForegroundWindow = user32.lookupFunction<_GetForegroundWindowC,
            _GetForegroundWindowDart>('GetForegroundWindow'),
        _getWindowThreadProcessId = user32.lookupFunction<
            _GetWindowThreadProcessIdC,
            _GetWindowThreadProcessIdDart>('GetWindowThreadProcessId'),
        _isIconic =
            user32.lookupFunction<_IsIconicC, _IsIconicDart>('IsIconic'),
        _ownPid = kernel32.lookupFunction<_GetCurrentProcessIdC,
            _GetCurrentProcessIdDart>('GetCurrentProcessId')();

  final _GetCursorPosDart _getCursorPos;
  final _SetCursorPosDart _setCursorPos;
  final _GetForegroundWindowDart _getForegroundWindow;
  final _GetWindowThreadProcessIdDart _getWindowThreadProcessId;
  final _IsIconicDart _isIconic;
  final int _ownPid;

  /// One POINT and one pid slot for the life of the lock: both are read every
  /// frame, so allocating per call would be a malloc a frame for a few bytes.
  Pointer<_Point>? _pt = calloc<_Point>();
  Pointer<Uint32>? _pid = calloc<Uint32>();

  int _pinX = 0, _pinY = 0;
  bool _captured = false;

  @override
  bool get supported => true;

  @override
  bool get captured => _captured;

  /// Whether the window in front is one of OURS, and not minimised.
  ///
  /// The guard that makes warping safe. A capture only ever releases on a
  /// lifecycle CHANGE, and a window that never had focus — launched
  /// minimised, captured by a driver, or behind whatever the player alt-tabbed
  /// to before the change arrived — sees none: measured live, a minimised
  /// build sat captured, and every frame it ran would have pinned the cursor
  /// of whatever the player was actually using. Asked before every warp, so
  /// the lock can only ever hold the cursor inside the window the player is
  /// looking at.
  bool _weAreInFront() {
    final pid = _pid;
    if (pid == null) return false;
    final hwnd = _getForegroundWindow();
    if (hwnd == 0 || _isIconic(hwnd) != 0) return false;
    pid.value = 0;
    _getWindowThreadProcessId(hwnd, pid);
    return pid.value == _ownPid;
  }

  @override
  void capture() {
    final pt = _pt;
    if (pt == null) return;
    // Never capture for a window the player is not in front of.
    if (!_weAreInFront()) return;
    // Pinned where the cursor already is: warping it somewhere new on
    // capture would be a jump the player sees in the first frame.
    if (_getCursorPos(pt) == 0) return;
    _pinX = pt.ref.x;
    _pinY = pt.ref.y;
    _captured = true;
  }

  @override
  void release() => _captured = false;

  @override
  (double, double) takeDelta() {
    final pt = _pt;
    if (!_captured || pt == null) return (0, 0);
    // Focus went elsewhere between frames: let go, and do NOT warp — the
    // cursor now belongs to whatever window the player moved to.
    if (!_weAreInFront()) {
      _captured = false;
      return (0, 0);
    }
    if (_getCursorPos(pt) == 0) return (0, 0);
    final dx = pt.ref.x - _pinX, dy = pt.ref.y - _pinY;
    if (dx == 0 && dy == 0) return (0, 0);
    // Back to the pin, so the next frame measures from a cursor that has
    // not moved — and so it can never reach an edge and stop the look.
    _setCursorPos(_pinX, _pinY);
    return (dx.toDouble(), dy.toDouble());
  }

  @override
  void dispose() {
    _captured = false;
    final pt = _pt, pid = _pid;
    _pt = null;
    _pid = null;
    if (pt != null) calloc.free(pt);
    if (pid != null) calloc.free(pid);
  }
}
