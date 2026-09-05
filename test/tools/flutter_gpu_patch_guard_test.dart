// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Guards the hand-applied patches to flutter_gpu's HostBuffer, which live in
// the pinned SDK's engine cache rather than in this repo:
//
//   <sdk>/bin/cache/pkg/flutter_gpu/lib/src/buffer.dart
//
// A `flutter precache`, a cache rebuild, or an SDK re-pin silently restores the
// stock file and the app regresses (black frames near the rings, a fresh 1 MB
// device buffer leaked every frame in the city studio) with no compile error
// to point at the cause. This test reads the SDK file and asserts the patch
// text is present so the loss surfaces in the test run instead. Each patch is
// documented, with its diff and re-apply steps, in tool/patches/:
//
//   flutter_gpu_hostbuffer_straddle.md
//   flutter_gpu_hostbuffer_alignment_reuse.md
//
// Pure string checks — no GPU context is needed, so this runs anywhere the
// pinned SDK is installed.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _relativeSdkPath = 'bin/cache/pkg/flutter_gpu/lib/src/buffer.dart';

/// Locates the pinned SDK's buffer.dart. The test VM is the SDK's own
/// flutter_tester, so walking up from the executable finds the SDK root
/// without any environment setup; FLUTTER_ROOT and the FVM pin in .fvmrc are
/// fallbacks for other launchers.
File _locateSdkBufferDart() {
  final candidates = <String>[];

  Directory? dir = File(Platform.resolvedExecutable).parent;
  while (dir != null) {
    candidates.add('${dir.path}/$_relativeSdkPath');
    final parent = dir.parent;
    dir = parent.path == dir.path ? null : parent;
  }

  final root = Platform.environment['FLUTTER_ROOT'];
  if (root != null && root.isNotEmpty) candidates.add('$root/$_relativeSdkPath');

  final fvmrc = File('.fvmrc');
  if (fvmrc.existsSync()) {
    final pin = RegExp(r'"flutter"\s*:\s*"([^"]+)"')
        .firstMatch(fvmrc.readAsStringSync())
        ?.group(1);
    final fvmHome = Platform.environment['FVM_HOME'] ??
        '${Platform.environment['USERPROFILE'] ?? Platform.environment['HOME']}/fvm';
    if (pin != null) candidates.add('$fvmHome/versions/$pin/$_relativeSdkPath');
  }

  for (final path in candidates) {
    final f = File(path);
    if (f.existsSync()) return f;
  }
  fail('Could not locate the pinned SDK buffer.dart. Tried:\n'
      '${candidates.join('\n')}');
}

void main() {
  late final String source;

  setUpAll(() {
    source = _locateSdkBufferDart().readAsStringSync();
  });

  test('block-straddle patch is present (tool/patches/flutter_gpu_hostbuffer_straddle.md)',
      () {
    // The rollover must test whether the WRITE fits, not merely whether the
    // cursor is already past the end.
    expect(source,
        contains('if (_offsetCursor + padding + bytes.lengthInBytes > blockLengthInBytes) {'),
        reason: 'straddle rollover condition missing — re-apply per the doc');
    // The stock condition must be gone, or the fix has been overwritten.
    expect(source,
        isNot(contains('if (_offsetCursor + padding >= blockLengthInBytes) {')),
        reason: 'stock rollover condition found — SDK cache was restored');
  });

  test('alignment cache + block reuse patch is present '
      '(tool/patches/flutter_gpu_hostbuffer_alignment_reuse.md)', () {
    // The alignment is read from the native getter exactly once, in the
    // constructor initializer, and every padding computation uses the cache.
    expect(source, contains('final int _uniformAlignment;'),
        reason: 'cached alignment field missing');
    expect(source,
        contains('}) : _uniformAlignment = _gpuContext.minimumUniformByteAlignment {'),
        reason: 'alignment must be cached in the constructor initializer');
    expect(source,
        contains('int padding = _uniformAlignment - (_offsetCursor % _uniformAlignment);'),
        reason: 'padding must use the cached alignment');
    expect(source, contains('padding %= _uniformAlignment;'),
        reason: 'padding wrap must use the cached alignment');
    // Only the constructor may touch the native getter.
    expect('minimumUniformByteAlignment'.allMatches(source).length,
        equals(1 + _docMentions(source)),
        reason: 'the native alignment getter must be read exactly once, '
            'in the HostBuffer constructor');

    // On overflow the frame's existing blocks are reused before allocating.
    expect(source, contains('final List<DeviceBuffer> frame = _buffers[_frameCursor];'),
        reason: 'overflow path must look at the frame\'s existing block list');
    expect(source, contains('if (_bufferCursor >= frame.length) {'),
        reason: 'overflow path must only allocate once the block list is exhausted');
    expect(source, contains('frame.add(_allocateNewBlock(blockLengthInBytes));'),
        reason: 'overflow allocation must append to the frame list');
    expect(source, contains('final DeviceBuffer buffer = frame[_bufferCursor];'),
        reason: 'overflow path must hand back the block at the cursor');
    // The stock unconditional allocate-on-overflow must be gone.
    expect(source,
        isNot(contains('DeviceBuffer buffer = _allocateNewBlock(blockLengthInBytes);')),
        reason: 'stock allocate-on-every-overflow found — SDK cache was restored');
  });
}

/// The stock file's doc comment on [HostBuffer] cites
/// `[GpuContext.minimumUniformByteAlignment]`; that mention is prose, not a
/// native read, so it is subtracted from the read count.
int _docMentions(String source) =>
    '[GpuContext.minimumUniformByteAlignment]'.allMatches(source).length;
