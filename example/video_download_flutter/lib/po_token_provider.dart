import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:youtube_explode_dart/solvers.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Flutter implementation of [BasePoTokenProvider] that runs BotGuard JS
/// inside a headless [WebViewController] to generate content-bound PO tokens.
class WebViewPoTokenProvider extends BasePoTokenProvider {
  WebViewPoTokenProvider._();

  late final WebViewController _controller;
  bool _ready = false;
  final Completer<void> _readyCompleter = Completer();
  Completer<String>? _pendingPoToken;

  static Future<WebViewPoTokenProvider> create() async {
    final provider = WebViewPoTokenProvider._();
    await provider._init();
    return provider;
  }

  Future<void> _init() async {
    final htmlContent = await rootBundle.loadString('assets/po_token.html');

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'PoTokenChannel',
        onMessageReceived: (msg) {
          final completer = _pendingPoToken;
          if (completer != null && !completer.isCompleted) {
            completer.complete(msg.message);
          }
        },
      )
      ..addJavaScriptChannel(
        'PoFetchChannel',
        onMessageReceived: (msg) {
          unawaited(_handleFetchRequest(msg.message));
        },
      );

    await _controller.loadHtmlString(
      htmlContent,
      baseUrl: 'https://www.youtube.com',
    );

    await Future.delayed(const Duration(milliseconds: 300));
    _ready = true;
    _readyCompleter.complete();
  }

  Future<void> _handleFetchRequest(String message) async {
    try {
      final request = jsonDecode(message) as Map<String, dynamic>;
      final id = request['id'] as String;
      final url = Uri.parse(request['url'] as String);
      final method = (request['method'] as String?) ?? 'GET';
      final headers = Map<String, String>.from(
        (request['headers'] as Map?)?.map(
              (key, value) => MapEntry(key.toString(), value.toString()),
            ) ??
            {},
      );
      final body = request['body'] as String?;

      late http.Response response;
      if (method.toUpperCase() == 'POST') {
        response = await http.post(url, headers: headers, body: body);
      } else {
        response = await http.get(url, headers: headers);
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        await _resolveFetch(
          id,
          false,
          'HTTP ${response.statusCode}: ${response.body}',
        );
        return;
      }

      dynamic parsedBody;
      try {
        parsedBody = jsonDecode(response.body);
      } catch (_) {
        parsedBody = response.body;
      }

      await _resolveFetch(
        id,
        true,
        jsonEncode({'status': response.statusCode, 'body': parsedBody}),
      );
    } catch (e) {
      final id = (jsonDecode(message) as Map<String, dynamic>)['id'] as String?;
      if (id != null) {
        await _resolveFetch(id, false, e.toString());
      }
    }
  }

  Future<void> _resolveFetch(String id, bool success, String payload) async {
    await _controller.runJavaScript(
      'resolveDartFetch(${jsonEncode(id)}, ${success ? 'true' : 'false'}, ${jsonEncode(payload)})',
    );
  }

  @override
  Future<String> generatePoToken(
    String videoId,
    PoTokenContext context, {
    PoTokenKind kind = PoTokenKind.gvs,
  }) async {
    if (!_ready) await _readyCompleter.future;
    if (context.initialAttestationDataSource == null) {
      throw Exception(
          'initialAttestationData not found in watch page; cannot mint PO token');
    }

    final completer = Completer<String>();
    _pendingPoToken = completer;

    final ytConfigJson = jsonEncode(context.ytConfig);
    final innertubeContextJson = jsonEncode(context.innertubeContext);
    final initialAttestationSource = context.initialAttestationDataSource!;

    String escaped(String s) =>
        s.replaceAll('\\', '\\\\').replaceAll("'", "\\'");

    await _controller.runJavaScript(
      "generatePoToken('${escaped(videoId)}', '${escaped(innertubeContextJson)}', "
      "'${escaped(initialAttestationSource)}', '${escaped(ytConfigJson)}')",
    );

    final raw = await completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException(
          'PO Token generation timed out for video $videoId'),
    );

    _pendingPoToken = null;

    final result = jsonDecode(raw) as Map<String, dynamic>;
    if (result['success'] == true) {
      return result['token'] as String;
    }
    throw Exception('PO Token generation failed: ${result['error']}');
  }

  @override
  void dispose() {
    _controller.loadHtmlString('<html></html>');
  }
}

/// JS challenge solver backed by a headless WebView.
///
/// This avoids desktop-only runtimes (like Deno) and works inside Flutter apps.
class WebViewEJSSolver extends BaseEJSSolver {
  WebViewEJSSolver._();

  late final WebViewController _controller;
  bool _ready = false;
  bool _modulesLoaded = false;
  final Completer<void> _readyCompleter = Completer<void>();

  static Future<WebViewEJSSolver> create() async {
    final solver = WebViewEJSSolver._();
    await solver._init();
    return solver;
  }

  Future<void> _init() async {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted);
    await _controller.loadHtmlString('<html><body></body></html>');
    await _loadModules();

    _ready = true;
    _readyCompleter.complete();
  }

  Future<void> _loadModules() async {
    final modules = await EJSBuilder.getJSModules();
    await _controller.runJavaScript(modules);
    _modulesLoaded = true;
  }

  Future<void> _ensureModulesAvailable() async {
    if (!_modulesLoaded) {
      await _loadModules();
      return;
    }
    final exists = await _controller
        .runJavaScriptReturningResult('typeof jsc === "function"');
    final normalized = _normalizeJsResult(exists);
    if (normalized != 'true') {
      await _loadModules();
    }
  }

  @override
  Future<String> executeJavaScript(String jsCode) async {
    if (!_ready) {
      await _readyCompleter.future;
    }
    await _ensureModulesAvailable();

    Object? raw = await _controller.runJavaScriptReturningResult('''
(() => {
  try {
    return ($jsCode);
  } catch (e) {
    return JSON.stringify({ type: 'error', error: String(e) });
  }
})()
''');

    var normalized = _normalizeJsResult(raw);
    if (normalized.contains('ReferenceError: jsc is not defined')) {
      // WebView JS context may be recreated; reload modules and retry once.
      await _loadModules();
      raw = await _controller.runJavaScriptReturningResult('''
(() => {
  try {
    return ($jsCode);
  } catch (e) {
    return JSON.stringify({ type: 'error', error: String(e) });
  }
})()
''');
      normalized = _normalizeJsResult(raw);
    }
    if (normalized.startsWith('{"type":"error"')) {
      throw Exception('WebViewEJSSolver execution error: $normalized');
    }
    return normalized;
  }

  static String _normalizeJsResult(Object? raw) {
    if (raw == null) return '';
    if (raw is String) {
      final value = raw.trim();
      if (value.startsWith('"') && value.endsWith('"')) {
        try {
          final decoded = jsonDecode(value);
          if (decoded is String) return decoded;
        } catch (_) {
          // Fall through and return raw string.
        }
      }
      return value;
    }
    return raw.toString();
  }

  @override
  void dispose() {
    _controller.loadHtmlString('<html></html>');
  }
}

/// Writes asset scripts to temp files for Flutter/desktop embedders where
/// [Isolate.resolvePackageUri] is unavailable.
Future<String> preparePoScriptFromAsset([
  String assetPath = 'assets/po_token_deno.mjs',
]) async {
  final script = await rootBundle.loadString(assetPath);
  final scriptFile = File(
    '${(await Directory.systemTemp.createTemp('yt_po_token_')).path}/po_token_deno.mjs',
  );
  await scriptFile.writeAsString(script);
  return scriptFile.path;
}

/// Writes the SABR Deno script from a Flutter asset to a temp file.
Future<String> prepareSabrScriptFromAsset([
  String assetPath = 'assets/deno_sabr_download.mjs',
]) async {
  final script = await rootBundle.loadString(assetPath);
  final scriptFile = File(
    '${(await Directory.systemTemp.createTemp('yt_sabr_')).path}/deno_sabr_download.mjs',
  );
  await scriptFile.writeAsString(script);
  return scriptFile.path;
}
