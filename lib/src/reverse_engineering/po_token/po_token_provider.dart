/// Context data extracted from the YouTube watch page,
/// needed to generate a content-bound PO Token via BotGuard.
class PoTokenContext {
  /// The visitor data string (`visitorData`) from the InnerTube session context.
  final String visitorData;

  /// The client version string from the InnerTube context.
  final String clientVersion;

  /// The full InnerTube client context map, as returned by the watch page.
  final Map<String, dynamic> innertubeContext;

  /// The full `ytcfg` map extracted from the watch page.
  ///
  /// This contains values used by BotGuard (e.g. `EVENT_ID`) that are
  /// required to mint a valid content-bound PO token.
  final Map<String, dynamic> ytConfig;

  /// Raw JavaScript object passed to `window.ytAtN(...)` on the watch page.
  ///
  /// FreeTube uses this as the primary BotGuard attestation source. It is not
  /// always strict JSON, so keeping the original source string allows platform
  /// providers to parse it in a real JS runtime.
  final String? initialAttestationDataSource;

  /// Creates a [PoTokenContext].
  const PoTokenContext({
    required this.visitorData,
    required this.clientVersion,
    required this.innertubeContext,
    required this.ytConfig,
    this.initialAttestationDataSource,
  });
}

/// Abstract interface for providing YouTube Proof-of-Origin (PO) tokens.
///
/// YouTube requires a content-bound PO token for most InnerTube clients
/// (iOS, Android, Web, etc.) in order to access video streams without
/// receiving HTTP 403 errors from the Google Video Server (GVS).
///
/// Implement this class to integrate PO token generation into your app.
/// The token is generated per-video by running Google's BotGuard JS challenge
/// in a real JavaScript environment (e.g. a WebView on mobile/desktop).
///
/// ## Example using bgutils-js in a WebView (Flutter)
///
/// ```dart
/// class MyPoTokenProvider extends BasePoTokenProvider {
///   @override
///   Future<String> generatePoToken(String videoId, PoTokenContext context) async {
///     // Run bgutils-js inside a headless WebView and return the minted token.
///     // See: https://github.com/LuanRT/BgUtils
///     final token = await myWebViewBridge.generateToken(videoId, context);
///     return token;
///   }
/// }
/// ```
///
/// Then pass it to [YoutubeExplode]:
/// ```dart
/// final yt = YoutubeExplode(poTokenProvider: MyPoTokenProvider());
/// ```
abstract class BasePoTokenProvider {
  /// Generates a content-bound PO Token for the given [videoId].
  ///
  /// [videoId] is the YouTube video ID (e.g. `dQw4w9WgXcQ`).
  /// [context] contains the InnerTube context data extracted from the watch
  /// page, needed as input to the BotGuard challenge.
  ///
  /// Returns the PO token as a websafe base64 string.
  Future<String> generatePoToken(String videoId, PoTokenContext context);

  /// Optional cleanup. Called when [YoutubeExplode.close] is invoked.
  void dispose() {}
}
