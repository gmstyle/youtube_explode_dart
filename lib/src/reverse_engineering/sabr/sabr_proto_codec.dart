import 'dart:typed_data';

import '../../exceptions/sabr_protocol_exception.dart';
import 'proto_wire.dart';
import 'sabr_models.dart';

/// Encodes `VideoPlaybackAbrRequest` and decodes UMP control/media protobuf parts.
abstract final class SabrProtoCodec {
  static const int _discardSentinel = 0x7fffffff;
  static const int maxControlValueBytes = 64 * 1024;
  static const int _maxContextPolicyEntries = 256;

  /// Encodes a `VideoPlaybackAbrRequest` protobuf payload.
  static Uint8List encodeRequest({
    required SabrBootstrap bootstrap,
    required int playerTimeMs,
    required bool initialized,
    required List<SabrBufferedRange> bufferedRanges,
    required Uint8List? playbackCookie,
    required Iterable<SabrContext> contexts,
    required Set<int> activeContextTypes,
    SabrMediaType mediaType = SabrMediaType.audio,
    ProtoWriter? writer,
    Uint8List? poToken,
  }) {
    final effectivePoToken = poToken ?? bootstrap.poToken;
    final videoFormat = mediaType == SabrMediaType.video
        ? (bootstrap.selectedVideoFormat ??
              (throw StateError('SABR video format is not selected')))
        : bootstrap.discardVideoFormat;
    final videoHeight = mediaType == SabrMediaType.video
        ? (bootstrap.selectedVideoHeight ??
              (throw StateError('SABR video height is not selected')))
        : bootstrap.discardVideoHeight;

    final w = writer ?? ProtoWriter();
    w.reset();

    w.message(1, (s) {
      if (videoHeight != 0) s.int32(21, videoHeight);
      if (playerTimeMs != 0) s.int64(28, playerTimeMs);
      s.int32(34, 1);
      s.float32(35, 1.0);
      s.int32(40, mediaType == SabrMediaType.audio ? 1 : 2);
      if (bootstrap.isDrc) s.boolField(46, true);
      final trackId = bootstrap.audioTrackId;
      if (trackId != null && trackId.isNotEmpty) {
        s.string(69, trackId);
      }
    });

    if (initialized) {
      w.message(
        2,
        (f) => _writeFormatId(
          f,
          mediaType == SabrMediaType.audio ? bootstrap.audioFormat : videoFormat,
        ),
      );
    }
    w.message(
      2,
      (f) => _writeFormatId(
        f,
        mediaType == SabrMediaType.audio ? videoFormat : bootstrap.audioFormat,
      ),
    );

    for (final range in bufferedRanges) {
      w.message(3, (r) => _writeBufferedRange(r, range));
    }
    w.message(
      3,
      (r) => _writeDiscardRange(
        r,
        mediaType == SabrMediaType.audio ? videoFormat : bootstrap.audioFormat,
      ),
    );

    w.bytes(5, bootstrap.videoPlaybackUstreamerConfig);
    w.message(16, (f) => _writeFormatId(f, bootstrap.audioFormat));
    w.message(17, (f) => _writeFormatId(f, videoFormat));

    w.message(19, (ctx) {
      ctx.message(1, (info) {
        info.int32(16, bootstrap.clientNameId);
        info.string(17, bootstrap.clientVersion);
      });
      if (effectivePoToken != null) {
        ctx.bytes(2, effectivePoToken);
      }
      if (playbackCookie != null) {
        ctx.bytes(3, playbackCookie);
      }
      final inactive = <int>[];
      for (final context in contexts) {
        if (activeContextTypes.contains(context.type)) {
          ctx.message(5, (entry) {
            entry.int32(1, context.type);
            entry.bytes(2, context.value);
          });
        } else {
          inactive.add(context.type);
        }
      }
      if (inactive.isNotEmpty) {
        ctx.packedInt32(6, inactive);
      }
    });

    return w.toBytes();
  }

  static SabrMediaHeader decodeMediaHeader(
    Uint8List data, [
    int from = 0,
    int? to,
  ]) {
    final reader = ProtoReader(data, from, to ?? data.length);
    var headerId = 0;
    String? videoId;
    var formatItag = 0;
    var formatLastModified = 0;
    String? formatXtags;
    var startRange = 0;
    var compressionAlgorithm = 0;
    var isInitSegment = false;
    var sequenceNumber = 0;
    var startMs = 0;
    var durationMs = 0;
    var contentLength = 0;
    var hasTimeRange = false;
    var rangeStartTicks = 0;
    var rangeDurationTicks = 0;
    var rangeTimescale = 0;

    while (reader.hasRemaining) {
      final tag = reader.tag();
      switch (tag.field) {
        case 1:
          _requireWireType(tag, 0);
          headerId = reader.intValue(max: 255);
        case 2:
          _requireWireType(tag, 2);
          videoId = reader.string();
        case 3:
          _requireWireType(tag, 0);
          formatItag = reader.intValue();
        case 4:
          _requireWireType(tag, 0);
          formatLastModified = reader.unsignedValue();
        case 5:
          _requireWireType(tag, 2);
          formatXtags = reader.string();
        case 6:
          _requireWireType(tag, 0);
          startRange = reader.unsignedValue();
        case 7:
          _requireWireType(tag, 0);
          compressionAlgorithm = reader.intValue();
        case 8:
          _requireWireType(tag, 0);
          isInitSegment = reader.boolValue();
        case 9:
          _requireWireType(tag, 0);
          sequenceNumber = reader.intValue();
        case 11:
          _requireWireType(tag, 0);
          startMs = reader.unsignedValue();
        case 12:
          _requireWireType(tag, 0);
          durationMs = reader.unsignedValue();
        case 13:
          _requireWireType(tag, 2);
          final sub = reader.slice();
          while (sub.hasRemaining) {
            final subTag = sub.tag();
            switch (subTag.field) {
              case 1:
                _requireWireType(subTag, 0);
                formatItag = sub.intValue();
              case 2:
                _requireWireType(subTag, 0);
                formatLastModified = sub.unsignedValue();
              case 3:
                _requireWireType(subTag, 2);
                formatXtags = sub.string();
              default:
                sub.skip(subTag);
            }
          }
        case 14:
          _requireWireType(tag, 0);
          contentLength = reader.unsignedValue();
        case 15:
          _requireWireType(tag, 2);
          hasTimeRange = true;
          final rangeReader = reader.slice();
          while (rangeReader.hasRemaining) {
            final subTag = rangeReader.tag();
            switch (subTag.field) {
              case 1:
                _requireWireType(subTag, 0);
                rangeStartTicks = rangeReader.unsignedValue();
              case 2:
                _requireWireType(subTag, 0);
                rangeDurationTicks = rangeReader.unsignedValue();
              case 3:
                _requireWireType(subTag, 0);
                rangeTimescale = rangeReader.intValue(min: 1);
              default:
                rangeReader.skip(subTag);
            }
          }
        default:
          reader.skip(tag);
      }
    }

    if (headerId < 0 || headerId > 255) {
      throw SabrProtocolException('Invalid SABR media header ID $headerId');
    }
    if (formatItag <= 0) {
      throw SabrProtocolException('SABR media header has no format ID');
    }
    if (hasTimeRange && rangeTimescale > 0) {
      if (startMs == 0) startMs = _ticksToMs(rangeStartTicks, rangeTimescale);
      if (durationMs == 0) {
        durationMs = _ticksToMs(rangeDurationTicks, rangeTimescale);
      }
    }

    return SabrMediaHeader(
      headerId: headerId,
      videoId: videoId,
      formatId: SabrFormatId(
        formatItag,
        lastModified: formatLastModified,
        xtags: formatXtags,
      ),
      startRange: startRange,
      compressionAlgorithm: compressionAlgorithm,
      isInitSegment: isInitSegment,
      sequenceNumber: sequenceNumber,
      startMs: startMs,
      durationMs: durationMs,
      contentLength: contentLength,
    );
  }

  static SabrFormatInitialization? decodeFormatInitialization(
    Uint8List data, [
    int from = 0,
    int? to,
  ]) {
    final reader = ProtoReader(data, from, to ?? data.length);
    SabrFormatId? formatId;
    int? endTimeMs;
    int? endSegmentNumber;
    int? durationUnits;
    int? durationTimescale;

    while (reader.hasRemaining) {
      final tag = reader.tag();
      switch (tag.field) {
        case 2:
          _requireWireType(tag, 2);
          formatId = _decodeFormatId(
            reader.slice(),
            formatId ?? const SabrFormatId(0),
          );
        case 3:
          _requireWireType(tag, 0);
          endTimeMs = reader.unsignedValue();
        case 4:
          _requireWireType(tag, 0);
          endSegmentNumber = reader.intValue();
        case 9:
          _requireWireType(tag, 0);
          durationUnits = reader.unsignedValue();
        case 10:
          _requireWireType(tag, 0);
          durationTimescale = reader.intValue(min: 1);
        default:
          reader.skip(tag);
      }
    }

    if (formatId == null) return null;
    final durationMs = (durationUnits != null && durationTimescale != null)
        ? _ticksToMs(durationUnits, durationTimescale)
        : endTimeMs;
    return SabrFormatInitialization(
      formatId: formatId,
      endTimeMs: endTimeMs,
      endSegmentNumber: endSegmentNumber,
      durationMs: durationMs,
    );
  }

  static SabrNextRequestPolicyEvent decodeNextRequestPolicy(
    Uint8List data, [
    int from = 0,
    int? to,
  ]) {
    final reader = ProtoReader(data, from, to ?? data.length);
    var targetAudioReadaheadMs = 0;
    var maxTimeSinceLastRequestMs = 0;
    var backoffTimeMs = 0;
    var minAudioReadaheadMs = 0;
    Uint8List? playbackCookie;

    while (reader.hasRemaining) {
      final tag = reader.tag();
      switch (tag.field) {
        case 1:
          _requireWireType(tag, 0);
          targetAudioReadaheadMs = reader.unsignedValue();
        case 3:
          _requireWireType(tag, 0);
          maxTimeSinceLastRequestMs = reader.unsignedValue();
        case 4:
          _requireWireType(tag, 0);
          backoffTimeMs = reader.unsignedValue();
        case 5:
          _requireWireType(tag, 0);
          minAudioReadaheadMs = reader.unsignedValue();
        case 7:
          _requireWireType(tag, 2);
          playbackCookie = reader.bytes(maxControlValueBytes);
        default:
          reader.skip(tag);
      }
    }

    return SabrNextRequestPolicyEvent(
      targetAudioReadaheadMs: targetAudioReadaheadMs,
      maxTimeSinceLastRequestMs: maxTimeSinceLastRequestMs,
      backoffTimeMs: backoffTimeMs,
      minAudioReadaheadMs: minAudioReadaheadMs,
      playbackCookie: playbackCookie,
    );
  }

  static String? decodeRedirect(Uint8List data, [int from = 0, int? to]) {
    final reader = ProtoReader(data, from, to ?? data.length);
    String? url;
    while (reader.hasRemaining) {
      final tag = reader.tag();
      if (tag.field == 1) {
        _requireWireType(tag, 2);
        url = reader.string();
      } else {
        reader.skip(tag);
      }
    }
    return url;
  }

  static SabrErrorEvent decodeError(Uint8List data, [int from = 0, int? to]) {
    final reader = ProtoReader(data, from, to ?? data.length);
    String? type;
    var code = 0;
    while (reader.hasRemaining) {
      final tag = reader.tag();
      switch (tag.field) {
        case 1:
          _requireWireType(tag, 2);
          type = reader.string();
        case 2:
          _requireWireType(tag, 0);
          code = reader.intValue();
        default:
          reader.skip(tag);
      }
    }
    return SabrErrorEvent(type, code);
  }

  static SabrContext? decodeContextUpdate(
    Uint8List data, [
    int from = 0,
    int? to,
  ]) {
    final reader = ProtoReader(data, from, to ?? data.length);
    var type = 0;
    Uint8List? value;
    var sendByDefault = false;
    var writePolicy = 0;

    while (reader.hasRemaining) {
      final tag = reader.tag();
      switch (tag.field) {
        case 1:
          _requireWireType(tag, 0);
          type = reader.intValue();
        case 3:
          _requireWireType(tag, 2);
          value = reader.bytes(maxControlValueBytes);
        case 4:
          _requireWireType(tag, 0);
          sendByDefault = reader.boolValue();
        case 5:
          _requireWireType(tag, 0);
          writePolicy = reader.intValue();
        default:
          reader.skip(tag);
      }
    }
    if (value == null) return null;
    return SabrContext(
      type: type,
      value: value,
      sendByDefault: sendByDefault,
      writePolicy: writePolicy,
    );
  }

  static SabrStreamProtectionStatusEvent decodeStreamProtectionStatus(
    Uint8List data, [
    int from = 0,
    int? to,
  ]) {
    final reader = ProtoReader(data, from, to ?? data.length);
    var status = 0;
    var maxRetries = -1;
    while (reader.hasRemaining) {
      final tag = reader.tag();
      switch (tag.field) {
        case 1:
          _requireWireType(tag, 0);
          status = reader.intValue();
        case 2:
          _requireWireType(tag, 0);
          maxRetries = reader.intValue();
        default:
          reader.skip(tag);
      }
    }
    return SabrStreamProtectionStatusEvent(status, maxRetries);
  }

  static SabrContextSendingPolicyEvent decodeContextSendingPolicy(
    Uint8List data, [
    int from = 0,
    int? to,
  ]) {
    final reader = ProtoReader(data, from, to ?? data.length);
    final start = <int>{};
    final stop = <int>{};
    final discard = <int>{};
    var entryCount = 0;

    while (reader.hasRemaining) {
      final tag = reader.tag();
      final Set<int>? target = switch (tag.field) {
        1 => start,
        2 => stop,
        3 => discard,
        _ => null,
      };
      if (target == null) {
        reader.skip(tag);
      } else if (tag.wireType == 2) {
        final packed = reader.slice();
        while (packed.hasRemaining) {
          if (++entryCount > _maxContextPolicyEntries) {
            throw SabrProtocolException(
              'SABR context policy exceeded the entry limit',
            );
          }
          target.add(packed.intValue());
        }
      } else {
        _requireWireType(tag, 0);
        if (++entryCount > _maxContextPolicyEntries) {
          throw SabrProtocolException(
            'SABR context policy exceeded the entry limit',
          );
        }
        target.add(reader.intValue());
      }
    }

    return SabrContextSendingPolicyEvent(
      start: start,
      stop: stop,
      discard: discard,
    );
  }

  static int _ticksToMs(int ticks, int timescale) =>
      (ticks * 1000) ~/ timescale;

  static void _writeFormatId(ProtoWriter w, SabrFormatId formatId) {
    w.int32(1, formatId.itag);
    if (formatId.lastModified != 0) w.int64(2, formatId.lastModified);
    final xtags = formatId.xtags;
    if (xtags != null && xtags.isNotEmpty) w.string(3, xtags);
  }

  static void _writeBufferedRange(ProtoWriter w, SabrBufferedRange range) {
    w.message(1, (f) => _writeFormatId(f, range.formatId));
    if (range.startTimeMs != 0) w.int64(2, range.startTimeMs);
    w.int64(3, range.durationMs);
    w.int32(4, range.startSegmentIndex);
    w.int32(5, range.endSegmentIndex);
    w.message(6, (tr) {
      if (range.startTimeMs != 0) tr.int64(1, range.startTimeMs);
      tr.int64(2, range.durationMs);
      tr.int32(3, 1000);
    });
  }

  static void _writeDiscardRange(ProtoWriter w, SabrFormatId formatId) {
    w.message(1, (f) => _writeFormatId(f, formatId));
    w.int64(3, _discardSentinel);
    w.int32(4, _discardSentinel);
    w.int32(5, _discardSentinel);
    w.message(6, (tr) {
      tr.int64(2, _discardSentinel);
      tr.int32(3, 1000);
    });
  }

  static SabrFormatId _decodeFormatId(ProtoReader r, SabrFormatId previous) {
    var itag = previous.itag;
    var lastModified = previous.lastModified;
    var xtags = previous.xtags;
    while (r.hasRemaining) {
      final tag = r.tag();
      switch (tag.field) {
        case 1:
          _requireWireType(tag, 0);
          itag = r.intValue();
        case 2:
          _requireWireType(tag, 0);
          lastModified = r.unsignedValue();
        case 3:
          _requireWireType(tag, 2);
          xtags = r.string();
        default:
          r.skip(tag);
      }
    }
    return SabrFormatId(itag, lastModified: lastModified, xtags: xtags);
  }

  static void _requireWireType(ProtoTag tag, int expected) {
    if (tag.wireType != expected) {
      throw SabrProtocolException(
        'Unexpected protobuf wire type ${tag.wireType} for field ${tag.field}',
      );
    }
  }
}
