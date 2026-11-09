import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'platform_io.dart'
    if (dart.library.js_interop) 'platform_web.dart'
    as platform;

/// The Flutter build mode: `debug`, `profile` or `release`.
String get buildMode => kReleaseMode
    ? 'release'
    : kProfileMode
    ? 'profile'
    : 'debug';

/// Whether the app runs under `flutter test`.
bool get isFlutterTest => platform.isFlutterTest;

/// Whether this is the root isolate of a Flutter engine. Spawned isolates
/// must not start the Sentry SDK. This cannot tell the main engine from a
/// background engine (e.g. WorkManager): apps call init only from `main()`.
bool get isRootIsolate {
  if (kIsWeb) return true;
  try {
    return RootIsolateToken.instance != null;
  } catch (_) {
    return true;
  }
}
