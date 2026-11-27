import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:youtube_explode_dart/src/exceptions/sabr_protocol_exception.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/sabr/proto_wire.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/sabr/sabr_models.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/sabr/sabr_ump_processor.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/sabr/ump_reader.dart';

Uint8List _encodeUmpVarint(int value) {
  if (value < 0x80) return Uint8List.fromList([value]);
  if (value < 0x4000) {
    return Uint8List.fromList([(value & 0x3f) | 0x80, value >> 6]);
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
      final mediaPayload = Uint8List.fromList([
        0,
        ...List.generate(300, (i) => i & 0xff),
      ]);
      final combined =
          (BytesBuilder()
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
      final truncated = _umpPart(UmpPartType.mediaHeader, [
        1,
        2,
        3,
      ]).sublist(0, 3);
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

    test('SabrUmpProcessor preserves buffered MEDIA bytes when reader reuses internal buffer', () {
      final mediaBytes = Uint8List.fromList(List.generate(64, (i) => i + 10));
      final hdr =
          (ProtoWriter()
                ..int32(1, 0)
                ..string(2, 'abcdefghijk')
                ..int32(3, 251)
                ..int64(4, 1700000)
                ..int64(6, 0)
                ..boolField(8, false)
                ..int32(9, 1)
                ..int64(11, 0)
                ..int64(12, 1000)
                ..int64(14, mediaBytes.length))
              .toBytes();

      final part1 = _umpPart(UmpPartType.mediaHeader, hdr);
      final part2 = _umpPart(UmpPartType.media, [0, ...mediaBytes]);
      final part3 = _umpPart(UmpPartType.mediaEnd, [0]);

      // Split right inside the MEDIA header so UmpReader copies it into _buffer,
      // then follow with the rest of MEDIA and another buffered part (MEDIA_END)
      // that will overwrite _buffer.
      final splitAt = part1.length + 1;
      final combined =
          (BytesBuilder()
                ..add(part1)
                ..add(part2)
                ..add(part3))
              .takeBytes();
      final chunkA = combined.sublist(0, splitAt);
      final chunkB = combined.sublist(splitAt, combined.length - 1);
      final chunkC = combined.sublist(combined.length - 1);

      final processor = SabrUmpProcessor();
      final events = <SabrEvent>[];
      processor.feed(chunkA, onEvent: events.add);
      processor.feed(chunkB, onEvent: events.add);
      processor.feed(chunkC, onEvent: events.add);
      processor.finish();

      final segEvent = events.whereType<SabrSegmentEvent>().single;
      expect(segEvent.segment.data, orderedEquals(mediaBytes));
    });
  });
}
