/// Test helpers for apps that use carp_glitchtip_wrapper, e.g. to check that
/// their ignore rules drop the errors they should, and only those.
///
/// ```dart
/// late GlitchTipTestTransport transport;
///
/// setUp(() async {
///   await CarpGlitchTip.resetForTest(); // init only works once otherwise
///   transport = GlitchTipTestTransport();
///   await CarpGlitchTip.init(CarpGlitchTipOptions(
///     enabled: true, // reporting is off under `flutter test` otherwise
///     dsn: 'https://key@glitchtip.example.com/1',
///     ignoreErrors: myRules,
///     configure: (options) => options.transport = transport,
///   ));
/// });
/// tearDown(CarpGlitchTip.resetForTest);
///
/// test('my rules', () async {
///   expect(CarpGlitchTip.isEnabled, isTrue);
///   await CarpGlitchTip.captureException(StateError('a real bug'));
///   await CarpGlitchTip.captureException(MyExpectedError());
///   expect(transport.events, hasLength(1)); // only the real bug
/// });
/// ```
///
/// Captures of the app are delivered when the returned future completes.
/// Events and transactions of HTTP requests are captured in the background:
/// wait a moment (e.g. `await Future<void>.delayed(...)`) before asserting.
library;

import 'package:sentry_flutter/sentry_flutter.dart';

export 'package:sentry_flutter/sentry_flutter.dart'
    show SentryEnvelope, SentryId, SentryTransaction;

/// A Sentry transport that keeps every envelope instead of sending it.
class GlitchTipTestTransport implements Transport {
  /// Everything that would have been sent, in order.
  final List<SentryEnvelope> envelopes = [];

  /// The error events that would have been sent.
  List<SentryEvent> get events => [
    for (final envelope in envelopes)
      for (final item in envelope.items)
        if (item.originalObject case final SentryEvent event
            when event is! SentryTransaction)
          event,
  ];

  /// The transactions that would have been sent.
  List<SentryTransaction> get transactions => [
    for (final envelope in envelopes)
      for (final item in envelope.items)
        if (item.originalObject case final SentryTransaction transaction)
          transaction,
  ];

  /// Forgets everything recorded so far.
  void clear() => envelopes.clear();

  @override
  Future<SentryId?> send(SentryEnvelope envelope) async {
    envelopes.add(envelope);
    return envelope.header.eventId ?? SentryId.empty();
  }
}
