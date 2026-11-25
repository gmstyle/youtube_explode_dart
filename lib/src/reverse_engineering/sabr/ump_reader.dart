import 'dart:math' as math;
import 'dart:typed_data';

import '../../exceptions/sabr_protocol_exception.dart';

/// Part type IDs in YouTube's UMP framing (`application/vnd.yt-ump`).
abstract final class UmpPartType {
  static const int mediaHeader = 20;
  static const int media = 21;
  static const int mediaEnd = 22;
  static const int nextRequestPolicy = 35;
  static const int formatInitializationMetadata = 42;
  static const int sabrRedirect = 43;
  static const int sabrError = 44;
  static const int reloadPlayerResponse = 46;
  static const int sabrContextUpdate = 57;
  static const int streamProtectionStatus = 58;
  static const int sabrContextSendingPolicy = 59;
  static const int endOfTrack = 62;
}

/// Incremental parser for YouTube's UMP framing.
class UmpReader {
  static const int defaultMaxPartSize = 8 * 1024 * 1024;
  static const int _defaultBufferSize = 8 * 1024;
  static const int _maxRetainedBufferSize = 128 * 1024;
  static const int _maxHeaderBytes = 10;
  static const int _maxPendingBytes = 16 * 1024 * 1024;

  final int maxPartSize;
  final int Function(int type) maxPartSizeForType;

  Uint8List _buffer = Uint8List(0);
  int _start = 0;
  int _end = 0;
  int _streamingPartType = -1;
  int _streamingRemainingBytes = 0;

  UmpReader({
    this.maxPartSize = defaultMaxPartSize,
    int Function(int type)? maxPartSizeForType,
  }) : maxPartSizeForType = maxPartSizeForType ?? ((_) => maxPartSize);

  int get _pendingSize => _end - _start;

  void reset() {
    _start = 0;
    _end = 0;
    _streamingPartType = -1;
    _streamingRemainingBytes = 0;
    if (_buffer.length > _maxRetainedBufferSize) {
      _buffer = Uint8List(0);
    }
  }

  /// Parses UMP parts from `chunk[offset .. offset + length)`.
  ///
  /// Parts of [streamPartType] are streamed directly through
  /// [onStreamStart] / [onStreamChunk] / [onStreamEnd] without staging their
  /// payload in [_buffer].
  void feedStreaming({
    required Uint8List chunk,
    int offset = 0,
    int? length,
    required int streamPartType,
    required bool Function(int type, int size) onStreamStart,
    required bool Function(Uint8List data, int from, int to) onStreamChunk,
    required bool Function() onStreamEnd,
    required bool Function(int type, Uint8List data, int from, int to) onPart,
  }) {
    final len = length ?? chunk.length;
    if (offset < 0 || len < 0 || offset > chunk.length - len) {
      throw ArgumentError('Invalid UMP input range');
    }
    var chunkPos = offset;
    final chunkEnd = offset + len;

    while (true) {
      if (_streamingPartType >= 0) {
        if (_streamingRemainingBytes == 0) {
          _streamingPartType = -1;
          if (!onStreamEnd()) return;
          continue;
        }
        if (_pendingSize > 0) {
          final take = math.min(_streamingRemainingBytes, _pendingSize);
          final payloadStart = _start;
          _start += take;
          if (_start == _end) {
            _start = 0;
            _end = 0;
          }
          _streamingRemainingBytes -= take;
          if (!onStreamChunk(_buffer, payloadStart, payloadStart + take)) {
            return;
          }
          if (_streamingRemainingBytes == 0) {
            _streamingPartType = -1;
            if (!onStreamEnd()) return;
          }
          continue;
        }
        final available = chunkEnd - chunkPos;
        if (available == 0) return;
        final take = math.min(_streamingRemainingBytes, available);
        final payloadStart = chunkPos;
        chunkPos += take;
        _streamingRemainingBytes -= take;
        if (!onStreamChunk(chunk, payloadStart, payloadStart + take)) return;
        if (_streamingRemainingBytes == 0) {
          _streamingPartType = -1;
          if (!onStreamEnd()) return;
        }
        continue;
      }

      if (_pendingSize == 0) {
        if (chunkPos >= chunkEnd) return;
        final typeRes = _readUmpVarint(chunk, chunkPos, chunkEnd);
        if (typeRes == null) {
          _appendToBuffer(chunk, chunkPos, chunkEnd - chunkPos);
          return;
        }
        final sizeRes = _readUmpVarint(chunk, typeRes.nextOffset, chunkEnd);
        if (sizeRes == null) {
          _appendToBuffer(chunk, chunkPos, chunkEnd - chunkPos);
          return;
        }
        final type = typeRes.value;
        final size = sizeRes.value;
        final sizeNext = sizeRes.nextOffset;
        _validatePartSize(type, size);

        if (type == streamPartType) {
          chunkPos = sizeNext;
          _streamingPartType = type;
          _streamingRemainingBytes = size;
          if (!onStreamStart(type, size)) return;
          if (size == 0) {
            _streamingPartType = -1;
            if (!onStreamEnd()) return;
          }
          continue;
        }

        final partEnd = sizeNext + size;
        if (partEnd <= chunkEnd) {
          chunkPos = partEnd;
          if (!onPart(type, chunk, sizeNext, partEnd)) return;
          continue;
        }
        _appendToBuffer(chunk, chunkPos, chunkEnd - chunkPos);
        return;
      }

      // _pendingSize > 0: finish straddling header or buffered part.
      final typeRes = _readUmpVarint(_buffer, _start, _end);
      if (typeRes == null) {
        if (chunkPos >= chunkEnd) return;
        final copy = math.min<int>(
          _maxHeaderBytes - math.min<int>(_pendingSize, _maxHeaderBytes - 1),
          chunkEnd - chunkPos,
        );
        _appendToBuffer(chunk, chunkPos, copy);
        chunkPos += copy;
        continue;
      }
      final sizeRes = _readUmpVarint(_buffer, typeRes.nextOffset, _end);
      if (sizeRes == null) {
        if (chunkPos >= chunkEnd) return;
        final copy = math.min<int>(
          _maxHeaderBytes - math.min<int>(_pendingSize, _maxHeaderBytes - 1),
          chunkEnd - chunkPos,
        );
        _appendToBuffer(chunk, chunkPos, copy);
        chunkPos += copy;
        continue;
      }

      final type = typeRes.value;
      final size = sizeRes.value;
      final sizeNext = sizeRes.nextOffset;
      _validatePartSize(type, size);

      if (type == streamPartType) {
        _start = sizeNext;
        if (_start == _end) {
          _start = 0;
          _end = 0;
        }
        _streamingPartType = type;
        _streamingRemainingBytes = size;
        if (!onStreamStart(type, size)) return;
        if (size == 0) {
          _streamingPartType = -1;
          if (!onStreamEnd()) return;
        }
        continue;
      }

      final partEnd = sizeNext + size;
      if (partEnd <= _end) {
        _start = partEnd;
        if (_start == _end) {
          _start = 0;
          _end = 0;
        }
        if (!onPart(type, _buffer, sizeNext, partEnd)) return;
        continue;
      }

      if (chunkPos >= chunkEnd) return;
      final needed = partEnd - _end;
      final copy = math.min(needed, chunkEnd - chunkPos);
      _appendToBuffer(chunk, chunkPos, copy);
      chunkPos += copy;
    }
  }

  /// Ensures no incomplete UMP part or varint remains at end of response.
  void finish() {
    final remaining = _pendingSize + _streamingRemainingBytes;
    if (remaining > 0 || _streamingPartType >= 0) {
      throw SabrProtocolException(
        'Truncated UMP response ($remaining bytes remain)',
      );
    }
  }

  void _validatePartSize(int type, int size) {
    final cap = math.min(maxPartSize, maxPartSizeForType(type));
    if (size < 0 || size > cap) {
      throw SabrProtocolException('UMP part is too large: $size bytes');
    }
  }

  void _appendToBuffer(Uint8List source, int offset, int count) {
    if (count <= 0) return;
    _ensureCapacity(count);
    _buffer.setRange(_end, _end + count, source, offset);
    _end += count;
  }

  void _ensureCapacity(int additionalBytes) {
    final required = _pendingSize + additionalBytes;
    if (required > _maxPendingBytes) {
      throw SabrProtocolException(
        'Incomplete UMP part exceeded the pending byte limit',
      );
    }
    if (_buffer.length - _end >= additionalBytes) return;
    if (_start > 0 && _buffer.length >= required) {
      _buffer.setRange(0, _pendingSize, _buffer, _start);
      _end = _pendingSize;
      _start = 0;
      return;
    }
    final doubled = math.max(_buffer.length, _defaultBufferSize) * 2;
    final newCapacity = math.min(
      math.max(required, doubled),
      _maxPendingBytes,
    );
    final expanded = Uint8List(newCapacity);
    if (_pendingSize > 0) {
      expanded.setRange(0, _pendingSize, _buffer, _start);
    }
    _end = _pendingSize;
    _start = 0;
    _buffer = expanded;
  }

  ({int value, int nextOffset})? _readUmpVarint(
    Uint8List data,
    int offset,
    int limit,
  ) {
    if (offset >= limit) return null;
    final first = data[offset];
    final byteLength = switch (first) {
      < 0x80 => 1,
      < 0xc0 => 2,
      < 0xe0 => 3,
      < 0xf0 => 4,
      _ => 5,
    };
    if (limit - offset < byteLength) return null;

    final int value;
    switch (byteLength) {
      case 1:
        value = first;
      case 2:
        value = (first & 0x3f) + 64 * data[offset + 1];
      case 3:
        value =
            (first & 0x1f) + 32 * (data[offset + 1] + 256 * data[offset + 2]);
      case 4:
        value =
            (first & 0x0f) +
            16 *
                (data[offset + 1] +
                    256 * (data[offset + 2] + 256 * data[offset + 3]));
      default:
        value =
            data[offset + 1] +
            256 *
                (data[offset + 2] +
                    256 * (data[offset + 3] + 256 * data[offset + 4]));
    }
    if (value < 0 || value > 0x7fffffff) {
      throw SabrProtocolException('UMP varint exceeds Int32 range');
    }
    return (value: value, nextOffset: offset + byteLength);
  }
}
