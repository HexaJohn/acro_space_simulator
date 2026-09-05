# flutter_gpu HostBuffer alignment-cache + block-reuse patch (REQUIRED for the 3D backend)

Two per-frame costs in flutter_gpu's `HostBuffer` bump allocator, both
in the same file as the [block-straddle patch](flutter_gpu_hostbuffer_straddle.md)
and applied on top of it:

1. **Alignment re-read on every emplace.** `_allocateEmplacement` reads
   `_gpuContext.minimumUniformByteAlignment` — a native getter, one FFI
   round-trip each — up to three times per call to compute the padding.
   The value is fixed for the lifetime of the context. The city studio
   (127k buildings, orbit camera) makes thousands of emplacements per
   frame, so this alone is on the order of 20k FFI calls per frame on the
   UI thread, which is the thread the whole frame budget lives on.

2. **A fresh block allocated on every overflow.** When a write does not fit
   the current block, the stock code allocates a brand-new 1,024,000-byte
   `DeviceBuffer` and appends it to the current frame's block list.
   `reset()` only rewinds `_bufferCursor`/`_offsetCursor` and never trims
   the list, so a frame that emplaces more than one block's worth (the
   instance buffer alone is ~0.8 MB per pass today) grows its list by a new
   device buffer *every frame* and never reuses the blocks it already
   holds — an unbounded GPU-memory leak plus an allocation stall per frame.

## The patch

File (inside the pinned FVM SDK, engine cache artifact — re-apply after
`flutter precache`/cache rebuilds or an SDK re-pin):

    <fvm>/versions/84af28a0646eb00c06b5556be0d28e5e32cdf1c7/bin/cache/pkg/flutter_gpu/lib/src/buffer.dart

Verify the straddle patch is present first (`grep 'padding + bytes.lengthInBytes'`);
if it is not, apply that doc's diff before this one.

### 1. Cache the alignment once

Add a field after `_gpuContext` and initialise it in the constructor's
initializer list:

```dart
  final GpuContext _gpuContext;

  // PATCHED (acro_space_simulator): the uniform alignment is fixed for the
  // lifetime of the context, yet the stock emplace() path read the native
  // getter up to three times per call. At thousands of emplacements a frame
  // that was ~20k FFI round-trips of pure overhead, so it is read once here
  // and kept.
  final int _uniformAlignment;
```

```dart
// BEFORE
  HostBuffer._initialize(
    this._gpuContext, {
    this.blockLengthInBytes = HostBuffer.kDefaultBlockLengthInBytes,
  }) {

// AFTER
  HostBuffer._initialize(
    this._gpuContext, {
    this.blockLengthInBytes = HostBuffer.kDefaultBlockLengthInBytes,
  }) : _uniformAlignment = _gpuContext.minimumUniformByteAlignment {
```

Then in `_allocateEmplacement` use the cached value for the padding:

```dart
// BEFORE
    int padding =
        _gpuContext.minimumUniformByteAlignment -
        (_offsetCursor % _gpuContext.minimumUniformByteAlignment);
    // If the padding is the full alignment size, then we're already aligned.
    // So reset the padding to zero.
    padding %= _gpuContext.minimumUniformByteAlignment;

// AFTER
    int padding = _uniformAlignment - (_offsetCursor % _uniformAlignment);
    // If the padding is the full alignment size, then we're already aligned.
    // So reset the padding to zero.
    padding %= _uniformAlignment;
```

### 2. Reuse the frame's existing blocks on overflow

Inside the (already straddle-patched) rollover branch, replace the
unconditional allocation with a step to the next block the frame already
holds, allocating only when the list is exhausted:

```dart
// BEFORE
    if (_offsetCursor + padding + bytes.lengthInBytes > blockLengthInBytes) {
      DeviceBuffer buffer = _allocateNewBlock(blockLengthInBytes);
      _buffers[_frameCursor].add(buffer);
      _bufferCursor++;
      _offsetCursor = bytes.lengthInBytes;

// AFTER
    if (_offsetCursor + padding + bytes.lengthInBytes > blockLengthInBytes) {
      // PATCHED (acro_space_simulator): reset() only rewinds the cursors, so
      // a frame keeps every block it ever grew into. The stock code ignored
      // those and appended a fresh block on every overflow, so a frame that
      // emplaces more than one block's worth leaked a new device buffer
      // every frame. Step to the next block this frame already holds; only
      // allocate when the list runs out.
      final List<DeviceBuffer> frame = _buffers[_frameCursor];
      _bufferCursor++;
      if (_bufferCursor >= frame.length) {
        frame.add(_allocateNewBlock(blockLengthInBytes));
      }
      final DeviceBuffer buffer = frame[_bufferCursor];
      _offsetCursor = bytes.lengthInBytes;
```

The rest of the branch (the `BufferView(buffer, offsetInBytes: 0,
lengthInBytes: bytes.lengthInBytes)` return) is unchanged. Every block in
a frame list is exactly `blockLengthInBytes` long — oversized emplacements
get a private buffer that is never added to the list — so a reused block
always has room for a write that passed the size check above.

No public API changes: `emplace`, `reset`, `blockLengthInBytes`,
`frameCount` and the `BufferView` contract are identical. The steady state
after the first few frames is that each of the four frame lists holds as
many blocks as its heaviest frame needed, and no further device buffers
are created.

## Guard test

`test/tools/flutter_gpu_patch_guard_test.dart` locates the pinned SDK's
`buffer.dart` (walking up from the test VM executable, with `FLUTTER_ROOT`
and the `.fvmrc` pin under `~/fvm/versions` as fallbacks) and asserts, by
plain string presence, that both this patch and the straddle patch are in
the file — the cached `_uniformAlignment` field and initializer, the
padding lines that use it, exactly one read of the native
`minimumUniformByteAlignment` getter, the `frame.length` check on the
overflow path, and the *absence* of the stock lines each patch replaced.
A restored cache fails the test with the doc to re-apply named in the
reason, instead of regressing silently at runtime:

    fvm flutter test test/tools/flutter_gpu_patch_guard_test.dart

Upstream: worth filing against flutter/flutter (flutter_gpu) alongside the
straddle fix.
