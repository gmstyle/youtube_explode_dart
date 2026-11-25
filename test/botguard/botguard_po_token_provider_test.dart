import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:youtube_explode_dart/js_challenge.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class _FakeWebJsRunner extends BaseWebJsRunner {
  int _generation = 0;
  int resetCount = 0;
  int runBotGuardCount = 0;
  int createMinterCount = 0;
  int mintCalls = 0;
  int ejsLoads = 0;
  final List<String> evaluatedScripts = [];

  @override
  int get contextGeneration => _generation;

  @override
  Future<void> resetContext({
    required Uri originUrl,
    String htmlContent = '<!doctype html><title></title>',
  }) async {
    _generation++;
    resetCount++;
  }

  @override
  Future<String?> evaluateAsync(String jsCode) async {
    evaluatedScripts.add(jsCode);
    if (jsCode.contains('__ytBgRun(')) {
      runBotGuardCount++;
      return 'bg-snapshot-xyz';
    }
    if (jsCode.contains('__ytBgCreateMinter(')) {
      createMinterCount++;
      return 'ok';
    }
    if (jsCode.contains('__ytBgMintToken(')) {
      mintCalls++;
      final match = RegExp(r'__ytBgMintToken\("([^"]+)"\)').firstMatch(jsCode);
      return 'pot_${match?.group(1) ?? "unknown"}';
    }
    if (jsCode.contains('typeof globalThis.jsc')) {
      ejsLoads++;
      return 'ok';
    }
    return 'ok';
  }
}

void main() {
  group('BotGuardPoTokenProvider', () {
    test('caches session minter across videos and resets on invalidateSession', () async {
      var watchFetches = 0;
      var interpFetches = 0;
      var generateItCalls = 0;

      const challengeObj = {
        'bgChallenge': {
          'interpreterUrl': {
            'privateDoNotAccessOrElseTrustedResourceUrlWrappedValue':
                'https://www.google.com/js/th/AbCdEfGhIjKlMnOpQrStUvWxYz123456.js',
          },
          'interpreterHash': 'hash123',
          'program': 'prog-abc',
          'globalName': 'trayride',
        },
      };

      final mockClient = MockClient((req) async {
        if (req.url.path == '/watch') {
          watchFetches++;
          return http.Response(
            '''
<!doctype html><html><head><script>
ytcfg.set({"EVENT_ID":"ev-1","VISITOR_DATA":"vd-session","STS":20801});
window.ytAtN(cb, {'R': ${jsonEncode(jsonEncode(challengeObj))}});
</script></head><body></body></html>
''',
            200,
            request: req,
          );
        }
        if (req.url.host == 'www.google.com') {
          interpFetches++;
          return http.Response('var trayride = { a: function(){} };', 200, request: req);
        }
        if (req.url.path == '/api/jnn/v1/GenerateIT') {
          generateItCalls++;
          final b64 = base64Url.encode([1, 2, 3, 4]);
          return http.Response(jsonEncode([b64, 3600]), 200, request: req);
        }
        return http.Response('Not found', 404, request: req);
      });

      final httpClient = YoutubeHttpClient(mockClient);
      final runner = _FakeWebJsRunner();
      final provider = BotGuardPoTokenProvider(
        runner: runner,
        httpClient: httpClient,
        ownsRunner: true,
      );
      addTearDown(() {
        provider.dispose();
        httpClient.close();
      });

      // Cookieless native clients return null immediately without touching runner.
      expect(
        await provider.getPoToken(
          client: YoutubeApiClient.visionos,
          videoId: VideoId('aaaaaaaaaaa'),
        ),
        isNull,
      );
      expect(runner.runBotGuardCount, 0);

      // Concurrent requests for video 1 and video 2 run BotGuard only ONCE!
      final results = await Future.wait([
        provider.getPoToken(
          client: YoutubeApiClient.webRemix,
          videoId: VideoId('aaaaaaaaaaa'),
        ),
        provider.getPoToken(
          client: YoutubeApiClient.webRemix,
          videoId: VideoId('bbbbbbbbbbb'),
        ),
      ]);

      expect(watchFetches, 1);
      expect(interpFetches, 1);
      expect(generateItCalls, 1);
      expect(runner.runBotGuardCount, 1);
      expect(runner.createMinterCount, 1);
      expect(results[0]?.sessionPoToken, 'pot_vd-session');
      expect(results[0]?.streamingDataPoToken, 'pot_aaaaaaaaaaa');
      expect(results[1]?.sessionPoToken, 'pot_vd-session');
      expect(results[1]?.streamingDataPoToken, 'pot_bbbbbbbbbbb');
      expect(results[0]?.signatureTimestamp, '20801');

      // Invalidate forces a fresh BotGuard bootstrap (reusing cached interpreter).
      provider.invalidateSession();
      final res3 = await provider.getPoToken(
        client: YoutubeApiClient.webRemix,
        videoId: VideoId('ccccccccccc'),
      );
      expect(watchFetches, 2);
      expect(interpFetches, 1);
      expect(generateItCalls, 2);
      expect(runner.runBotGuardCount, 2);
      expect(res3?.streamingDataPoToken, 'pot_ccccccccccc');
    });
  });
}
