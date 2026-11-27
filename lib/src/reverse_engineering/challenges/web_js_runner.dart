/// Executes JavaScript inside a real browser/WebView context anchored at an
/// origin (e.g. `https://www.youtube.com/robots.txt`) without requiring the
/// browser context to make external network requests.
///
/// Shared by both [BotGuardPoTokenProvider] (PO token minting) and
/// [RunnerEJSSolver] (`n` / `sig` challenge solving).
abstract class BaseWebJsRunner {
  /// Monotonically incremented whenever [resetContext] reloads the JS context.
  int get contextGeneration;

  /// Ensures a clean JS context is loaded at [originUrl] with [htmlContent].
  Future<void> resetContext({
    required Uri originUrl,
    String htmlContent = '<!doctype html><title></title>',
  });

  /// Ensures a JS context has been initialized (calling [resetContext] only
  /// when [contextGeneration] is `0`).
  Future<void> ensureContext({
    required Uri originUrl,
    String htmlContent = '<!doctype html><title></title>',
  }) {
    if (contextGeneration > 0) {
      return Future<void>.value();
    }
    return resetContext(originUrl: originUrl, htmlContent: htmlContent);
  }

  /// Evaluates [jsCode] (which may return a `Promise` or synchronous value)
  /// and returns its string/JSON result, or `null` if the evaluation yields
  /// `null`/`undefined`.
  ///
  /// Implementations must serialize concurrent calls.
  Future<String?> evaluateAsync(String jsCode);

  /// Releases any resources owned by this runner.
  void dispose() {}
}
