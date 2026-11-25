import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:youtube_explode_webview/src/webview_js_runner.dart';

class _FakeWebViewAdapter extends WebViewJsAdapter {
  final void Function(String message) onChannel;
  final List<String> loadedHtmlUrls = [];
  final List<String> executedScripts = [];
  bool disposed = false;

  _FakeWebViewAdapter(this.onChannel);

  @override
  Future<void> loadHtml(String html, {required Uri baseUrl}) async {
    loadedHtmlUrls.add(baseUrl.toString());
  }

  @override
  Future<void> runJavaScript(String jsCode) async {
    executedScripts.add(jsCode);
    final idMatch = RegExp(r'var __id = (\d+);').firstMatch(jsCode);
    final id = int.parse(idMatch!.group(1)!);
    if (jsCode.contains('fail_me')) {
      onChannel(jsonEncode({'id': id, 'ok': false, 'error': 'boom'}));
    } else {
      onChannel(jsonEncode({'id': id, 'ok': true, 'value': 'res-$id'}));
    }
  }

  @override
  void dispose() {
    disposed = true;
  }
}

void main() {
  group('WebViewJsRunner', () {
    test('loads origin lazily, serializes concurrent evals, and propagates errors', () async {
      late _FakeWebViewAdapter fakeAdapter;
      final runner = WebViewJsRunner(
        adapterFactory: (origin, onMsg) {
          fakeAdapter = _FakeWebViewAdapter(onMsg);
          return fakeAdapter;
        },
      );

      expect(runner.contextGeneration, 0);

      await runner.resetContext(
        originUrl: Uri.parse('https://www.youtube.com/robots.txt'),
      );
      expect(runner.contextGeneration, 1);
      expect(fakeAdapter.loadedHtmlUrls, ['https://www.youtube.com/robots.txt']);

      final r1 = runner.evaluateAsync('"a"');
      final r2 = runner.evaluateAsync('"b"');
      expect(await Future.wait([r1, r2]), ['res-1', 'res-2']);

      await expectLater(
        runner.evaluateAsync('fail_me()'),
        throwsA(isA<StateError>()),
      );

      runner.dispose();
      expect(fakeAdapter.disposed, isTrue);
    });
  });
}
