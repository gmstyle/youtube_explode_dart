import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:youtube_explode_dart/src/exceptions/sabr_protocol_exception.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/sabr/proto_wire.dart';

void main() {
  group('ProtoWriter & ProtoReader', () {
    test('round-trips int32, int64, bool, float32, bytes, string, nested and packed', () {
      final w = ProtoWriter();
      w.int32(1, 101);
      w.int64(2, 1732550000123456);
      w.boolField(3, true);
      w.float32(4, 1.5);
      w.bytes(5, [1, 2, 3, 4]);
      w.string(6, 'WEB_REMIX');
      w.message(7, (sub) {
        sub.int32(1, 67);
        sub.string(2, '1.20260707.12.00');
      });
      w.packedInt32(8, [10, 20, 300]);

      final bytes = w.toBytes();
      final r = ProtoReader(bytes);

      int? f1;
      int? f2;
      bool? f3;
      Uint8List? f5;
      String? f6;
      int? nestedId;
      String? nestedVer;
      final packed = <int>[];

      while (r.hasRemaining) {
        final tag = r.tag();
        switch (tag.field) {
          case 1:
            f1 = r.intValue();
          case 2:
            f2 = r.unsignedValue();
          case 3:
            f3 = r.boolValue();
          case 4:
            r.skip(tag);
          case 5:
            f5 = r.bytes();
          case 6:
            f6 = r.string();
          case 7:
            final sub = r.slice();
            while (sub.hasRemaining) {
              final st = sub.tag();
              if (st.field == 1) nestedId = sub.intValue();
              if (st.field == 2) nestedVer = sub.string();
            }
          case 8:
            final p = r.slice();
            while (p.hasRemaining) {
              packed.add(p.intValue());
            }
          default:
            r.skip(tag);
        }
      }

      expect(f1, 101);
      expect(f2, 1732550000123456);
      expect(f3, isTrue);
      expect(f5, orderedEquals([1, 2, 3, 4]));
      expect(f6, 'WEB_REMIX');
      expect(nestedId, 67);
      expect(nestedVer, '1.20260707.12.00');
      expect(packed, orderedEquals([10, 20, 300]));
    });

    test('rejects truncated varint and oversized field', () {
      expect(
        () => ProtoReader(Uint8List.fromList([0x08, 0x80])).tag(),
        // tag is ok, varint fails:
        returnsNormally,
      );
      final r = ProtoReader(Uint8List.fromList([0x08, 0x80]));
      r.tag();
      expect(() => r.varintBigInt(), throwsA(isA<SabrProtocolException>()));

      final r2 = ProtoReader(Uint8List.fromList([0x12, 0x0a, 1, 2]));
      r2.tag();
      expect(() => r2.bytes(5), throwsA(isA<SabrProtocolException>()));
    });
  });
}
