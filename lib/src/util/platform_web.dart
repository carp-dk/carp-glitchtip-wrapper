/// Whether the app runs under `flutter test` on the Dart VM: not on the web,
/// which has no `FLUTTER_TEST` to read.
bool get isFlutterTest => false;
