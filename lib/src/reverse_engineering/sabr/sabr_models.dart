import 'dart:typed_data';

import '../../exceptions/sabr_protocol_exception.dart';

/// Media track type streamed by [SabrStream].
enum SabrMediaType { audio, video }

/// Inclusive byte range `[start, end]` reported in `initRange` / `indexRange`.
class SabrByteRange {
  final int start;
  final int end;

  const SabrByteRange(this.start, this.end);

  @override
  bool operator ==(Object other) =>
      other is SabrByteRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'SabrByteRange($start-$end)';
}

/// Identifies a specific rendition inside SABR requests and headers.
class SabrFormatId {
  final int itag;
  final int lastModified;
  final String? xtags;

  const SabrFormatId(this.itag, {this.lastModified = 0, this.xtags});

  /// Whether this format ID matches [other] (wildcards 0 / null allowed on [other]).
  bool matches(SabrFormatId other) =>
      itag == other.itag &&
      (other.lastModified == 0 || lastModified == other.lastModified) &&
      (other.xtags == null || other.xtags!.isEmpty || xtags == other.xtags);

  @override
  bool operator ==(Object other) =>
      other is SabrFormatId &&
      other.itag == itag &&
      other.lastModified == lastModified &&
      other.xtags == xtags;

  @override
  int get hashCode => Object.hash(itag, lastModified, xtags);

  @override
  String toString() => 'SabrFormatId(itag=$itag, lmt=$lastModified)';
}

/// Immutable bootstrap parameters extracted from `/player` for starting a [SabrStream].
class SabrBootstrap {
  final String videoId;
  final String serverAbrStreamingUrl;
  final Uint8List videoPlaybackUstreamerConfig;
  final int clientNameId;
  final String clientVersion;
  final SabrFormatId audioFormat;
  final SabrFormatId discardVideoFormat;
  final int discardVideoHeight;
  final SabrFormatId? selectedVideoFormat;
  final int? selectedVideoWidth;
  final int? selectedVideoHeight;
  final int? selectedVideoContentLengthBytes;
  final String? selectedVideoMimeType;
  final int? selectedVideoBitrate;
  final int durationMs;
  final int? contentLengthBytes;
  final String mimeType;
  final String? audioTrackId;
  final bool isDrc;
  final Uint8List? poToken;
  final String? requestUserAgent;
  final String? requestOrigin;
  final String? tokenVisitorData;
  final SabrByteRange? initRange;
  final SabrByteRange? indexRange;

  const SabrBootstrap({
    required this.videoId,
    required this.serverAbrStreamingUrl,
    required this.videoPlaybackUstreamerConfig,
    required this.clientNameId,
    required this.clientVersion,
    required this.audioFormat,
    required this.discardVideoFormat,
    required this.discardVideoHeight,
    this.selectedVideoFormat,
    this.selectedVideoWidth,
    this.selectedVideoHeight,
    this.selectedVideoContentLengthBytes,
    this.selectedVideoMimeType,
    this.selectedVideoBitrate,
    required this.durationMs,
    required this.contentLengthBytes,
    required this.mimeType,
    this.audioTrackId,
    this.isDrc = false,
    this.poToken,
    this.requestUserAgent,
    this.requestOrigin,
    this.tokenVisitorData,
    this.initRange,
    this.indexRange,
  });

  /// Returns a copy with an updated [poToken] or [serverAbrStreamingUrl].
  SabrBootstrap copyWith({
    String? serverAbrStreamingUrl,
    Uint8List? poToken,
  }) => SabrBootstrap(
    videoId: videoId,
    serverAbrStreamingUrl: serverAbrStreamingUrl ?? this.serverAbrStreamingUrl,
    videoPlaybackUstreamerConfig: videoPlaybackUstreamerConfig,
    clientNameId: clientNameId,
    clientVersion: clientVersion,
    audioFormat: audioFormat,
    discardVideoFormat: discardVideoFormat,
    discardVideoHeight: discardVideoHeight,
    selectedVideoFormat: selectedVideoFormat,
    selectedVideoWidth: selectedVideoWidth,
    selectedVideoHeight: selectedVideoHeight,
    selectedVideoContentLengthBytes: selectedVideoContentLengthBytes,
    selectedVideoMimeType: selectedVideoMimeType,
    selectedVideoBitrate: selectedVideoBitrate,
    durationMs: durationMs,
    contentLengthBytes: contentLengthBytes,
    mimeType: mimeType,
    audioTrackId: audioTrackId,
    isDrc: isDrc,
    poToken: poToken ?? this.poToken,
    requestUserAgent: requestUserAgent,
    requestOrigin: requestOrigin,
    tokenVisitorData: tokenVisitorData,
    initRange: initRange,
    indexRange: indexRange,
  );

  @override
  String toString() =>
      'SabrBootstrap(audioItag=${audioFormat.itag}, videoItag=${selectedVideoFormat?.itag}, '
      'ustreamerConfigBytes=${videoPlaybackUstreamerConfig.length}, '
      'poTokenBytes=${poToken?.length ?? 0})';
}

/// Decoded media chunk emitted by [SabrStream.chunks].
class SabrChunk {
  final Uint8List data;
  final int startRange;
  final bool isInitialization;
  final int? sequenceNumber;
  final int? startMs;
  final int? durationMs;

  const SabrChunk({
    required this.data,
    required this.startRange,
    required this.isInitialization,
    this.sequenceNumber,
    this.startMs,
    this.durationMs,
  });

  int get endRangeExclusive => startRange + data.length;
}

class SabrMediaHeader {
  final int headerId;
  final String? videoId;
  final SabrFormatId formatId;
  final int startRange;
  final int compressionAlgorithm;
  final bool isInitSegment;
  final int sequenceNumber;
  final int startMs;
  final int durationMs;
  final int contentLength;

  const SabrMediaHeader({
    required this.headerId,
    this.videoId,
    required this.formatId,
    this.startRange = 0,
    this.compressionAlgorithm = 0,
    this.isInitSegment = false,
    this.sequenceNumber = 0,
    this.startMs = 0,
    this.durationMs = 0,
    this.contentLength = 0,
  });
}

class SabrFormatInitialization {
  final SabrFormatId formatId;
  final int? endTimeMs;
  final int? endSegmentNumber;
  final int? durationMs;

  const SabrFormatInitialization({
    required this.formatId,
    this.endTimeMs,
    this.endSegmentNumber,
    this.durationMs,
  });
}

class SabrSegment {
  final SabrMediaHeader header;
  final Uint8List data;

  const SabrSegment(this.header, this.data);

  SabrChunk toChunk() => SabrChunk(
    data: data,
    startRange: header.startRange,
    isInitialization: header.isInitSegment,
    sequenceNumber: header.isInitSegment ? null : header.sequenceNumber,
    startMs: header.isInitSegment ? null : header.startMs,
    durationMs: header.isInitSegment ? null : header.durationMs,
  );

  int get checkedEndTimeMs {
    if (header.startMs < 0 || header.durationMs < 0) {
      throw SabrProtocolException('SABR segment has an invalid time range');
    }
    return header.startMs + header.durationMs;
  }
}

class SabrBufferedRange {
  final SabrFormatId formatId;
  final int startTimeMs;
  final int durationMs;
  final int startSegmentIndex;
  final int endSegmentIndex;

  const SabrBufferedRange({
    required this.formatId,
    required this.startTimeMs,
    required this.durationMs,
    required this.startSegmentIndex,
    required this.endSegmentIndex,
  });
}

class SabrContext {
  final int type;
  final Uint8List value;
  final bool sendByDefault;
  final int writePolicy;

  const SabrContext({
    required this.type,
    required this.value,
    required this.sendByDefault,
    required this.writePolicy,
  });
}

sealed class SabrEvent {
  const SabrEvent();
}

final class SabrMediaHeaderEvent extends SabrEvent {
  final SabrMediaHeader header;
  const SabrMediaHeaderEvent(this.header);
}

final class SabrSegmentEvent extends SabrEvent {
  final SabrSegment segment;
  const SabrSegmentEvent(this.segment);
}

final class SabrFormatInitializedEvent extends SabrEvent {
  final SabrFormatInitialization? initialization;
  const SabrFormatInitializedEvent(this.initialization);
}

final class SabrNextRequestPolicyEvent extends SabrEvent {
  final int targetAudioReadaheadMs;
  final int maxTimeSinceLastRequestMs;
  final int backoffTimeMs;
  final int minAudioReadaheadMs;
  final Uint8List? playbackCookie;

  const SabrNextRequestPolicyEvent({
    required this.targetAudioReadaheadMs,
    required this.maxTimeSinceLastRequestMs,
    required this.backoffTimeMs,
    required this.minAudioReadaheadMs,
    this.playbackCookie,
  });
}

final class SabrRedirectEvent extends SabrEvent {
  final String url;
  const SabrRedirectEvent(this.url);
}

final class SabrContextUpdateEvent extends SabrEvent {
  final SabrContext context;
  const SabrContextUpdateEvent(this.context);
}

final class SabrContextSendingPolicyEvent extends SabrEvent {
  final Set<int> start;
  final Set<int> stop;
  final Set<int> discard;

  const SabrContextSendingPolicyEvent({
    required this.start,
    required this.stop,
    required this.discard,
  });
}

final class SabrStreamProtectionStatusEvent extends SabrEvent {
  final int status;
  final int maxRetries;

  const SabrStreamProtectionStatusEvent(this.status, this.maxRetries);
}

final class SabrErrorEvent extends SabrEvent {
  final String? type;
  final int code;

  const SabrErrorEvent(this.type, this.code);
}

final class SabrReloadPlayerResponseEvent extends SabrEvent {
  const SabrReloadPlayerResponseEvent();
}

final class SabrEndOfTrackEvent extends SabrEvent {
  const SabrEndOfTrackEvent();
}

/// Validates that [value] is an HTTPS `googlevideo.com/videoplayback` endpoint.
String requireAllowedSabrUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme.toLowerCase() != 'https' ||
      (uri.hasPort && uri.port != 443)) {
    throw SabrProtocolException('Invalid SABR streaming URL');
  }
  final host = uri.host.toLowerCase();
  if ((host != 'googlevideo.com' && !host.endsWith('.googlevideo.com')) ||
      uri.path != '/videoplayback' ||
      uri.userInfo.isNotEmpty) {
    throw SabrProtocolException(
      'SABR streaming URL is not an HTTPS googlevideo endpoint',
    );
  }
  return value;
}
