import 'package:flutter/foundation.dart';

const _prefix = '[CarpGlitchTip]';

final Set<String> _warned = {};

/// Prints [message] in debug builds. With [once], a message is printed only
/// the first time, so a failure on every event does not flood the console.
void debugWarn(String message, {bool once = false}) {
  if (!kDebugMode) return;
  if (once && !_warned.add(message)) return;
  debugPrint('$_prefix $message');
}

/// Prints [line] in every build mode, e.g. the status line printed at init,
/// so it also reaches logcat / the iOS console of release builds.
void printLine(String line) => debugPrint('$_prefix $line');

/// Runs [action] and returns its result, or `null` when it throws.
///
/// The wrapper must never break the app it reports on, so every piece of
/// wrapper logic that runs inside app code paths (HTTP requests, Sentry
/// hooks) goes through this guard.
T? guard<T>(String what, T Function() action) {
  try {
    return action();
  } catch (error) {
    debugWarn('$what failed: $error', once: true);
    return null;
  }
}

/// Forgets which messages [debugWarn] already printed. For tests.
void resetDiagnostics() => _warned.clear();
