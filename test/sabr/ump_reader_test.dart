import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:youtube_explode_dart/src/exceptions/sabr_protocol_exception.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/sabr/ump_reader.dart';

Uint8List _encodeUmpVarint(int value) {
  if (value < 0x80) return Uint8List.fromList([value]);
  if (value < 0x4000) {
    return Uint8List.fromList([
      (value & 0x3f) | 0x80,
      value >> 6,
    ]);
  }
  if (value < 0x200000) {
    return Uint8List.fromList([
      (value & 0x1f) | 0xc0,
      (value >> 5) & 0xff,
      (value >> 13) & 0xff,
    ]);
  }
  throw ArgumentError('Unsupported test varint $value');
}

Uint8List _umpPart(int type, List<int> payload) {
  final b = BytesBuilder()
    ..add(_encodeUmpVarint(type))
    ..add(_encodeUmpVarint(payload.length))
    ..add(payload);
  return b.takeBytes();
}

void main() {
  group('UmpReader', () {
    test('parses multi-byte varints and byte-by-byte splits with streaming MEDIA part', () {
      final mediaPayload = Uint8List.fromList(
        [0, ...List.generate(300, (i) => i & 0xff)],
      );
      final combined = (BytesBuilder()
            ..add(_umpPart(UmpPartType.mediaHeader, [1, 2, 3]))
            ..add(_umpPart(UmpPartType.media, mediaPayload))
            ..add(_umpPart(UmpPartType.mediaEnd, [0])))
          .takeBytes();

      final reader = UmpReader();
      final parts = <(int, List<int>)>[];
      final streamedMedia = BytesBuilder();

      // Feed 1 byte at a time to exercise all straddling header/payload paths.
      for (var i = 0; i < combined.length; i++) {
        reader.feedStreaming(
          chunk: Uint8List.fromList([combined[i]]),
          streamPartType: UmpPartType.media,
          onStreamStart: (_, _) => true,
          onStreamChunk: (data, from, to) {
            streamedMedia.add(data.sublist(from, to));
            return true;
          },
          onStreamEnd: () => true,
          onPart: (type, data, from, to) {
            parts.add((type, data.sublist(from, to)));
            return true;
          },
        );
      }
      reader.finish();

      expect(parts, hasLength(2));
      expect(parts[0].$1, UmpPartType.mediaHeader);
      expect(parts[0].$2, orderedEquals([1, 2, 3]));
      expect(parts[1].$1, UmpPartType.mediaEnd);
      expect(parts[1].$2, orderedEquals([0]));
      expect(streamedMedia.takeBytes(), orderedEquals(mediaPayload));
    });

    test('throws SabrProtocolException on truncated part', () {
      final truncated = _umpPart(UmpPartType.mediaHeader, [1, 2, 3]).sublist(0, 3);
      final reader = UmpReader();
      reader.feedStreaming(
        chunk: truncated,
        streamPartType: UmpPartType.media,
        onStreamStart: (_, _) => true,
        onStreamChunk: (_, _, _) => true,
        onStreamEnd: () => true,
        onPart: (_, _, _, _) => true,
      );
      expect(reader.finish, throwsA(isA<SabrProtocolException>()));
    });
  });
}
