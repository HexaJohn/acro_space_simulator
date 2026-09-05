import 'dart:typed_data';

import 'package:flutter/foundation.dart' show internal;
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:vector_math/vector_math.dart';

import 'package:flutter_scene/src/geometry/geometry.dart';
import 'package:flutter_scene/src/geometry/interleaved_layout.dart';
import 'package:flutter_scene/src/geometry/mesh_data.dart';

/// How a [MeshGeometry] manages its GPU buffers over its lifetime.
/// {@category Geometry}
enum GeometryStorage {
  /// The vertex and index buffers are uploaded once at construction and
  /// never change. This is the right choice for imported or generated
  /// meshes that stay still.
  fixed,

  /// The vertex and index buffers are retained so the mesh can be
  /// updated in place every frame without reallocating GPU memory. Use
  /// this for geometry that is regenerated continuously, such as a route
  /// line that follows a moving vehicle.
  ///
  /// An updatable geometry keeps a CPU-side copy of each attribute and
  /// allocates its buffers with spare capacity, so topology-stable
  /// updates ([MeshGeometry.updatePositions] and friends) and bounded
  /// growth ([MeshGeometry.rebuild]) avoid reallocation.
  updatable,
}

/// A triangle mesh built at runtime from vertex attribute arrays.
///
/// `MeshGeometry` is the general-purpose [Geometry] for procedurally
/// generated content. Build one directly from attribute arrays with
/// [MeshGeometry.fromArrays], or assemble it incrementally with a
/// [GeometryBuilder].
///
/// Callers supply attributes as independent typed arrays (positions,
/// normals, texture coordinates, colors) and never pack vertex bytes by
/// hand; the arrays are interleaved into the engine vertex layout
/// internally.
///
/// Pass [GeometryStorage.updatable] as the storage mode to create a
/// geometry that can be mutated in place. [updatePositions],
/// [updateNormals], [updateTexCoords], and [updateColors] replace one
/// attribute when the vertex count is unchanged; [rebuild] replaces
/// everything and reallocates only when the data outgrows the spare
/// capacity.
/// {@category Geometry}
class MeshGeometry extends UnskinnedGeometry {
  /// Builds a mesh from structure-of-arrays vertex attributes.
  ///
  /// [positions] is required and holds three floats per vertex. The
  /// optional attributes hold, per vertex, three floats for [normals],
  /// two for [texCoords], and four for [colors]; each must match the
  /// vertex count implied by [positions] when supplied. Absent
  /// attributes fall back to defaults: texture coordinate `(0, 0)` and
  /// color opaque white.
  ///
  /// When [normals] is omitted and [primitiveType] is a triangle list,
  /// area-weighted vertex normals are generated from the faces; for line
  /// and point primitives, absent normals keep their default. [indices],
  /// when supplied, is an index list; when omitted a triangle mesh must
  /// have a vertex count that is a multiple of three.
  ///
  /// [primitiveType] selects how the vertex/index data is assembled into
  /// primitives when drawn, and defaults to a triangle list.
  ///
  /// [storage] selects whether the mesh can later be updated in place.
  /// An updatable mesh fixes its indexed-or-not state at construction:
  /// supplying [indices] makes [rebuild] require indices thereafter, and
  /// omitting them makes it reject them. To start empty, pass a
  /// zero-length [positions] array with [GeometryStorage.updatable].
  ///
  /// [retainCpuData] (see the field) may be false only for a fixed mesh.
  MeshGeometry.fromArrays({
    required Float32List positions,
    Float32List? normals,
    Float32List? texCoords,
    Float32List? colors,
    List<int>? indices,
    gpu.PrimitiveType primitiveType = gpu.PrimitiveType.triangle,
    this.storage = GeometryStorage.fixed,
    this.retainCpuData = true,
  }) {
    if (positions.length % 3 != 0) {
      throw ArgumentError(
        'positions has ${positions.length} floats; expected a multiple of '
        'three (one vec3 per vertex)',
      );
    }
    if (!retainCpuData && storage != GeometryStorage.fixed) {
      throw ArgumentError(
        'an updatable mesh keeps its attributes on the CPU: retainCpuData '
        'must be true with GeometryStorage.updatable',
      );
    }
    final vertexCount = positions.length ~/ 3;
    this.primitiveType = primitiveType;

    if (storage == GeometryStorage.fixed) {
      _uploadFixed(
        FixedMeshUploadPlan(
          positions: positions,
          normals: normals,
          texCoords: texCoords,
          colors: colors,
          indices: indices,
          primitiveType: primitiveType,
          retainCpuData: retainCpuData,
        ),
      );
    } else {
      // Normals are generated from triangle faces; line and point
      // geometry has none, so absent normals are left at their default.
      final resolvedNormals =
          normals ??
          (vertexCount > 0 && primitiveType == gpu.PrimitiveType.triangle
              ? InterleavedLayoutAdapter.generateNormals(
                  positions: positions,
                  vertexCount: vertexCount,
                  indices: indices,
                )
              : null);
      _indexed = indices != null;
      _setCpuStreams(
        positions,
        vertexCount,
        resolvedNormals,
        texCoords,
        colors,
      );
      _positionRing = _RingBufferStream(
        InterleavedLayoutAdapter.positionStreamBytes,
      );
      _normalRing = _RingBufferStream(
        InterleavedLayoutAdapter.normalStreamBytes,
      );
      _texCoordRing = _RingBufferStream(
        InterleavedLayoutAdapter.texCoordStreamBytes,
      );
      _colorRing = _RingBufferStream(InterleavedLayoutAdapter.colorStreamBytes);
      _liveVertexCount = vertexCount;
      // Indices first, so the attribute upload can retain them for raycasting.
      if (_indexed) _uploadIndices(indices!);
      _uploadAllStreams();
      _recomputeBounds();
    }
  }

  /// Uploads a mesh from a [MeshData] snapshot built off the render
  /// isolate.
  ///
  /// The snapshot's CPU work (vertex assembly, normal generation) can run
  /// on a background isolate; this constructor performs only the GPU
  /// upload. See [MeshData] for the recipe. [storage] selects whether the
  /// mesh can later be updated in place.
  factory MeshGeometry.fromMeshData(
    MeshData data, {
    GeometryStorage storage = GeometryStorage.fixed,
    bool retainCpuData = true,
  }) {
    return MeshGeometry.fromArrays(
      positions: data.positions,
      normals: data.normals,
      texCoords: data.texCoords,
      colors: data.colors,
      indices: data.indices,
      primitiveType: data.primitiveType,
      storage: storage,
      retainCpuData: retainCpuData,
    );
  }

  // PATCHED (acro_space_simulator): a fixed mesh whose bytes arrive over
  // several frames. Only [StagedMeshUpload] builds one; see [stageFromArrays].
  MeshGeometry._staged(gpu.PrimitiveType primitiveType, this.retainCpuData)
    : storage = GeometryStorage.fixed {
    this.primitiveType = primitiveType;
  }

  /// PATCHED (acro_space_simulator): prepares a fixed mesh from
  /// structure-of-arrays attributes without copying its bytes to the GPU
  /// yet, so the copy can be spread over several frames.
  ///
  /// [MeshGeometry.fromArrays] hands the whole mesh to one host-visible
  /// buffer in one call, and the driver pays for that copy on the raster
  /// thread inside the frame that flushes it: on ANGLE/GLES a multi-megabyte
  /// mesh costs tens of milliseconds there, which the calling thread never
  /// sees. The staged form does every CPU-side part of [fromArrays] here —
  /// the attribute streams with their defaults, the normals when they are
  /// generated, the index packing, the raycast copies and the bounds — and
  /// allocates the one buffer at its full size, but copies nothing. The
  /// caller then moves the bytes a slice a frame with
  /// [StagedMeshUpload.step] and takes the finished geometry with
  /// [StagedMeshUpload.finish]. That geometry is indistinguishable from the
  /// one [fromArrays] would have built from the same arguments: the same
  /// stream views into the same buffer layout, the same index view, raycast
  /// attributes and [localBounds].
  ///
  /// The arguments mean what they mean for [fromArrays]; the storage is
  /// always [GeometryStorage.fixed], since an updatable mesh has its own
  /// per-attribute rings and no single buffer to stage. With
  /// [retainCpuData] false (see the field) the stage copies nothing at all
  /// on the CPU: the caller's arrays are what the slices are cut from, and
  /// they must stay unchanged until [StagedMeshUpload.step] has moved every
  /// byte.
  static StagedMeshUpload stageFromArrays({
    required Float32List positions,
    Float32List? normals,
    Float32List? texCoords,
    Float32List? colors,
    List<int>? indices,
    gpu.PrimitiveType primitiveType = gpu.PrimitiveType.triangle,
    bool retainCpuData = true,
  }) {
    if (positions.length % 3 != 0) {
      throw ArgumentError(
        'positions has ${positions.length} floats; expected a multiple of '
        'three (one vec3 per vertex)',
      );
    }
    final plan = FixedMeshUploadPlan(
      positions: positions,
      normals: normals,
      texCoords: texCoords,
      colors: colors,
      indices: indices,
      primitiveType: primitiveType,
      retainCpuData: retainCpuData,
    );
    final geometry = MeshGeometry._staged(primitiveType, retainCpuData);
    geometry._adoptPlan(plan);

    // The segments in the order [Geometry._uploadStreams] lays them out:
    // the four attribute streams in slot order, then the indices.
    final indexBytes = plan.indexBytes;
    final segments = <UploadSegment>[
      ...plan.segments,
      if (indexBytes != null) UploadSegment.bytes(indexBytes),
    ];
    final layout = StagedUploadLayout([
      for (final s in segments) s.lengthInBytes,
    ]);
    final buffer = gpu.gpuContext.createDeviceBuffer(
      gpu.StorageMode.hostVisible,
      layout.totalBytes,
    );
    return StagedMeshUpload._(
      geometry,
      segments,
      layout,
      buffer,
      indexed: indexBytes != null,
      indexType: plan.indexType,
    );
  }

  /// Takes what a [FixedMeshUploadPlan] worked out on the CPU: the live
  /// vertex count, the retained attribute copies and the index bytes (when
  /// the plan kept them), the raycast attributes that reference them, and
  /// the bounds. The GPU side — the upload of [FixedMeshUploadPlan.segments]
  /// — is the caller's, immediate or staged.
  void _adoptPlan(FixedMeshUploadPlan plan) {
    _liveVertexCount = plan.vertexCount;
    final cpu = plan.cpuStreams;
    if (cpu != null) {
      _cpuPositions = cpu.positions;
      _cpuNormals = cpu.normals;
      _cpuTexCoords = cpu.texCoords;
      _cpuColors = cpu.colors;
      _packedIndexBytes = plan.packedIndexBytes;
      _packedIndices32Bit = plan.packedIndices32Bit;
      // Raycast off this geometry's own attribute arrays instead of the
      // transient upload copies, so no extra position/texcoord copy lingers.
      // Keep the index bytes so an indexed mesh raycasts as indexed.
      setRaycastAttributes(
        positions: cpu.positions,
        texCoords: cpu.texCoords,
        indices: plan.indexBytes,
      );
    }
    final bounds = plan.bounds;
    if (bounds != null) applyScannedBounds(bounds);
  }

  /// Replaces this updatable geometry's data from a [MeshData] snapshot.
  ///
  /// Equivalent to passing the snapshot's arrays to [rebuild], so the same
  /// indexed-or-not contract applies. Throws a [StateError] unless this
  /// geometry is [GeometryStorage.updatable].
  void applyMeshData(MeshData data) {
    rebuild(
      positions: data.positions,
      normals: data.normals,
      texCoords: data.texCoords,
      colors: data.colors,
      indices: data.indices,
    );
  }

  /// How this geometry's GPU buffers are managed; see [GeometryStorage].
  final GeometryStorage storage;

  /// PATCHED (acro_space_simulator): whether this geometry keeps its
  /// attributes on the CPU after the upload.
  ///
  /// True by default: the geometry retains a copy of every attribute stream
  /// and its packed indices, which is what scene raycasts read and what
  /// [packedData] and [soaData] serialise from. False — allowed for a fixed
  /// mesh only — uploads the caller's arrays from their own bytes, allocates
  /// nothing on the CPU for absent attributes, and keeps nothing: the
  /// geometry then CANNOT be raycast (a scene raycast passes straight
  /// through it) and CANNOT be re-serialised ([packedData] and [soaData]
  /// throw). [localBounds] is still scanned from the positions before they
  /// are let go. A city of hundreds of large meshes that are never picked
  /// and never saved otherwise keeps hundreds of megabytes of typed data in
  /// the old generation for the collector to mark on every pass.
  final bool retainCpuData;

  // --- Updatable-storage state. Unused while [storage] is fixed. ---

  bool _indexed = false;
  int _liveVertexCount = 0;
  int _indexCapacity = 0;
  gpu.DeviceBuffer? _indexBuffer;
  gpu.IndexType _indexType = gpu.IndexType.int16;

  // One ring of host-visible buffers per attribute, so an in-place update
  // writes to a buffer the GPU is not currently reading (avoiding the
  // write-vs-read race). The index buffer stays single-buffered, since
  // topology-stable updates leave it untouched and only the slow rebuild path
  // rewrites it. [_streamViews] holds the currently bound view of each ring,
  // in slot order (position, normal, texcoord, color).
  late final _RingBufferStream _positionRing;
  late final _RingBufferStream _normalRing;
  late final _RingBufferStream _texCoordRing;
  late final _RingBufferStream _colorRing;
  List<gpu.BufferView> _streamViews = const [];

  // The interleaved vertex bytes, built lazily from the structure-of-arrays
  // CPU streams only when the scene serializer asks for them, and invalidated
  // on every update. Nothing interleaves on the upload path anymore.
  Uint8List? _packedVertexBytes;
  Uint8List? _packedIndexBytes;
  bool _packedIndices32Bit = false;

  /// The packed interleaved vertex bytes (and packed index bytes with their
  /// width), in the engine's interleaved unskinned layout. Interleaved lazily
  /// from the per-attribute CPU streams on first access. The scene serializer
  /// emits the de-interleaved [soaData] instead; this stays as a convenience
  /// for callers wanting the interleaved form.
  ({Uint8List vertexBytes, Uint8List? indexBytes, bool indices32Bit})
  get packedData {
    _ensureCpuData('packedData');
    return (
      vertexBytes: _packedVertexBytes ??=
          InterleavedLayoutAdapter.packUnskinned(
            positions: _cpuPositions,
            vertexCount: _liveVertexCount,
            normals: _cpuNormals,
            texCoords: _cpuTexCoords,
            colors: _cpuColors,
          ),
      indexBytes: _packedIndexBytes,
      indices32Bit: _packedIndices32Bit,
    );
  }

  /// The de-interleaved (structure-of-arrays) vertex bytes (the four attribute
  /// streams concatenated) plus the packed index bytes, for re-emitting this
  /// geometry as a `.fscene` payload with the
  /// [InterleavedLayoutAdapter.unskinnedSoaLayout] layout. Built directly from
  /// the per-attribute CPU streams, no interleave.
  @internal
  ({Uint8List vertexBytes, Uint8List? indexBytes, bool indices32Bit})
  get soaData {
    _ensureCpuData('soaData');
    return (
      vertexBytes: InterleavedLayoutAdapter.concatUnskinnedStreams(
        UnskinnedAttributeStreams(
          position: _bytesOf(_cpuPositions),
          normal: _bytesOf(_cpuNormals),
          texCoord: _bytesOf(_cpuTexCoords),
          color: _bytesOf(_cpuColors),
        ),
      ),
      indexBytes: _packedIndexBytes,
      indices32Bit: _packedIndices32Bit,
    );
  }

  void _ensureCpuData(String what) {
    if (!retainCpuData) {
      throw StateError(
        '$what needs the CPU attributes, and this MeshGeometry was built '
        'with retainCpuData: false',
      );
    }
  }

  Float32List _cpuPositions = Float32List(0);
  Float32List _cpuNormals = Float32List(0);
  Float32List _cpuTexCoords = Float32List(0);
  Float32List _cpuColors = Float32List(0);

  /// The number of vertices currently drawn.
  int get vertexCount => _liveVertexCount;

  /// Whether this geometry can be updated in place.
  bool get isUpdatable => storage == GeometryStorage.updatable;

  /// Replaces every vertex position, keeping the vertex count unchanged.
  ///
  /// [positions] holds three floats per vertex and must match the
  /// current [vertexCount]. To change the vertex count, use [rebuild].
  /// Throws a [StateError] unless this geometry is
  /// [GeometryStorage.updatable].
  ///
  /// When only a contiguous span of vertices changed, pass [dirtyStart]
  /// and [dirtyCount] (in vertices) to upload just that span. [positions]
  /// must still hold every vertex (the full array backs raycasting and
  /// bounds); the hint only narrows the GPU upload. Omit both to upload
  /// the whole stream.
  void updatePositions(
    Float32List positions, {
    int? dirtyStart,
    int? dirtyCount,
  }) {
    _ensureUpdatable('updatePositions');
    _checkAttributeLength('positions', positions.length, 3);
    _cpuPositions = Float32List.fromList(positions);
    _writeStream(
      0,
      _positionRing,
      _cpuPositions,
      dirtyStart: dirtyStart,
      dirtyCount: dirtyCount,
    );
    _recomputeBounds();
  }

  /// Replaces every vertex normal, keeping the vertex count unchanged.
  ///
  /// Pass [dirtyStart]/[dirtyCount] to upload only a contiguous span; see
  /// [updatePositions].
  void updateNormals(Float32List normals, {int? dirtyStart, int? dirtyCount}) {
    _ensureUpdatable('updateNormals');
    _checkAttributeLength('normals', normals.length, 3);
    _cpuNormals = Float32List.fromList(normals);
    _writeStream(
      1,
      _normalRing,
      _cpuNormals,
      dirtyStart: dirtyStart,
      dirtyCount: dirtyCount,
    );
  }

  /// Replaces every texture coordinate, keeping the vertex count
  /// unchanged.
  ///
  /// Pass [dirtyStart]/[dirtyCount] to upload only a contiguous span; see
  /// [updatePositions].
  void updateTexCoords(
    Float32List texCoords, {
    int? dirtyStart,
    int? dirtyCount,
  }) {
    _ensureUpdatable('updateTexCoords');
    _checkAttributeLength('texCoords', texCoords.length, 2);
    _cpuTexCoords = Float32List.fromList(texCoords);
    _writeStream(
      2,
      _texCoordRing,
      _cpuTexCoords,
      dirtyStart: dirtyStart,
      dirtyCount: dirtyCount,
    );
  }

  /// Replaces every vertex color, keeping the vertex count unchanged.
  ///
  /// Pass [dirtyStart]/[dirtyCount] to upload only a contiguous span; see
  /// [updatePositions].
  void updateColors(Float32List colors, {int? dirtyStart, int? dirtyCount}) {
    _ensureUpdatable('updateColors');
    _checkAttributeLength('colors', colors.length, 4);
    _cpuColors = Float32List.fromList(colors);
    _writeStream(
      3,
      _colorRing,
      _cpuColors,
      dirtyStart: dirtyStart,
      dirtyCount: dirtyCount,
    );
  }

  /// Replaces all of this geometry's data, allowing the vertex and index
  /// counts to change.
  ///
  /// Reuses the existing GPU buffers when the new data fits within their
  /// spare capacity, and reallocates with headroom only when it does
  /// not. The indexed-or-not state is fixed at construction: a geometry
  /// created with indices requires [indices] here, and one created
  /// without must omit them. Throws a [StateError] unless this geometry
  /// is [GeometryStorage.updatable].
  void rebuild({
    required Float32List positions,
    Float32List? normals,
    Float32List? texCoords,
    Float32List? colors,
    List<int>? indices,
  }) {
    _ensureUpdatable('rebuild');
    if (positions.length % 3 != 0) {
      throw ArgumentError(
        'positions has ${positions.length} floats; expected a multiple of '
        'three (one vec3 per vertex)',
      );
    }
    if (_indexed && indices == null) {
      throw ArgumentError(
        'This geometry was created with indices; rebuild requires them',
      );
    }
    if (!_indexed && indices != null) {
      throw ArgumentError(
        'This geometry was created without indices; rebuild must not '
        'supply them',
      );
    }
    final vertexCount = positions.length ~/ 3;
    final resolvedNormals =
        normals ??
        (vertexCount > 0 && primitiveType == gpu.PrimitiveType.triangle
            ? InterleavedLayoutAdapter.generateNormals(
                positions: positions,
                vertexCount: vertexCount,
                indices: indices,
              )
            : null);

    _setCpuStreams(positions, vertexCount, resolvedNormals, texCoords, colors);
    _liveVertexCount = vertexCount;
    // The rings reallocate themselves when the count outgrows their capacity.
    if (_indexed) _uploadIndices(indices!);
    _uploadAllStreams();
    _recomputeBounds();
  }

  // The fixed path: the plan's CPU side adopted, its segments uploaded at
  // once. The retained copies (when kept) are the segments themselves, so
  // they go to the GPU directly — the second de-interleave copy
  // [Geometry.uploadUnskinnedAttributes] used to make on the way is gone.
  void _uploadFixed(FixedMeshUploadPlan plan) {
    _adoptPlan(plan);
    uploadUnskinnedSegments(
      plan.segments,
      plan.vertexCount,
      indices: plan.indexBytes,
      indexType: plan.indexType,
    );
  }

  // Writes all four attribute streams into their rings and binds them.
  // Used at construction and on rebuild.
  void _uploadAllStreams() {
    _streamViews = [
      _positionRing.write(_bytesOf(_cpuPositions), _liveVertexCount),
      _normalRing.write(_bytesOf(_cpuNormals), _liveVertexCount),
      _texCoordRing.write(_bytesOf(_cpuTexCoords), _liveVertexCount),
      _colorRing.write(_bytesOf(_cpuColors), _liveVertexCount),
    ];
    setVertexStreams(_streamViews, _liveVertexCount);
    _refreshRaycastData();
    // Invalidate the lazily interleaved serialization bytes.
    _packedVertexBytes = null;
  }

  // Writes one changed attribute into its ring's next buffer and rebinds the
  // streams. The other attributes keep their current ring buffers, so only
  // the dirty stream's bytes are re-uploaded.
  void _writeStream(
    int slot,
    _RingBufferStream ring,
    Float32List attribute, {
    int? dirtyStart,
    int? dirtyCount,
  }) {
    final (start, end) = _resolveDirtyRange(dirtyStart, dirtyCount);
    _streamViews = List<gpu.BufferView>.of(_streamViews);
    _streamViews[slot] = ring.writeRange(
      _bytesOf(attribute),
      _liveVertexCount,
      start,
      end,
    );
    setVertexStreams(_streamViews, _liveVertexCount);
    _refreshRaycastData();
    _packedVertexBytes = null;
  }

  // Resolves an optional caller dirty range (in vertices) to a half-open
  // span, defaulting to the whole stream when unspecified. Validates the
  // span lies within the current vertex count.
  (int, int) _resolveDirtyRange(int? dirtyStart, int? dirtyCount) {
    if (dirtyStart == null && dirtyCount == null) {
      return (0, _liveVertexCount);
    }
    final start = dirtyStart ?? 0;
    final count = dirtyCount ?? (_liveVertexCount - start);
    if (start < 0 || count < 0 || start + count > _liveVertexCount) {
      throw RangeError(
        'dirty range [$start, ${start + count}) is outside the '
        '$_liveVertexCount vertices',
      );
    }
    return (start, start + count);
  }

  void _refreshRaycastData() {
    setRaycastAttributes(
      positions: _cpuPositions,
      texCoords: _cpuTexCoords,
      indices: _packedIndexBytes == null
          ? null
          : ByteData.sublistView(_packedIndexBytes!),
    );
  }

  static Uint8List _bytesOf(Float32List attribute) => attribute.buffer
      .asUint8List(attribute.offsetInBytes, attribute.lengthInBytes);

  void _uploadIndices(List<int> indices) {
    final packed = InterleavedLayoutAdapter.packIndices(indices);
    _packedIndexBytes = packed.bytes;
    _packedIndices32Bit = packed.is32Bit;
    // Raycast index data is retained alongside the attribute streams by
    // [_refreshRaycastData]; this method only manages the GPU index buffer.
    final indexType = packed.is32Bit
        ? gpu.IndexType.int32
        : gpu.IndexType.int16;
    final elementBytes = packed.is32Bit ? 4 : 2;
    if (_indexBuffer == null ||
        indices.length > _indexCapacity ||
        indexType != _indexType) {
      _indexCapacity = nextBufferCapacity(indices.length);
      _indexType = indexType;
      // Host-visible for the same reason as the attribute streams (see
      // [_RingBufferStream]); a rebuild may rewrite the index buffer.
      _indexBuffer = gpu.gpuContext.createDeviceBuffer(
        gpu.StorageMode.hostVisible,
        _indexCapacity * elementBytes,
      );
    }
    final buffer = _indexBuffer!;
    if (packed.bytes.isNotEmpty) {
      buffer.overwrite(ByteData.sublistView(packed.bytes));
      buffer.flush(offsetInBytes: 0, lengthInBytes: packed.bytes.length);
    }
    setIndices(
      gpu.BufferView(
        buffer,
        offsetInBytes: 0,
        lengthInBytes: packed.bytes.length,
      ),
      indexType,
    );
  }

  void _setCpuStreams(
    Float32List positions,
    int vertexCount,
    Float32List? normals,
    Float32List? texCoords,
    Float32List? colors,
  ) {
    final cpu = _cpuStreamsOf(
      positions,
      vertexCount,
      normals,
      texCoords,
      colors,
    );
    _cpuPositions = cpu.positions;
    _cpuNormals = cpu.normals;
    _cpuTexCoords = cpu.texCoords;
    _cpuColors = cpu.colors;
  }

  // The retained copies of the four attributes, defaults filled (normal
  // `(0, 0, 1)`, texture coordinate `(0, 0)`, color opaque white) and each
  // checked against the vertex count. Shared by the updatable path and
  // [FixedMeshUploadPlan].
  static ({
    Float32List positions,
    Float32List normals,
    Float32List texCoords,
    Float32List colors,
  })
  _cpuStreamsOf(
    Float32List positions,
    int vertexCount,
    Float32List? normals,
    Float32List? texCoords,
    Float32List? colors,
  ) {
    if (normals != null && normals.length != vertexCount * 3) {
      throw ArgumentError(
        'normals has ${normals.length} floats; expected ${vertexCount * 3}',
      );
    }
    if (texCoords != null && texCoords.length != vertexCount * 2) {
      throw ArgumentError(
        'texCoords has ${texCoords.length} floats; expected '
        '${vertexCount * 2}',
      );
    }
    if (colors != null && colors.length != vertexCount * 4) {
      throw ArgumentError(
        'colors has ${colors.length} floats; expected ${vertexCount * 4}',
      );
    }
    return (
      positions: Float32List.fromList(positions),
      normals: normals != null
          ? Float32List.fromList(normals)
          : _filledStream(vertexCount, 3, const [0.0, 0.0, 1.0]),
      texCoords: texCoords != null
          ? Float32List.fromList(texCoords)
          : Float32List(vertexCount * 2),
      colors: colors != null
          ? Float32List.fromList(colors)
          : _filledStream(vertexCount, 4, const [1.0, 1.0, 1.0, 1.0]),
    );
  }

  void _recomputeBounds() {
    if (_liveVertexCount == 0) {
      setLocalBounds(null, null);
      return;
    }
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = double.negativeInfinity,
        maxY = double.negativeInfinity,
        maxZ = double.negativeInfinity;
    for (var v = 0; v < _liveVertexCount; v++) {
      final x = _cpuPositions[v * 3];
      final y = _cpuPositions[v * 3 + 1];
      final z = _cpuPositions[v * 3 + 2];
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (z < minZ) minZ = z;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
      if (z > maxZ) maxZ = z;
    }
    final min = Vector3(minX, minY, minZ);
    final max = Vector3(maxX, maxY, maxZ);
    final center = (min + max) * 0.5;
    final radius = ((max - min) * 0.5).length;
    setLocalBounds(Aabb3.minMax(min, max), Sphere.centerRadius(center, radius));
  }

  void _ensureUpdatable(String operation) {
    if (storage != GeometryStorage.updatable) {
      throw StateError(
        '$operation requires GeometryStorage.updatable; this geometry is '
        'fixed',
      );
    }
  }

  void _checkAttributeLength(String name, int length, int componentsPerVertex) {
    final expected = _liveVertexCount * componentsPerVertex;
    if (length != expected) {
      throw ArgumentError(
        '$name has $length floats; a topology-stable update expects '
        '$expected for $_liveVertexCount vertices. Use rebuild to change '
        'the vertex count.',
      );
    }
  }

  static Float32List _filledStream(
    int vertexCount,
    int componentsPerVertex,
    List<double> value,
  ) {
    final stream = Float32List(vertexCount * componentsPerVertex);
    for (var v = 0; v < vertexCount; v++) {
      for (var c = 0; c < componentsPerVertex; c++) {
        stream[v * componentsPerVertex + c] = value[c];
      }
    }
    return stream;
  }
}

/// PATCHED (acro_space_simulator): the CPU side of building a fixed
/// [MeshGeometry] from structure-of-arrays attributes, with no GPU in it.
///
/// [MeshGeometry.fromArrays] and [MeshGeometry.stageFromArrays] used to do
/// this work twice over in their own words; both now build a plan and
/// differ only in how its [segments] reach the buffer — at once, or a slice
/// a frame. Being pure, the plan is where the two contracts of
/// [MeshGeometry.retainCpuData] are pinned without a context: with it, the
/// retained streams (defaults filled, as
/// [InterleavedLayoutAdapter.unskinnedAttributeStreams] fills them) ARE the
/// segments; without it, the segments are the caller's own bytes and
/// repeated defaults, [cpuStreams] is null, and nothing but [bounds] is
/// kept. Either way the bytes that reach the buffer are the same.
@internal
class FixedMeshUploadPlan {
  FixedMeshUploadPlan({
    required Float32List positions,
    Float32List? normals,
    Float32List? texCoords,
    Float32List? colors,
    List<int>? indices,
    gpu.PrimitiveType primitiveType = gpu.PrimitiveType.triangle,
    required this.retainCpuData,
  }) : vertexCount = positions.length ~/ 3 {
    if (positions.length % 3 != 0) {
      throw ArgumentError(
        'positions has ${positions.length} floats; expected a multiple of '
        'three (one vec3 per vertex)',
      );
    }
    // Normals are generated from triangle faces; line and point
    // geometry has none, so absent normals are left at their default.
    final resolvedNormals =
        normals ??
        (vertexCount > 0 && primitiveType == gpu.PrimitiveType.triangle
            ? InterleavedLayoutAdapter.generateNormals(
                positions: positions,
                vertexCount: vertexCount,
                indices: indices,
              )
            : null);

    if (indices != null) {
      final packed = InterleavedLayoutAdapter.packIndices(indices);
      indexBytes = ByteData.sublistView(packed.bytes);
      indexType = packed.is32Bit ? gpu.IndexType.int32 : gpu.IndexType.int16;
      packedIndices32Bit = packed.is32Bit;
      packedIndexBytes = retainCpuData ? packed.bytes : null;
    } else {
      indexBytes = null;
      indexType = gpu.IndexType.int16;
      packedIndices32Bit = false;
      packedIndexBytes = null;
    }

    if (retainCpuData) {
      // The retained copies, filled with the same defaults the upload
      // streams would carry, so they are uploaded as they are rather than
      // copied once more on the way.
      final cpu = MeshGeometry._cpuStreamsOf(
        positions,
        vertexCount,
        resolvedNormals,
        texCoords,
        colors,
      );
      cpuStreams = cpu;
      segments = [
        UploadSegment.bytes(ByteData.sublistView(cpu.positions)),
        UploadSegment.bytes(ByteData.sublistView(cpu.normals)),
        UploadSegment.bytes(ByteData.sublistView(cpu.texCoords)),
        UploadSegment.bytes(ByteData.sublistView(cpu.colors)),
      ];
    } else {
      cpuStreams = null;
      segments = InterleavedLayoutAdapter.unskinnedUploadSegments(
        positions: positions,
        vertexCount: vertexCount,
        normals: resolvedNormals,
        texCoords: texCoords,
        colors: colors,
      );
    }
    bounds = Geometry.boundsOfPositions(positions, vertexCount);
  }

  /// See [MeshGeometry.retainCpuData].
  final bool retainCpuData;

  /// Vertices in the mesh.
  final int vertexCount;

  /// The four attribute segments in slot order (position, normal, texture
  /// coordinate, color), as the upload lays them out.
  late final List<UploadSegment> segments;

  /// The packed index bytes to upload after the segments, or null for a
  /// non-indexed mesh; [indexType] is their width.
  late final ByteData? indexBytes;
  late final gpu.IndexType indexType;

  /// The retained attribute copies — what the geometry raycasts and
  /// serialises from — or null when [retainCpuData] is false.
  late final ({
    Float32List positions,
    Float32List normals,
    Float32List texCoords,
    Float32List colors,
  })?
  cpuStreams;

  /// The packed indices the geometry serialises from, kept only with
  /// [retainCpuData]; [packedIndices32Bit] is their width either way.
  late final Uint8List? packedIndexBytes;
  late final bool packedIndices32Bit;

  /// The box around the positions, scanned before they are let go; null for
  /// an empty mesh.
  late final Aabb3? bounds;
}

/// PATCHED (acro_space_simulator): a fixed mesh whose GPU copy is made a
/// slice at a time. Created by [MeshGeometry.stageFromArrays].
///
/// The CPU work is done and the device buffer allocated when the stage is
/// created; each [step] copies the next contiguous run of bytes — the
/// attribute streams in slot order, then the indices, exactly as
/// [MeshGeometry.fromArrays] lays them out — into the buffer, at most
/// `maxBytes` per call. A host-visible buffer's `overwrite` is recorded and
/// executed on the raster thread when the frame flushes, so one slice a frame
/// is what bounds the raster-side cost of a frame. Once [step] has returned
/// true, [finish] binds the views and hands over the geometry.
class StagedMeshUpload {
  StagedMeshUpload._(
    this._geometry,
    this._segments,
    this.layout,
    this._buffer, {
    required bool indexed,
    required gpu.IndexType indexType,
  }) : _indexed = indexed,
       _indexType = indexType;

  final MeshGeometry _geometry;
  final List<UploadSegment> _segments;
  final gpu.DeviceBuffer _buffer;
  final bool _indexed;
  final gpu.IndexType _indexType;
  bool _finished = false;
  int _cursor = 0;

  /// The buffer's segments and their offsets: the four attribute streams,
  /// then the indices when the mesh has them.
  final StagedUploadLayout layout;

  /// Every byte the mesh occupies on the GPU: streams plus indices.
  int get totalBytes => layout.totalBytes;

  /// Bytes handed to the buffer so far.
  int get uploadedBytes => _cursor;

  /// Whether every byte has been handed to the buffer, so [finish] may run.
  bool get isResident => _cursor >= layout.totalBytes;

  /// Copies the next run of bytes, at most [maxBytes] of them, into the
  /// device buffer, and returns whether the whole mesh is now resident.
  ///
  /// A [maxBytes] of zero or less copies nothing; the call still answers
  /// whether the upload is complete. Once resident, further calls are no-ops
  /// that return true.
  bool step(int maxBytes) {
    if (isResident) return true;
    if (maxBytes <= 0) return false;
    for (final slice in layout.slicesFrom(_cursor, maxBytes)) {
      // A slice of a repeated-default segment is several overwrites of a
      // block each; [Geometry.writeSegmentSlice] is the same writer the
      // immediate upload uses, so the buffers come out identical.
      Geometry.writeSegmentSlice(
        _buffer,
        _segments[slice.segment],
        offsetInSegment: slice.offsetInSegment,
        length: slice.length,
        destinationOffset: slice.destinationOffset,
      );
      _cursor += slice.length;
    }
    return isResident;
  }

  /// The finished geometry: the same views, raycast data and bounds that
  /// [MeshGeometry.fromArrays] would have produced from the same arguments.
  ///
  /// Valid once [step] has returned true, and once only: the geometry is
  /// bound to its buffer here, and a second binding would be the same object
  /// again with nothing to add. Throws a [StateError] otherwise.
  MeshGeometry finish() {
    if (!isResident) {
      throw StateError(
        'finish() before the upload is resident: $_cursor of '
        '${layout.totalBytes} bytes copied',
      );
    }
    if (_finished) {
      throw StateError('finish() called twice on one StagedMeshUpload');
    }
    _finished = true;
    final views = <gpu.BufferView>[
      for (var slot = 0; slot < 4; slot++)
        gpu.BufferView(
          _buffer,
          offsetInBytes: layout.segmentOffsets[slot],
          lengthInBytes: layout.segmentLengths[slot],
        ),
    ];
    _geometry.setVertexStreams(views, _geometry._liveVertexCount);
    if (_indexed) {
      _geometry.setIndices(
        gpu.BufferView(
          _buffer,
          offsetInBytes: layout.segmentOffsets[4],
          lengthInBytes: layout.segmentLengths[4],
        ),
        _indexType,
      );
    }
    return _geometry;
  }
}

/// One contiguous copy of a staged upload: [length] bytes of segment
/// [segment], starting [offsetInSegment] bytes into it, landing at byte
/// [destinationOffset] of the device buffer.
typedef StagedUploadSlice = ({
  int segment,
  int offsetInSegment,
  int length,
  int destinationOffset,
});

/// PATCHED (acro_space_simulator): the byte layout of a staged upload —
/// several source segments packed back to back into one buffer — and the
/// arithmetic that cuts it into bounded slices. Pure, so the slicing can be
/// checked without a GPU: the slices of successive [slicesFrom] calls tile
/// the buffer exactly, never cross a segment boundary (each slice is one
/// `overwrite` from one source), and never exceed the byte cap they were
/// asked for.
class StagedUploadLayout {
  StagedUploadLayout(List<int> segmentLengths)
    : segmentLengths = List<int>.unmodifiable(segmentLengths),
      segmentOffsets = List<int>.unmodifiable(_prefixSums(segmentLengths)),
      totalBytes = segmentLengths.fold(0, (sum, n) => sum + n) {
    for (final n in segmentLengths) {
      if (n < 0) {
        throw ArgumentError.value(
          segmentLengths,
          'segmentLengths',
          'a segment cannot have a negative length',
        );
      }
    }
  }

  /// The byte length of each segment, in buffer order.
  final List<int> segmentLengths;

  /// Where each segment starts in the buffer.
  final List<int> segmentOffsets;

  /// The buffer's size: every segment's bytes.
  final int totalBytes;

  /// The slices that move the bytes from [cursor] (a buffer offset) up to
  /// [maxBytes] further, one slice per segment touched, in buffer order.
  /// Empty when the cursor is at the end or [maxBytes] is not positive.
  List<StagedUploadSlice> slicesFrom(int cursor, int maxBytes) {
    if (cursor < 0 || cursor > totalBytes) {
      throw RangeError.range(cursor, 0, totalBytes, 'cursor');
    }
    final slices = <StagedUploadSlice>[];
    var at = cursor;
    var left = maxBytes;
    var segment = _segmentAt(at);
    while (left > 0 && at < totalBytes) {
      final segmentEnd = segmentOffsets[segment] + segmentLengths[segment];
      if (at >= segmentEnd) {
        // An empty segment, or the cursor sitting on a boundary.
        segment++;
        continue;
      }
      final length = (segmentEnd - at) < left ? (segmentEnd - at) : left;
      slices.add((
        segment: segment,
        offsetInSegment: at - segmentOffsets[segment],
        length: length,
        destinationOffset: at,
      ));
      at += length;
      left -= length;
    }
    return slices;
  }

  // The first segment whose span could hold [offset]; a cursor on a boundary
  // resolves to the segment that starts there, and [slicesFrom] steps past
  // any empty ones.
  int _segmentAt(int offset) {
    for (var i = 0; i < segmentLengths.length; i++) {
      if (offset < segmentOffsets[i] + segmentLengths[i]) return i;
    }
    return segmentLengths.length;
  }

  static List<int> _prefixSums(List<int> lengths) {
    final offsets = <int>[];
    var sum = 0;
    for (final n in lengths) {
      offsets.add(sum);
      sum += n;
    }
    return offsets;
  }
}

/// Rounds [needed] up to a buffer capacity with spare headroom.
///
/// Updatable geometry allocates its GPU buffers at the returned size so
/// that a buffer which grows gradually reallocates only a logarithmic
/// number of times rather than on every change. The result is the
/// smallest power of two that is at least [needed] and at least
/// [minimum].
int nextBufferCapacity(int needed, {int minimum = 16}) {
  if (needed <= minimum) return minimum;
  var capacity = minimum;
  while (capacity < needed) {
    capacity <<= 1;
  }
  return capacity;
}

/// A small ring of host-visible device buffers for one updatable attribute
/// stream.
///
/// Each [write] advances to the next buffer in the ring before overwriting,
/// so the GPU keeps reading the previously bound buffer while the CPU writes
/// the next one. The ring depth matches the frame count the engine's
/// transient `HostBuffer` cycles through, which bounds the GPU's in-flight
/// reads. The ring reallocates (at a power-of-two capacity) only when the
/// vertex count outgrows it, so steady-state updates never allocate.
/// The bounding vertex range that covers both [a] and [b]. An empty input
/// (`start >= end`) contributes nothing. Ranges are half-open
/// `[start, end)`. Used to accumulate which span of a ring buffer is stale
/// relative to the CPU copy, so a partial update uploads only what a given
/// buffer is missing.
({int start, int end}) unionVertexRange(
  ({int start, int end}) a,
  ({int start, int end}) b,
) {
  if (a.start >= a.end) return b;
  if (b.start >= b.end) return a;
  return (
    start: a.start < b.start ? a.start : b.start,
    end: a.end > b.end ? a.end : b.end,
  );
}

// A ring of host-visible device buffers for one updatable attribute stream.
//
// Vertex data must be CPU-written every update, and `hostVisible` is the
// only storage mode that allows that: flutter_gpu has no buffer-to-buffer
// blit or read-back, so a `devicePrivate` buffer cannot be filled after
// allocation. On the coherent and unified-memory backends this is the
// shared CPU/GPU region, so the `flush` after a write is a no-op; on
// non-coherent backends `flush` uploads only the written range. The ring
// hands each update a buffer the GPU is not currently reading, avoiding the
// write-vs-read race.
class _RingBufferStream {
  _RingBufferStream(this.bytesPerVertex);

  /// Tightly packed bytes for one vertex of this attribute.
  final int bytesPerVertex;

  // Matches `gpu.HostBuffer`'s frame count, the number of frames the engine
  // cycles transient buffers through.
  static const int _ringDepth = 4;

  final List<gpu.DeviceBuffer> _buffers = [];
  // Per-buffer span (in vertices) that is stale relative to the current CPU
  // copy. Because the ring rotates, a buffer last written `_ringDepth`
  // writes ago is missing every change made since, so a partial write must
  // refresh that accumulated span, not just the caller's dirty span.
  final List<({int start, int end})> _stale = [];
  int _capacityVertices = 0;
  int _cursor = 0;

  /// Replaces every vertex (the full-stream write used at construction and
  /// on rebuild).
  gpu.BufferView write(Uint8List bytes, int vertexCount) =>
      writeRange(bytes, vertexCount, 0, vertexCount);

  /// Writes [bytes] (the full attribute array) into the ring's next buffer,
  /// uploading only the span that buffer is missing. [dirtyStart] and
  /// [dirtyEnd] mark the half-open vertex range the caller changed since the
  /// last write; the accumulated stale span of the chosen buffer is unioned
  /// in so a rotated, several-writes-old buffer is still brought current.
  gpu.BufferView writeRange(
    Uint8List bytes,
    int vertexCount,
    int dirtyStart,
    int dirtyEnd,
  ) {
    if (_buffers.isEmpty || vertexCount > _capacityVertices) {
      _capacityVertices = nextBufferCapacity(vertexCount);
      _buffers
        ..clear()
        ..addAll(
          List.generate(
            _ringDepth,
            (_) => gpu.gpuContext.createDeviceBuffer(
              gpu.StorageMode.hostVisible,
              _capacityVertices * bytesPerVertex,
            ),
          ),
        );
      // Freshly allocated buffers hold no data, so each is fully stale until
      // it is first written.
      _stale
        ..clear()
        ..addAll(List.filled(_ringDepth, (start: 0, end: vertexCount)));
      _cursor = 0;
    } else {
      _cursor = (_cursor + 1) % _ringDepth;
    }

    // The caller's change makes every buffer stale over that span.
    final change = (start: dirtyStart, end: dirtyEnd);
    for (var i = 0; i < _stale.length; i++) {
      _stale[i] = unionVertexRange(_stale[i], change);
    }

    final buffer = _buffers[_cursor];
    final upload = _stale[_cursor];
    if (upload.end > upload.start) {
      final offset = upload.start * bytesPerVertex;
      final length = (upload.end - upload.start) * bytesPerVertex;
      buffer.overwrite(
        ByteData.sublistView(bytes, offset, offset + length),
        destinationOffsetInBytes: offset,
      );
      buffer.flush(offsetInBytes: offset, lengthInBytes: length);
    }
    // This buffer now matches the CPU copy.
    _stale[_cursor] = (start: 0, end: 0);
    return gpu.BufferView(
      buffer,
      offsetInBytes: 0,
      lengthInBytes: vertexCount * bytesPerVertex,
    );
  }
}

/// Assembles a [MeshGeometry] one vertex and triangle at a time.
///
/// The attribute setters ([normal], [texCoord], [color]) are sticky:
/// each value applies to every [addVertex] call that follows until it is
/// changed. [addVertex] returns the index of the added vertex; when
/// [deduplicate] is set, a vertex equal to one already added is merged
/// and the existing index is returned instead.
///
/// ```dart
/// final geometry = (GeometryBuilder()
///       ..color(Vector4(1, 0, 0, 1))
///       ..addVertex(Vector3(0, 0, 0))
///       ..addVertex(Vector3(1, 0, 0))
///       ..addVertex(Vector3(0, 1, 0))
///       ..addTriangle(0, 1, 2))
///     .build();
/// ```
/// {@category Geometry}
class GeometryBuilder {
  /// Creates an empty builder.
  ///
  /// When [deduplicate] is `true` (the default), [addVertex] merges a
  /// vertex equal to one already added.
  GeometryBuilder({this.deduplicate = true});

  /// Whether [addVertex] merges a vertex equal to one already added.
  final bool deduplicate;

  final List<double> _positions = [];
  final List<double> _normals = [];
  final List<double> _texCoords = [];
  final List<double> _colors = [];
  final List<int> _indices = [];
  final Map<String, int> _vertexLookup = {};

  Vector3 _normal = Vector3(0.0, 0.0, 1.0);
  Vector2 _texCoord = Vector2.zero();
  Vector4 _color = Vector4(1.0, 1.0, 1.0, 1.0);
  bool _normalsAuthored = false;

  /// The number of vertices added so far.
  int get vertexCount => _positions.length ~/ 3;

  /// The number of triangles added so far.
  int get triangleCount => _indices.length ~/ 3;

  /// Sets the normal applied to vertices added after this call.
  ///
  /// Authoring any normal opts the whole mesh out of generated normals;
  /// vertices added without an explicit normal keep the default
  /// `(0, 0, 1)`.
  GeometryBuilder normal(Vector3 value) {
    _normal = value.clone();
    _normalsAuthored = true;
    return this;
  }

  /// Sets the texture coordinate applied to vertices added after this
  /// call.
  GeometryBuilder texCoord(Vector2 value) {
    _texCoord = value.clone();
    return this;
  }

  /// Sets the color applied to vertices added after this call.
  GeometryBuilder color(Vector4 value) {
    _color = value.clone();
    return this;
  }

  /// Adds a vertex at [position] carrying the current sticky attributes
  /// and returns its index.
  int addVertex(Vector3 position) {
    if (deduplicate) {
      final key = _vertexKey(position);
      final existing = _vertexLookup[key];
      if (existing != null) return existing;
      final index = vertexCount;
      _vertexLookup[key] = index;
      _appendVertex(position);
      return index;
    }
    final index = vertexCount;
    _appendVertex(position);
    return index;
  }

  /// Adds a triangle referencing three previously added vertex indices.
  GeometryBuilder addTriangle(int a, int b, int c) {
    final count = vertexCount;
    for (final index in [a, b, c]) {
      if (index < 0 || index >= count) {
        throw RangeError.range(index, 0, count - 1, 'vertex index');
      }
    }
    _indices
      ..add(a)
      ..add(b)
      ..add(c);
    return this;
  }

  /// Packs the accumulated vertices into the interleaved layout.
  ///
  /// Pure and free of GPU resources; [build] uses it, and it can be
  /// exercised directly without a render context.
  Uint8List packVertices() {
    return InterleavedLayoutAdapter.packUnskinned(
      positions: Float32List.fromList(_positions),
      vertexCount: vertexCount,
      normals: _resolveNormals(),
      texCoords: Float32List.fromList(_texCoords),
      colors: Float32List.fromList(_colors),
    );
  }

  /// Builds and GPU-uploads the accumulated mesh.
  ///
  /// Pass [GeometryStorage.updatable] for [storage] to build a mesh that
  /// can be mutated in place afterwards.
  MeshGeometry build({GeometryStorage storage = GeometryStorage.fixed}) {
    return MeshGeometry.fromArrays(
      positions: Float32List.fromList(_positions),
      normals: _resolveNormals(),
      texCoords: Float32List.fromList(_texCoords),
      colors: Float32List.fromList(_colors),
      indices: _indices.isEmpty ? null : List.of(_indices),
      storage: storage,
    );
  }

  Float32List _resolveNormals() {
    if (_normalsAuthored) return Float32List.fromList(_normals);
    return InterleavedLayoutAdapter.generateNormals(
      positions: Float32List.fromList(_positions),
      vertexCount: vertexCount,
      indices: _indices,
    );
  }

  void _appendVertex(Vector3 position) {
    _positions
      ..add(position.x)
      ..add(position.y)
      ..add(position.z);
    _normals
      ..add(_normal.x)
      ..add(_normal.y)
      ..add(_normal.z);
    _texCoords
      ..add(_texCoord.x)
      ..add(_texCoord.y);
    _colors
      ..add(_color.x)
      ..add(_color.y)
      ..add(_color.z)
      ..add(_color.w);
  }

  String _vertexKey(Vector3 position) {
    return '${position.x},${position.y},${position.z},'
        '${_normal.x},${_normal.y},${_normal.z},'
        '${_texCoord.x},${_texCoord.y},'
        '${_color.x},${_color.y},${_color.z},${_color.w}';
  }
}
