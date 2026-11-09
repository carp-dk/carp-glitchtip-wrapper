import 'dart:async';

import '../util/diagnostics.dart';
import 'network_errors.dart';
import 'network_health.dart';

/// An error the app is about to report, as seen by an [IgnoreRule].
///
/// Rules run twice for an error of a request of the instrumented HTTP
/// client: when the request fails (to decide about its failure event and
/// transaction) and when the error is reported later, e.g. because the app
/// did not catch it. Both times the candidate has the error, the request's
/// [url] and [method]; only the second time are Sentry's exception values
/// part of [details].
final class IgnoreCandidate {
  /// Creates a candidate. Apps only need this to unit-test their rules.
  IgnoreCandidate({
    this.error,
    this.message,
    this.url,
    this.method,
    this.statusCode,
    this.details = const [],
  });

  /// The thrown object, or `null` for a reported message.
  final Object? error;

  /// The reported message, if any.
  final String? message;

  /// The URL of the HTTP request the error came from, if any.
  final Uri? url;

  /// The method of the HTTP request the error came from, if any.
  final String? method;

  /// The status code of the HTTP response the error came from, if any.
  final int? statusCode;

  /// Texts the wrapper extracted from the error: the exception values of
  /// the Sentry SDK and the text of `CarpGlitchTipOptions.describeError`.
  final List<String> details;

  /// Whether the error came from an HTTP request.
  bool get isHttp => url != null;

  /// Every text describing the error: `error.toString()`, the exception
  /// values the Sentry SDK extracted, the text from
  /// `CarpGlitchTipOptions.describeError` and the [message]. Each text is
  /// cut at 2,000 characters.
  late final List<String> texts = [
    if (error != null) ?guard('error.toString()', () => error.toString()),
    ...details,
    ?message,
  ].map(_cap).toList(growable: false);

  static String _cap(String text) =>
      text.length <= 2000 ? text : text.substring(0, 2000);
}

/// A rule for errors that must not be reported to GlitchTip.
///
/// ```dart
/// ignoreErrors: [
///   // by type, optionally narrowed by message or a typed predicate
///   IgnoreType<PlatformException>(where: (e) => e.code == 'discovery_failed'),
///   IgnoreType<CarpServiceRequestException>(message: 'Service Unavailable'),
///   // by message (String = contains, RegExp = hasMatch)
///   IgnoreRule.message('Location services are disabled'),
///   // anything else
///   IgnoreRule.custom((c) => c.isHttp && c.statusCode == 503),
///   // only while the phone looks offline
///   IgnoreType<TimeoutException>().whenOffline(),
/// ],
/// ```
///
/// A rule that throws is treated as not matching, so a buggy rule never
/// hides errors. Patterns run on the UI isolate: keep regular expressions
/// simple (no nested quantifiers).
abstract final class IgnoreRule {
  const IgnoreRule._({this.name});

  /// Ignores errors whose text matches [pattern] (see
  /// [IgnoreCandidate.texts]). A [String] pattern matches when a text
  /// contains it, a [RegExp] when it has a match. An empty pattern matches
  /// nothing.
  const factory IgnoreRule.message(Pattern pattern, {String? name}) =
      _MessageRule;

  /// Ignores errors for which [test] returns `true`.
  const factory IgnoreRule.custom(
    bool Function(IgnoreCandidate candidate) test, {
    String? name,
  }) = _CustomRule;

  /// Ignores transient network failures: what CARP packages throw while the
  /// phone is offline or the connection drops, such as a DNS failure
  /// ("Failed host lookup", "nodename nor servname provided", "No address
  /// associated with hostname"), an unreachable network, a reset or aborted
  /// connection, and timeouts of HTTP requests.
  ///
  /// A bare `TimeoutException` raised outside an HTTP request is only
  /// ignored while the network looks offline (see [whenOffline]).
  ///
  /// A refused connection (the server is down), TLS / certificate failures
  /// and HTTP error responses are still reported.
  const factory IgnoreRule.offline({String? name}) = _OfflineRule;

  /// A name used in diagnostics, e.g. when a rule throws.
  final String? name;

  /// Whether [candidate] must be ignored.
  bool matches(IgnoreCandidate candidate);

  /// This rule, but only applied while [condition] returns `true`, e.g. a
  /// cached connectivity state of the app.
  IgnoreRule when(bool Function() condition) =>
      _ConditionalRule(this, condition, name: name);

  /// This rule, but only applied while the network looks offline, judged by
  /// the instrumented HTTP traffic: the last request failed with a network
  /// error and nothing has succeeded since, or a request has been hanging
  /// for more than 5 seconds plus the time its body needs at 16 KB/s.
  IgnoreRule whenOffline() => _ConditionalRule(
    this,
    () => NetworkHealth.instance.looksOffline,
    name: name,
  );

  @override
  String toString() => name ?? runtimeType.toString();
}

/// Ignores errors of type [T] (including subtypes), optionally narrowed by
/// a [message] pattern and a typed [where] predicate.
///
/// ```dart
/// const IgnoreType<SocketException>()
/// IgnoreType<PlatformException>(where: (e) => e.code == 'token_failed')
/// ```
final class IgnoreType<T extends Object> extends IgnoreRule {
  /// Creates a rule for errors of type [T].
  const IgnoreType({this.message, this.where, super.name}) : super._();

  /// If set, a text of the error must match it (see [IgnoreRule.message]).
  final Pattern? message;

  /// If set, the error must also satisfy it.
  final bool Function(T error)? where;

  @override
  bool matches(IgnoreCandidate candidate) {
    final error = candidate.error;
    if (error is! T) return false;
    final where = this.where;
    if (where != null && !where(error)) return false;
    final message = this.message;
    return message == null || _matchesText(candidate, message);
  }

  @override
  String toString() => name ?? 'IgnoreType<$T>';
}

final class _MessageRule extends IgnoreRule {
  const _MessageRule(this.pattern, {super.name}) : super._();

  final Pattern pattern;

  @override
  bool matches(IgnoreCandidate candidate) => _matchesText(candidate, pattern);

  @override
  String toString() => name ?? 'IgnoreRule.message($pattern)';
}

final class _CustomRule extends IgnoreRule {
  const _CustomRule(this.test, {super.name}) : super._();

  final bool Function(IgnoreCandidate candidate) test;

  @override
  bool matches(IgnoreCandidate candidate) => test(candidate);
}

final class _OfflineRule extends IgnoreRule {
  const _OfflineRule({super.name}) : super._();

  @override
  bool matches(IgnoreCandidate candidate) {
    final error = candidate.error;
    if (error is TimeoutException) {
      return candidate.isHttp || NetworkHealth.instance.looksOffline;
    }
    if (error != null &&
        isNetworkUnavailableError(error, fromHttpRequest: candidate.isHttp)) {
      return true;
    }
    // e.g. errors from other isolates, which arrive as text only
    return candidate.texts.any(
      (t) => hasTransientNetworkMessage(t, networkError: candidate.isHttp),
    );
  }

  @override
  String toString() => name ?? 'IgnoreRule.offline()';
}

final class _ConditionalRule extends IgnoreRule {
  const _ConditionalRule(this.rule, this.condition, {super.name}) : super._();

  final IgnoreRule rule;
  final bool Function() condition;

  @override
  bool matches(IgnoreCandidate candidate) =>
      rule.matches(candidate) && condition();

  @override
  String toString() => name ?? '$rule.when(...)';
}

/// The first of [rules] that matches [candidate], or `null`. A rule that
/// throws counts as not matching.
IgnoreRule? firstMatchingRule(
  Iterable<IgnoreRule> rules,
  IgnoreCandidate candidate,
) {
  for (final rule in rules) {
    if (guard('ignore rule $rule', () => rule.matches(candidate)) ?? false) {
      return rule;
    }
  }
  return null;
}

// whether a text of [candidate] matches [pattern]; an empty pattern, which
// would match every error, matches nothing
bool _matchesText(IgnoreCandidate candidate, Pattern pattern) {
  final empty = pattern is RegExp ? pattern.pattern.isEmpty : pattern == '';
  if (empty) {
    debugWarn(
      'an ignore rule with an empty pattern matches nothing',
      once: true,
    );
    return false;
  }
  return candidate.texts.any((text) => text.contains(pattern));
}
