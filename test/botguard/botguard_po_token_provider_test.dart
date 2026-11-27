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
  bool jscDefined = false;
  bool failNextMint = false;
  Future<void> Function()? onAfterEjsLoad;
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
    jscDefined = false;
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
      if (failNextMint) {
        failNextMint = false;
        throw StateError(
          'TypeError: globalThis.__ytBgMintToken is not a function',
        );
      }
      final match = RegExp(r'__ytBgMintToken\("([^"]+)"\)').firstMatch(jsCode);
      return 'pot_${match?.group(1) ?? "unknown"}';
    }
    if (jsCode == 'typeof globalThis.jsc') {
      return jscDefined ? 'function' : 'undefined';
    }
    if (jsCode.contains('globalThis.jsc = jsc')) {
      ejsLoads++;
      jscDefined = true;
      await onAfterEjsLoad?.call();
      return 'ok';
    }
    if (jsCode.contains('__YT_EJS_MISSING_JSC__') && !jscDefined) {
      return '__YT_EJS_MISSING_JSC__';
    }
    if (jsCode.contains('jsc(')) {
      return '{"ok":true}';
    }
    return 'ok';
  }
}

void main() {
  group('BotGuardPoTokenProvider', () {
    test(
      'caches session minter across videos and resets on invalidateSession',
      () async {
        var watchFetches = 0;
        var interpFetches = 0;
        var generateItCalls = 0;

        const challengeObj = {
          'bgChallenge': {
            'interpreterUrl': {
              'privateDoNotAccessOrElseTrustedResourceUrlWrappedValue': 'https://www.google.com/js/th/AbCdEfGhIjKlMnOpQrStUvWxYz123456.js',
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
            return http.Response(
              'var trayride = { a: function(){} };',
              200,
              request: req,
            );
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

        // Renderer wipe (without explicit invalidateSession) auto-rebootstraps.
        runner.failNextMint = true;
        final res4 = await provider.getPoToken(
          client: YoutubeApiClient.webRemix,
          videoId: VideoId('ddddddddddd'),
        );
        expect(watchFetches, 3);
        expect(generateItCalls, 3);
        expect(runner.runBotGuardCount, 3);
        expect(res4?.streamingDataPoToken, 'pot_ddddddddddd');
      },
    );
  });

  group('RunnerEJSSolver', () {
    test('evaluates modules at top level, assigns globalThis.jsc, and reloads on resetContext', () async {
      final runner = _FakeWebJsRunner();
      var loaderCalls = 0;
      final solver = RunnerEJSSolver(
        runner: runner,
        ownsRunner: true,
        modulesLoader: () async {
          loaderCalls++;
          return 'const jsc = (x) => x;';
        },
      );
      addTearDown(solver.dispose);

      final res1 = await solver.executeJavaScript('jsc({})');
      expect(res1, '{"ok":true}');
      expect(loaderCalls, 1);
      expect(runner.ejsLoads, 1);
      expect(runner.resetCount, 1);

      final moduleScript = runner.evaluatedScripts.firstWhere(
        (s) => s.contains('const jsc = (x) => x;'),
      );
      expect(moduleScript.trimLeft(), startsWith('const jsc = (x) => x;'));
      expect(moduleScript, contains('globalThis.jsc = jsc'));

      // Second call in the same generation skips reloading modules.
      final res2 = await solver.executeJavaScript('jsc({})');
      expect(res2, '{"ok":true}');
      expect(loaderCalls, 1);
      expect(runner.ejsLoads, 1);

      // Context reset bumps contextGeneration -> reloads modules.
      await runner.resetContext(
        originUrl: Uri.parse('https://www.youtube.com/robots.txt'),
      );
      final res3 = await solver.executeJavaScript('jsc({})');
      expect(res3, '{"ok":true}');
      expect(loaderCalls, 2);
      expect(runner.ejsLoads, 2);
    });

    test(
      'recovers when resetContext wipes globalThis.jsc mid-execution',
      () async {
        final runner = _FakeWebJsRunner();
        var triggeredReset = false;
        runner.onAfterEjsLoad = () async {
          if (!triggeredReset) {
            triggeredReset = true;
            await runner.resetContext(
              originUrl: Uri.parse('https://www.youtube.com/robots.txt'),
            );
          }
        };

        var loaderCalls = 0;
        final solver = RunnerEJSSolver(
          runner: runner,
          ownsRunner: true,
          modulesLoader: () async {
            loaderCalls++;
            return 'const jsc = (x) => x;';
          },
        );
        addTearDown(solver.dispose);

        final res = await solver.executeJavaScript('jsc({})');
        expect(res, '{"ok":true}');
        expect(triggeredReset, isTrue);
        expect(loaderCalls, 2);
        expect(runner.ejsLoads, 2);
      },
    );

    test('rewrites globalThis.location and window.location assignments to avoid browser navigation', () async {
      final runner = _FakeWebJsRunner();
      final solver = RunnerEJSSolver(
        runner: runner,
        ownsRunner: true,
        modulesLoader: () async =>
            'if (globalThis.location === undefined) { globalThis.location = new URL("https://www.youtube.com/watch?v=yt-dlp-wins"); } '
            'window.location = "https://www.youtube.com/"; '
            'const jsc = (x) => x;',
      );
      addTearDown(solver.dispose);

      final res = await solver.executeJavaScript('jsc({})');
      expect(res, '{"ok":true}');

      final loaded = runner.evaluatedScripts.firstWhere(
        (s) => s.contains('const jsc = (x) => x;'),
      );
      expect(loaded, contains('globalThis.location === undefined'));
      expect(loaded, contains('globalThis.__ytEjsLocation = new URL('));
      expect(
        loaded,
        isNot(matches(RegExp(r'\bglobalThis\.location\s*=(?!=)'))),
      );
      expect(loaded, isNot(contains('window.location =')));
    });

    test(
      'uses ensureContext so concurrent BotGuard bootstrap is not wiped',
      () async {
        final runner = _FakeWebJsRunner();
        await runner.resetContext(
          originUrl: Uri.parse('https://www.youtube.com/robots.txt'),
        );
        final solver = RunnerEJSSolver(
          runner: runner,
          ownsRunner: true,
          modulesLoader: () async => 'const jsc = (x) => x;',
        );
        addTearDown(solver.dispose);

        await solver.executeJavaScript('jsc({})');
        expect(runner.contextGeneration, 1);
        expect(runner.resetCount, 1);
      },
    );
  });
}
