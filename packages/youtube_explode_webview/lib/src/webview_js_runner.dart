import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:youtube_explode_dart/js_challenge.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

/// Minimal WebView surface abstracted for headless unit testing.
@visibleForTesting
abstract class WebViewJsAdapter {
  Future<void> loadHtml(String html, {required Uri baseUrl});
  Future<void> runJavaScript(String jsCode);
  void dispose() {}
}

class _FlutterWebViewAdapter implements WebViewJsAdapter {
  final WebViewController _controller;
  final Uri _allowedOrigin;
  Completer<void>? _pageFinished;

  _FlutterWebViewAdapter({
    required this._allowedOrigin,
    required void Function(String message) onChannelMessage,
  }) : _controller = WebViewController() {
    _controller
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        WebViewJsRunner.channelName,
        onMessageReceived: (msg) => onChannelMessage(msg.message),
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri == null) return NavigationDecision.prevent;
            if (uri.scheme == 'about') return NavigationDecision.navigate;
            if (uri.scheme == _allowedOrigin.scheme &&
                uri.host == _allowedOrigin.host &&
                uri.path == _allowedOrigin.path) {
              return NavigationDecision.navigate;
            }
            return NavigationDecision.prevent;
          },
          onPageFinished: (_) {
            final c = _pageFinished;
            if (c != null && !c.isCompleted) {
              c.complete();
            }
          },
          onWebResourceError: (error) {
            final c = _pageFinished;
            if (c != null && !c.isCompleted && (error.isForMainFrame ?? true)) {
              c.completeError(
                StateError('WebView failed loading origin: ${error.description}'),
              );
            }
          },
        ),
      );
  }

  @override
  Future<void> loadHtml(String html, {required Uri baseUrl}) async {
    final completer = Completer<void>();
    _pageFinished = completer;
    await _controller.loadHtmlString(html, baseUrl: baseUrl.toString());
    await completer.future;
  }

  @override
  Future<void> runJavaScript(String jsCode) =>
      _controller.runJavaScript(jsCode);

  @override
  void dispose() {}
}

/// Hidden offscreen [WebViewController] runner implementing [BaseWebJsRunner].
///
/// The WebView is created lazily on the first [resetContext] or
/// [evaluateAsync] call, anchored to an empty HTML document on
/// `https://www.youtube.com/robots.txt`, and never makes direct network
/// requests.
class WebViewJsRunner extends BaseWebJsRunner {
  static const String channelName = 'YtExplodeJsRunner';

  final Duration _timeout;
  final WebViewJsAdapter Function(
    Uri originUrl,
    void Function(String message) onChannelMessage,
  )?
  _adapterFactory;

  WebViewJsAdapter? _adapter;
  Uri _originUrl = Uri.parse('https://www.youtube.com/robots.txt');
  int _contextGeneration = 0;
  int _nextId = 1;
  final Map<int, Completer<String?>> _pending = {};
  Future<void> _serial = Future<void>.value();
  bool _disposed = false;

  /// Creates a lazy offscreen [WebViewJsRunner].
  WebViewJsRunner({
    this._timeout = const Duration(seconds: 25),
    @visibleForTesting this._adapterFactory,
  });

  @override
  int get contextGeneration => _contextGeneration;

  WebViewJsAdapter _ensureAdapter(Uri originUrl) {
    final existing = _adapter;
    if (existing != null) return existing;
    final adapter = _adapterFactory != null
        ? _adapterFactory(originUrl, handleChannelMessage)
        : _FlutterWebViewAdapter(
            allowedOrigin: originUrl,
            onChannelMessage: handleChannelMessage,
          );
    _adapter = adapter;
    return adapter;
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _serial = _serial.then((_) async {
      if (_disposed) {
        completer.completeError(StateError('WebViewJsRunner is disposed'));
        return;
      }
      try {
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  @override
  Future<void> resetContext({
    required Uri originUrl,
    String htmlContent = '<!doctype html><title></title>',
  }) {
    return _serialized(() async {
      _originUrl = originUrl;
      _contextGeneration++;
      final adapter = _ensureAdapter(originUrl);
      await adapter.loadHtml(htmlContent, baseUrl: originUrl).timeout(_timeout);
    });
  }

  @override
  Future<String?> evaluateAsync(String jsCode) {
    return _serialized(() async {
      if (_contextGeneration == 0) {
        _contextGeneration++;
        final adapter = _ensureAdapter(_originUrl);
        await adapter
            .loadHtml('<!doctype html><title></title>', baseUrl: _originUrl)
            .timeout(_timeout);
      }
      final adapter = _ensureAdapter(_originUrl);
      final id = _nextId++;
      final completer = Completer<String?>();
      // Prevent synchronous completeError inside runJavaScript from firing
      // an uncaught zone error before completer.future is awaited below.
      completer.future.catchError((_) => null).ignore();
      _pending[id] = completer;

      final codeJson = json.encode(jsCode);
      final script =
          '''
(function() {
  var __id = $id;
  try {
    Promise.resolve().then(function() {
      return (0, eval)($codeJson);
    }).then(function(val) {
      $channelName.postMessage(JSON.stringify({
        id: __id,
        ok: true,
        value: val == null ? null : String(val)
      }));
    }).catch(function(err) {
      $channelName.postMessage(JSON.stringify({
        id: __id,
        ok: false,
        error: String(err && err.message ? err.message : err)
      }));
    });
  } catch (err) {
    $channelName.postMessage(JSON.stringify({
      id: __id,
      ok: false,
      error: String(err && err.message ? err.message : err)
    }));
  }
})();
''';

      try {
        await adapter.runJavaScript(script);
        return await completer.future.timeout(
          _timeout,
          onTimeout: () {
            _pending.remove(id);
            throw TimeoutException('WebView JS evaluation #$id timed out');
          },
        );
      } catch (_) {
        _pending.remove(id);
        rethrow;
      }
    });
  }

  /// Processes a raw JSON message posted by JS on [channelName].
  @visibleForTesting
  void handleChannelMessage(String rawMessage) {
    final decoded = json.decode(rawMessage);
    if (decoded is! Map<String, dynamic>) return;
    final id = decoded['id'];
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;

    if (decoded['ok'] == true) {
      final value = decoded['value'];
      completer.complete(value?.toString());
    } else {
      completer.completeError(
        StateError(decoded['error']?.toString() ?? 'WebView JS error'),
      );
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final c in _pending.values) {
      if (!c.isCompleted) {
        c.completeError(StateError('WebViewJsRunner disposed'));
      }
    }
    _pending.clear();
    _adapter?.dispose();
    _adapter = null;
  }
}

/// Convenience bundle wiring one shared [WebViewJsRunner] into both
/// [BotGuardPoTokenProvider] and [RunnerEJSSolver].
class WebViewBotGuardBundle {
  /// Shared hidden WebView runner.
  final WebViewJsRunner runner;

  /// BotGuard PO token provider backed by [runner].
  final BotGuardPoTokenProvider poTokenProvider;

  /// JS `n`/`sig` challenge solver backed by [runner].
  final RunnerEJSSolver jsSolver;

  /// Creates a [WebViewBotGuardBundle] sharing one [WebViewJsRunner].
  factory WebViewBotGuardBundle({
    required YoutubeHttpClient httpClient,
    String? userAgent,
    String? Function()? visitorDataProvider,
    String? Function()? sessionKeyProvider,
    Duration timeout = const Duration(seconds: 25),
  }) {
    final runner = WebViewJsRunner(timeout: timeout);
    final poTokenProvider = BotGuardPoTokenProvider(
      runner: runner,
      httpClient: httpClient,
      userAgent: userAgent,
      visitorDataProvider: visitorDataProvider,
      sessionKeyProvider: sessionKeyProvider,
    );
    final jsSolver = RunnerEJSSolver(runner: runner);
    return WebViewBotGuardBundle._(runner, poTokenProvider, jsSolver);
  }

  WebViewBotGuardBundle._(this.runner, this.poTokenProvider, this.jsSolver);

  /// Invalidates cached PO token session state.
  void invalidateSession() => poTokenProvider.invalidateSession();

  /// Releases all resources including the underlying [WebViewJsRunner].
  void dispose() {
    poTokenProvider.dispose();
    jsSolver.dispose();
    runner.dispose();
  }
}
