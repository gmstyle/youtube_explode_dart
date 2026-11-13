import '../../videos/video_id.dart';

/// Shared context for all SABR streams extracted from a single /player response.
class SabrStreamContext {
  /// Video this context belongs to.
  final VideoId videoId;

  /// Content-bound PO token used for SABR requests.
  final String poToken;

  /// Innertube client name id (WEB = 1).
  final int clientName;

  /// Innertube client version string.
  final String clientVersion;

  /// Raw /player JSON, with [serverAbrStreamingUrl] deciphered when possible.
  final Map<String, dynamic> playerResponse;

  /// Initializes an instance of [SabrStreamContext].
  const SabrStreamContext({
    required this.videoId,
    required this.poToken,
    required this.clientName,
    required this.clientVersion,
    required this.playerResponse,
  });
}

/// Maps innertube client name strings to numeric ids used by googlevideo.
int innertubeClientNameId(String clientName) {
  const ids = {
    'WEB': 1,
    'MWEB': 2,
    'ANDROID': 3,
    'IOS': 5,
    'TVHTML5': 7,
  };
  return ids[clientName.toUpperCase()] ?? 1;
}
