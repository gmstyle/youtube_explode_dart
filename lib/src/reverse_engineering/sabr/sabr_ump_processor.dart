import 'dart:typed_data';

import '../../exceptions/sabr_protocol_exception.dart';
import 'sabr_models.dart';
import 'sabr_proto_codec.dart';
import 'ump_reader.dart';

class _PendingSegment {
  final SabrMediaHeader header;
  final bool collect;
  final BytesBuilder? builder;
  int byteCount = 0;

  _PendingSegment(this.header, this.collect)
    : builder = collect ? BytesBuilder(copy: true) : null;
}

/// Converts framed UMP parts into complete media segments and control events.
class SabrUmpProcessor {
  static const int _maxControlPartBytes = 128 * 1024;
  static const int _maxResponseHeaders = 4096;
  static const int _compressionNone = 0;
  static const int _defaultMaxCollectedSegmentSize = 16 * 1024 * 1024;
  static const int _defaultMaxPendingMediaBytes = 32 * 1024 * 1024;
  static const int _defaultMaxResponseBytes = 96 * 1024 * 1024;

  final bool Function(SabrMediaHeader header) shouldCollectMedia;
  final int maxCollectedSegmentSize;
  final int maxPendingMediaBytes;
  final int maxResponseBytes;
  late final UmpReader _reader;

  final Map<int, _PendingSegment> _pendingSegments = {};
  int _pendingMediaBytes = 0;
  int _responseBytes = 0;
  int _responseHeaderCount = 0;
  bool _terminalProtection = false;
  _PendingSegment? _activeMediaSegment;
  bool _expectingMediaHeaderId = false;

  SabrUmpProcessor({
    int maxPartSize = UmpReader.defaultMaxPartSize,
    bool Function(SabrMediaHeader header)? shouldCollectMedia,
    this.maxCollectedSegmentSize = _defaultMaxCollectedSegmentSize,
    this.maxPendingMediaBytes = _defaultMaxPendingMediaBytes,
    this.maxResponseBytes = _defaultMaxResponseBytes,
  }) : shouldCollectMedia = shouldCollectMedia ?? ((_) => true) {
    _reader = UmpReader(
      maxPartSize: maxPartSize,
      maxPartSizeForType: (type) =>
          (type == UmpPartType.sabrContextUpdate ||
              type == UmpPartType.nextRequestPolicy)
          ? _maxControlPartBytes
          : maxPartSize,
    );
  }

  void resetForNextResponse() {
    _reader.reset();
    _pendingSegments.clear();
    _pendingMediaBytes = 0;
    _responseBytes = 0;
    _responseHeaderCount = 0;
    _terminalProtection = false;
    _activeMediaSegment = null;
    _expectingMediaHeaderId = false;
  }

  void feed(
    Uint8List chunk, {
    int? length,
    required void Function(SabrEvent event) onEvent,
  }) {
    if (_terminalProtection) return;
    final len = length ?? chunk.length;
    if (len < 0 || _responseBytes > maxResponseBytes - len) {
      throw SabrProtocolException(
        'SABR response exceeded $maxResponseBytes bytes',
      );
    }
    _responseBytes += len;

    _reader.feedStreaming(
      chunk: chunk,
      length: len,
      streamPartType: UmpPartType.media,
      onStreamStart: (_, size) {
        if (size == 0) throw SabrProtocolException('Empty UMP MEDIA part');
        _activeMediaSegment = null;
        _expectingMediaHeaderId = true;
        return true;
      },
      onStreamChunk: (data, from, to) {
        _appendMediaSlice(data, from, to);
        return true;
      },
      onStreamEnd: () {
        _activeMediaSegment = null;
        _expectingMediaHeaderId = false;
        return true;
      },
      onPart: (type, data, from, to) {
        final event = _processPart(type, data, from, to);
        if (event != null) {
          onEvent(event);
          if (event is SabrStreamProtectionStatusEvent && event.status >= 3) {
            _terminalProtection = true;
          }
        }
        return !_terminalProtection;
      },
    );
  }

  void finish() {
    if (_terminalProtection) return;
    _reader.finish();
    if (_pendingSegments.isNotEmpty) {
      final keys = _pendingSegments.keys.toList()..sort();
      throw SabrProtocolException(
        'SABR response ended with incomplete media headers: ${keys.join(', ')}',
      );
    }
  }

  SabrEvent? _processPart(int type, Uint8List data, int from, int to) {
    switch (type) {
      case UmpPartType.mediaHeader:
        if (++_responseHeaderCount > _maxResponseHeaders) {
          throw SabrProtocolException(
            'SABR response exceeded the media header limit',
          );
        }
        final header = SabrProtoCodec.decodeMediaHeader(data, from, to);
        if (_pendingSegments.containsKey(header.headerId)) {
          throw SabrProtocolException(
            'Duplicate SABR media header ID ${header.headerId}',
          );
        }
        final collect = shouldCollectMedia(header);
        if (collect && header.compressionAlgorithm != _compressionNone) {
          throw SabrProtocolException(
            'Unsupported compression ${header.compressionAlgorithm} for SABR media segment',
          );
        }
        if (collect && header.contentLength > maxCollectedSegmentSize) {
          throw SabrProtocolException(
            'SABR segment is too large: ${header.contentLength} bytes',
          );
        }
        _pendingSegments[header.headerId] = _PendingSegment(header, collect);
        return SabrMediaHeaderEvent(header);
      case UmpPartType.mediaEnd:
        return _finalizeMedia(data, from, to);
      case UmpPartType.formatInitializationMetadata:
        return SabrFormatInitializedEvent(
          SabrProtoCodec.decodeFormatInitialization(data, from, to),
        );
      case UmpPartType.nextRequestPolicy:
        return SabrProtoCodec.decodeNextRequestPolicy(data, from, to);
      case UmpPartType.sabrRedirect:
        final url = SabrProtoCodec.decodeRedirect(data, from, to);
        return url != null ? SabrRedirectEvent(url) : null;
      case UmpPartType.sabrError:
        return SabrProtoCodec.decodeError(data, from, to);
      case UmpPartType.reloadPlayerResponse:
        return const SabrReloadPlayerResponseEvent();
      case UmpPartType.sabrContextUpdate:
        final ctx = SabrProtoCodec.decodeContextUpdate(data, from, to);
        return ctx != null ? SabrContextUpdateEvent(ctx) : null;
      case UmpPartType.streamProtectionStatus:
        return SabrProtoCodec.decodeStreamProtectionStatus(data, from, to);
      case UmpPartType.sabrContextSendingPolicy:
        return SabrProtoCodec.decodeContextSendingPolicy(data, from, to);
      case UmpPartType.endOfTrack:
        return const SabrEndOfTrackEvent();
      default:
        return null;
    }
  }

  void _appendMediaSlice(Uint8List data, int from, int to) {
    var pos = from;
    if (_expectingMediaHeaderId) {
      if (pos >= to) return;
      final headerId = data[pos++];
      final seg = _pendingSegments[headerId];
      if (seg == null) {
        throw SabrProtocolException(
          'UMP MEDIA refers to unknown header ID $headerId',
        );
      }
      _activeMediaSegment = seg;
      _expectingMediaHeaderId = false;
    }
    final segment = _activeMediaSegment;
    if (segment == null) return;
    final payloadSize = to - pos;
    if (payloadSize <= 0) return;

    segment.byteCount += payloadSize;
    if (segment.header.contentLength > 0 &&
        segment.byteCount > segment.header.contentLength) {
      throw SabrProtocolException(
        'SABR segment ${segment.header.sequenceNumber} exceeded its content length',
      );
    }
    if (!segment.collect) return;
    if (segment.byteCount > maxCollectedSegmentSize) {
      throw SabrProtocolException(
        'SABR segment is too large: ${segment.byteCount} bytes',
      );
    }
    if (_pendingMediaBytes + payloadSize > maxPendingMediaBytes) {
      throw SabrProtocolException(
        'SABR pending media exceeded $maxPendingMediaBytes bytes',
      );
    }
    _pendingMediaBytes += payloadSize;
    segment.builder!.add(Uint8List.sublistView(data, pos, to));
  }

  SabrSegmentEvent? _finalizeMedia(Uint8List data, int from, int to) {
    if (from >= to) throw SabrProtocolException('Empty UMP MEDIA_END part');
    final headerId = data[from];
    final pending = _pendingSegments.remove(headerId);
    if (pending == null) {
      throw SabrProtocolException(
        'UMP MEDIA_END refers to unknown header ID $headerId',
      );
    }
    if (pending.header.contentLength > 0 &&
        pending.byteCount != pending.header.contentLength) {
      throw SabrProtocolException(
        'SABR segment ${pending.header.sequenceNumber} has ${pending.byteCount} bytes, '
        'expected ${pending.header.contentLength}',
      );
    }
    if (!pending.collect) return null;
    if (pending.byteCount == 0) {
      throw SabrProtocolException('Empty selected SABR media segment');
    }
    _pendingMediaBytes -= pending.byteCount;
    final bytes = pending.builder!.takeBytes();
    return SabrSegmentEvent(SabrSegment(pending.header, bytes));
  }
}
