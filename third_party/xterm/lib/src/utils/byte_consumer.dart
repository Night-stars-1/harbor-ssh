import 'dart:collection';

const _highSurrogateStart = 0xD800;

const _highSurrogateEnd = 0xDBFF;

const _lowSurrogateStart = 0xDC00;

const _lowSurrogateEnd = 0xDFFF;

/// A queue of code points that keeps the original [String] chunks instead of
/// copying them into per-code-point lists.
///
/// The public counters ([length], [totalConsumed] and the arguments of
/// [rollback]) are measured in code points, while the read position is the
/// UTF-16 offset inside the first chunk. Surrogate pairs are only combined when
/// both halves come from the same chunk, which matches the per-chunk
/// `String.runes` semantics.
class ByteConsumer {
  final _queue = ListQueue<String>();

  final _consumed = ListQueue<String>();

  /// UTF-16 offset of the next unconsumed code unit in the first chunk.
  var _currentUnitOffset = 0;

  var _length = 0;

  var _totalConsumed = 0;

  void add(String data) {
    if (data.isEmpty) return;
    _queue.addLast(data);
    _length += _countCodePoints(data);
  }

  int peek() {
    final data = _queue.first;
    if (_currentUnitOffset < data.length) {
      return _codePointAt(data, _currentUnitOffset);
    }
    final result = consume();
    rollback();
    return result;
  }

  int consume() {
    while (true) {
      final data = _queue.first;

      if (_currentUnitOffset >= data.length) {
        _consumed.add(_queue.removeFirst());
        _currentUnitOffset -= data.length;
        continue;
      }

      final offset = _currentUnitOffset;
      final unit = data.codeUnitAt(offset);

      _length--;
      _totalConsumed++;

      if (unit < _highSurrogateStart) {
        _currentUnitOffset = offset + 1;
        return unit;
      }

      if (unit <= _highSurrogateEnd && offset + 1 < data.length) {
        final low = data.codeUnitAt(offset + 1);
        if (low >= _lowSurrogateStart && low <= _lowSurrogateEnd) {
          _currentUnitOffset = offset + 2;
          return 0x10000 +
              ((unit - _highSurrogateStart) << 10) +
              (low - _lowSurrogateStart);
        }
      }

      _currentUnitOffset = offset + 1;
      return unit;
    }
  }

  /// Rolls back the last [n] call.
  void rollback([int n = 1]) {
    _totalConsumed -= n;
    _length += n;

    if (n < 0) {
      _advance(-n);
      return;
    }

    var remaining = n;
    while (remaining > 0) {
      if (_currentUnitOffset == 0) {
        final data = _consumed.removeLast();
        _queue.addFirst(data);
        _currentUnitOffset = data.length;
        continue;
      }
      _currentUnitOffset = _previousCodePointOffset(
        _queue.first,
        _currentUnitOffset,
      );
      remaining--;
    }
  }

  /// Moves the read position forward by [count] code points without changing
  /// the counters. Only reachable through a negative [rollback] argument.
  void _advance(int count) {
    var remaining = count;
    while (remaining > 0) {
      if (_queue.isEmpty) return;
      final data = _queue.first;
      if (_currentUnitOffset >= data.length) {
        _consumed.add(_queue.removeFirst());
        _currentUnitOffset -= data.length;
        continue;
      }
      final offset = _currentUnitOffset;
      final codePoint = _codePointAt(data, offset);
      _currentUnitOffset = offset + (codePoint > 0xFFFF ? 2 : 1);
      remaining--;
    }
  }

  /// Rolls back to the state when this consumer had [length] code points.
  void rollbackTo(int length) {
    rollback(length - _length);
  }

  int get length => _length;

  int get totalConsumed => _totalConsumed;

  bool get isEmpty => _length == 0;

  bool get isNotEmpty => _length != 0;

  /// Unreferences data blocks that have been consumed. After calling this
  /// method, the consumer will not be able to roll back to consumed blocks.
  void unrefConsumedBlocks() {
    _consumed.clear();
  }

  /// Resets the consumer to its initial state.
  void reset() {
    _queue.clear();
    _consumed.clear();
    _currentUnitOffset = 0;
    _totalConsumed = 0;
    _length = 0;
  }

  static int _codePointAt(String data, int offset) {
    final unit = data.codeUnitAt(offset);
    if (unit >= _highSurrogateStart && unit <= _highSurrogateEnd) {
      if (offset + 1 < data.length) {
        final low = data.codeUnitAt(offset + 1);
        if (low >= _lowSurrogateStart && low <= _lowSurrogateEnd) {
          return 0x10000 +
              ((unit - _highSurrogateStart) << 10) +
              (low - _lowSurrogateStart);
        }
      }
    }
    return unit;
  }

  /// Offset of the code point that ends at [offset], pairing the high and low
  /// surrogate halves only when they belong to this chunk.
  static int _previousCodePointOffset(String data, int offset) {
    var previous = offset - 1;
    if (previous > 0) {
      final unit = data.codeUnitAt(previous);
      if (unit >= _lowSurrogateStart && unit <= _lowSurrogateEnd) {
        final high = data.codeUnitAt(previous - 1);
        if (high >= _highSurrogateStart && high <= _highSurrogateEnd) {
          previous--;
        }
      }
    }
    return previous;
  }
}

/// Counts the code points of [data] without allocating an intermediate list.
/// Unpaired surrogates count as one code point, as with `String.runes`.
int _countCodePoints(String data) {
  final length = data.length;
  var count = 0;
  var i = 0;
  while (i < length) {
    final unit = data.codeUnitAt(i);
    i++;
    if (unit >= _highSurrogateStart && unit <= _highSurrogateEnd) {
      if (i < length) {
        final next = data.codeUnitAt(i);
        if (next >= _lowSurrogateStart && next <= _lowSurrogateEnd) {
          i++;
        }
      }
    }
    count++;
  }
  return count;
}
