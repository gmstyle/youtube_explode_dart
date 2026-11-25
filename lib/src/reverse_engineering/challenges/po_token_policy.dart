import '../../videos/youtube_api_client.dart';

/// Describes PO token and cookie behavior for an InnerTube [YoutubeApiClient].
class YoutubeClientPoPolicy {
  /// Whether `/player` requires `serviceIntegrityDimensions.poToken`.
  final bool requiresPlayerPoToken;

  /// Whether CDN / SABR requests accept/require a GVS content PO token.
  final bool usesGvsPoToken;

  /// Whether SABR can start before the GVS PO token finishes minting.
  final bool sabrAllowsLateToken;

  /// Whether the client supports browser session cookies.
  final bool supportsCookies;

  /// Origin header value for SABR POST requests, or `null` for native clients.
  final String? sabrOrigin;

  /// Creates a [YoutubeClientPoPolicy].
  const YoutubeClientPoPolicy({
    required this.requiresPlayerPoToken,
    required this.usesGvsPoToken,
    required this.sabrAllowsLateToken,
    required this.supportsCookies,
    this.sabrOrigin,
  });

  static const _cookielessNative = YoutubeClientPoPolicy(
    requiresPlayerPoToken: false,
    usesGvsPoToken: false,
    sabrAllowsLateToken: false,
    supportsCookies: false,
  );

  static const _webRemix = YoutubeClientPoPolicy(
    requiresPlayerPoToken: false,
    usesGvsPoToken: true,
    sabrAllowsLateToken: true,
    supportsCookies: true,
    sabrOrigin: 'https://music.youtube.com',
  );

  static const _web = YoutubeClientPoPolicy(
    requiresPlayerPoToken: false,
    usesGvsPoToken: true,
    sabrAllowsLateToken: false,
    supportsCookies: true,
    sabrOrigin: 'https://www.youtube.com',
  );

  static const _mweb = YoutubeClientPoPolicy(
    requiresPlayerPoToken: false,
    usesGvsPoToken: true,
    sabrAllowsLateToken: false,
    supportsCookies: true,
    sabrOrigin: 'https://m.youtube.com',
  );

  static const _tvHtml5Simply = YoutubeClientPoPolicy(
    requiresPlayerPoToken: true,
    usesGvsPoToken: true,
    sabrAllowsLateToken: false,
    supportsCookies: false,
    sabrOrigin: 'https://www.youtube.com',
  );

  static const _defaultCookieClient = YoutubeClientPoPolicy(
    requiresPlayerPoToken: false,
    usesGvsPoToken: false,
    sabrAllowsLateToken: false,
    supportsCookies: true,
  );

  /// Resolves the policy for [client].
  static YoutubeClientPoPolicy forClient(YoutubeApiClient client) {
    final context = client.payload['context'] as Map<String, dynamic>?;
    final clientMap = context?['client'] as Map<String, dynamic>?;
    final name = clientMap?['clientName'] as String? ?? '';
    return forClientName(name);
  }

  /// Resolves the policy for normalized InnerTube [clientName].
  static YoutubeClientPoPolicy forClientName(String clientName) {
    return switch (clientName.trim().toUpperCase()) {
      'VISIONOS' ||
      'ANDROID_VR' ||
      'IOS' ||
      'ANDROID' ||
      'ANDROID_MUSIC' => _cookielessNative,
      'WEB_REMIX' => _webRemix,
      'WEB' || 'WEB_CREATOR' => _web,
      'MWEB' => _mweb,
      'TVHTML5_SIMPLY' => _tvHtml5Simply,
      _ => _defaultCookieClient,
    };
  }
}
