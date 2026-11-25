import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../web_js_runner.dart';

/// Headless Chromium JS runner over Chrome DevTools Protocol (`dart:io` only).
///
/// Launches a local Chromium/Chrome browser in headless mode with network
/// access blocked via `Fetch.enable` except for fulfilling the anchored origin
/// page (`https://www.youtube.com/robots.txt`) locally in memory.
class ChromiumCdpJsRunner extends BaseWebJsRunner {
  static const List<String> _defaultBinaries = [
    'chromium',
    'chromium-browser',
    'google-chrome',
    'google-chrome-stable',
    'brave-browser',
    'microsoft-edge',
  ];

  final Process _process;
  final Directory _userDataDir;
  final WebSocket _ws;
  final Duration _timeout;

  int _contextGeneration = 0;
  Uri _originUrl = Uri.parse('https://www.youtube.com/robots.txt');
  String _htmlContent = '<!doctype html><title></title>';
  int _nextCommandId = 1;
  final Map<int, Completer<Map<String, dynamic>>> _pendingCommands = {};
  Completer<void>? _pageLoadCompleter;
  Future<void> _serial = Future<void>.value();
  bool _disposed = false;

  ChromiumCdpJsRunner._(
    this._process,
    this._userDataDir,
    this._ws,
    this._timeout,
  ) {
    _ws.listen(
      _onWsMessage,
      onError: (_) => _failPending(StateError('CDP WebSocket error')),
      onDone: () => _failPending(StateError('CDP WebSocket closed')),
    );
  }

  @override
  int get contextGeneration => _contextGeneration;

  /// Probes `PATH` (or [executablePath]) for a Chromium-compatible browser and
  /// launches a headless CDP session, or returns `null` if none is available.
  static Future<ChromiumCdpJsRunner?> tryCreate({
    String? executablePath,
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final binary = await _findExecutable(executablePath);
    if (binary == null) return null;

    final userDataDir = await Directory.systemTemp.createTemp('yt_cdp_');
    Process? process;
    WebSocket? ws;
    try {
      process = await Process.start(binary, [
        '--headless=new',
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-gpu',
        '--disable-extensions',
        '--disable-background-networking',
        '--disable-sync',
        '--remote-debugging-port=0',
        '--user-data-dir=${userDataDir.path}',
        'about:blank',
      ]);

      final wsBrowserUri = await _waitForDevToolsUri(process, timeout);
      final pageWsUri = await _resolvePageWebSocketUri(
        wsBrowserUri.port,
        timeout,
      );
      ws = await WebSocket.connect(pageWsUri.toString()).timeout(timeout);

      final runner = ChromiumCdpJsRunner._(process, userDataDir, ws, timeout);
      await runner._sendCommand('Page.enable');
      await runner._sendCommand('Runtime.enable');
      await runner._sendCommand('Fetch.enable', {
        'patterns': [
          {'urlPattern': '*'},
        ],
      });
      return runner;
    } catch (_) {
      await ws?.close();
      process?.kill();
      try {
        if (await userDataDir.exists()) {
          await userDataDir.delete(recursive: true);
        }
      } catch (_) {}
      return null;
    }
  }

  static Future<String?> _findExecutable(String? explicit) async {
    if (explicit != null && explicit.isNotEmpty) {
      return await File(explicit).exists() ? explicit : null;
    }
    for (final candidate in _defaultBinaries) {
      try {
        final result = await Process.run('which', [candidate]);
        if (result.exitCode == 0) {
          final path = (result.stdout as String).trim().split('\n').first;
          if (path.isNotEmpty) return path;
        }
      } catch (_) {}
    }
    return null;
  }

  static Future<Uri> _waitForDevToolsUri(
    Process process,
    Duration timeout,
  ) async {
    final completer = Completer<Uri>();
    final exp = RegExp(r'DevTools listening on (ws://[^\s]+)');
    late final StreamSubscription<String> sub;
    sub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            final match = exp.firstMatch(line);
            if (match != null && !completer.isCompleted) {
              completer.complete(Uri.parse(match.group(1)!));
              sub.cancel();
            }
          },
          onDone: () {
            if (!completer.isCompleted) {
              completer.completeError(
                StateError('Chromium exited before exposing DevTools endpoint'),
              );
            }
          },
        );
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        sub.cancel();
        throw TimeoutException('Timed out waiting for Chromium DevTools');
      },
    );
  }

  static Future<Uri> _resolvePageWebSocketUri(
    int port,
    Duration timeout,
  ) async {
    final client = HttpClient();
    try {
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:$port/json/list'))
          .timeout(timeout);
      final resp = await req.close().timeout(timeout);
      final body = await utf8.decodeStream(resp).timeout(timeout);
      final targets = json.decode(body) as List<dynamic>;
      for (final target in targets) {
        if (target is Map &&
            target['type'] == 'page' &&
            target['webSocketDebuggerUrl'] is String) {
          return Uri.parse(target['webSocketDebuggerUrl'] as String);
        }
      }
      throw StateError('No CDP page target found');
    } finally {
      client.close(force: true);
    }
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _serial = _serial.then((_) async {
      if (_disposed) {
        completer.completeError(StateError('ChromiumCdpJsRunner is disposed'));
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
      _htmlContent = htmlContent;
      _contextGeneration++;
      final loadDone = Completer<void>();
      _pageLoadCompleter = loadDone;
      await _sendCommand('Page.navigate', {'url': originUrl.toString()});
      await loadDone.future.timeout(_timeout);
    });
  }

  @override
  Future<String?> evaluateAsync(String jsCode) {
    return _serialized(() async {
      final wrapped =
          'Promise.resolve().then(function() { return eval(${json.encode(jsCode)}); })'
          '.then(function(v) { return v == null ? null : String(v); })';
      final res = await _sendCommand('Runtime.evaluate', {
        'expression': wrapped,
        'awaitPromise': true,
        'returnByValue': true,
      });
      final exceptionDetails = res['exceptionDetails'];
      if (exceptionDetails is Map) {
        final desc =
            exceptionDetails['exception']?['description'] ??
            exceptionDetails['text'] ??
            'JS evaluation failed';
        throw StateError(desc.toString());
      }
      final result = res['result'] as Map<String, dynamic>?;
      if (result == null ||
          result['type'] == 'undefined' ||
          result['subtype'] == 'null') {
        return null;
      }
      final value = result['value'];
      return value?.toString();
    });
  }

  Future<Map<String, dynamic>> _sendCommand(
    String method, [
    Map<String, dynamic>? params,
  ]) async {
    if (_disposed) throw StateError('ChromiumCdpJsRunner is disposed');
    final id = _nextCommandId++;
    final completer = Completer<Map<String, dynamic>>();
    _pendingCommands[id] = completer;
    _ws.add(
      json.encode({
        'id': id,
        'method': method,
        'params': ?params,
      }),
    );
    return completer.future.timeout(
      _timeout,
      onTimeout: () {
        _pendingCommands.remove(id);
        throw TimeoutException('CDP command $method timed out');
      },
    );
  }

  void _onWsMessage(dynamic raw) {
    if (raw is! String) return;
    final decoded = json.decode(raw);
    if (decoded is! Map<String, dynamic>) return;

    final id = decoded['id'];
    if (id is int) {
      final completer = _pendingCommands.remove(id);
      if (completer == null || completer.isCompleted) return;
      final error = decoded['error'];
      if (error != null) {
        completer.completeError(StateError('CDP error: $error'));
      } else {
        completer.complete(
          (decoded['result'] as Map<String, dynamic>?) ?? const {},
        );
      }
      return;
    }

    final method = decoded['method'];
    final params = decoded['params'];
    if (method == 'Page.loadEventFired') {
      if (_pageLoadCompleter != null && !_pageLoadCompleter!.isCompleted) {
        _pageLoadCompleter!.complete();
      }
    } else if (method == 'Fetch.requestPaused' && params is Map) {
      final requestId = params['requestId'] as String?;
      final reqUrl = (params['request'] as Map?)?['url'] as String?;
      if (requestId == null) return;
      if (reqUrl == _originUrl.toString()) {
        _sendCommand('Fetch.fulfillRequest', {
          'requestId': requestId,
          'responseCode': 200,
          'responseHeaders': [
            {'name': 'Content-Type', 'value': 'text/html; charset=utf-8'},
          ],
          'body': base64Encode(utf8.encode(_htmlContent)),
        }).catchError((_) => const <String, dynamic>{});
      } else {
        _sendCommand('Fetch.failRequest', {
          'requestId': requestId,
          'errorReason': 'BlockedByClient',
        }).catchError((_) => const <String, dynamic>{});
      }
    }
  }

  void _failPending(Object error) {
    for (final c in _pendingCommands.values) {
      if (!c.isCompleted) c.completeError(error);
    }
    _pendingCommands.clear();
    if (_pageLoadCompleter != null && !_pageLoadCompleter!.isCompleted) {
      _pageLoadCompleter!.completeError(error);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _failPending(StateError('ChromiumCdpJsRunner disposed'));
    _ws.close();
    _process.kill();
    try {
      if (_userDataDir.existsSync()) {
        _userDataDir.deleteSync(recursive: true);
      }
    } catch (_) {}
  }
}
