import 'package:sentry_flutter/sentry_flutter.dart';

/// [dsn] without surrounding white space and trailing slashes, a common
/// copy-paste mistake that the Sentry SDK turns into an empty project id.
String normalizeDsn(String dsn) {
  var normalized = dsn.trim();
  while (normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized;
}

// the Android emulator reaches the development machine as 10.0.2.2
const _localHosts = {'localhost', '127.0.0.1', '10.0.2.2'};

/// Why [dsn] cannot be used, or `null` when it is valid.
///
/// A DSN needs a host, a public key and a project id, and must use `https`;
/// `http` is only accepted for a server on the development machine
/// (`localhost`, `127.0.0.1` or `10.0.2.2`) when [allowInsecureLocal] is set
/// (debug builds).
String? validateDsn(String dsn, {required bool allowInsecureLocal}) {
  final uri = Uri.tryParse(dsn);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return 'not a URL';
  final local =
      allowInsecureLocal &&
      uri.scheme == 'http' &&
      _localHosts.contains(uri.host);
  if (uri.scheme != 'https' && !local) return 'not https';
  if (uri.userInfo.split(':').first.isEmpty) return 'no public key';
  if (uri.path.split('/').every((segment) => segment.isEmpty)) {
    return 'no project id';
  }
  // check what the Sentry SDK makes of it: it takes the project id from the
  // last path segment, e.g. none for `.../7/?x=1`
  try {
    final parsed = Dsn.parse(dsn);
    if (parsed.publicKey.isEmpty) return 'no public key';
    if (parsed.projectId.isEmpty) return 'no project id';
    parsed.postUri; // throws when the ingest URL cannot be built
  } catch (_) {
    return 'not accepted by the Sentry SDK';
  }
  return null;
}

/// [dsn] without its key, e.g. `glitchtip.example.com/7`, safe for logs.
String dsnLabel(String dsn) {
  final uri = Uri.tryParse(dsn);
  if (uri == null || uri.host.isEmpty) return '<invalid DSN>';
  final port = uri.hasPort ? ':${uri.port}' : '';
  return '${uri.host}$port${uri.path}';
}

/// The URL prefix the Sentry SDK sends envelopes to for [dsn], e.g.
/// `https://glitchtip.example.com/api/7/`, or `null` if [dsn] is invalid.
Uri? ingestPrefix(String dsn) {
  try {
    final post = Dsn.parse(dsn).postUri;
    final path = post.path;
    final end = path.lastIndexOf('envelope');
    return post.replace(path: end < 0 ? path : path.substring(0, end));
  } catch (_) {
    return null;
  }
}

/// Whether [url] is a request of the Sentry SDK to GlitchTip itself.
bool isIngestUrl(Uri url, Uri prefix) =>
    url.scheme == prefix.scheme &&
    url.host.toLowerCase() == prefix.host.toLowerCase() &&
    url.port == prefix.port &&
    url.path.startsWith(prefix.path);
