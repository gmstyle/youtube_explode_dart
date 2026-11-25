import '../web_js_runner.dart';
import 'base_ejs_solver.dart';
import 'ejs.dart';

/// Solves YouTube `n` and `sig` challenges using a shared [BaseWebJsRunner]
/// (for example, a hidden Flutter WebView on Android or Chromium CDP on Linux).
class RunnerEJSSolver extends BaseEJSSolver {
  static final Uri _defaultOriginUri = Uri.parse(
    'https://www.youtube.com/robots.txt',
  );

  final BaseWebJsRunner _runner;
  final bool _ownsRunner;
  int _loadedGeneration = -1;

  /// Creates a [RunnerEJSSolver] backed by [runner].
  RunnerEJSSolver({
    required this._runner,
    this._ownsRunner = false,
  });

  @override
  Future<String> executeJavaScript(String jsCode) async {
    if (_runner.contextGeneration == 0) {
      await _runner.resetContext(originUrl: _defaultOriginUri);
    }
    if (_runner.contextGeneration != _loadedGeneration) {
      final modules = await EJSBuilder.getJSModules();
      await _runner.evaluateAsync(
        'if (typeof globalThis.jsc !== "function") { $modules } "ok";',
      );
      _loadedGeneration = _runner.contextGeneration;
    }

    final result = await _runner.evaluateAsync(
      '(function() { return $jsCode; })()',
    );
    if (result == null || result.isEmpty) {
      throw Exception('RunnerEJSSolver returned empty result');
    }
    return result;
  }

  @override
  void dispose() {
    if (_ownsRunner) {
      _runner.dispose();
    }
  }
}
