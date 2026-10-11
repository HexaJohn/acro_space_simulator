// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// Platform binding for targets WITH `dart:ffi`: XInput on Windows (the
/// pointer lock's pattern: bind, or report nothing), nothing elsewhere. See
/// `gamepad.dart` for the seam.
library;

import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:ffi/ffi.dart' show calloc;

import 'gamepad.dart';

/// XINPUT_STATE: a packet number, then XINPUT_GAMEPAD.
final class _XInputState extends Struct {
  @Uint32()
  external int packet;
  @Uint16()
  external int buttons;
  @Uint8()
  external int leftTrigger;
  @Uint8()
  external int rightTrigger;
  @Int16()
  external int thumbLX;
  @Int16()
  external int thumbLY;
  @Int16()
  external int thumbRX;
  @Int16()
  external int thumbRY;
}

typedef _GetStateC = Uint32 Function(Uint32, Pointer<_XInputState>);
typedef _GetStateDart = int Function(int, Pointer<_XInputState>);

class PlatformGamepad implements Gamepad {
  PlatformGamepad() : _get = _bind();

  final _GetStateDart? _get;

  /// No pad found at the last look: try again only now and then, as XInput
  /// asks (a poll of an empty slot is costly).
  int _idleFrames = 0;

  static _GetStateDart? _bind() {
    if (!Platform.isWindows) return null;
    for (final dll in const ['xinput1_4.dll', 'xinput9_1_0.dll']) {
      try {
        return DynamicLibrary.open(dll).lookupFunction<_GetStateC, _GetStateDart>('XInputGetState');
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  @override
  GamepadState? read() {
    final get = _get;
    if (get == null) return null;
    if (_idleFrames > 0) {
      _idleFrames--;
      return null;
    }
    final p = calloc<_XInputState>();
    try {
      if (get(0, p) != 0) {
        _idleFrames = 120;
        return null;
      }
      final s = p.ref;
      double stick(int v) => (v / 32767.0).clamp(-1.0, 1.0);
      return GamepadState(
        lx: stick(s.thumbLX),
        ly: stick(s.thumbLY),
        rx: stick(s.thumbRX),
        ry: stick(s.thumbRY),
        lt: s.leftTrigger / 255.0,
        rt: s.rightTrigger / 255.0,
        buttons: s.buttons,
      );
    } finally {
      calloc.free(p);
    }
  }
}
