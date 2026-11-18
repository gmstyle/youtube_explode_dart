import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

void main() {
  group('YoutubeApiClient payloads', () {
    test('androidVr defines a native Quest 3 userAgent', () {
      final client =
          YoutubeApiClient.androidVr.payload['context']['client']
              as Map<String, dynamic>;
      expect(client['userAgent'], isA<String>());
      expect((client['userAgent'] as String), contains('Quest 3'));
    });

    test('stream clients include contentCheckOk and racyCheckOk', () {
      for (final client in [
        YoutubeApiClient.visionos,
        YoutubeApiClient.androidVr,
        YoutubeApiClient.ios,
        YoutubeApiClient.androidMusic,
        YoutubeApiClient.tv,
      ]) {
        expect(client.payload['contentCheckOk'], isTrue);
        expect(client.payload['racyCheckOk'], isTrue);
      }
    });
  });

  group('StreamClient offline manifest resolution', () {
    test('stops at the first client that yields valid streams', () async {
      final playerClientsCalled = <String>[];
      final mockClient = MockClient((req) async {
        if (req.url.path.endsWith('/youtubei/v1/player')) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final clientName = body['context']['client']['clientName'] as String;
          playerClientsCalled.add(clientName);
          expect(req.headers['Sec-Fetch-Mode'], isNull);

          return http.Response(
            jsonEncode({
              'playabilityStatus': {'status': 'OK'},
              'videoDetails': {
                'videoId': 'abcdefghijk',
                'title': 'Song',
                'author': 'Artist',
                'lengthSeconds': '120',
                'channelId': 'UC123',
              },
              'streamingData': {
                'adaptiveFormats': [
                  {
                    'itag': 140,
                    'url':
                        'https://cdn.example.com/videoplayback?itag=140&c=$clientName',
                    'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
                    'bitrate': 128000,
                    'contentLength': '1024',
                    'qualityLabel': 'medium',
                  },
                ],
              },
            }),
            200,
            request: req,
          );
        }
        if (req.method == 'HEAD') {
          return http.Response(
            '',
            200,
            headers: {'content-length': '1024'},
            request: req,
          );
        }
        return http.Response('Not found', 404, request: req);
      });

      final yt = YoutubeExplode(httpClient: YoutubeHttpClient(mockClient));
      addTearDown(yt.close);

      final manifest = await yt.videos.streams.getManifest(
        'abcdefghijk',
        ytClients: const [
          YoutubeApiClient.visionos,
          YoutubeApiClient.androidVr,
        ],
        requireWatchPage: false,
      );

      expect(manifest.audioOnly, hasLength(1));
      expect(playerClientsCalled, equals(['VISIONOS']));
    });

    test('fetches watchPage for STS and deciphers signatureCipher when solver is null', () async {
      final stsSeen = <String?>[];
      Uri? headUrl;

      final mockClient = MockClient((req) async {
        if (req.url.path == '/watch') {
          return http.Response(
            '''
<!doctype html><html><head>
<meta property="og:url" content="https://www.youtube.com/watch?v=abcdefghijk">
<script>
ytcfg.set({"VISITOR_DATA":"vd-1","INNERTUBE_CONTEXT":{"client":{"visitorData":"vd-1"}}});
ytcfg.set({"STS":20123});
</script>
<script src="/s/player/12345/player_ias.vflset/en_US/base.js"></script>
</head><body><div id="player"></div></body></html>
''',
            200,
            headers: {'set-cookie': 'YSC=abc; Path=/; Domain=.youtube.com'},
            request: req,
          );
        }
        if (req.url.path.endsWith('/base.js')) {
          return http.Response(
            'var signatureTimestamp:20123;'
            'var _x={aa:function(a){a.reverse()},bb:function(a,b){a.splice(0,b)}};'
            '_y=function(a){a=a.split("");_x.aa(a,2);_x.bb(a,1);return a.join("")};',
            200,
            request: req,
          );
        }
        if (req.url.path.endsWith('/youtubei/v1/player')) {
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final sts =
              body['playbackContext']?['contentPlaybackContext']?['signatureTimestamp']
                  as String?;
          stsSeen.add(sts);
          expect(body['contentCheckOk'], isTrue);
          expect(body['racyCheckOk'], isTrue);
          return http.Response(
            jsonEncode({
              'playabilityStatus': {'status': 'OK'},
              'videoDetails': {
                'videoId': 'abcdefghijk',
                'title': 'Song',
                'author': 'Artist',
                'lengthSeconds': '120',
                'channelId': 'UC123',
              },
              'streamingData': {
                'adaptiveFormats': [
                  {
                    'itag': 140,
                    'signatureCipher': 's=abcd&sp=sig&url=https%3A%2F%2Fcdn.example.com%2Fvideoplayback%3Fitag%3D140',
                    'mimeType': 'audio/mp4; codecs="mp4a.40.2"',
                    'bitrate': 128000,
                    'contentLength': '2048',
                    'qualityLabel': 'medium',
                  },
                ],
              },
            }),
            200,
            request: req,
          );
        }
        if (req.method == 'HEAD') {
          headUrl = req.url;
          return http.Response(
            '',
            200,
            headers: {'content-length': '2048'},
            request: req,
          );
        }
        return http.Response('Not found', 404, request: req);
      });

      final yt = YoutubeExplode(httpClient: YoutubeHttpClient(mockClient));
      addTearDown(yt.close);

      final manifest = await yt.videos.streams.getManifest(
        'abcdefghijk',
        ytClients: [YoutubeApiClient.tv],
        requireWatchPage: false,
      );

      expect(stsSeen, equals([null, '20123']));
      // "abcd" reversed -> "dcba", splice(0, 1) -> "cba".
      expect(headUrl?.queryParameters['sig'], equals('cba'));
      expect(
        manifest.audioOnly.single.url.queryParameters['sig'],
        equals('cba'),
      );
    });
  });
}
