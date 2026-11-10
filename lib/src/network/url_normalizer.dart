import 'package:meta/meta.dart';

/// An app-specific rewrite applied to a request path before the default
/// normalisation, e.g. to hide a secret path segment or to name a route.
///
/// ```dart
/// // invitation codes are secrets: never send them to GlitchTip
/// PathTemplate(RegExp(r'/invite/[^/]+'), '/invite/{code}')
/// ```
@immutable
final class PathTemplate {
  /// Creates a rewrite of every [pattern] match in a path to [replacement].
  const PathTemplate(this.pattern, this.replacement);

  /// What to look for in the URL path (the path has no query or fragment).
  final Pattern pattern;

  /// The literal replacement text. Group references such as `$1` are not
  /// expanded. Segments written as `{placeholder}` are left alone by the
  /// default normalisation.
  final String replacement;
}

/// Maximum length of a normalised route, so names stay readable in GlitchTip.
const int maxRouteLength = 200;

// Segments longer than this that are not identifiers become `{long}`.
const int _maxSegmentLength = 64;

// Segments longer than this are never inspected with regular expressions.
const int _maxInspectedLength = 4096;

final _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);
final _digits = RegExp(r'^\d+$');
final _hex = RegExp(r'^[0-9a-f]{16,}$', caseSensitive: false);
final _jwt = RegExp(r'^eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*$');
final _token = RegExp(r'^[A-Za-z0-9_\-.~%]{24,}$');
final _hasDigit = RegExp(r'\d');
final _hasLetter = RegExp('[A-Za-z]');
final _placeholderName = RegExp(r'^[A-Za-z_]{1,32}$');
final _braced = RegExp(r'^(?:\{|%7B)(.*)(?:\}|%7D)$', caseSensitive: false);
final _encodedPlaceholder = RegExp(
  r'%7B([A-Za-z_]{1,32})%7D',
  caseSensitive: false,
);

/// Turns [url] into a low-cardinality route such as
/// `cans.cachet.dk/api/studies/{uuid}/participants`.
///
/// The scheme, user info, query and fragment are dropped, the host is lower
/// cased, a non-default port is kept and a trailing slash is removed.
/// [templates] are applied to the path first; then every remaining path
/// segment that looks like an identifier is replaced, see
/// [normalizePathSegment]. The result is at most [maxRouteLength] long and
/// only cut between segments.
String normalizeUrl(Uri url, {List<PathTemplate> templates = const []}) {
  // the raw (still percent-encoded) path: decoding can throw
  var path = url.path;
  if (path.length > _maxInspectedLength) {
    path = '/{long}';
  } else {
    for (final template in templates) {
      path = path.replaceAll(template.pattern, template.replacement);
    }
    final segments = path.split('/').map(normalizePathSegment).toList();
    while (segments.isNotEmpty && segments.last.isEmpty) {
      segments.removeLast();
    }
    path = segments.join('/');
    if (!path.startsWith('/')) path = '/$path';
  }

  // an IPv6 host keeps its brackets, so the result is still a URL
  final host = url.host.contains(':')
      ? '[${url.host.toLowerCase()}]'
      : url.host.toLowerCase();
  final authority = '$host${_portOf(url)}';
  final route = '$authority$path';
  if (route.length <= maxRouteLength) return route;
  // cut between segments, so a second normalisation gives the same text
  final cut = route.lastIndexOf('/', maxRouteLength);
  return cut > authority.length
      ? route.substring(0, cut)
      : route.substring(0, maxRouteLength);
}

/// [normalizeUrl] for a URL in text form, keeping the scheme, e.g.
/// `https://cans.cachet.dk/api/studies/{uuid}`. Text that is not an absolute
/// URL becomes `{url}`.
String normalizeUrlText(String url, {List<PathTemplate> templates = const []}) {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return '{url}';
  return '${uri.scheme}://${normalizeUrl(uri, templates: templates)}';
}

/// Replaces a single path [segment] with a placeholder when it looks like an
/// identifier, otherwise returns it unchanged:
///
/// | segment                                      | placeholder |
/// |----------------------------------------------|-------------|
/// | UUID                                         | `{uuid}`    |
/// | digits only                                  | `{id}`      |
/// | 16+ hex characters including a digit         | `{hash}`    |
/// | e-mail address                               | `{email}`   |
/// | JWT, or a 24+ character letters+digits token | `{token}`   |
/// | anything longer than 64 characters           | `{long}`    |
///
/// A placeholder such as `{code}` (also with the braces percent-encoded by
/// `Uri.parse`) is kept, also inside a segment; other braced values are
/// checked without the braces.
String normalizePathSegment(String segment) {
  if (segment.isEmpty) return segment;
  // all patterns are linear, but there is no point in scanning huge segments
  if (segment.length > _maxInspectedLength) return '{long}';
  // placeholders (e.g. the `{mac}` of the privacy policy, or those of a
  // path template) keep their braces, which Uri.parse encodes, so
  // normalising again gives the same text
  if (segment.contains('%')) {
    segment = segment.replaceAllMapped(_encodedPlaceholder, (m) => '{${m[1]}}');
  }
  final braced = _braced.firstMatch(segment);
  if (braced != null) {
    final inner = braced[1]!;
    if (_placeholderName.hasMatch(inner)) return '{$inner}';
    final normalized = _identifier(inner);
    return normalized ?? '{$inner}';
  }
  return _identifier(segment) ?? segment;
}

// the placeholder for an id-like segment, or null
String? _identifier(String segment) {
  if (segment.isEmpty) return null;
  if (_uuid.hasMatch(segment)) return '{uuid}';
  if (_digits.hasMatch(segment)) return '{id}';
  if (_hex.hasMatch(segment) && _hasDigit.hasMatch(segment)) return '{hash}';
  if (segment.contains('@') || segment.toLowerCase().contains('%40')) {
    return '{email}';
  }
  if (_jwt.hasMatch(segment)) return '{token}';
  if (_token.hasMatch(segment) &&
      _hasDigit.hasMatch(segment) &&
      _hasLetter.hasMatch(segment)) {
    return '{token}';
  }
  if (segment.length > _maxSegmentLength) return '{long}';
  return null;
}

String _portOf(Uri url) {
  if (!url.hasPort) return '';
  final secure = url.scheme == 'https' || url.scheme == 'wss';
  final plain = url.scheme == 'http' || url.scheme == 'ws';
  final isDefault = (plain && url.port == 80) || (secure && url.port == 443);
  return isDefault ? '' : ':${url.port}';
}
