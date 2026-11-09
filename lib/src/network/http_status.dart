import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:sentry_flutter/sentry_flutter.dart';

/// The transaction status of an HTTP response with [statusCode].
///
/// Unlike `SpanStatus.fromHttpStatusCode`, every 5xx maps to a status that
/// GlitchTip counts as an error: Sentry maps e.g. 502 to `unknown_error`,
/// which GlitchTip's error rate ignores.
SpanStatus spanStatusForHttp(int statusCode) => switch (statusCode) {
  < 400 => const SpanStatus.ok(),
  401 => const SpanStatus.unauthenticated(),
  403 => const SpanStatus.permissionDenied(),
  404 => const SpanStatus.notFound(),
  409 => const SpanStatus.alreadyExists(),
  429 => const SpanStatus.resourceExhausted(),
  499 => const SpanStatus.cancelled(),
  < 500 => const SpanStatus.invalidArgument(),
  501 => const SpanStatus.unimplemented(),
  503 => const SpanStatus.unavailable(),
  504 => const SpanStatus.deadlineExceeded(),
  _ => const SpanStatus.internalError(),
};

/// The transaction status of a request that failed with [error].
SpanStatus spanStatusForError(Object error, {required bool networkError}) {
  if (error is TimeoutException) return const SpanStatus.deadlineExceeded();
  if (error is http.RequestAbortedException) {
    return const SpanStatus.cancelled();
  }
  if (networkError) return const SpanStatus.unavailable();
  return const SpanStatus.internalError();
}
