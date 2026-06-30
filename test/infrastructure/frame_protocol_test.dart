import 'dart:typed_data';

import 'package:acro_space_simulator/infrastructure/bridge/frame_protocol.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List bytes(List<int> b) => Uint8List.fromList(b);

  test('round-trips multiple frames in one chunk', () {
    final parser = FrameParser();
    final chunk = <int>[
      ...frameMessage(bytes([1, 2, 3])),
      ...frameMessage(bytes([9])),
    ];
    final out = parser.addChunk(chunk);
    expect(out.length, 2);
    expect(out[0], bytes([1, 2, 3]));
    expect(out[1], bytes([9]));
  });

  test('reassembles a frame split across chunks', () {
    final parser = FrameParser();
    final framed = frameMessage(bytes([10, 20, 30, 40]));
    expect(parser.addChunk(framed.sublist(0, 3)), isEmpty); // partial
    expect(parser.addChunk(framed.sublist(3)).single, bytes([10, 20, 30, 40]));
  });

  test('handles byte-by-byte fragmentation without dropping data', () {
    final parser = FrameParser();
    final framed = frameMessage(bytes([7, 7, 7]));
    final collected = <Uint8List>[];
    for (final b in framed) {
      collected.addAll(parser.addChunk([b]));
    }
    expect(collected.single, bytes([7, 7, 7]));
  });

  test('rejects an oversize length prefix', () {
    final parser = FrameParser();
    final bad = Uint8List(4);
    ByteData.view(bad.buffer).setUint32(0, kMaxFrameBytes + 1, Endian.little);
    expect(() => parser.addChunk(bad), throwsFormatException);
  });
}
