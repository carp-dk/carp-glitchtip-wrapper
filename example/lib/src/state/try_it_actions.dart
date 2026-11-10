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
/// In preview mode the outcome is read from [outbox], so it shows exactly
/// what would have been sent.
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

  /// Uploads collected data, like the data manager of a CARP app. What is
  /// reported depends on the network condition.
  Future<ActionOutcome> syncData() async {
    final invitation = state.invitation;
    if (invitation == null) return _noStudy;
    final watch = Stopwatch()..start();
    try {
      await state.caws.appendToDataStreams(
        invitation.studyDeploymentId,
        invitation.deviceRoleName ?? 'Primary Phone',
      );
      final seconds = (watch.elapsedMilliseconds / 1000).toStringAsFixed(1);
      final slow = state.networkCondition == NetworkCondition.slow;
      return _orOff(
        ActionOutcome(
          OutcomeKind.recorded,
          'Uploaded in $seconds s',
          'Recorded as the transaction "$syncTransaction"'
              '${slow ? ', which shows the slow response.' : '.'}',
        ),
      );
    } on CawsException catch (error) {
      return _orOff(
        ActionOutcome(
          OutcomeKind.reported,
          'CAWS answered ${error.statusCode}',
          error.statusCode >= 500
              ? 'The wrapper reported "HTTP ${error.statusCode}: '
                    '$syncTransaction", at most once per 10 minutes. The '
                    'app shows the error and does not report it again.'
              : 'Only server errors (5xx) are reported by the wrapper.',
        ),
      );
    } on http.ClientException catch (error) {
      return _orOff(
        ActionOutcome(
          OutcomeKind.ignored,
          'No connection',
          '${error.message}. IgnoreRule.offline() drops this expected '
              'error: nothing is reported, the request stays a breadcrumb.',
        ),
      );
    }
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
    return _orOff(
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
    if (sent != null) {
      return ActionOutcome(
        OutcomeKind.reported,
        'Reported, scrubbed',
        'GlitchTip gets: "${sent.exceptions?.lastOrNull?.value}"',
      );
    }
    return _orOff(
      const ActionOutcome(
        OutcomeKind.reported,
        'Reported, scrubbed',
        'The wrapper replaced the e-mail address and dropped the query with '
            'the token.',
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
    return _orOff(
      ActionOutcome(
        OutcomeKind.recorded,
        'Measured $seconds s',
        'Recorded as the transaction "$taskName". GlitchTip shows the '
            'count and duration percentiles of each name.',
      ),
    );
  }

  static const _noStudy = ActionOutcome(
    OutcomeKind.info,
    'No study',
    'Accept an invitation first.',
  );

  // what reporting [error] did: in preview mode read from the outbox,
  // otherwise what the rules do with it
  ActionOutcome _captured(Object error, SentryEvent? sent) {
    final type = error.runtimeType.toString();
    if (sent != null) {
      return ActionOutcome(
        OutcomeKind.reported,
        'Reported $type',
        '"${sent.exceptions?.lastOrNull?.value}", with handled: yes and the '
            'tags of the study.',
      );
    }
    final ignored = switch (error) {
      DeviceNotConnectedException() => (
        'Ignored by the app',
        'IgnoreType<DeviceNotConnectedException>() matches it: nothing is '
            'sent.',
      ),
      http.ClientException(:final message) => (
        'Ignored: offline',
        '$message. IgnoreRule.offline() drops it: nothing is sent.',
      ),
      _ => null,
    };
    if (ignored != null && (outbox != null || CarpGlitchTip.isEnabled)) {
      return ActionOutcome(OutcomeKind.ignored, ignored.$1, ignored.$2);
    }
    final description = ExampleDescriptions.describe(error);
    return _orOff(
      ActionOutcome(OutcomeKind.reported, 'Reported $type', description),
    );
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

  ActionOutcome _orOff(ActionOutcome outcome) {
    if (outbox != null || CarpGlitchTip.isEnabled) return outcome;
    return ActionOutcome(
      OutcomeKind.off,
      outcome.title,
      'Reporting is off, so GlitchTip gets nothing: '
      '${CarpGlitchTip.status}.',
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
