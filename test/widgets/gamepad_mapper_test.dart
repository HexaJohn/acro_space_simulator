// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:acro_space_simulator/infrastructure/flutter/gamepad.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pad's mapping, driven by stub states: combat.md §7K.
void main() {
  test('sticks rest inside the dead zone, scale past it; the trigger fires', () {
    final m = GamepadMapper();
    expect(m.map(const GamepadState(lx: 0.2, ly: -0.1), 1 / 60).moveRight, 0);
    final f = m.map(const GamepadState(ly: 1, rx: 1, rt: 0.9), 1 / 60);
    expect(f.moveForward, closeTo(1, 1e-9));
    expect(f.lookYaw, closeTo(GamepadMapper.lookRadPerS / 60, 1e-9));
    expect(f.fire, isTrue);
  });

  test('a button counts once, on the frame it goes down', () {
    final m = GamepadMapper();
    expect(m.map(const GamepadState(buttons: PadButton.x), 0.016).tapped(PadButton.x), isTrue);
    expect(m.map(const GamepadState(buttons: PadButton.x), 0.016).tapped(PadButton.x), isFalse);
    expect(m.map(GamepadState.idle, 0.016).pressed, isEmpty);
    expect(m.map(const GamepadState(buttons: PadButton.x | PadButton.a), 0.016).pressed,
        containsAll([PadButton.x, PadButton.a]));
  });
}
