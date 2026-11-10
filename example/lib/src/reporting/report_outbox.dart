// Contains the transport of preview mode, which keeps reports on the device.
//
// Parts:
// - `ReportOutbox`, a `GlitchTipTestTransport` that tells the Reports tab
//   about every report.

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:carp_glitchtip_wrapper/testing.dart';
import 'package:flutter/foundation.dart';

import 'report.dart';

/// Keeps everything the Sentry SDK would send to GlitchTip, and notifies its
/// listeners when a report arrives.
///
/// The transport of preview mode (no DSN defined): nothing leaves the
/// device, and the Reports tab shows the app's reports as GlitchTip would
/// get them, after the wrapper's ignore rules and privacy policy.
class ReportOutbox extends GlitchTipTestTransport with ChangeNotifier {
  @override
  Future<SentryId?> send(SentryEnvelope envelope) async {
    final id = await super.send(envelope);
    notifyListeners();
    return id;
  }

  @override
  void clear() {
    super.clear();
    notifyListeners();
  }

  /// The error events, messages and transactions received, newest first.
  List<Report> get reports => [
    for (final envelope in envelopes.reversed)
      for (final item in envelope.items.reversed)
        if (item.originalObject case final SentryEvent event) Report.of(event),
  ];
}
