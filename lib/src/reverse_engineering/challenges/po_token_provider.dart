import '../../videos/video_id.dart';
import '../../videos/youtube_api_client.dart';
import '../pages/watch_page.dart';

/// Result returned by a [BasePoTokenProvider] for a player/streaming request.
class PoTokenResult {
  /// Session/player PO token (bound to visitorData) sent in `/player`
  /// `serviceIntegrityDimensions.poToken`.
  final String? sessionPoToken;

  /// Content/GVS PO token (bound to videoId) sent via `&pot=` or SABR
  /// `StreamerContext.poToken`.
  final String? streamingDataPoToken;

  /// VisitorData bound to this token pair (must match the `/player` request).
  final String? visitorData;

  /// Optional signatureTimestamp (STS) scraped alongside attestation.
  final String? signatureTimestamp;

  /// Optional expiration timestamp derived from GenerateIT `lifetimeSeconds`.
  final DateTime? expiresAt;

  /// Creates a [PoTokenResult].
  const PoTokenResult({
    this.sessionPoToken,
    this.streamingDataPoToken,
    this.visitorData,
    this.signatureTimestamp,
    this.expiresAt,
  });

  /// Returns `true` when [expiresAt] is set and has elapsed.
  bool get isExpired => expiresAt != null && DateTime.now().isAfter(expiresAt!);
}

/// Provides Proof-of-Origin (PO) tokens for InnerTube `/player` requests and
/// googlevideo stream / SABR requests.
abstract class BasePoTokenProvider {
  /// Mints or retrieves cached PO tokens for [client] and [videoId].
  ///
  /// Returns `null` when the client does not need a PO token or when minting
  /// could not produce a token.
  Future<PoTokenResult?> getPoToken({
    required YoutubeApiClient client,
    required VideoId videoId,
    String? visitorData,
    WatchPage? watchPage,
    bool forceRefresh = false,
  });

  /// Invalidates any cached session minter/tokens (e.g. on account switch or
  /// `StreamProtectionStatus = 3`).
  void invalidateSession() {}

  /// Releases any resources owned by this provider.
  void dispose() {}
}
