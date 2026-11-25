import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:youtube_explode_dart/src/exceptions/sabr_protocol_exception.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/sabr/proto_wire.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/sabr/sabr_models.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/sabr/sabr_stream.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/sabr/ump_reader.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/youtube_http_client.dart';

Uint8List _umpVarint(int value) {
  if (value < 0x80) return Uint8List.fromList([value]);
  if (value < 0x4000) return Uint8List.fromList([(value & 0x3f) | 0x80, value >> 6]);
  return Uint8List.fromList([(value & 0x1f) | 0xc0, (value >> 5) & 0xff, (value >> 13) & 0xff]);
}

Uint8List _part(int type, List<int> payload) => (BytesBuilder()
      ..add(_umpVarint(type))
      ..add(_umpVarint(payload.length))
      ..add(payload))
    .takeBytes();

Uint8List _mediaHeader({
  required int headerId,
  required int itag,
  required int startRange,
  required bool isInit,
  required int seq,
  required int startMs,
  required int durationMs,
  required int contentLength,
}) {
  final w = ProtoWriter()
    ..int32(1, headerId)
    ..string(2, 'abcdefghijk')
    ..int32(3, itag)
    ..int64(4, 1700000)
    ..int64(6, startRange)
    ..boolField(8, isInit)
    ..int32(9, seq)
    ..int64(11, startMs)
    ..int64(12, durationMs)
    ..int64(14, contentLength);
  return w.toBytes();
}

void main() {
  SabrBootstrap makeBootstrap({Uint8List? poToken, int? contentLengthBytes}) =>
      SabrBootstrap(
        videoId: 'abcdefghijk',
        serverAbrStreamingUrl: 'https://rr1.googlevideo.com/videoplayback?id=1',
        videoPlaybackUstreamerConfig: Uint8List.fromList([1, 2, 3]),
        clientNameId: 101,
        clientVersion: '1.02',
        audioFormat: const SabrFormatId(251, lastModified: 1700000),
        discardVideoFormat: const SabrFormatId(160, lastModified: 1700000),
        discardVideoHeight: 144,
        durationMs: 10000,
        contentLengthBytes: contentLengthBytes,
        mimeType: 'audio/webm',
        poToken: poToken,
      );

  group('SabrStream', () {
    test('handles redirect, out-of-order segments, and completes', () async {
      var callIndex = 0;
      final hostsSeen = <String>[];
      final initBytes = Uint8List.fromList([10, 11, 12, 13]);
      final seg1Bytes = Uint8List.fromList([20, 21, 22, 23, 24]);
      final seg2Bytes = Uint8List.fromList([30, 31, 32, 33, 34, 35]);

      final mockClient = MockClient((req) async {
        hostsSeen.add(req.url.host);
        callIndex++;
        if (callIndex == 1) {
          final redir = (ProtoWriter()
                ..string(1, 'https://rr2.googlevideo.com/videoplayback?id=1'))
              .toBytes();
          final cookie = (ProtoWriter()..bytes(7, [9, 9])).toBytes();
          final body = (BytesBuilder()
                ..add(_part(UmpPartType.sabrRedirect, redir))
                ..add(_part(UmpPartType.nextRequestPolicy, cookie))
                ..add(_part(UmpPartType.mediaHeader, _mediaHeader(
                  headerId: 0,
                  itag: 251,
                  startRange: 0,
                  isInit: true,
                  seq: 0,
                  startMs: 0,
                  durationMs: 0,
                  contentLength: initBytes.length,
                )))
                ..add(_part(UmpPartType.media, [0, ...initBytes]))
                ..add(_part(UmpPartType.mediaEnd, [0])))
              .takeBytes();
          return http.Response.bytes(
            body,
            200,
            headers: {'content-type': 'application/vnd.yt-ump'},
            request: req,
          );
        }

        final fmtInit = (ProtoWriter()
              ..message(2, (f) => f..int32(1, 251)..int64(2, 1700000))
              ..int64(3, 10000)
              ..int32(4, 2))
            .toBytes();
        // Send segment 2 before segment 1 to verify sequence reordering!
        final body = (BytesBuilder()
              ..add(_part(UmpPartType.formatInitializationMetadata, fmtInit))
              ..add(_part(UmpPartType.mediaHeader, _mediaHeader(
                headerId: 2,
                itag: 251,
                startRange: 9,
                isInit: false,
                seq: 2,
                startMs: 5000,
                durationMs: 5000,
                contentLength: seg2Bytes.length,
              )))
              ..add(_part(UmpPartType.media, [2, ...seg2Bytes]))
              ..add(_part(UmpPartType.mediaEnd, [2]))
              ..add(_part(UmpPartType.mediaHeader, _mediaHeader(
                headerId: 1,
                itag: 251,
                startRange: 4,
                isInit: false,
                seq: 1,
                startMs: 0,
                durationMs: 5000,
                contentLength: seg1Bytes.length,
              )))
              ..add(_part(UmpPartType.media, [1, ...seg1Bytes]))
              ..add(_part(UmpPartType.mediaEnd, [1]))
              ..add(_part(UmpPartType.endOfTrack, [])))
            .takeBytes();
        return http.Response.bytes(
          body,
          200,
          headers: {'content-type': 'application/vnd.yt-ump'},
          request: req,
        );
      });

      final httpClient = YoutubeHttpClient(mockClient);
      addTearDown(httpClient.close);

      final chunks = await SabrStream(
        httpClient: httpClient,
        bootstrap: makeBootstrap(
          contentLengthBytes: initBytes.length + seg1Bytes.length + seg2Bytes.length,
        ),
        retryDelay: (_) async {},
      ).chunks().toList();

      expect(hostsSeen, equals(['rr1.googlevideo.com', 'rr2.googlevideo.com']));
      expect(chunks.map((c) => c.sequenceNumber).toList(), [null, 1, 2]);
      expect(chunks[0].isInitialization, isTrue);
      expect(chunks[1].startRange, 4);
      expect(chunks[2].startRange, 9);
    });

    test('triggers lateTokenSupplier on StreamProtectionStatus = 3 and retries', () async {
      var requests = 0;
      final initBytes = Uint8List.fromList([1, 2]);
      final segBytes = Uint8List.fromList([3, 4, 5]);

      final mockClient = MockClient((req) async {
        requests++;
        if (requests == 1) {
          final sps = (ProtoWriter()..int32(1, 3)).toBytes();
          return http.Response.bytes(
            _part(UmpPartType.streamProtectionStatus, sps),
            200,
            headers: {'content-type': 'application/vnd.yt-ump'},
            request: req,
          );
        }
        // Verify request 2 includes the late PO token bytes!
        expect(req.bodyBytes, isNotEmpty);
        final fmtInit = (ProtoWriter()
              ..message(2, (f) => f..int32(1, 251)..int64(2, 1700000))
              ..int64(3, 10000)
              ..int32(4, 1))
            .toBytes();
        final body = (BytesBuilder()
              ..add(_part(UmpPartType.formatInitializationMetadata, fmtInit))
              ..add(_part(UmpPartType.mediaHeader, _mediaHeader(
                headerId: 0,
                itag: 251,
                startRange: 0,
                isInit: true,
                seq: 0,
                startMs: 0,
                durationMs: 0,
                contentLength: initBytes.length,
              )))
              ..add(_part(UmpPartType.media, [0, ...initBytes]))
              ..add(_part(UmpPartType.mediaEnd, [0]))
              ..add(_part(UmpPartType.mediaHeader, _mediaHeader(
                headerId: 1,
                itag: 251,
                startRange: 2,
                isInit: false,
                seq: 1,
                startMs: 0,
                durationMs: 10000,
                contentLength: segBytes.length,
              )))
              ..add(_part(UmpPartType.media, [1, ...segBytes]))
              ..add(_part(UmpPartType.mediaEnd, [1]))
              ..add(_part(UmpPartType.endOfTrack, [])))
            .takeBytes();
        return http.Response.bytes(
          body,
          200,
          headers: {'content-type': 'application/vnd.yt-ump'},
          request: req,
        );
      });

      final httpClient = YoutubeHttpClient(mockClient);
      addTearDown(httpClient.close);

      final bytes = await SabrStream(
        httpClient: httpClient,
        bootstrap: makeBootstrap(),
        lateTokenSupplier: () async => Uint8List.fromList([99, 100, 101]),
        retryDelay: (_) async {},
      ).bytes().expand((e) => e).toList();

      expect(requests, 2);
      expect(bytes, orderedEquals([1, 2, 3, 4, 5]));
    });

    test('throws SabrProtocolException(attestationRequired) when SPS=3 and no token', () async {
      final mockClient = MockClient((req) async {
        final sps = (ProtoWriter()..int32(1, 3)).toBytes();
        return http.Response.bytes(
          _part(UmpPartType.streamProtectionStatus, sps),
          200,
          headers: {'content-type': 'application/vnd.yt-ump'},
          request: req,
        );
      });

      final httpClient = YoutubeHttpClient(mockClient);
      addTearDown(httpClient.close);

      await expectLater(
        SabrStream(
          httpClient: httpClient,
          bootstrap: makeBootstrap(),
          retryDelay: (_) async {},
        ).bytes().drain<void>(),
        throwsA(
          isA<SabrProtocolException>().having(
            (e) => e.kind,
            'kind',
            SabrFailureKind.attestationRequired,
          ),
        ),
      );
    });
  });
}
