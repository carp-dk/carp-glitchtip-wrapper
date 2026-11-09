import 'package:http/http.dart' as http;
import 'package:sentry_flutter/sentry_flutter.dart';

import '../filters/ignore_rule.dart';
import '../filters/network_errors.dart';
import '../runtime.dart';
import '../util/diagnostics.dart';
import 'http_status.dart';
import 'url_normalizer.dart';

/// An HTTP client that records every request it sends: a breadcrumb, a
/// GlitchTip transaction when sampled, and an error event when the request
/// fails unexpectedly.
///
/// Recording never changes the outcome of a request: the response or the
/// original exception always reaches the caller unchanged, so e.g. the
/// retries of carp_webservices keep working.
class GlitchTipHttpClient extends http.BaseClient {
  /// Records the requests sent by [inner].
  GlitchTipHttpClient(this._inner);

  final http.Client _inner;
  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final runtime = GlitchTipRuntime.current;
    final recording = runtime == null || !runtime.active
        ? null
        : guard(
            'recording a request',
            () => _Recording.begin(runtime, request),
          );
    if (recording == null) return _inner.send(request);

    final http.StreamedResponse response;
    try {
      response = await _inner.send(request);
    } catch (error, stackTrace) {
      guard('recording a failed request', () {
        recording.failed(error, stackTrace);
      });
      rethrow;
    }
    guard('recording a response', () => recording.completed(response));
    return response;
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _inner.close();
  }
}

/// One request being recorded.
class _Recording {
  _Recording._(
    this.runtime,
    this.request,
    this.name,
    this.url,
    this.decision,
    this.transaction,
  ) : start = DateTime.now().toUtc();

  /// Starts recording [request], or returns `null` when it is not recorded.
  static _Recording? begin(GlitchTipRuntime runtime, http.BaseRequest request) {
    if (!runtime.records(request.url)) return null;
    final name = runtime.requestName(request);
    final url =
        '${request.url.scheme}://'
        '${normalizeUrl(request.url, templates: runtime.pathTemplates)}';
    final decision = runtime.sampleRequest();

    // the trace headers need the transaction's ids before sending
    ISentrySpan? transaction;
    if (decision != null && runtime.propagatesTo(request.url)) {
      transaction = runtime.startTransaction(
        name: name,
        operation: 'http.client',
        decision: decision,
        description: '${request.method} $url',
      );
      final trace = transaction.toSentryTrace();
      request.headers[trace.name] = trace.value;
      final baggage = transaction.toBaggageHeader();
      if (baggage != null) request.headers[baggage.name] = baggage.value;
    }

    final recording = _Recording._(
      runtime,
      request,
      name,
      url,
      decision,
      transaction,
    );
    runtime.health.started(recording, bodySize: request.contentLength);
    return recording;
  }

  final GlitchTipRuntime runtime;
  final http.BaseRequest request;

  /// The transaction name, e.g. `GET cans.cachet.dk/api/studies/{uuid}`.
  final String name;

  /// The normalised URL, e.g. `https://cans.cachet.dk/api/studies/{uuid}`.
  final String url;

  final SentryTracesSamplingDecision? decision;
  final ISentrySpan? transaction;
  final DateTime start;

  void completed(http.StreamedResponse response) {
    final end = DateTime.now().toUtc();
    runtime.health.succeeded(this);
    final status = response.statusCode;
    runtime.addRequestBreadcrumb(
      method: request.method,
      url: url,
      duration: end.difference(start),
      statusCode: status,
      requestSize: request.contentLength,
      responseSize: response.contentLength,
    );
    if (runtime.httpOptions.captureFailedRequests &&
        runtime.httpOptions.isFailedStatus(status)) {
      runtime.captureFailedResponse(
        request: request,
        response: response,
        name: name,
        url: url,
      );
    }
    _record(end, spanStatusForHttp(status), {
      'http.response.status_code': status,
      'http.response_content_length': response.contentLength,
    });
  }

  void failed(Object error, StackTrace stackTrace) {
    final end = DateTime.now().toUtc();
    // the network state first, so a failing rule cannot leave it stale
    final networkError =
        guard('classifying an error', () {
          return isNetworkUnavailableError(error, fromHttpRequest: true);
        }) ??
        false;
    runtime.health.failed(this, connectivity: networkError);
    GlitchTipRuntime.rememberRequest(error, request);

    final candidate = IgnoreCandidate(
      error: error,
      url: request.url,
      method: request.method,
      details: [?runtime.describe(error)],
    );
    final ignored = runtime.ignoringRule(candidate) != null;
    // the app cancelled the request itself (http's abortTrigger)
    final aborted = error is http.RequestAbortedException;
    runtime.addRequestBreadcrumb(
      method: request.method,
      url: url,
      duration: end.difference(start),
      reason: error.runtimeType.toString(),
      requestSize: request.contentLength,
    );
    if (!ignored && !aborted && runtime.httpOptions.captureFailedRequests) {
      runtime.captureFailedRequest(
        request: request,
        error: error,
        stackTrace: stackTrace,
        name: name,
        url: url,
      );
    }
    if (ignored && !runtime.httpOptions.traceIgnoredErrors) {
      final transaction = this.transaction;
      if (transaction != null) runtime.discardTransaction(transaction);
      return;
    }
    _record(end, spanStatusForError(error, networkError: networkError), {
      'error.type': error.runtimeType.toString(),
    });
  }

  void _record(DateTime end, SpanStatus status, Map<String, Object?> data) {
    final decision = this.decision;
    if (decision == null) return;
    runtime.recordTransaction(
      name: name,
      operation: 'http.client',
      decision: decision,
      start: start,
      end: end,
      status: status,
      description: '${request.method} $url',
      data: {
        'http.request.method': request.method,
        'url': url,
        'http.request_content_length': request.contentLength,
        ...data,
      },
      started: transaction,
    );
  }
}
