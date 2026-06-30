import 'dart:typed_data';

/// Upper bound on a single frame. A length prefix larger than this is treated
/// as a protocol error (corrupt/hostile peer) rather than buffered — without a
/// cap, one bad 4-byte prefix wedges the connection and grows memory unbounded.
const int kMaxFrameBytes = 16 * 1024 * 1024;

/// Length-prefixed framing for the engine-bridge TCP transport.
///
/// Each message on the stream is: a uint32 LITTLE-ENDIAN payload length,
/// followed by exactly that many payload bytes (one FlatBuffer frame). Little
/// endian is chosen so an x86/x64 consumer (Unreal on desktop) can read the
/// length with a plain memcpy — no byte-swap.
Uint8List frameMessage(Uint8List payload) {
  assert(payload.length <= kMaxFrameBytes, 'frame too large: ${payload.length}');
  final out = Uint8List(4 + payload.length);
  ByteData.view(out.buffer).setUint32(0, payload.length, Endian.little);
  out.setRange(4, out.length, payload);
  return out;
}

/// Incremental de-framer: feed it raw socket chunks, get back complete
/// payloads. Holds partial data between chunks, so a frame split across TCP
/// segments (or several frames in one segment) is handled.
class FrameParser {
  final BytesBuilder _buf = BytesBuilder(copy: true);
  Uint8List _pending = Uint8List(0);

  /// Returns every complete payload available now. EAGER (not a lazy generator):
  /// internal accumulator state is fully updated before returning, so a caller
  /// that abandons the result list mid-way can never drop or duplicate bytes.
  ///
  /// Throws [FormatException] on a length prefix exceeding [kMaxFrameBytes];
  /// the caller should drop the connection (the stream cannot be re-synced).
  List<Uint8List> addChunk(List<int> chunk) {
    _buf
      ..add(_pending)
      ..add(chunk);
    final data = _buf.takeBytes();
    final out = <Uint8List>[];
    var offset = 0;
    while (data.length - offset >= 4) {
      final len = ByteData.view(data.buffer, data.offsetInBytes + offset, 4)
          .getUint32(0, Endian.little);
      if (len > kMaxFrameBytes) {
        _pending = Uint8List(0);
        throw FormatException('frame length $len exceeds max $kMaxFrameBytes');
      }
      if (data.length - offset - 4 < len) break;
      out.add(Uint8List.sublistView(data, offset + 4, offset + 4 + len));
      offset += 4 + len;
    }
    _pending = Uint8List.sublistView(data, offset);
    return out;
  }
}
