// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

/// A gamepad for the battle (docs/plans/combat.md §7K, phase G1): an
/// Xbox-style pad on Windows through XInput, nothing elsewhere. Keyboard and
/// mouse stay primary; the pad only adds.
///
/// [Gamepad.platform] reads the device; [GamepadMapper] turns raw states into
/// what the battle does with them — pure, so a stub state drives it headless.
library;

import 'gamepad_stub.dart' if (dart.library.ffi) 'gamepad_native.dart' as platform;

/// One read of a pad: sticks −1..1 (up is +y), triggers 0..1, buttons by
/// XInput's bit mask.
class GamepadState {
  const GamepadState({
    this.lx = 0,
    this.ly = 0,
    this.rx = 0,
    this.ry = 0,
    this.lt = 0,
    this.rt = 0,
    this.buttons = 0,
  });
  final double lx, ly, rx, ry, lt, rt;
  final int buttons;

  bool down(int mask) => buttons & mask != 0;

  static const GamepadState idle = GamepadState();
}

/// XInput's button bits.
abstract final class PadButton {
  static const int dpadUp = 0x0001;
  static const int dpadDown = 0x0002;
  static const int dpadLeft = 0x0004;
  static const int dpadRight = 0x0008;
  static const int start = 0x0010;
  static const int back = 0x0020;
  static const int a = 0x1000;
  static const int b = 0x2000;
  static const int x = 0x4000;
  static const int y = 0x8000;
}

abstract interface class Gamepad {
  factory Gamepad.platform() = platform.PlatformGamepad;

  /// The first connected pad's state, or null with none.
  GamepadState? read();
}

/// What a frame of pad input asks of the battle.
class PadFrame {
  const PadFrame({
    this.moveForward = 0,
    this.moveRight = 0,
    this.lookYaw = 0,
    this.lookPitch = 0,
    this.fire = false,
    this.pressed = const [],
  });

  /// −1..1, after the dead zone.
  final double moveForward, moveRight;

  /// Radians this frame.
  final double lookYaw, lookPitch;
  final bool fire;

  /// Buttons that went down this frame (masks).
  final List<int> pressed;

  bool tapped(int mask) => pressed.contains(mask);
}

/// Raw states to a [PadFrame]: dead zones, look speed, button edges.
class GamepadMapper {
  /// Stick travel below this reads as rest.
  static const double deadZone = 0.24;

  /// Full right stick turns this fast, rad/s.
  static const double lookRadPerS = 2.6;

  int _last = 0;

  static double _dz(double v) {
    final a = v.abs();
    if (a < deadZone) return 0;
    return v.sign * (a - deadZone) / (1 - deadZone);
  }

  PadFrame map(GamepadState s, double dt) {
    final edges = <int>[];
    for (final mask in const [
      PadButton.dpadUp,
      PadButton.dpadDown,
      PadButton.dpadLeft,
      PadButton.dpadRight,
      PadButton.start,
      PadButton.back,
      PadButton.a,
      PadButton.b,
      PadButton.x,
      PadButton.y,
    ]) {
      if (s.buttons & mask != 0 && _last & mask == 0) edges.add(mask);
    }
    _last = s.buttons;
    return PadFrame(
      moveForward: _dz(s.ly),
      moveRight: _dz(s.lx),
      lookYaw: _dz(s.rx) * lookRadPerS * dt,
      lookPitch: -_dz(s.ry) * lookRadPerS * dt,
      fire: s.rt > 0.5,
      pressed: edges,
    );
  }
}
