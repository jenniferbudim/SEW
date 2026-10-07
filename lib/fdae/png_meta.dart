/// Minimal PNG tEXt chunk read/write so the manifest travels inside the
/// encrypted PNG (single file to share/store). No dependency on the `image`
/// package's metadata API.
library;

import 'dart:convert';
import 'dart:typed_data';

final _crcTable = () {
  final t = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    }
    t[n] = c;
  }
  return t;
}();

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >>> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

Uint8List injectTextChunk(Uint8List png, String keyword, String asciiText) {
  final iend = png.length - 12;
  if (iend < 8 || latin1.decode(png.sublist(iend + 4, iend + 8)) != 'IEND') {
    throw const FormatException('PNG does not end with an IEND chunk');
  }
  final body = BytesBuilder()
    ..add(latin1.encode('tEXt'))
    ..add(latin1.encode(keyword))
    ..addByte(0)
    ..add(latin1.encode(asciiText));
  final bodyBytes = body.toBytes();
  final chunk = ByteData(12 + bodyBytes.length - 4);
  chunk.setUint32(0, bodyBytes.length - 4); // data length excludes the type
  final out = Uint8List(chunk.lengthInBytes);
  out.setRange(0, 4, chunk.buffer.asUint8List(0, 4));
  out.setRange(4, 4 + bodyBytes.length, bodyBytes);
  final crc = ByteData(4)..setUint32(0, _crc32(bodyBytes));
  out.setRange(out.length - 4, out.length, crc.buffer.asUint8List());
  return (BytesBuilder()
        ..add(png.sublist(0, iend))
        ..add(out)
        ..add(png.sublist(iend)))
      .toBytes();
}

String? readTextChunk(Uint8List png, String keyword) {
  final bd = ByteData.sublistView(png);
  var p = 8; // skip signature
  while (p + 12 <= png.length) {
    final len = bd.getUint32(p);
    final type = latin1.decode(png.sublist(p + 4, p + 8));
    if (type == 'tEXt') {
      final data = png.sublist(p + 8, p + 8 + len);
      final z = data.indexOf(0);
      if (z > 0 && latin1.decode(data.sublist(0, z)) == keyword) {
        return latin1.decode(data.sublist(z + 1));
      }
    }
    if (type == 'IEND') break;
    p += 12 + len;
  }
  return null;
}
