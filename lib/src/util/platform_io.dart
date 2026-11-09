import 'dart:io';

/// Whether the app runs under `flutter test` (the tool sets `FLUTTER_TEST`).
bool get isFlutterTest {
  try {
    return Platform.environment['FLUTTER_TEST'] == 'true';
  } catch (_) {
    return false;
  }
}
