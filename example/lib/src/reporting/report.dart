// Contains what the Reports tab shows of one report.
//
// Parts:
// - `ReportKind`, the kinds of reports.
// - `Report`, a read-only view of an event or transaction the outbox got.

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:carp_glitchtip_wrapper/testing.dart';

/// The kinds of reports GlitchTip receives.
enum ReportKind {
  /// An error, with an exception.
  error,

  /// A message, e.g. of `CarpGlitchTip.captureMessage`.
  message,

  /// A transaction: a request or a `CarpGlitchTip.trace`.
  transaction,
}

/// A report as GlitchTip would receive it: an error event, a message or a
/// transaction, after the wrapper's ignore rules and privacy policy.
class Report {
  Report._(this.event, this.kind);

  /// The report of [event].
  factory Report.of(SentryEvent event) => Report._(
    event,
    event is SentryTransaction
        ? ReportKind.transaction
        : (event.exceptions?.isNotEmpty ?? false)
        ? ReportKind.error
        : ReportKind.message,
  );

  /// The event as the Sentry SDK would send it.
  final SentryEvent event;

  /// What kind of report this is.
  final ReportKind kind;

  /// A unique id of the report.
  String get id => event.eventId.toString();

  /// When the report was created (for a transaction: when it ended).
  DateTime? get time => event.timestamp?.toLocal();

  /// The headline: the error type, the message or the transaction name.
  String get title => switch (kind) {
    ReportKind.error => event.exceptions?.lastOrNull?.type ?? 'Error',
    ReportKind.message => event.message?.formatted ?? 'Message',
    ReportKind.transaction =>
      (event as SentryTransaction).transaction ?? 'Transaction',
  };

  /// The error text as GlitchTip shows it, after the privacy policy and the
  /// app's `describeError`; `null` for other reports.
  String? get errorValue =>
      kind == ReportKind.error ? event.exceptions?.lastOrNull?.value : null;

  /// The level, e.g. `error`.
  String? get level => event.level?.name;

  /// The searchable tags, sorted by key.
  Map<String, String> get tags => {
    for (final key in (event.tags?.keys.toList() ?? <String>[])..sort())
      key: event.tags![key]!,
  };

  /// Whether the app caught the error itself: `yes`, `no`, or `null`.
  String? get handled => event.tags?[GlitchTipTags.handled];

  /// How the error was captured, e.g. `PlatformDispatcher.onError`.
  String? get mechanism => event.tags?[GlitchTipTags.mechanism];

  /// The screen the app showed, if known.
  String? get screen => event.tags?[GlitchTipTags.screen];

  /// The `study` context, if the report has a study.
  Map<String, Object?>? get studyContext => switch (event.contexts['study']) {
    final Map<Object?, Object?> study => {
      for (final MapEntry(:key, :value) in study.entries) '$key': value,
    },
    _ => null,
  };

  /// Whether the report carries the study deployment.
  bool get hasStudy =>
      event.tags?.containsKey(GlitchTipTags.studyDeploymentId) ?? false;

  /// The method and URL of the request the report is about, if any.
  (String?, String?)? get request {
    final request = event.request;
    if (request == null || (request.url == null && request.method == null)) {
      return null;
    }
    return (request.method, request.url);
  }

  /// The breadcrumbs before the report, oldest first.
  List<Breadcrumb> get breadcrumbs => event.breadcrumbs ?? const [];

  /// The operation of a transaction, e.g. `http.client`.
  String? get operation => event.contexts.trace?.operation;

  /// The status of a transaction, e.g. `ok` or `internal_error`.
  String? get status => event.contexts.trace?.status?.toString();

  /// How long a transaction took.
  Duration? get duration {
    final event = this.event;
    if (event is! SentryTransaction) return null;
    final end = event.timestamp;
    return end?.difference(event.startTimestamp);
  }
}
