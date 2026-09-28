import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../domain/remote_file.dart';

/// Samples acknowledged bytes, including idle time, without work per chunk.
class TransferSpeed extends ChangeNotifier {
  TransferSpeed({this.elapsed});

  final Duration Function()? elapsed;
  final _clock = Stopwatch();
  final _samples = Queue<({Duration time, int bytes})>();
  Timer? _timer;
  int _bytes = 0;
  bool _disposed = false;
  double _bytesPerSecond = 0;
  double get bytesPerSecond => _bytesPerSecond;
  String get label => '${fileSizeLabel(bytesPerSecond.round())}/s';
  Duration get _now => elapsed?.call() ?? _clock.elapsed;

  void start() {
    if (_disposed) return;
    reset();
    _clock
      ..reset()
      ..start();
    _samples
      ..clear()
      ..add((time: _now, bytes: 0));
    _timer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _sample(),
    );
  }

  void update(int cumulativeBytes) {
    if (_timer != null && cumulativeBytes >= _bytes) _bytes = cumulativeBytes;
  }

  void _sample() {
    final now = _now;
    if (now <= _samples.last.time) return;
    _samples.add((time: now, bytes: _bytes));
    final cutoff = now - const Duration(seconds: 2);
    while (_samples.length > 2 && _samples.elementAt(1).time <= cutoff) {
      _samples.removeFirst();
    }
    final first = _samples.first;
    final seconds =
        (now - first.time).inMicroseconds / Duration.microsecondsPerSecond;
    final rate = (_bytes - first.bytes) / seconds;
    if (rate == bytesPerSecond) return;
    _bytesPerSecond = rate;
    notifyListeners();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _clock.stop();
  }

  void reset() {
    stop();
    _bytes = 0;
    _bytesPerSecond = 0;
    _samples.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
