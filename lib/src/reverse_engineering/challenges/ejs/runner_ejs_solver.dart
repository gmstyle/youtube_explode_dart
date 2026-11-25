import 'dart:async';

import 'package:meta/meta.dart';

import '../web_js_runner.dart';
import 'base_ejs_solver.dart';
import 'ejs.dart';

/// Solves YouTube `n` and `sig` challenges using a shared [BaseWebJsRunner]
/// (for example, a hidden Flutter WebView on Android or Chromium CDP on Linux).
class RunnerEJSSolver extends BaseEJSSolver {
  static final Uri _defaultOriginUri = Uri.parse(
    'https://www.youtube.com/robots.txt',
  );
  static const String _missingJscSentinel = '__YT_EJS_MISSING_JSC__';
  static final RegExp _locationAssignExp = RegExp(
    r'\b(?:globalThis|window)\.location\s*=(?!=)',
  );

  static String _sanitizeForBrowser(String modules) =>
      modules.replaceAll(_locationAssignExp, 'globalThis.__ytEjsLocation =');

  final BaseWebJsRunner _runner;
  final bool _ownsRunner;

  /// Optional module loader override for tests.
  @visibleForTesting
  final Future<String> Function()? modulesLoader;
  int _loadedGeneration = -1;
  Future<void> _serial = Future<void>.value();

  /// Creates a [RunnerEJSSolver] backed by [runner].
  RunnerEJSSolver({
    required this._runner,
    this._ownsRunner = false,
    this.modulesLoader,
  });

  Future<T> _serialized<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _serial = _serial.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  @override
  Future<String> executeJavaScript(String jsCode) {
    return _serialized(() async {
      for (var attempt = 0; attempt < 3; attempt++) {
        if (_runner.contextGeneration == 0) {
          await _runner.resetContext(originUrl: _defaultOriginUri);
        }
        final targetGen = _runner.contextGeneration;
        if (targetGen != _loadedGeneration) {
          final hasJsc = await _runner.evaluateAsync('typeof globalThis.jsc');
          if (hasJsc != 'function') {
            final rawModules = await (modulesLoader ?? EJSBuilder.getJSModules)();
            final modules = _sanitizeForBrowser(rawModules);
            await _runner.evaluateAsync(
              '$modules\n;if (typeof jsc === "function") { globalThis.jsc = jsc; }\n"ok";',
            );
          }
          if (_runner.contextGeneration != targetGen) {
            _loadedGeneration = -1;
            continue;
          }
          _loadedGeneration = targetGen;
        }

        final result = await _runner.evaluateAsync(
          '(function() { '
          'if (typeof globalThis.jsc !== "function") return "$_missingJscSentinel"; '
          'return $jsCode; '
          '})()',
        );
        if (result == _missingJscSentinel) {
          _loadedGeneration = -1;
          continue;
        }
        if (result == null || result.isEmpty) {
          throw Exception('RunnerEJSSolver returned empty result');
        }
        return result;
      }
      throw Exception(
        'RunnerEJSSolver failed: globalThis.jsc unavailable after retries',
      );
    });
  }

  @override
  void dispose() {
    if (_ownsRunner) {
      _runner.dispose();
    }
  }
}
