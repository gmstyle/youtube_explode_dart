import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/sabr/proto_wire.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/sabr/sabr_models.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/sabr/sabr_proto_codec.dart';

void main() {
  group('SabrProtoCodec', () {
    test('encodes VideoPlaybackAbrRequest with ClientAbrState, discard range and StreamerContext', () {
      final bootstrap = SabrBootstrap(
        videoId: 'abcdefghijk',
        serverAbrStreamingUrl: 'https://rr1.googlevideo.com/videoplayback?expire=9999999999',
        videoPlaybackUstreamerConfig: Uint8List.fromList([10, 20, 30]),
        clientNameId: 67,
        clientVersion: '1.20260707.12.00',
        audioFormat: const SabrFormatId(251, lastModified: 1700000000000000),
        discardVideoFormat: const SabrFormatId(160, lastModified: 1700000000000000),
        discardVideoHeight: 144,
        durationMs: 180000,
        contentLengthBytes: 2500000,
        mimeType: 'audio/webm',
        poToken: Uint8List.fromList([7, 8, 9]),
      );

      final encoded = SabrProtoCodec.encodeRequest(
        bootstrap: bootstrap,
        playerTimeMs: 12000,
        initialized: true,
        bufferedRanges: const [
          SabrBufferedRange(
            formatId: SabrFormatId(251, lastModified: 1700000000000000),
            startTimeMs: 0,
            durationMs: 12000,
            startSegmentIndex: 1,
            endSegmentIndex: 2,
          ),
        ],
        playbackCookie: Uint8List.fromList([1, 2]),
        contexts: [
          SabrContext(
            type: 5,
            value: Uint8List.fromList([99]),
            sendByDefault: true,
            writePolicy: 1,
          ),
        ],
        activeContextTypes: const {5},
      );

      final r = ProtoReader(encoded);
      final seenFields = <int>[];
      while (r.hasRemaining) {
        final tag = r.tag();
        seenFields.add(tag.field);
        r.skip(tag);
      }

      expect(seenFields, containsAll([1, 2, 3, 5, 16, 17, 19]));
    });

    test('decodes MediaHeader, NextRequestPolicy, StreamProtectionStatus, Redirect and ContextUpdate', () {
      final mh = ProtoWriter()
        ..int32(1, 3)
        ..string(2, 'abcdefghijk')
        ..int32(3, 251)
        ..int64(4, 1700000000)
        ..int64(6, 512)
        ..boolField(8, false)
        ..int32(9, 1)
        ..int64(11, 0)
        ..int64(12, 5000)
        ..int64(14, 4096);
      final decodedHeader = SabrProtoCodec.decodeMediaHeader(mh.toBytes());
      expect(decodedHeader.headerId, 3);
      expect(decodedHeader.formatId.itag, 251);
      expect(decodedHeader.startRange, 512);
      expect(decodedHeader.sequenceNumber, 1);
      expect(decodedHeader.durationMs, 5000);
      expect(decodedHeader.contentLength, 4096);

      final nrp = ProtoWriter()
        ..int64(1, 15000)
        ..int64(3, 60000)
        ..int64(4, 500)
        ..bytes(7, [4, 5, 6]);
      final policy = SabrProtoCodec.decodeNextRequestPolicy(nrp.toBytes());
      expect(policy.targetAudioReadaheadMs, 15000);
      expect(policy.backoffTimeMs, 500);
      expect(policy.playbackCookie, orderedEquals([4, 5, 6]));

      final sps = ProtoWriter()
        ..int32(1, 3)
        ..int32(2, 1);
      final status = SabrProtoCodec.decodeStreamProtectionStatus(sps.toBytes());
      expect(status.status, 3);
      expect(status.maxRetries, 1);

      final redir = ProtoWriter()..string(1, 'https://rr2.googlevideo.com/videoplayback');
      expect(
        SabrProtoCodec.decodeRedirect(redir.toBytes()),
        'https://rr2.googlevideo.com/videoplayback',
      );
    });
  });
}
