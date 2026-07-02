# flutter_gpu HostBuffer block-straddle patch (REQUIRED for the 3D backend)

`HostBuffer._allocateEmplacement` in flutter_gpu only rolls to a new
device-buffer block when the offset cursor is already **past** the block
end — it never checks whether the incoming write **fits** the remainder.
Any emplacement that straddles the 1,024,000-byte block boundary fails its
`overwrite()` and throws:

    Exception: Failed to write range (offset=..., length=...) to
    HostBuffer-managed DeviceBuffer

which aborts the whole SceneView render for that frame (full-frame black).
With the ring asteroid fields emplacing ~1.5 MB of instance data per frame
(mesh rock transforms + billboard batch), some write straddles the boundary
on most frames near Saturn's rings.

## The patch

File (inside the pinned FVM SDK, engine cache artifact — re-apply after
`flutter precache`/cache rebuilds or an SDK re-pin):

    <fvm>/versions/84af28a0646eb00c06b5556be0d28e5e32cdf1c7/bin/cache/pkg/flutter_gpu/lib/src/buffer.dart

In `_allocateEmplacement`, change the rollover condition (and give the
fresh-block view the write's true length):

```dart
// BEFORE
if (_offsetCursor + padding >= blockLengthInBytes) {
  ...
  return BufferView(buffer, offsetInBytes: 0, lengthInBytes: blockLengthInBytes);
}

// AFTER
if (_offsetCursor + padding + bytes.lengthInBytes > blockLengthInBytes) {
  ...
  return BufferView(buffer, offsetInBytes: 0, lengthInBytes: bytes.lengthInBytes);
}
```

Verified 2026-07-02: 203 straddle exceptions per test run before, zero
after, with ~11k mesh rock instances + 8k billboards live.

Upstream: worth filing against flutter/flutter (flutter_gpu). App-side
mitigations kept regardless: mesh instances hard-capped at 14,000
(`_maxMeshInstances`) and the billboard batch at 8,000 (`_farCapacity`) so
single writes stay well under one block.
