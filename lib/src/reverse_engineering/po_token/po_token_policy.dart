import '../../videos/youtube_api_client.dart';

/// Where a PO token is consumed (mirrors yt-dlp `PoTokenContext`).
enum PoTokenKind {
  /// Innertube `/player` body (`serviceIntegrityDimensions.poToken`).
  player,

  /// Google Video Server URLs (`?pot=` or `/pot/{token}` on manifests).
  gvs,

  /// Subtitle / caption requests.
  subs,
}

/// Streaming delivery protocol for GVS PO policy lookup.
enum StreamingProtocol {
  https,
  dash,
  hls,
}

/// Whether and how GVS PO tokens apply for a client/protocol pair.
class GvsPoTokenPolicy {
  final bool required;
  final bool recommended;

  const GvsPoTokenPolicy({
    this.required = false,
    this.recommended = false,
  });

  static const none = GvsPoTokenPolicy();
  static const web = GvsPoTokenPolicy(required: true, recommended: true);
  static const webHls = GvsPoTokenPolicy(recommended: true);
}

/// Per-client PO token requirements (aligned with yt-dlp `INNERTUBE_CLIENTS`).
abstract final class YoutubeClientPoPolicy {
  static bool usesWebPoToken(YoutubeApiClient client) =>
      client == YoutubeApiClient.safari;

  static bool requiresPlayerPoToken(YoutubeApiClient client) =>
      usesWebPoToken(client);

  static GvsPoTokenPolicy gvsPolicy(
    YoutubeApiClient client,
    StreamingProtocol protocol,
  ) {
    if (usesWebPoToken(client)) {
      return switch (protocol) {
        StreamingProtocol.hls => GvsPoTokenPolicy.webHls,
        _ => GvsPoTokenPolicy.web,
      };
    }
    return GvsPoTokenPolicy.none;
  }

  static bool requiresGvsPoToken(
    YoutubeApiClient client,
    StreamingProtocol protocol,
  ) =>
      gvsPolicy(client, protocol).required;

  static bool shouldAppendGvsPoToken(
    YoutubeApiClient client,
    StreamingProtocol protocol,
    String? poToken,
  ) =>
      poToken != null &&
      (requiresGvsPoToken(client, protocol) ||
          gvsPolicy(client, protocol).recommended);
}
