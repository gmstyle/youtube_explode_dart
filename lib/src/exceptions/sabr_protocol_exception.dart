import 'youtube_explode_exception.dart';

/// Category of a [SabrProtocolException].
enum SabrFailureKind {
  /// Malformed UMP/protobuf payload, unexpected HTTP response, or missing segments.
  protocol,

  /// Server returned `STREAM_PROTECTION_STATUS = 3` (or exhausted pending retries)
  /// indicating a valid PO token / attestation is required.
  attestationRequired,

  /// Server requested a fresh `/player` response (`RELOAD_PLAYER_RESPONSE`).
  reloadPlayer,

  /// Transient network/HTTP error during SABR streaming.
  network,
}

/// Exception thrown by the SABR/UMP streaming transport.
class SabrProtocolException extends YoutubeExplodeException {
  /// Failure classification for recovery decisions.
  final SabrFailureKind kind;

  /// Optional HTTP status code if the failure originated from an HTTP status.
  final int? httpStatusCode;

  /// Creates a [SabrProtocolException].
  SabrProtocolException(
    super.message, {
    this.kind = SabrFailureKind.protocol,
    this.httpStatusCode,
  });
}
