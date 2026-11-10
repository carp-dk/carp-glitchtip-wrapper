// Contains the actions of the Try it tab and what each one reports.
//
// Parts:
// - `OutcomeKind` and `ActionOutcome`, what happened, for the user.
// - `TryItActions`, which syncs data, reports errors and measures a task.

import 'dart:async';

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:http/http.dart' as http;

import '../caws/caws_api.dart';
import '../caws/caws_exception.dart';
import '../caws/network_condition.dart';
import '../caws/sample_caws_server.dart';
import '../models/device_not_connected_exception.dart';
import '../reporting/example_reporting.dart';
import '../reporting/report_outbox.dart';
import 'app_state.dart';

/// What happened to a report.
enum OutcomeKind {
  /// An error or message was sent to GlitchTip.
  reported,

  /// A transaction was recorded.
  recorded,

  /// The wrapper or an app rule dropped the error.
  ignored,

  /// Reporting is off, so nothing was sent.
  off,

  /// Nothing to report, e.g. the app navigated.
  info,
}

/// What an action did, shown below it on the Try it tab.
class ActionOutcome {
  /// Creates an outcome.
  const ActionOutcome(this.kind, this.title, this.detail);

  /// What happened to the report.
  final OutcomeKind kind;

  /// A short summary.
  final String title;

  /// What GlitchTip gets, and why.
  final String detail;
}

/// The actions of the Try it tab. Each one does what a CARP app does and
/// says what GlitchTip gets.
///
/// In preview mode, whether an error the app reported was sent is read from
/// [outbox]. The other outcomes follow from the app's rules, the sample
/// rates and the status of reporting.
class TryItActions {
  /// Creates the actions of the app with [state]; [outbox] is the preview
  /// mode's transport, `null` in live mode.
  TryItActions(this.state, {this.outbox});

  /// The app's state, with its CAWS client and study.
  final AppState state;

  /// The reports of preview mode, if any.
  final ReportOutbox? outbox;

  /// The name of the task [measureTask] records.
  static const taskName = 'study.prepare_tasks';

  /// The name of the transaction of a data upload.
  static const syncTransaction =
      'POST ${SampleCawsServer.host}${CawsApi.dataStreamService} '
      'AppendToDataStreams';

  /// The error [throwUnhandledError] throws.
  static StateError unhandledError() =>
      StateError('Heart rate stream closed while sampling');

  /// The error [reportPersonalData] reports, with an e-mail address and a
  /// token that must not reach GlitchTip.
  static StateError personalDataError() => StateError(
    'Upload for jane@example.com failed: '
    'https://caws.example.org/api/files?token=abc123',
  );

  /// Uploads collected data, like the data manager of a CARP app, and
  /// reports what fails. What GlitchTip gets depends on the network.
  Future<ActionOutcome> syncData() async {
    final invitation = state.invitation;
    if (invitation == null) return _noStudy;
    // the sample CAWS takes the condition when the request starts
    final slow = state.networkCondition == NetworkCondition.slow;
    final watch = Stopwatch()..start();
    try {
      await state.caws.appendToDataStreams(
        invitation.studyDeploymentId,
        invitation.deviceRoleName ?? 'Primary Phone',
      );
    } catch (error, stackTrace) {
      // like AppState: report every error, the rules drop the expected ones
      final sent = await _capture(
        error,
        () => CarpGlitchTip.captureException(error, stackTrace: stackTrace),
      );
      return _captured(error, sent);
    }
    final seconds = (watch.elapsedMilliseconds / 1000).toStringAsFixed(1);
    return _transaction(
      ActionOutcome(
        OutcomeKind.recorded,
        'Uploaded in $seconds s',
        'Recorded as the transaction "$syncTransaction"'
            '${slow ? ', which shows the slow response.' : '.'}',
      ),
      CarpGlitchTip.status.httpSampleRate,
      GlitchTipKeys.httpSampleRate,
    );
  }

  /// Asks CAWS for a device that is not in the study deployment, catches
  /// the error and reports it with `CarpGlitchTip.captureException`.
  Future<ActionOutcome> reportCaughtError() async {
    final invitation = state.invitation;
    if (invitation == null) return _noStudy;
    try {
      // a role that is not part of the deployment: CAWS answers 400
      await state.caws.getDeviceDeployment(
        invitation.studyDeploymentId,
        'Smartwatch',
      );
      return const ActionOutcome(
        OutcomeKind.info,
        'No error',
        'CAWS accepted the request.',
      );
    } catch (error, stackTrace) {
      final sent = await _capture(
        error,
        () => CarpGlitchTip.captureException(error, stackTrace: stackTrace),
      );
      return _captured(error, sent);
    }
  }

  /// Throws an error from an async callback that nobody catches, e.g. in a
  /// sensor listener. The Sentry SDK reports it with `handled: no`.
  ActionOutcome throwUnhandledError() {
    unawaited(
      Future<void>.delayed(const Duration(milliseconds: 50), () {
        throw unhandledError();
      }),
    );
    return _error(
      const ActionOutcome(
        OutcomeKind.reported,
        'Thrown and not caught',
        'The Sentry SDK reports it through PlatformDispatcher.onError, '
            'tagged handled: no.',
      ),
    );
  }

  /// Reports an error whose message has an e-mail address and a token.
  Future<ActionOutcome> reportPersonalData() async {
    final error = personalDataError();
    final sent = await _capture(
      error,
      () => CarpGlitchTip.captureException(error),
    );
    return _reported(
      error,
      sent,
      ActionOutcome(
        OutcomeKind.reported,
        'Reported, scrubbed',
        sent == null
            ? 'The wrapper replaced the e-mail address and dropped the query '
                  'with the token.'
            : 'GlitchTip gets: "${sent.exceptions?.lastOrNull?.value}"',
      ),
    );
  }

  /// Reports an error the app expects; the app's ignore rule drops it.
  Future<ActionOutcome> reportExpectedError() async {
    const error = DeviceNotConnectedException('eSense');
    final sent = await _capture(
      error,
      () => CarpGlitchTip.captureException(error),
    );
    return _captured(error, sent);
  }

  /// Times a piece of work with `CarpGlitchTip.trace`.
  Future<ActionOutcome> measureTask() async {
    final watch = Stopwatch()..start();
    await CarpGlitchTip.trace(
      taskName,
      () => Future<void>.delayed(const Duration(milliseconds: 600)),
    );
    final seconds = (watch.elapsedMilliseconds / 1000).toStringAsFixed(1);
    return _transaction(
      ActionOutcome(
        OutcomeKind.recorded,
        'Measured $seconds s',
        'Recorded as the transaction "$taskName". GlitchTip shows the '
            'count and duration percentiles of each name.',
      ),
      CarpGlitchTip.status.tracesSampleRate,
      GlitchTipKeys.tracesSampleRate,
    );
  }

  static const _noStudy = ActionOutcome(
    OutcomeKind.info,
    'No study',
    'Accept an invitation first.',
  );

  /// What opening the screen of [route] records: a navigation breadcrumb,
  /// and the screen tag of the reports from there.
  ActionOutcome openedScreen(String route) {
    final outcome = ActionOutcome(
      OutcomeKind.info,
      'Opened $route',
      'Recorded as a navigation breadcrumb. Reports from that screen carry '
          'screen: $route; route arguments are not recorded.',
    );
    return CarpGlitchTip.isEnabled ? outcome : _notSent(outcome);
  }

  // whether GlitchTip gets errors: also while the Sentry SDK is still
  // starting, unlike transactions and navigation
  static bool get _sendsErrors =>
      CarpGlitchTip.isEnabled ||
      CarpGlitchTip.status.disabledReason == DisabledReason.starting;

  // what reporting [error] did, see [_reported]: the app's rules drop some
  // errors
  ActionOutcome _captured(Object error, SentryEvent? sent) {
    final reported = ActionOutcome(
      OutcomeKind.reported,
      'Reported ${error.runtimeType}',
      sent == null
          ? ExampleDescriptions.describe(error)
          : '"${sent.exceptions?.lastOrNull?.value}", with handled: yes and '
                'the tags of the study.',
    );
    if (sent != null || !_sendsErrors) return _reported(error, sent, reported);
    final dropped = switch (error) {
      CawsException(:final statusCode)
          when ExampleReporting.reportedByHttpClient(error) =>
        _error(
          ActionOutcome(
            OutcomeKind.reported,
            'CAWS answered $statusCode',
            'The HTTP client reports a server error as "HTTP $statusCode" '
                'with the request, once per 10 minutes per request; it '
                'counts the repeats and sends the count with the next one. '
                'The app\'s own report is dropped by its rule, so it is not '
                'reported twice.',
          ),
        ),
      DeviceNotConnectedException() => const ActionOutcome(
        OutcomeKind.ignored,
        'Ignored by the app',
        'IgnoreType<DeviceNotConnectedException>() matches it: nothing is '
            'sent.',
      ),
      http.ClientException(:final message) => ActionOutcome(
        OutcomeKind.ignored,
        'Ignored: offline',
        '$message. IgnoreRule.offline() drops it: nothing is sent, the '
            'request stays a breadcrumb.',
      ),
      _ => null,
    };
    return dropped ?? _reported(error, sent, reported);
  }

  // [reported], the outcome of [error] when GlitchTip gets it, or what kept
  // it from GlitchTip. In preview mode [sent] is the event the outbox got
  ActionOutcome _reported(
    Object error,
    SentryEvent? sent,
    ActionOutcome reported,
  ) {
    final title = 'Not reported: ${error.runtimeType}';
    if (!_sendsErrors) return _notSent(reported, title: title);
    if (sent != null) return reported;
    if (outbox != null) {
      return _notSent(
        reported,
        title: title,
        reason:
            'it was sampled out (${GlitchTipKeys.sampleRate} is '
            '${CarpGlitchTip.status.sampleRate})',
      );
    }
    return _error(reported);
  }

  // runs [capture]; in preview mode returns the event the outbox got for
  // [error], or null when it was dropped
  Future<SentryEvent?> _capture(
    Object error,
    Future<void> Function() capture,
  ) async {
    final outbox = this.outbox;
    final before = outbox?.envelopes.length ?? 0;
    await capture();
    if (outbox == null) return null;
    final type = error.runtimeType.toString();
    for (final envelope in outbox.envelopes.skip(before)) {
      for (final item in envelope.items) {
        if (item.originalObject case final SentryEvent event
            when event.exceptions?.lastOrNull?.type == type) {
          return event;
        }
      }
    }
    return null;
  }

  // [outcome] of an error: GlitchTip gets the share of errors the env sets
  ActionOutcome _error(ActionOutcome outcome) => _sendsErrors
      ? _share(
          outcome,
          CarpGlitchTip.status.sampleRate,
          GlitchTipKeys.sampleRate,
        )
      : _notSent(outcome);

  // [outcome] of a transaction: GlitchTip gets the share [rate] that [key]
  // sets in the env (in preview mode too, overriding its 1)
  ActionOutcome _transaction(ActionOutcome outcome, double? rate, String key) =>
      CarpGlitchTip.isEnabled ? _share(outcome, rate, key) : _notSent(outcome);

  static ActionOutcome _share(ActionOutcome outcome, double? rate, String key) {
    if (rate == null || rate >= 1) return outcome;
    if (rate <= 0) {
      return _notSent(
        outcome,
        reason: '$key is 0 in this build; define $key=1 to get every one',
      );
    }
    return ActionOutcome(
      outcome.kind,
      outcome.title,
      '${outcome.detail} $key is $rate, so GlitchTip gets only this share.',
    );
  }

  // [outcome] when GlitchTip gets nothing of it, because of [reason], by
  // default the reason reporting is off
  static ActionOutcome _notSent(
    ActionOutcome outcome, {
    String? title,
    String? reason,
  }) {
    final why =
        reason ??
        CarpGlitchTip.status.disabledReason?.description ??
        'reporting is off';
    return ActionOutcome(
      OutcomeKind.off,
      title ??
          (outcome.kind == OutcomeKind.reported
              ? 'Not reported'
              : outcome.title),
      'GlitchTip gets nothing: $why.',
    );
  }
}

/// Readable texts of the errors the example meets.
abstract final class ExampleDescriptions {
  /// A text for [error]: the description of a CAWS error, the message of a
  /// network error, else its `toString()`.
  static String describe(Object error) => switch (error) {
    CawsException() => error.description,
    http.ClientException(:final message) => message,
    _ => '$error',
  };
}
