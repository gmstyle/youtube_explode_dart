import 'po_token_policy.dart';

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
/// YouTube requires a content-bound PO token for most WEB InnerTube clients
/// in order to access video streams without HTTP 403 from the GVS CDN.
///
/// Use [PoTokenKind.player] for `/player` requests and [PoTokenKind.gvs] for
/// stream URL `?pot=` / manifest `/pot/{token}` (see [YoutubeClientPoPolicy]).
abstract class BasePoTokenProvider {
  /// Generates a content-bound PO Token for the given [videoId].
  ///
  /// [kind] distinguishes player vs GVS contexts (yt-dlp uses separate tokens;
  /// most providers return the same token for both).
  Future<String> generatePoToken(
    String videoId,
    PoTokenContext context, {
    PoTokenKind kind = PoTokenKind.gvs,
  });

  /// Optional cleanup. Called when [YoutubeExplode.close] is invoked.
  void dispose() {}
}
