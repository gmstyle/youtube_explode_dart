import '../../../../youtube_explode_dart.dart';

/// Mixin for streams delivered via YouTube's Server Adaptive Bitrate (SABR) protocol.
mixin SabrStreamInfo on StreamInfo {
  /// Shared SABR session data for this /player response.
  SabrStreamContext get sabrContext;
}
