import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:youtube_explode_dart/js_challenge.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/pages/watch_page.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/sabr/proto_wire.dart';
import 'package:youtube_explode_dart/src/reverse_engineering/sabr/ump_reader.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class _PolicyFakePoProvider extends BasePoTokenProvider {
  int calls = 0;

  @override
  Future<PoTokenResult?> getPoToken({
    required YoutubeApiClient client,
    required VideoId videoId,
    String? visitorData,
    WatchPage? watchPage,
    bool forceRefresh = false,
  }) async {
    calls++;
    return PoTokenResult(
      sessionPoToken: 'sess-pot-$calls',
      streamingDataPoToken: base64Url.encode([1, 2, 3]),
      visitorData: 'vd-po-1',
      signatureTimestamp: '20999',
    );
  }
}

Uint8List _testUmpPart(int type, List<int> payload) {
  final b = BytesBuilder();
  void addVarint(int v) {
    if (v < 0x80) {
      b.addByte(v);
    } else {
      b.addByte((v & 0x3f) | 0x80);
      b.addByte(v >> 6);
    }
  }
  addVarint(type);
  addVarint(payload.length);
  b.add(payload);
  return b.takeBytes();
}

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

    test('preserves Title-Case User-Agent on player and HEAD probe and omits Origin on native clients', () async {
      final recordedPlayerReqs = <http.Request>[];
      final recordedHeadReqs = <http.Request>[];
      final mockClient = MockClient((req) async {
        if (req.url.path.endsWith('/youtubei/v1/player')) {
          recordedPlayerReqs.add(req);
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final clientName = body['context']['client']['clientName'] as String;
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
          recordedHeadReqs.add(req);
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

      final questUa =
          (YoutubeApiClient.androidVr.payload['context']
                  as Map)['client']['userAgent']
              as String;

      await yt.videos.streams.getManifest(
        'abcdefghijk',
        ytClients: const [YoutubeApiClient.androidVr],
        requireWatchPage: false,
      );
      await yt.videos.streams.getManifest(
        'abcdefghijk',
        ytClients: const [YoutubeApiClient.visionos],
        requireWatchPage: false,
      );
      await yt.videos.streams.getManifest(
        'abcdefghijk',
        ytClients: const [YoutubeApiClient.androidMusic],
        requireWatchPage: false,
      );
      await yt.videos.streams.getManifest(
        'abcdefghijk',
        ytClients: const [YoutubeApiClient.tv],
        requireWatchPage: false,
      );

      final vrPlayer = recordedPlayerReqs[0];
      final vrUaHeaders = vrPlayer.headers.entries
          .where((e) => e.key.toLowerCase() == 'user-agent')
          .toList();
      expect(vrUaHeaders, hasLength(1));
      expect(vrUaHeaders.single.value, questUa);
      expect(vrPlayer.headers.containsKey('Origin'), isFalse);

      expect(recordedPlayerReqs[1].headers.containsKey('Origin'), isFalse);
      expect(recordedPlayerReqs[2].headers.containsKey('Origin'), isFalse);
      expect(
        recordedPlayerReqs[3].headers['Origin'],
        'https://www.youtube.com',
      );

      final vrHead = recordedHeadReqs[0];
      final vrHeadUa = vrHead.headers.entries
          .where((e) => e.key.toLowerCase() == 'user-agent')
          .toList();
      expect(vrHeadUa, hasLength(1));
      expect(vrHeadUa.single.value, questUa);
    });

    test(
      'WatchPage.get parses Set-Cookie dates via headersSplitValues cleanly',
      () async {
        final mockClient = MockClient((req) async {
          return http.Response(
            '''
<!doctype html><html><head>
<meta property="og:url" content="https://www.youtube.com/watch?v=abcdefghijk">
</head><body><div id="player"></div></body></html>
''',
            200,
            headers: {
              'set-cookie':
                  'YSC=abc123; Path=/; Domain=.youtube.com; HttpOnly, '
                  'OLD=; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Path=/, '
                  'VISITOR_INFO1_LIVE=vis456; Expires=Tue, 19 Jan 2038 03:14:07 GMT; Path=/',
            },
            request: req,
          );
        });

        final httpClient = YoutubeHttpClient(mockClient);
        addTearDown(httpClient.close);

        final page = await WatchPage.get(httpClient, 'abcdefghijk');
        expect(page.cookies['YSC'], 'abc123');
        expect(page.cookies['VISITOR_INFO1_LIVE'], 'vis456');
        expect(page.cookies.containsKey('OLD'), isFalse);
        expect(page.cookies['SOCS'], 'CAI');
        for (final key in page.cookies.keys) {
          expect(key, isNot(contains('01 Jan 1970')));
          expect(key, isNot(contains('19 Jan 2038')));
        }
      },
    );

    test(
      '403 HEAD probe retries at most once per client (<=2 tries)',
      () async {
        var headCount = 0;
        final mockClient = MockClient((req) async {
          if (req.url.path.endsWith('/youtubei/v1/player')) {
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
                      'url': 'https://cdn.example.com/videoplayback?itag=140&c=ANDROID_VR',
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
            headCount++;
            return http.Response('', 403, request: req);
          }
          return http.Response('Not found', 404, request: req);
        });

        final yt = YoutubeExplode(httpClient: YoutubeHttpClient(mockClient));
        addTearDown(yt.close);

        await expectLater(
          yt.videos.streams.getManifest(
            'abcdefghijk',
            ytClients: const [YoutubeApiClient.androidVr],
            requireWatchPage: false,
          ),
          throwsA(isA<FatalFailureException>()),
        );
        expect(headCount, 2);
      },
    );

    test('bootstraps, caches, and refreshes anonymous visitorData for VISIONOS and ANDROID_VR without mutating const payload', () async {
      var visitorIdCalls = 0;
      var swJsCalls = 0;
      final recordedPlayerReqs = <http.Request>[];
      var rejectCachedTokenOnce = true;

      final mockClient = MockClient((req) async {
        if (req.url.path == '/youtubei/v1/visitor_id') {
          visitorIdCalls++;
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final clientName = body['context']['client']['clientName'] as String;
          if (clientName == 'ANDROID_VR') {
            // Force fallback to /sw.js_data on ANDROID_VR.
            return http.Response('err', 400, request: req);
          }
          return http.Response(
            jsonEncode({
              'responseContext': {'visitorData': 'vd-vis-$visitorIdCalls'},
            }),
            200,
            request: req,
          );
        }
        if (req.url.path == '/sw.js_data') {
          swJsCalls++;
          final payload = jsonEncode([
            [
              null,
              null,
              [
                [
                  [
                    '0',
                    '1',
                    '2',
                    '3',
                    '4',
                    '5',
                    '6',
                    '7',
                    '8',
                    '9',
                    '10',
                    '11',
                    '12',
                    'vd-vr-$swJsCalls',
                  ],
                ],
              ],
            ],
          ]);
          return http.Response(")]}'$payload", 200, request: req);
        }
        if (req.url.path.endsWith('/youtubei/v1/player')) {
          recordedPlayerReqs.add(req);
          final body = jsonDecode(req.body) as Map<String, dynamic>;
          final vd = body['context']['client']['visitorData'] as String?;
          final hdrVd = req.headers['X-Goog-Visitor-Id'];
          final clientName = body['context']['client']['clientName'] as String;
          expect(vd, isNotNull);
          expect(hdrVd, equals(vd));

          if (clientName == 'VISIONOS' &&
              vd == 'vd-vis-1' &&
              recordedPlayerReqs.length == 2 &&
              rejectCachedTokenOnce) {
            rejectCachedTokenOnce = false;
            return http.Response(
              jsonEncode({
                'playabilityStatus': {
                  'status': 'LOGIN_REQUIRED',
                  'reason': "Sign in to confirm you're not a bot",
                },
              }),
              200,
              request: req,
            );
          }

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

      // 1. First VISIONOS call fetches vd-vis-1 and caches it.
      await yt.videos.streams.getManifest(
        'abcdefghijk',
        ytClients: const [YoutubeApiClient.visionos],
        requireWatchPage: false,
      );
      expect(visitorIdCalls, 1);
      expect(recordedPlayerReqs[0].headers['X-Goog-Visitor-Id'], 'vd-vis-1');

      // 2. Second VISIONOS call reuses cache; mock returns LOGIN_REQUIRED,
      // triggering a single refresh (vd-vis-2) and retry.
      await yt.videos.streams.getManifest(
        'abcdefghijk',
        ytClients: const [YoutubeApiClient.visionos],
        requireWatchPage: false,
      );
      expect(visitorIdCalls, 2);
      expect(recordedPlayerReqs[1].headers['X-Goog-Visitor-Id'], 'vd-vis-1');
      expect(recordedPlayerReqs[2].headers['X-Goog-Visitor-Id'], 'vd-vis-2');

      // 3. ANDROID_VR fails /visitor_id and falls back to /sw.js_data.
      await yt.videos.streams.getManifest(
        'abcdefghijk',
        ytClients: const [YoutubeApiClient.androidVr],
        requireWatchPage: false,
      );
      expect(swJsCalls, 1);
      expect(recordedPlayerReqs[3].headers['X-Goog-Visitor-Id'], 'vd-vr-1');

      // 4. Static const payloads were never mutated.
      expect(
        (YoutubeApiClient.visionos.payload['context']
            as Map)['client']['visitorData'],
        isNull,
      );
      expect(
        (YoutubeApiClient.androidVr.payload['context']
            as Map)['client']['visitorData'],
        isNull,
      );
    });

    test('WatchPage.ytCfg extracts VISITOR_DATA and STS with trailing HTML and braces in strings', () {
      const html = '''
<!doctype html><html><head>
<script>
ytcfg.set({"VISITOR_DATA":"vd-curly-}-123","NESTED":{"note":"keep { } balanced"},"INNERTUBE_CONTEXT":{"client":{"visitorData":"vd-curly-}-123"}}});
</script>
<script>
ytcfg.set({"STS":20774,"EXTRA":"{ok}"});
</script>
</head><body><div id="player"></div><script>window.trailing={"a":1};</script></body></html>
''';
      final page = WatchPage.parse(html, VideoId('abcdefghijk'), const {});
      expect(page.ytCfg['VISITOR_DATA'], 'vd-curly-}-123');
      expect(page.ytCfg['STS'], 20774);
      expect(
        (page.ytCfg['INNERTUBE_CONTEXT'] as Map)['client']['visitorData'],
        'vd-curly-}-123',
      );
    });

    test(
      'HEAD 403 falls back to GET Range: bytes=0-0 (accepts 206, rejects 403)',
      () async {
        var return403OnRange = false;
        final recordedGets = <http.Request>[];

        final mockClient = MockClient((req) async {
          if (req.url.path.endsWith('/youtubei/v1/player')) {
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
                      'url': 'https://cdn.example.com/videoplayback?itag=140&c=ANDROID_VR',
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
            return http.Response('', 403, request: req);
          }
          if (req.method == 'GET' && req.url.host == 'cdn.example.com') {
            recordedGets.add(req);
            if (return403OnRange) {
              return http.Response('', 403, request: req);
            }
            return http.Response.bytes(
              const [0],
              206,
              headers: {'content-range': 'bytes 0-0/1024'},
              request: req,
            );
          }
          return http.Response('Not found', 404, request: req);
        });

        final yt = YoutubeExplode(httpClient: YoutubeHttpClient(mockClient));
        addTearDown(yt.close);

        final questUa =
            (YoutubeApiClient.androidVr.payload['context']
                    as Map)['client']['userAgent']
                as String;

        final manifest = await yt.videos.streams.getManifest(
          'abcdefghijk',
          ytClients: const [YoutubeApiClient.androidVr],
          requireWatchPage: false,
        );
        expect(manifest.audioOnly, hasLength(1));
        expect(recordedGets, hasLength(1));
        expect(recordedGets.single.headers['Range'], 'bytes=0-0');
        final uaHeader = recordedGets.single.headers.entries
            .where((e) => e.key.toLowerCase() == 'user-agent')
            .single
            .value;
        expect(uaHeader, questUa);

        return403OnRange = true;
        await expectLater(
          yt.videos.streams.getManifest(
            'abcdefghijk',
            ytClients: const [YoutubeApiClient.androidVr],
            requireWatchPage: false,
          ),
          throwsA(isA<FatalFailureException>()),
        );
      },
    );

    test('applies PO token policy per client and keeps visitorData consistent', () async {
      final potProvider = _PolicyFakePoProvider();
      final playerBodies = <Map<String, dynamic>>[];
      final playerHeaders = <Map<String, String>>[];

      final mockClient = MockClient((req) async {
        if (req.url.path.endsWith('/youtubei/v1/player')) {
          playerBodies.add(jsonDecode(req.body) as Map<String, dynamic>);
          playerHeaders.add(req.headers);
          final body = playerBodies.last;
          final clientName = body['context']['client']['clientName'] as String;
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
        if (req.url.path == '/youtubei/v1/visitor_id') {
          return http.Response(
            jsonEncode({
              'responseContext': {'visitorData': 'vd-anon'},
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

      final yt = YoutubeExplode(
        httpClient: YoutubeHttpClient(mockClient),
        poTokenProvider: potProvider,
      );
      addTearDown(yt.close);

      // 1. VISIONOS must NOT trigger PO token provider or attach &pot=.
      final visionManifest = await yt.videos.streams.getManifest(
        'abcdefghijk',
        ytClients: const [YoutubeApiClient.visionos],
        requireWatchPage: false,
      );
      expect(potProvider.calls, 0);
      expect(visionManifest.audioOnly.single.url.queryParameters['pot'], isNull);

      // 2. TVHTML5_SIMPLY requires player + GVS PO tokens and aligned visitorData.
      final tvManifest = await yt.videos.streams.getManifest(
        'abcdefghijk',
        ytClients: const [YoutubeApiClient.tvHtml5Simply],
        requireWatchPage: false,
      );
      expect(potProvider.calls, 1);
      expect(
        playerBodies.last['serviceIntegrityDimensions']['poToken'],
        'sess-pot-1',
      );
      expect(
        playerBodies.last['context']['client']['visitorData'],
        'vd-po-1',
      );
      expect(playerHeaders.last['X-Goog-Visitor-Id'], 'vd-po-1');
      expect(
        tvManifest.audioOnly.single.url.queryParameters['pot'],
        isNotEmpty,
      );
    });

    test('extracts SabrAudioStreamInfo and streams via StreamClient.get without HEAD probe', () async {
      var headCalled = false;
      final initBytes = Uint8List.fromList([7, 8, 9]);
      final segBytes = Uint8List.fromList([10, 11, 12, 13]);

      final mockClient = MockClient((req) async {
        if (req.method == 'HEAD') {
          headCalled = true;
          return http.Response('', 403, request: req);
        }
        if (req.url.path == '/youtubei/v1/visitor_id') {
          return http.Response(
            jsonEncode({
              'responseContext': {'visitorData': 'vd-sabr'},
            }),
            200,
            request: req,
          );
        }
        if (req.url.path.endsWith('/youtubei/v1/player')) {
          return http.Response(
            jsonEncode({
              'playabilityStatus': {'status': 'OK'},
              'videoDetails': {
                'videoId': 'abcdefghijk',
                'title': 'Song',
                'author': 'Artist',
                'lengthSeconds': '10',
                'channelId': 'UC123',
              },
              'playerConfig': {
                'mediaCommonConfig': {
                  'mediaUstreamerRequestConfig': {
                    'videoPlaybackUstreamerConfig': base64Url.encode([1, 2, 3]),
                  },
                },
              },
              'streamingData': {
                'serverAbrStreamingUrl':
                    'https://rr1.googlevideo.com/videoplayback?expire=9999999999',
                'adaptiveFormats': [
                  {
                    'itag': 251,
                    'mimeType': 'audio/webm; codecs="opus"',
                    'bitrate': 128000,
                    'lastModified': '1700000',
                    'approxDurationMs': '10000',
                    'contentLength': '${initBytes.length + segBytes.length}',
                    'qualityLabel': 'AUDIO_QUALITY_MEDIUM',
                  },
                  {
                    'itag': 160,
                    'mimeType': 'video/mp4; codecs="avc1.4d400c"',
                    'bitrate': 80000,
                    'width': 256,
                    'height': 144,
                    'lastModified': '1700000',
                    'approxDurationMs': '10000',
                    'qualityLabel': '144p',
                  },
                ],
              },
            }),
            200,
            request: req,
          );
        }
        if (req.url.host == 'rr1.googlevideo.com' && req.method == 'POST') {
          final fmtInit = (ProtoWriter()
                ..message(2, (f) => f..int32(1, 251)..int64(2, 1700000))
                ..int64(3, 10000)
                ..int32(4, 1))
              .toBytes();
          final initHdr = (ProtoWriter()
                ..int32(1, 0)
                ..string(2, 'abcdefghijk')
                ..int32(3, 251)
                ..int64(4, 1700000)
                ..int64(6, 0)
                ..boolField(8, true)
                ..int32(9, 0)
                ..int64(14, initBytes.length))
              .toBytes();
          final segHdr = (ProtoWriter()
                ..int32(1, 1)
                ..string(2, 'abcdefghijk')
                ..int32(3, 251)
                ..int64(4, 1700000)
                ..int64(6, initBytes.length)
                ..boolField(8, false)
                ..int32(9, 1)
                ..int64(11, 0)
                ..int64(12, 10000)
                ..int64(14, segBytes.length))
              .toBytes();
          final body = (BytesBuilder()
                ..add(_testUmpPart(UmpPartType.formatInitializationMetadata, fmtInit))
                ..add(_testUmpPart(UmpPartType.mediaHeader, initHdr))
                ..add(_testUmpPart(UmpPartType.media, [0, ...initBytes]))
                ..add(_testUmpPart(UmpPartType.mediaEnd, [0]))
                ..add(_testUmpPart(UmpPartType.mediaHeader, segHdr))
                ..add(_testUmpPart(UmpPartType.media, [1, ...segBytes]))
                ..add(_testUmpPart(UmpPartType.mediaEnd, [1]))
                ..add(_testUmpPart(UmpPartType.endOfTrack, [])))
              .takeBytes();
          return http.Response.bytes(
            body,
            200,
            headers: {'content-type': 'application/vnd.yt-ump'},
            request: req,
          );
        }
        return http.Response('Not found', 404, request: req);
      });

      final yt = YoutubeExplode(httpClient: YoutubeHttpClient(mockClient));
      addTearDown(yt.close);

      final manifest = await yt.videos.streams.getManifest(
        'abcdefghijk',
        ytClients: const [YoutubeApiClient.visionosSabr],
        requireWatchPage: false,
      );

      expect(headCalled, isFalse);
      expect(manifest.sabrAudio, hasLength(1));
      expect(manifest.sabrVideo, hasLength(1));
      expect(manifest.audioOnly, isEmpty);

      final streamed = await yt.videos.streams
          .get(manifest.sabrAudio.single)
          .expand((e) => e)
          .toList();
      expect(streamed, orderedEquals([...initBytes, ...segBytes]));
    });
  });
}
