import 'dart:collection';

/// Infers from the instrumented HTTP traffic whether the phone currently
/// looks offline, without a connectivity plugin.
///
/// The network looks offline when
///  * the last request that failed with a connectivity error (see
///    `isNetworkUnavailableError`) failed recently and nothing has
///    succeeded since, or
///  * a request has been waiting for a response for a while and nothing has
///    succeeded since it started (a black-holed connection, e.g. a captive
///    portal or no signal). Requests with a body get extra time to upload
///    it, so a long upload on a slow network does not count.
///
/// This is what makes it safe to ignore the bare `TimeoutException` that
/// carp_webservices throws after its retries: it is created outside the HTTP
/// client, so it cannot be told apart from a Bluetooth or database timeout
/// by its type alone.
class NetworkHealth {
  /// Creates a tracker. The durations are tuned for carp_webservices, whose
  /// retries of one call can take up to ~11.5 minutes and whose attempts
  /// time out after 5-20 seconds.
  NetworkHealth({
    this.offlineMemory = const Duration(minutes: 15),
    this.hangThreshold = const Duration(seconds: 5),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// The tracker fed by the wrapper's HTTP client.
  static NetworkHealth instance = NetworkHealth();

  /// Replaces [instance] with a fresh tracker. For tests.
  static void reset([NetworkHealth? health]) =>
      instance = health ?? NetworkHealth();

  /// How long a connectivity failure keeps the network looking offline.
  final Duration offlineMemory;

  /// How long a request without a body may wait for a response before the
  /// network looks offline.
  final Duration hangThreshold;

  /// The upload speed assumed for request bodies (16 KB/s, a slow mobile
  /// connection): a request gets this much extra time per byte of body.
  static const bytesPerSecond = 16 * 1024;

  final DateTime Function() _clock;

  DateTime? _lastSuccess;
  DateTime? _lastConnectivityFailure;

  // requests waiting for a response, oldest first: when each started and
  // when it counts as hanging
  final LinkedHashMap<Object, (DateTime, DateTime)> _inFlight =
      LinkedHashMap.identity();

  // requests whose response never arrives (orphans of `Future.timeout`)
  // must not pile up forever
  static const _maxInFlight = 64;
  static const _maxInFlightAge = Duration(minutes: 30);

  /// Records that [request] was sent, with a body of [bodySize] bytes.
  void started(Object request, {int? bodySize}) {
    if (_inFlight.length >= _maxInFlight) {
      _inFlight.remove(_inFlight.keys.first);
    }
    final start = _clock();
    final upload = Duration(
      milliseconds: (bodySize ?? 0) * 1000 ~/ bytesPerSecond,
    );
    _inFlight[request] = (start, start.add(hangThreshold + upload));
  }

  /// Records that [request] got a response (any HTTP status).
  void succeeded(Object request) {
    _inFlight.remove(request);
    _lastSuccess = _clock();
  }

  /// Records that [request] failed, with a [connectivity] error or not.
  void failed(Object request, {required bool connectivity}) {
    _inFlight.remove(request);
    if (connectivity) _lastConnectivityFailure = _clock();
  }

  /// Whether the network currently looks offline.
  bool get looksOffline {
    final now = _clock();
    final lastSuccess = _lastSuccess;
    final failure = _lastConnectivityFailure;
    if (failure != null &&
        now.difference(failure) < offlineMemory &&
        (lastSuccess == null || lastSuccess.isBefore(failure))) {
      return true;
    }
    _inFlight.removeWhere(
      (_, times) => now.difference(times.$1) > _maxInFlightAge,
    );
    for (final (start, hangsAt) in _inFlight.values) {
      if (!now.isBefore(hangsAt) &&
          (lastSuccess == null || lastSuccess.isBefore(start))) {
        return true;
      }
    }
    return false;
  }
}
