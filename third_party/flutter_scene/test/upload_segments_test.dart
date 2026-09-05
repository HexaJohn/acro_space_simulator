// Copyright (c) 2026 John Peroutka
//
// This work is licensed under the PolyForm Noncommercial License 1.0.0.
// To view a copy of this license, visit https://polyformproject.org/licenses/noncommercial/1.0.0/

// Pure-Dart coverage for the no-copy upload patch. Two contracts are pinned
// here without a GPU: the bytes a no-copy upload hands its buffer — the
// caller's own arrays plus repeated defaults, cut into slices of any size —
// are byte-for-byte what the copying path (`unskinnedAttributeStreams`, and
// the retained copies `FixedMeshUploadPlan` keeps) would have uploaded; and
// a plan without `retainCpuData` keeps no attributes, no packed indices, and
// still the bounds. `MeshGeometry` itself needs a context to allocate a
// buffer, so the plan it adopts is what is tested.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_scene/src/geometry/geometry.dart';
import 'package:flutter_scene/src/geometry/interleaved_layout.dart';
import 'package:flutter_scene/src/geometry/mesh_geometry.dart';
import 'package:flutter_scene/src/gpu/gpu.dart' as gpu;
import 'package:flutter_test/flutter_test.dart';

/// The bytes of [segment] as an upload would lay them down, moving at most
/// [sliceBytes] per call — the way a staged upload steps through it — and
/// checking that every piece lands where its offset says.
Uint8List _materialize(UploadSegment segment, {int sliceBytes = 0}) {
  final out = Uint8List(segment.lengthInBytes);
  final step = sliceBytes <= 0 ? segment.lengthInBytes : sliceBytes;
  var at = 0;
  while (at < segment.lengthInBytes) {
    final length = math.min(step, segment.lengthInBytes - at);
    var expectedNext = at;
    for (final piece in segment.pieces(at, length)) {
      expect(piece.offsetInSegment, expectedNext, reason: 'pieces must tile');
      final bytes = piece.view.buffer.asUint8List(
        piece.view.offsetInBytes,
        piece.view.lengthInBytes,
      );
      out.setRange(piece.offsetInSegment, piece.offsetInSegment + bytes.length,
          bytes);
      expectedNext += bytes.length;
    }
    expect(expectedNext, at + length, reason: 'pieces must cover the slice');
    at += length;
  }
  return out;
}

Uint8List _concat(List<UploadSegment> segments, {int sliceBytes = 0}) {
  final total = segments.fold(0, (n, s) => n + s.lengthInBytes);
  final out = Uint8List(total);
  var at = 0;
  for (final s in segments) {
    out.setRange(at, at + s.lengthInBytes,
        _materialize(s, sliceBytes: sliceBytes));
    at += s.lengthInBytes;
  }
  return out;
}

Uint8List _concatStreams(UnskinnedAttributeStreams s) =>
    InterleavedLayoutAdapter.concatUnskinnedStreams(s);

/// Whether [view] is a window onto [source]'s memory rather than a copy: a
/// write through [source] shows through [view]. (`ByteBuffer` wrappers are
/// not identical across calls, so identity is no test of aliasing.) The
/// source is restored afterwards.
bool _aliases(ByteData view, Float32List source) {
  final was = source[0];
  source[0] = was + 1;
  final seen = view.getFloat32(0, Endian.host) == source[0];
  source[0] = was;
  return seen;
}

/// A little mesh with unmistakable attribute values: every float different,
/// so a stream uploaded out of phase or from the wrong array shows.
({
  Float32List positions,
  Float32List normals,
  Float32List texCoords,
  Float32List colors,
  List<int> indices,
})
_mesh(int vertexCount) {
  final rng = math.Random(vertexCount);
  Float32List floats(int n) {
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = rng.nextDouble() * 200 - 100;
    }
    return out;
  }

  final indices = <int>[];
  for (var i = 0; i + 2 < vertexCount; i += 3) {
    indices.addAll([i, i + 1, i + 2]);
  }
  return (
    positions: floats(vertexCount * 3),
    normals: floats(vertexCount * 3),
    texCoords: floats(vertexCount * 2),
    colors: floats(vertexCount * 4),
    indices: indices,
  );
}

void main() {
  group('UploadSegment', () {
    test('a bytes segment is one piece, wherever it is sliced', () {
      final bytes = Uint8List.fromList(List.generate(100, (i) => i));
      final s = UploadSegment.bytes(ByteData.sublistView(bytes));
      expect(s.isRepeated, isFalse);
      expect(s.lengthInBytes, 100);
      expect(_materialize(s), bytes);
      expect(_materialize(s, sliceBytes: 7), bytes);
      expect(s.pieces(10, 20).length, 1);
      expect(s.pieces(10, 0), isEmpty);
    });

    test('a repeated segment reproduces the pattern in phase at any cut', () {
      // A block of two patterns, so slices that straddle the block edge are
      // easy to come by; the segment ends on a partial pattern.
      final block = Uint8List.fromList([1, 2, 3, 1, 2, 3]);
      final s = UploadSegment.repeated(20, block);
      expect(s.isRepeated, isTrue);
      final want = Uint8List.fromList(List.generate(20, (i) => 1 + i % 3));
      for (final slice in [0, 1, 2, 3, 5, 6, 7, 11, 13, 20, 64]) {
        expect(_materialize(s, sliceBytes: slice), want,
            reason: 'sliced $slice at a time');
      }
      // Every piece is at most a block long and never straddles the block.
      for (final p in s.pieces(0, 20)) {
        expect(p.view.lengthInBytes, lessThanOrEqualTo(block.length));
      }
      expect(s.pieces(0, 20).length, 4);
    });

    test('rejects a run outside the segment', () {
      final s = UploadSegment.repeated(8, Uint8List.fromList([9, 9]));
      expect(() => s.pieces(4, 8).toList(), throwsRangeError);
      expect(() => s.pieces(-1, 1).toList(), throwsRangeError);
      expect(() => UploadSegment.repeated(4, Uint8List(0)),
          throwsArgumentError);
    });

    test('the default blocks are in phase with every stream stride', () {
      const b = InterleavedLayoutAdapter.defaultBlockBytes;
      expect(b % InterleavedLayoutAdapter.normalStreamBytes, 0);
      expect(b % InterleavedLayoutAdapter.texCoordStreamBytes, 0);
      expect(b % InterleavedLayoutAdapter.colorStreamBytes, 0);
      expect(InterleavedLayoutAdapter.defaultNormalBlock.length, b);
      expect(InterleavedLayoutAdapter.defaultTexCoordBlock.length, b);
      expect(InterleavedLayoutAdapter.defaultColorBlock.length, b);
      final normals = InterleavedLayoutAdapter.defaultNormalBlock.buffer
          .asFloat32List();
      expect(normals.sublist(0, 6), [0, 0, 1, 0, 0, 1]);
      final colors = InterleavedLayoutAdapter.defaultColorBlock.buffer
          .asFloat32List();
      expect(colors.every((c) => c == 1.0), isTrue);
    });
  });

  group('unskinnedUploadSegments', () {
    // Every combination of present and absent optional attributes, at a
    // vertex count that makes the repeated defaults span several blocks
    // (so the block edge is crossed many times) and end mid-block.
    const vertexCount = 4096 * 3 + 7;
    final m = _mesh(vertexCount);

    for (final normals in [true, false]) {
      for (final texCoords in [true, false]) {
        for (final colors in [true, false]) {
          test(
            'matches the copying path '
            '(normals: $normals, texCoords: $texCoords, colors: $colors)',
            () {
              final copying = _concatStreams(
                InterleavedLayoutAdapter.unskinnedAttributeStreams(
                  positions: m.positions,
                  vertexCount: vertexCount,
                  normals: normals ? m.normals : null,
                  texCoords: texCoords ? m.texCoords : null,
                  colors: colors ? m.colors : null,
                ),
              );
              final segments = InterleavedLayoutAdapter.unskinnedUploadSegments(
                positions: m.positions,
                vertexCount: vertexCount,
                normals: normals ? m.normals : null,
                texCoords: texCoords ? m.texCoords : null,
                colors: colors ? m.colors : null,
              );
              expect(segments, hasLength(4));
              expect(segments[0].isRepeated, isFalse);
              expect(segments[1].isRepeated, !normals);
              expect(segments[2].isRepeated, !texCoords);
              expect(segments[3].isRepeated, !colors);
              // Whole, and in slices of sizes that are not multiples of any
              // stride, nor of the block.
              expect(_concat(segments), copying);
              expect(_concat(segments, sliceBytes: 1000), copying);
              expect(_concat(segments, sliceBytes: 65521), copying);
              expect(_concat(segments, sliceBytes: 5), copying);
            },
          );
        }
      }
    }

    test('a supplied attribute is the caller\'s own bytes, not a copy', () {
      final segments = InterleavedLayoutAdapter.unskinnedUploadSegments(
        positions: m.positions,
        vertexCount: vertexCount,
        normals: m.normals,
      );
      final piece = segments[0].pieces(0, 12).single;
      expect(_aliases(piece.view, m.positions), isTrue);
      final normal = segments[1].pieces(0, 12).single;
      expect(_aliases(normal.view, m.normals), isTrue);
      expect(_aliases(normal.view, m.positions), isFalse);
    });

    test('an empty mesh is four empty segments', () {
      final segments = InterleavedLayoutAdapter.unskinnedUploadSegments(
        positions: Float32List(0),
        vertexCount: 0,
      );
      for (final s in segments) {
        expect(s.lengthInBytes, 0);
        expect(s.pieces(0, 0), isEmpty);
      }
    });

    test('a ragged attribute is refused, as the copying path refuses it', () {
      expect(
        () => InterleavedLayoutAdapter.unskinnedUploadSegments(
          positions: m.positions,
          vertexCount: vertexCount,
          texCoords: Float32List(vertexCount * 2 - 1),
        ),
        throwsArgumentError,
      );
    });
  });

  group('FixedMeshUploadPlan', () {
    const vertexCount = 300;
    final m = _mesh(vertexCount);

    FixedMeshUploadPlan plan({
      required bool retain,
      bool normals = true,
      bool texCoords = true,
      bool colors = true,
      bool indices = true,
    }) => FixedMeshUploadPlan(
      positions: m.positions,
      normals: normals ? m.normals : null,
      texCoords: texCoords ? m.texCoords : null,
      colors: colors ? m.colors : null,
      indices: indices ? m.indices : null,
      retainCpuData: retain,
    );

    test('the two contracts upload the same bytes', () {
      for (final normals in [true, false]) {
        for (final texCoords in [true, false]) {
          for (final colors in [true, false]) {
            final kept = plan(
              retain: true,
              normals: normals,
              texCoords: texCoords,
              colors: colors,
            );
            final dropped = plan(
              retain: false,
              normals: normals,
              texCoords: texCoords,
              colors: colors,
            );
            expect(_concat(dropped.segments, sliceBytes: 333),
                _concat(kept.segments),
                reason: 'normals $normals texCoords $texCoords colors $colors');
            expect(dropped.indexBytes!.buffer.asUint8List(),
                kept.indexBytes!.buffer.asUint8List());
            expect(dropped.indexType, kept.indexType);
          }
        }
      }
    });

    test('with retainCpuData the copies are the segments', () {
      final p = plan(retain: true);
      final cpu = p.cpuStreams!;
      expect(cpu.positions, m.positions);
      expect(identical(cpu.positions, m.positions), isFalse,
          reason: 'a retained copy, so the caller may reuse its array');
      expect(cpu.normals, m.normals);
      expect(cpu.texCoords, m.texCoords);
      expect(cpu.colors, m.colors);
      final view = p.segments[0].pieces(0, 12).single.view;
      expect(_aliases(view, cpu.positions), isTrue,
          reason: 'the retained copy is what is uploaded');
      expect(_aliases(view, m.positions), isFalse,
          reason: 'and the caller\'s array is not');
      expect(p.packedIndexBytes, isNotNull);
      expect(p.segments.every((s) => !s.isRepeated), isTrue);
    });

    test('without retainCpuData nothing is kept but the bounds', () {
      final p = plan(retain: false, colors: false);
      expect(p.cpuStreams, isNull);
      expect(p.packedIndexBytes, isNull);
      expect(p.packedIndices32Bit, isFalse);
      expect(p.indexBytes, isNotNull, reason: 'the upload still needs them');
      expect(p.segments[3].isRepeated, isTrue);
      expect(
        _aliases(p.segments[0].pieces(0, 12).single.view, m.positions),
        isTrue,
        reason: 'the caller\'s own bytes',
      );
      final bounds = p.bounds!;
      final want = Geometry.boundsOfPositions(m.positions, vertexCount)!;
      expect(bounds.min, want.min);
      expect(bounds.max, want.max);
      expect(plan(retain: true).bounds!.min, want.min);
      expect(plan(retain: true).bounds!.max, want.max);
    });

    test('generated normals reach the buffer either way', () {
      final kept = plan(retain: true, normals: false);
      final dropped = plan(retain: false, normals: false);
      expect(dropped.segments[1].isRepeated, isFalse,
          reason: 'a triangle list generates its normals');
      expect(_materialize(dropped.segments[1]),
          _materialize(kept.segments[1]));
      expect(_materialize(dropped.segments[1]).buffer.asFloat32List(),
          isNot(everyElement(0)));
    });

    test('a non-indexed mesh has no index segment', () {
      final p = plan(retain: false, indices: false);
      expect(p.indexBytes, isNull);
      expect(p.indexType, gpu.IndexType.int16);
    });

    test('an empty mesh has no bounds', () {
      final p = FixedMeshUploadPlan(
        positions: Float32List(0),
        retainCpuData: false,
      );
      expect(p.vertexCount, 0);
      expect(p.bounds, isNull);
      expect(p.segments.every((s) => s.lengthInBytes == 0), isTrue);
    });

    test('a staged layout of the segments is the fromArrays layout', () {
      // Streams in slot order, then the indices: the buffer StagedMeshUpload
      // cuts is laid out as Geometry._uploadSegments lays it out.
      final p = plan(retain: false);
      final layout = StagedUploadLayout([
        for (final s in p.segments) s.lengthInBytes,
        p.indexBytes!.lengthInBytes,
      ]);
      expect(layout.segmentOffsets, [
        0,
        vertexCount * 12,
        vertexCount * 24,
        vertexCount * 32,
        vertexCount * 48,
      ]);
      expect(layout.totalBytes, vertexCount * 48 + m.indices.length * 2);
    });
  });
}
