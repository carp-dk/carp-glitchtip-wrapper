import 'dart:collection';

/// Lets the first event per key through in each time window and counts the
/// rest, so a failure that repeats (e.g. 15 retries of every CAWS call while
/// the server is down) is reported once per window instead of every time.
class EventThrottle {
  /// Creates a throttle with the given [window].
  EventThrottle(this.window, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// How long a key stays throttled after an event was let through.
  final Duration window;

  final DateTime Function() _clock;

  // insertion ordered, so the oldest key is evicted first
  final LinkedHashMap<String, _Window> _windows = LinkedHashMap();

  static const _maxKeys = 256;

  /// Returns `null` when an event for [key] must be dropped. Otherwise
  /// returns how many events for [key] were dropped since the last one that
  /// was let through.
  int? admit(String key) {
    final now = _clock();
    final current = _windows[key];
    if (current != null && now.difference(current.start) < window) {
      current.suppressed++;
      return null;
    }
    _windows.remove(key);
    if (_windows.length >= _maxKeys) _windows.remove(_windows.keys.first);
    _windows[key] = _Window(now);
    return current?.suppressed ?? 0;
  }
}

class _Window {
  _Window(this.start);
  final DateTime start;
  int suppressed = 0;
}

/// A token bucket that allows at most [perMinute] actions per minute, e.g.
/// recorded network transactions, independent of the sample rate.
class RateLimiter {
  /// Creates a limiter allowing [perMinute] actions per minute.
  RateLimiter(this.perMinute, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now,
      _tokens = perMinute.toDouble();

  /// The allowed number of actions per minute. `0` allows none.
  final int perMinute;

  final DateTime Function() _clock;
  double _tokens;
  DateTime? _last;

  /// Takes a token. Returns `false` when the limit is reached.
  bool tryTake() {
    if (perMinute <= 0) return false;
    final now = _clock();
    final last = _last;
    if (last != null) {
      final elapsed = now.difference(last).inMicroseconds / 60e6;
      _tokens = (_tokens + elapsed * perMinute).clamp(0, perMinute.toDouble());
    }
    _last = now;
    if (_tokens < 1) return false;
    _tokens -= 1;
    return true;
  }
}
