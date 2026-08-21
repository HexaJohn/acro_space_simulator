// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The flutter_gpu HostBuffer patch is still applied to the running SDK.
///
/// `HostBuffer._allocateEmplacement` rolls to a new device-buffer block only
/// when the offset cursor is already PAST the block end — it never checks that
/// the incoming write FITS the remainder. Any emplacement straddling the
/// 1,024,000-byte boundary is written past it, `overwrite()` fails, and the
/// exception takes the whole SceneView frame down with it (a black render).
///
/// The patch lives in the SDK's engine cache, not in this repo, so it is wiped
/// by `flutter precache`, a cache rebuild, or an SDK re-pin — and nothing says
/// so. It has already been lost once that way. This test is the alarm: without
/// it the first symptom is a black viewport in the running app, which is a long
/// way from the cause.
///
/// See tool/patches/flutter_gpu_hostbuffer_straddle.md for the patch itself.
void main() {
  test('flutter_gpu HostBuffer straddle patch is applied', () {
    // The test runner's dart lives somewhere under <flutter>/bin/cache, but
    // how deep varies by SDK layout, so walk up looking for the package rather
    // than counting directories.
    File? buffer;
    for (var dir = File(Platform.resolvedExecutable).parent;
        dir.path != dir.parent.path;
        dir = dir.parent) {
      final candidate =
          File('${dir.path}/pkg/flutter_gpu/lib/src/buffer.dart');
      if (candidate.existsSync()) {
        buffer = candidate;
        break;
      }
    }
    if (buffer == null) {
      markTestSkipped('flutter_gpu not found under ${Platform.resolvedExecutable}');
      return;
    }
    final src = buffer.readAsStringSync();
    expect(src, contains('_allocateEmplacement'),
        reason: 'found the wrong file');

    expect(
      src,
      contains('_offsetCursor + padding + bytes.lengthInBytes'),
      reason: 'flutter_gpu HostBuffer straddle patch is MISSING from\n'
          '  ${buffer.path}\n'
          'Re-apply it from tool/patches/flutter_gpu_hostbuffer_straddle.md. '
          'Without it, any per-frame uniform write that straddles a 1,024,000 '
          'byte block boundary throws and blanks the SceneView frame.',
    );
  });
}
