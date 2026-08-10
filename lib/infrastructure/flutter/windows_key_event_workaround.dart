// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'package:flutter/foundation.dart';

/// Silences a known Flutter-on-Windows debug assertion the app cannot avoid.
///
/// After an Alt-driven focus switch (Alt+Tab away and back), the Windows
/// embedder delivers a bare "Alt Left" key-down whose `modifiers` field is 0.
/// The framework's legacy `RawKeyboard` sync path then sanitizes
/// `_keysPressed` to empty and trips
/// `'event is! RawKeyDownEvent || _keysPressed.isNotEmpty'`
/// (raw_keyboard.dart:863) — even though this app only uses the modern
/// `KeyboardListener`/`HardwareKeyboard` API. The assert exists only in debug
/// builds (release strips it and the event flows fine), so the only effect is
/// console spam. Swallow exactly that assertion; forward everything else.
void installWindowsAltKeyAssertFilter() {
  final FlutterExceptionHandler? previous = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    final Object exception = details.exception;
    if (exception is AssertionError &&
        exception.toString().contains(
            'Attempted to send a key down event when no keys are in keysPressed')) {
      return;
    }
    previous?.call(details);
  };
}
