import 'dart:convert';
import 'dart:typed_data';

import '../../exceptions/sabr_protocol_exception.dart';

const int _maxProtobufFieldNumber = 536870911;
const int _firstReservedFieldNumber = 19000;
const int _lastReservedFieldNumber = 19999;

bool _isValidProtobufFieldNumber(int field) =>
    field >= 1 &&
    field <= _maxProtobufFieldNumber &&
    (field < _firstReservedFieldNumber || field > _lastReservedFieldNumber);

/// Minimal, allocation-bounded protobuf wire encoder.
class ProtoWriter {
  static const int _wireVarint = 0;
  static const int _wireLengthDelimited = 2;
  static const int _wireFixed32 = 5;

  Uint8List _buffer;
  int _size = 0;
  ProtoWriter? _childWriter;

  /// Creates a [ProtoWriter].
  ProtoWriter([int initialCapacity = 256])
    : _buffer = Uint8List(initialCapacity < 1 ? 1 : initialCapacity);

  /// Resets the write cursor for reuse.
  void reset() {
    _size = 0;
  }

  ProtoWriter _child() {
    final child = _childWriter ??= ProtoWriter();
    child.reset();
    return child;
  }

  void _messageBytes(int field, ProtoWriter value) {
    _tag(field, _wireLengthDelimited);
    _varintInt(value._size);
    _appendBytes(value._buffer, value._size);
  }

  /// Writes a varint int32 [field].
  void int32(int field, int value) {
    _tag(field, _wireVarint);
    _varintInt(value);
  }

  /// Writes a varint int64/uint64 [field].
  void int64(int field, int value) {
    _tag(field, _wireVarint);
    _varintInt(value);
  }

  /// Writes a boolean [field].
  void boolField(int field, bool value) => int32(field, value ? 1 : 0);

  /// Writes an IEEE-754 float32 [field].
  void float32(int field, double value) {
    _tag(field, _wireFixed32);
    final bd = ByteData(4)..setFloat32(0, value, Endian.little);
    _appendBytes(bd.buffer.asUint8List(), 4);
  }

  /// Writes a UTF-8 string [field].
  void string(int field, String value) => bytes(field, utf8.encode(value));

  /// Writes a length-delimited byte [field].
  void bytes(int field, List<int> value) {
    _tag(field, _wireLengthDelimited);
    _varintInt(value.length);
    _appendBytes(value, value.length);
  }

  /// Writes a packed repeated int32 [field].
  void packedInt32(int field, Iterable<int> values) {
    final packed = _child();
    for (final v in values) {
      packed._varintInt(v);
    }
    _messageBytes(field, packed);
  }

  /// Writes a nested message [field] populated by [build].
  void message(int field, void Function(ProtoWriter writer) build) {
    final child = _child();
    build(child);
    _messageBytes(field, child);
  }

  /// Returns an exact copy of the encoded protobuf bytes.
  Uint8List toBytes() => Uint8List.sublistView(_buffer, 0, _size).sublist(0);

  void _tag(int field, int wireType) {
    if (!_isValidProtobufFieldNumber(field)) {
      throw ArgumentError('Invalid protobuf field number $field');
    }
    _varintInt((field * 8) + wireType);
  }

  void _varintInt(int input) {
    if (input >= 0 && input <= 0x7fffffff) {
      var v = input;
      while (true) {
        if ((v & ~0x7f) == 0) {
          _appendByte(v);
          return;
        }
        _appendByte((v & 0x7f) | 0x80);
        v = v ~/ 128;
      }
    }
    var v = BigInt.from(input);
    if (v < BigInt.zero) {
      v = v.toUnsigned(64);
    }
    final mask7f = BigInt.from(0x7f);
    while (true) {
      final low = (v & mask7f).toInt();
      v = v >> 7;
      if (v == BigInt.zero) {
        _appendByte(low);
        return;
      }
      _appendByte(low | 0x80);
    }
  }

  void _appendByte(int value) {
    _ensureCapacity(1);
    _buffer[_size++] = value & 0xff;
  }

  void _appendBytes(List<int> value, int count) {
    if (count == 0) return;
    _ensureCapacity(count);
    _buffer.setRange(_size, _size + count, value);
    _size += count;
  }

  void _ensureCapacity(int extra) {
    final required = _size + extra;
    if (required <= _buffer.length) return;
    var capacity = _buffer.length;
    while (capacity < required) {
      capacity = capacity * 2;
      if (capacity < required) capacity = required;
    }
    final next = Uint8List(capacity);
    next.setRange(0, _size, _buffer);
    _buffer = next;
  }
}

/// Decoded protobuf tag `(field, wireType)`.
class ProtoTag {
  final int field;
  final int wireType;

  const ProtoTag(this.field, this.wireType);
}

/// Minimal, bounds-checked protobuf wire decoder.
class ProtoReader {
  final Uint8List _data;
  int _position;
  final int _limit;

  /// Creates a [ProtoReader] over `_data[from .. limit)`.
  ProtoReader(this._data, [int from = 0, int? limit])
    : _position = from,
      _limit = limit ?? _data.length {
    if (from < 0 || from > _limit || _limit > _data.length) {
      throw ArgumentError('Invalid protobuf input range');
    }
  }

  int get position => _position;
  bool get hasRemaining => _position < _limit;

  /// Reads the next field tag.
  ProtoTag tag() {
    final raw = varintBigInt();
    final field = (raw >> 3).toInt();
    if (!_isValidProtobufFieldNumber(field)) {
      throw SabrProtocolException('Invalid protobuf field number $field');
    }
    return ProtoTag(field, (raw & BigInt.from(7)).toInt());
  }

  /// Reads an unsigned 64-bit varint as [BigInt].
  BigInt varintBigInt() {
    var result = BigInt.zero;
    var shift = 0;
    for (var i = 0; i < 10; i++) {
      if (_position >= _limit) {
        throw SabrProtocolException('Truncated protobuf varint');
      }
      final byte = _data[_position++];
      if (shift == 63 && ((byte & 0x7f) > 1 || (byte & 0x80) != 0)) {
        throw SabrProtocolException('Protobuf varint overflows 64 bits');
      }
      result |= BigInt.from(byte & 0x7f) << shift;
      if ((byte & 0x80) == 0) return result;
      shift += 7;
    }
    throw SabrProtocolException('Protobuf varint is too long');
  }

  /// Reads an unsigned varint fitting in a non-negative 53-bit/64-bit Dart [int].
  int unsignedValue() {
    final big = varintBigInt();
    if (!big.isValidInt || big.toInt() < 0) {
      throw SabrProtocolException('Protobuf unsigned value exceeds Dart int');
    }
    return big.toInt();
  }

  /// Reads an unsigned varint validated against `[min, max]`.
  int intValue({int max = 0x7fffffff, int min = 0}) {
    final value = unsignedValue();
    if (value < min || value > max) {
      throw SabrProtocolException(
        'Protobuf unsigned value $value does not fit in [$min, $max]',
      );
    }
    return value;
  }

  /// Reads a protobuf boolean varint.
  bool boolValue() {
    final value = varintBigInt();
    return value != BigInt.zero;
  }

  /// Reads a length-delimited byte slice up to [maxSize].
  Uint8List bytes([int maxSize = 0x7fffffff]) {
    final length = _readLength(maxSize);
    final end = _position + length;
    final out = Uint8List.fromList(_data.sublist(_position, end));
    _position = end;
    return out;
  }

  /// Returns a sub-[ProtoReader] for a length-delimited embedded message.
  ProtoReader slice([int maxSize = 0x7fffffff]) {
    final length = _readLength(maxSize);
    final start = _position;
    final end = start + length;
    _position = end;
    return ProtoReader(_data, start, end);
  }

  /// Reads a length-delimited UTF-8 string up to [maxSize] bytes.
  String string([int maxSize = 0x7fffffff]) {
    final length = _readLength(maxSize);
    final end = _position + length;
    final decoded = utf8.decode(Uint8List.sublistView(_data, _position, end));
    _position = end;
    return decoded;
  }

  int _readLength(int maxSize) {
    final length = unsignedValue();
    if (length > maxSize) {
      throw SabrProtocolException('Protobuf field exceeded $maxSize bytes');
    }
    final end = _position + length;
    if (end < _position || end > _limit) {
      throw SabrProtocolException('Truncated protobuf field');
    }
    return length;
  }

  /// Skips the field payload corresponding to [tag].
  void skip(ProtoTag tag) {
    switch (tag.wireType) {
      case 0:
        varintBigInt();
      case 1:
        _advance(8);
      case 2:
        _advance(_readLength(0x7fffffff));
      case 5:
        _advance(4);
      default:
        throw SabrProtocolException(
          'Unsupported protobuf wire type ${tag.wireType}',
        );
    }
  }

  void _advance(int count) {
    final end = _position + count;
    if (end < _position || end > _limit) {
      throw SabrProtocolException('Truncated protobuf field');
    }
    _position = end;
  }
}
