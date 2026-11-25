import '../../../reverse_engineering/sabr/sabr_models.dart';
import 'stream_info.dart';

/// Metadata for a YouTube SABR (Server-Adaptive Bitrate) media stream.
///
/// Unlike direct HTTP streams, [url] is not directly playable via HTTP GET;
/// use [StreamClient.get] or [StreamClient.openSabrStream] to stream bytes.
mixin SabrStreamInfo on StreamInfo {
  /// Bootstrap parameters required to open a [SabrStream].
  SabrBootstrap get sabrBootstrap;

  /// Approximate track duration.
  Duration get duration;

  /// Container initialization byte range (`initRange`), if reported.
  SabrByteRange? get initRange;

  /// Container segment index byte range (`indexRange`), if reported.
  SabrByteRange? get indexRange;
}
