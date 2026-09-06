// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// The city's device buffers, reused instead of dropped.
//
// Every geometry chunk a replaced tile lets go of is a flutter_gpu
// DeviceBuffer, and a DeviceBuffer has a native finalizer: the collector
// runs it inside the next old-generation pass, at ~100 µs each, in the
// stop-the-world part of the pass (ProcessWeakHandles). A zoom that
// replaces forty tiles queues a few hundred of them, and they were 26-34 ms
// of the 108 ms worst frame the colony sweep measured. Pooled, a dropped
// chunk's buffer is the next chunk's, and the finalizer never runs.
//
// The pool is generic over the buffer handle so its policy — size classes,
// cooling, the byte budget, the accounting — can be pinned without a GPU
// (see test/flutter_scene/device_buffer_pool_test.dart); [GpuDeviceBufferPool]
// is the one the city uses, over the engine's buffers.

// The staged upload and its buffer are a fork patch the public barrel does
// not export; this file and the mesh step are their only users.
// ignore_for_file: implementation_imports
import 'package:flutter_scene/scene.dart' as fs;
import 'package:flutter_scene/src/geometry/mesh_geometry.dart'
    show MeshGeometry;
import 'package:flutter_scene/src/gpu/gpu.dart' as igpu;

/// A free list of buffers by size class, with a cooling period and a byte
/// budget.
///
/// A request for `n` bytes is served from the class [classFor] rounds it
/// up to — the next power of two from [minClassBytes] to [maxClassBytes] —
/// so a chunk that lands in a pooled buffer finds one at most twice its
/// size, and the bytes past its own layout are never read. A request past
/// the largest class is unpooled: too big to keep around on the chance
/// another chunk that size comes along.
///
/// A released buffer is not handed out again until it has COOLED for
/// [coolingFrames] frames: on the GLES backend an in-place overwrite of a
/// buffer a still-in-flight frame reads tears (black shards where the old
/// chunk was), and a chunk whose node left the scene this frame may be
/// read by the frame the raster thread is finishing now. The caller's
/// frame index is the clock; [release] stamps it and [acquire] compares.
///
/// The free list holds at most [budgetBytes]; over it, the coldest buffers
/// — released longest ago — are dropped, to be finalized later as they
/// all were before the pool. A budget of zero disables the pool: nothing
/// is kept, every acquire misses, and buffers are dropped as they come.
class DeviceBufferPool<B extends Object> {
  DeviceBufferPool({required this.budgetBytes, this.coolingFrames = 3});

  /// The smallest size class: a request under it is served from it.
  static const int minClassBytes = 256 << 10;

  /// The largest size class: a request over it is unpooled.
  static const int maxClassBytes = 4 << 20;

  /// The size class a request of [bytes] is served from — the next power
  /// of two in [[minClassBytes], [maxClassBytes]] — or null when a request
  /// that size is unpooled (larger than the largest class, or nothing).
  static int? classFor(int bytes) {
    if (bytes <= 0 || bytes > maxClassBytes) return null;
    var size = minClassBytes;
    while (size < bytes) {
      size <<= 1;
    }
    return size;
  }

  /// How many bytes of free buffers the pool keeps; 0 disables it. Read on
  /// every release and acquire, so it can be changed while the city runs.
  int budgetBytes;

  /// Frames a released buffer waits before it can be acquired again.
  int coolingFrames;

  final List<_FreeBuffer<B>> _free = [];

  /// Acquires that were served from the free list.
  int hits = 0;

  /// Acquires that found nothing cooled in their class.
  int misses = 0;

  /// Buffers dropped from the free list for the budget.
  int evicted = 0;

  /// Bytes of free buffers held now.
  int freeBytes = 0;

  /// Free buffers held now.
  int get freeCount => _free.length;

  /// A cooled buffer of [classBytes], the coldest one, or null when none
  /// has cooled by [frame]. A disabled pool answers null without counting
  /// a miss: nothing was asked of it.
  B? acquire(int classBytes, int frame) {
    // The budget is a knob: lowered between calls, the list sheds first.
    _evictOverBudget();
    if (budgetBytes <= 0) return null;
    var coldest = -1;
    for (var i = 0; i < _free.length; i++) {
      final e = _free[i];
      if (e.classBytes != classBytes) continue;
      if (frame - e.releasedFrame < coolingFrames) continue;
      if (coldest < 0 || e.releasedFrame < _free[coldest].releasedFrame) {
        coldest = i;
      }
    }
    if (coldest < 0) {
      misses++;
      return null;
    }
    final e = _free.removeAt(coldest);
    freeBytes -= e.classBytes;
    hits++;
    return e.buffer;
  }

  /// Puts [buffer], of size class [classBytes], on the free list as of
  /// [frame], then drops the coldest buffers until the list fits the
  /// budget. With the pool disabled the buffer is dropped at once.
  void release(B buffer, int classBytes, int frame) {
    if (budgetBytes > 0 && classBytes > 0) {
      _free.add(_FreeBuffer(buffer, classBytes, frame));
      freeBytes += classBytes;
    } else {
      evicted++;
    }
    _evictOverBudget();
  }

  /// Forgets every free buffer.
  void clear() {
    _free.clear();
    freeBytes = 0;
  }

  void _evictOverBudget() {
    while (freeBytes > budgetBytes && _free.isNotEmpty) {
      var coldest = 0;
      for (var i = 1; i < _free.length; i++) {
        if (_free[i].releasedFrame < _free[coldest].releasedFrame) coldest = i;
      }
      freeBytes -= _free.removeAt(coldest).classBytes;
      evicted++;
    }
  }
}

class _FreeBuffer<B> {
  const _FreeBuffer(this.buffer, this.classBytes, this.releasedFrame);
  final B buffer;
  final int classBytes;
  final int releasedFrame;
}

/// The pool over the engine's buffers: allocates for a staged upload and
/// reclaims from the nodes a tile drops.
class GpuDeviceBufferPool extends DeviceBufferPool<igpu.DeviceBuffer> {
  GpuDeviceBufferPool({required super.budgetBytes, super.coolingFrames});

  /// A host-visible buffer for a chunk of [bytes] as of [frame]: a pooled
  /// one of the chunk's class when one has cooled, else a fresh one — at
  /// the class size while the pool is on, so it can be reclaimed into that
  /// class later, and at exactly [bytes] when the pool is off or the chunk
  /// is past the largest class.
  ///
  /// A reused buffer is written by the same overwrites a fresh one is; the
  /// driver marks the written range dirty and uploads it at the chunk's
  /// first draw, the same cost as a first draw in a fresh buffer.
  igpu.DeviceBuffer allocate(int bytes, int frame) {
    final classBytes = budgetBytes > 0
        ? DeviceBufferPool.classFor(bytes)
        : null;
    if (classBytes == null) {
      return igpu.gpuContext.createDeviceBuffer(
        igpu.StorageMode.hostVisible,
        bytes,
      );
    }
    return acquire(classBytes, frame) ??
        igpu.gpuContext.createDeviceBuffer(
          igpu.StorageMode.hostVisible,
          classBytes,
        );
  }

  /// Puts [buffer] on the free list as of [frame], if it is a class-sized
  /// buffer; an exact-sized or oversized one — allocated with the pool off,
  /// or past the largest class — is dropped, to be finalized as before.
  void reclaim(igpu.DeviceBuffer buffer, int frame) {
    final size = buffer.sizeInBytes;
    if (DeviceBufferPool.classFor(size) != size) return;
    release(buffer, size, frame);
  }

  /// Takes the staged buffer of every mesh geometry under [nodes] (the
  /// nodes and their children) back into the pool as of [frame]. Only for
  /// nodes that have left the scene for good: the geometries are unbound
  /// as their buffers go (see [MeshGeometry.takeBuffer]). Geometries that
  /// never had a single staged buffer — the instanced archetypes, the
  /// planting — are left alone.
  void reclaimNodes(Iterable<fs.Node> nodes, int frame) {
    for (final node in nodes) {
      final mesh = node.mesh;
      if (mesh != null) {
        for (final p in mesh.primitives) {
          final g = p.geometry;
          if (g is MeshGeometry) {
            final buffer = g.takeBuffer();
            if (buffer != null) reclaim(buffer, frame);
          }
        }
      }
      if (node.children.isNotEmpty) reclaimNodes(node.children, frame);
    }
  }
}
