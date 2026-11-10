import 'package:sentry_flutter/sentry_flutter.dart';

import '../network/caws.dart';
import '../network/url_normalizer.dart';
import '../util/diagnostics.dart';

/// The CARP privacy policy, applied to everything the wrapper sends: no
/// direct identifiers, no query strings, ids in URLs replaced by
/// placeholders, no secrets in paths.
///
/// It runs last (after the app's hooks), and on breadcrumbs before they are
/// stored in the scope, which is synced to the native SDKs and so ends up
/// in native crash reports that never pass Dart code. Breadcrumbs and
/// transaction names are scrubbed twice: scrubbing scrubbed text again
/// changes nothing, except for contrived text such as URLs glued into one
/// another.
class Privacy {
  /// Creates the policy. [user] replaces the user of every event: a random
  /// id per app launch, so no installation or account id is sent.
  Privacy({required this.user, this.templates = const [], this.describeError});

  /// The user every event is reported with.
  final SentryUser user;

  /// Path templates applied to every URL.
  final List<PathTemplate> templates;

  /// Describes errors whose `toString()` says nothing; must not throw.
  final String? Function(Object error)? describeError;

  static const _maxTextLength = 8192;
  static const _maxDepth = 4;

  // a URL in free text, with any scheme (also the custom schemes of OAuth
  // redirects such as carp-studies-auth://) and an optional IPv6 host;
  // braces are kept, so already normalised URLs stay intact
  static final _url = RegExp(
    r'''\b[a-z][a-z0-9+.-]{1,31}:/{1,3}(?:\[[0-9a-f:.]+\])?[^\s'"<>()\[\]\\^`|…]*''',
    caseSensitive: false,
  );
  static final _webScheme = RegExp('^(?:https?|wss?):', caseSensitive: false);
  // punctuation after a URL, which is not part of it
  static const _trailing = '.,;:!?';
  static final _queryStart = RegExp('[?#]');
  // the user info of a URL with another scheme, e.g. ftp://user:password@,
  // up to the last @ of the authority (a password may contain one)
  static final _userInfo = RegExp(
    r'^([a-z][a-z0-9+.-]*:/{1,3})[^/?#]*@',
    caseSensitive: false,
  );
  // JSON escapes of & = ? # @ (Go, .NET and Gson escape some of them), so
  // URLs, parameters and e-mail addresses are recognised
  static final _unicodeEscape = RegExp(r'\\u00(26|3[dDfF]|23|40)');
  // only at the start of a token run: linear time on long base64 text
  static final _jwt = RegExp(
    r'(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]{5,}\.[A-Za-z0-9_-]*',
  );
  // a token has a digit or is long, so prose such as "Missing Bearer
  // authorization header" is kept
  static final _bearer = RegExp(
    r'\b(Bearer|bearer|BEARER)\s+'
    r'(?=[A-Za-z0-9._~+/=-]*\d|[A-Za-z0-9._~+/=-]{20,})'
    r'[A-Za-z0-9._~+/=-]{8,}',
  );
  // an alphabetic top-level domain, so `package@1.2.3` is kept
  static final _email = RegExp(
    r'[A-Za-z0-9._%+-]{1,64}(?:@|%40)[A-Za-z0-9-]{1,63}'
    r'(?:\.[A-Za-z0-9-]{1,63}){0,7}\.[A-Za-z]{2,63}\b',
  );
  // secret parameters of a query, a fragment (OAuth implicit flow) or a
  // form body: the names of secrets anywhere, common words such as `code`
  // only after ?, & or #
  static final _querySecret = RegExp(
    '((?<![A-Za-z0-9_])'
    '(?:access_token|refresh_token|id_token|client_secret|password)='
    '|[?&#](?:code|state|session_state|token)=)'
    '[^&\\s#"\']+',
    caseSensitive: false,
  );
  // the same names in `name: value` form (Dart's Map.toString, toString()s
  // such as carp_webservices' OAuthToken, also camelCase), and a quoted
  // password=; values that are placeholders already are skipped
  static final _namedSecret = RegExp(
    '((?<![A-Za-z0-9_])'
    '(?:(?:access_?token|refresh_?token|id_?token|client_?secret)'
    '(?:\\s*:\\s*|=)["\']?|password=["\']))'
    '(?!\\{)[^\\s,;}&"\']+',
    caseSensitive: false,
  );
  // the value may contain escaped quotes
  static final _jsonSecret = RegExp(
    r'("(?:access_token|refresh_token|id_token|client_secret|password)"\s*:\s*")'
    r'(?:[^"\\]|\\.)*"',
    caseSensitive: false,
  );
  // the same in JSON inside a JSON string, e.g. in the message of a
  // PlatformException; an escape of the inner string is an escaped
  // backslash followed by one outer character or escape
  static final _escapedJsonSecret = RegExp(
    r'(\\"(?:access_token|refresh_token|id_token|client_secret|password)\\"'
    r'\s*:\s*\\")(?:\\\\(?:\\.|[^\\])|\\[^"\\]|[^"\\])*\\"',
    caseSensitive: false,
  );
  // a run of hex byte pairs, which can hold hardware addresses (e.g. of a
  // BLE wearable, a persistent id), see [_macs]
  static final _hexPairs = RegExp(
    r'(?<![0-9A-Za-z])[0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5,}(?![0-9A-Za-z])',
  );
  static final _whiteSpace = RegExp(r'\s');
  // linear: a URL, and each white-space-free run that contains an @
  static final _coarseUrl = RegExp(r'\b[A-Za-z][\w+.-]{0,31}:/\S*');
  static final _coarseEmail = RegExp(r'(?<!\S)\S*?(?:@|%40)\S*');

  /// Breadcrumb categories of the native SDKs that describe the
  /// participant's behaviour (screen on/off, charging, connectivity, ...).
  static const droppedBreadcrumbCategories = {
    'device.event',
    'device.connectivity',
    'device.orientation',
    'network.event',
    'touch',
    'ui.lifecycle',
  };

  /// [input] with URLs normalised (see [url]) and tokens, secrets, e-mail
  /// and hardware addresses replaced by placeholders. Long texts are cut at
  /// about 8,000 characters.
  String text(String input) {
    var text = _cap(input);
    if (text.contains(r':\/')) text = text.replaceAll(r'\/', '/');
    if (text.contains(r'\u00')) {
      text = text.replaceAllMapped(
        _unicodeEscape,
        (m) => String.fromCharCode(int.parse(m[1]!, radix: 16)),
      );
    }
    if (text.contains(':/')) text = text.replaceAllMapped(_url, _urlMatch);
    if (text.contains('eyJ')) text = text.replaceAll(_jwt, '{jwt}');
    text = text.replaceAllMapped(_bearer, (match) => '${match[1]} {token}');
    if (text.contains('@') || text.contains('%40')) {
      text = text.replaceAll(_email, '{email}');
    }
    if (text.contains('=')) {
      text = text.replaceAllMapped(_querySecret, (m) => '${m[1]}{redacted}');
    }
    if (text.contains('=') || text.contains(':')) {
      text = text.replaceAllMapped(_namedSecret, (m) => '${m[1]}{redacted}');
    }
    if (text.contains('"')) {
      text = text.replaceAllMapped(_jsonSecret, (m) => '${m[1]}{redacted}"');
      if (text.contains(r'\"')) {
        text = text.replaceAllMapped(
          _escapedJsonSecret,
          (m) => '${m[1]}{redacted}\\"',
        );
      }
    }
    text = text.replaceAllMapped(_hexPairs, _macs);
    return _cap(redactCawsPaths(text));
  }

  /// A transaction [name] as sent: a route name (e.g. of a navigation
  /// transaction) without its query and fragment, as the screen tag, and
  /// then scrubbed as [text].
  String transactionName(String name) =>
      text(name.startsWith('/') ? name.split(_queryStart).first : name);

  String _urlMatch(Match match) {
    final found = match[0]!;
    // punctuation after a URL is not part of it, nor are closing braces
    // without an opening one (e.g. of a JSON object around it); one pass
    // each, so long runs stay linear
    var end = found.length;
    while (end > 0 && _trailing.contains(found[end - 1])) {
      end--;
    }
    var unbalanced = 0;
    for (var i = 0; i < end; i++) {
      final char = found[i];
      if (char == '}') unbalanced++;
      if (char == '{') unbalanced--;
    }
    while (unbalanced > 0 && end > 0 && found[end - 1] == '}') {
      end--;
      unbalanced--;
    }
    final url = found.substring(0, end);
    final tail = found.substring(end);
    if (_webScheme.hasMatch(url)) return '${this.url(url)}$tail';
    // another scheme, e.g. an OAuth redirect: keep it without user info,
    // query and fragment
    final cut = url.indexOf(_queryStart);
    final kept = (cut < 0 ? url : url.substring(0, cut)).replaceFirstMapped(
      _userInfo,
      (m) => m[1]!,
    );
    return '$kept$tail';
  }

  // A hardware address is a stretch of exactly six pairs joined by one kind
  // of separator, also when glued to other pairs with another separator;
  // longer stretches are hex dumps and kept. Pair i starts at 3 * i, and
  // the separator after it is at 3 * i + 2.
  static String _macs(Match match) {
    final run = match[0]!;
    final count = (run.length + 1) ~/ 3;
    final addresses = <(int, int)>[];
    var start = 0;
    while (start < count - 1) {
      final separator = run[3 * start + 2];
      var end = start;
      while (end < count - 1 && run[3 * end + 2] == separator) {
        end++;
      }
      // pairs start..end, joined by equal separators
      final overlaps = addresses.isNotEmpty && addresses.last.$2 >= start;
      if (end - start == 5 && !overlaps) addresses.add((start, end));
      start = end;
    }
    if (addresses.isEmpty) return run;
    final scrubbed = StringBuffer();
    var next = 0;
    for (final (first, last) in addresses) {
      scrubbed
        ..write(run.substring(next, 3 * first))
        ..write('{mac}');
      next = 3 * last + 2;
    }
    return (scrubbed..write(run.substring(next))).toString();
  }

  // cut at a white space near the limit, so no URL or placeholder is cut
  String _cap(String text) {
    if (text.length <= _maxTextLength) return text;
    final space = text.lastIndexOf(_whiteSpace, _maxTextLength);
    final end = space > _maxTextLength - 1024 ? space : _maxTextLength;
    return '${text.substring(0, end)} …';
  }

  /// [input] without user info, query and fragment, and with ids in the
  /// path replaced by placeholders.
  String url(String input) => normalizeUrlText(input, templates: templates);

  /// Applies the policy to an error [event]. Returns `null` only if even
  /// the coarse fallback fails, so a bug in the policy drops an event
  /// rather than leaking data.
  SentryEvent? event(SentryEvent event) {
    try {
      _event(event);
      return event;
    } catch (error) {
      debugWarn('scrubbing an event failed: $error', once: true);
      try {
        _coarse(event);
        return event;
      } catch (_) {
        return null;
      }
    }
  }

  void _event(SentryEvent event) {
    _common(event);
    final throwable = event.throwable as Object?;
    for (final exception in event.exceptions ?? const <SentryException>[]) {
      final error = exception.throwable as Object?;
      final described = error == null ? null : _describe(error);
      final value = described ?? exception.value;
      if (value != null) exception.value = text(value);
    }
    final message = event.message;
    if (message != null) {
      message.formatted = text(message.formatted);
      final template = message.template;
      if (template != null) message.template = text(template);
      message.params = null;
    }

    // Dart errors are never fatal (the app keeps running), so `level:fatal`
    // in GlitchTip means native crashes only
    if (event.level == SentryLevel.fatal) event.level = SentryLevel.error;
    final exceptions = event.exceptions;
    if (exceptions != null && exceptions.isNotEmpty) {
      // the mechanism of the reported error, not of a chained cause such as
      // the OSError of a SocketException; the first one only for events
      // whose reported error is not among their exceptions
      final reported = throwable == null
          ? null
          : exceptions
                .where((e) => identical(e.throwable, throwable))
                .firstOrNull;
      final mechanism = reported != null
          ? reported.mechanism
          : exceptions.map((e) => e.mechanism).nonNulls.firstOrNull;
      event.tags = {
        ...?event.tags,
        // without a mechanism, the app reported the error itself
        'handled': mechanism?.handled == false ? 'no' : 'yes',
        'mechanism': mechanism?.type ?? 'generic',
      };
    }
  }

  // what error, feedback and log events share: user, request, contexts and
  // breadcrumbs
  void _common(SentryEvent event) {
    event.user = user;
    event.serverName = null;
    event.request = _request(event.request);
    _contexts(event.contexts);
    event.breadcrumbs = [
      for (final crumb in event.breadcrumbs ?? const <Breadcrumb>[])
        ?breadcrumb(crumb),
    ];
  }

  // used when the full policy fails: keep the error, drop everything else
  void _coarse(SentryEvent event) {
    event.user = user;
    event.serverName = null;
    event.request = null;
    event.breadcrumbs = null;
    for (final key in [
      'accessibility',
      'flutter_context',
      'flutter_error_details',
      'device',
      'app',
    ]) {
      event.contexts.remove(key);
    }
    String cut(String value) => _cap(
      value,
    ).replaceAll(_coarseUrl, '{url}').replaceAll(_coarseEmail, '{email}');
    for (final exception in event.exceptions ?? const <SentryException>[]) {
      final value = exception.value;
      if (value != null) exception.value = cut(value);
    }
    final message = event.message;
    if (message != null) {
      message.formatted = cut(message.formatted);
      message.template = null;
      message.params = null;
    }
  }

  String? _describe(Object error) {
    final describe = describeError;
    if (describe == null) return null;
    return guard<String?>('describeError', () => describe(error));
  }

  SentryRequest? _request(SentryRequest? request) {
    if (request == null) return null;
    final url = request.url;
    return SentryRequest(
      url: url == null ? null : this.url(url),
      method: request.method,
    );
  }

  void _contexts(Contexts contexts) {
    // screen reader / high contrast use can reveal a disability
    contexts.remove('accessibility');
    final flutter = contexts['flutter_context'];
    if (flutter is Map) {
      // the initial route can carry deep-link parameters
      contexts['flutter_context'] = {
        for (final entry in flutter.entries)
          if (entry.key != 'default_route_name') entry.key: entry.value,
      };
    }
    final details = contexts['flutter_error_details'];
    if (details is Map) {
      // `information` lists widget properties, e.g. the text on screen
      contexts['flutter_error_details'] = {
        for (final entry in details.entries)
          if (entry.key != 'information')
            entry.key: entry.value is String
                ? text(entry.value as String)
                : entry.value,
      };
    }
    final device = contexts.device;
    if (device != null) {
      // the Android SDK reports its persistent installation id as device id
      final json = device.toJson()
        ..remove('id')
        ..remove('device_unique_identifier')
        ..remove('boot_time');
      contexts.device = SentryDevice.fromJson(json);
    }
    // the iOS SDK reports a persistent hash of the vendor id
    contexts.app?.deviceAppHash = null;
    final response = contexts.response;
    if (response != null) {
      contexts.response = SentryResponse(
        statusCode: response.statusCode,
        bodySize: response.bodySize,
      );
    }
  }

  /// Applies the policy to a [breadcrumb]. Returns `null` for breadcrumbs
  /// that must not be recorded.
  Breadcrumb? breadcrumb(Breadcrumb? breadcrumb) {
    if (breadcrumb == null) return null;
    if (droppedBreadcrumbCategories.contains(breadcrumb.category)) return null;
    final message = breadcrumb.message;
    if (message != null) breadcrumb.message = text(message);
    final data = breadcrumb.data;
    if (data != null) breadcrumb.data = _data(data, 0);
    return breadcrumb;
  }

  // breadcrumb and span data, scrubbed at every level
  Map<String, dynamic> _data(Map<dynamic, dynamic> data, int depth) => {
    for (final entry in data.entries)
      // route arguments (e.g. GoRouter path and query parameters) and query
      // strings
      if (!'${entry.key}'.endsWith('_arguments') &&
          entry.key != 'http.query' &&
          entry.key != 'http.fragment')
        '${entry.key}': entry.key == 'url' && entry.value is String
            ? url(entry.value as String)
            : _value(entry.value, depth),
  };

  Object? _value(Object? value, int depth) => switch (value) {
    null || num() || bool() => value,
    String() => text(value),
    Uri() => url(value.toString()),
    Map() when depth < _maxDepth => _data(value, depth + 1),
    List() when depth < _maxDepth => [
      for (final item in value) _value(item, depth + 1),
    ],
    // serialised with toString() by the SDK
    _ => text(guard('toString()', value.toString) ?? '{unknown}'),
  };

  /// Applies the policy to a [transaction] and reduces it to what GlitchTip
  /// stores (name, operation, method, status and timing). Returns `null`
  /// for transactions that must not be sent.
  SentryTransaction? transaction(SentryTransaction transaction) {
    try {
      final trace = transaction.contexts.trace;
      final data = trace?.data;
      if (data?[discardKey] == true) return null;

      transaction.breadcrumbs = null;
      transaction.user = null;
      transaction.tags = null;
      transaction.serverName = null;
      // ignore: deprecated_member_use
      transaction.extra = null;
      for (final key in transaction.contexts.keys.toList()) {
        if (key != SentryTraceContext.type) transaction.contexts.remove(key);
      }
      final description = trace?.description;
      if (description != null) trace!.description = text(description);
      Map<String, dynamic>? scrubbed;
      if (trace != null && data != null) {
        scrubbed = _data({
          for (final entry in data.entries)
            if (entry.key != 'route_settings_arguments') entry.key: entry.value,
        }, 0);
        trace.data = scrubbed;
      }
      for (final span in transaction.spans) {
        final description = span.context.description;
        if (description != null) span.context.description = text(description);
        final spanData = _data(span.data, 0);
        span.data
          ..clear()
          ..addAll(spanData);
        span.tags.clear();
      }
      if (trace?.operation == 'http.client') {
        // GlitchTip groups transactions by name, operation and method
        transaction.request = SentryRequest(
          method: scrubbed?['http.request.method'] as String?,
          url: scrubbed?['url'] as String?,
        );
      } else {
        transaction.request = null;
      }
      final name = transaction.transaction;
      if (name != null) transaction.transaction = transactionName(name);
      return transaction;
    } catch (error) {
      debugWarn('scrubbing a transaction failed: $error', once: true);
      return null;
    }
  }

  /// Applies the policy to a user feedback [event]. What the participant
  /// wrote (message, name, e-mail) is sent as written.
  SentryEvent? feedback(SentryEvent event) {
    try {
      _common(event);
      final feedback = event.contexts.feedback;
      final url = feedback?.url;
      if (url != null) feedback!.url = this.url(url);
      return event;
    } catch (error) {
      debugWarn('scrubbing feedback failed: $error', once: true);
      return null;
    }
  }

  /// Applies the policy to a structured [log]: its body and attributes.
  SentryLog log(SentryLog log) {
    log.body = text(log.body);
    log.attributes = _attributes(log.attributes);
    return log;
  }

  /// Applies the policy to a [metric]: its name, unit and attributes.
  SentryMetric metric(SentryMetric metric) {
    metric.name = text(metric.name);
    final unit = metric.unit;
    if (unit != null) metric.unit = text(unit);
    metric.attributes = _attributes(metric.attributes);
    return metric;
  }

  // the user is replaced (the SDK adds the scope's, which an app may have
  // set to the participant), the raw arguments of a formatted log message
  // are dropped (its body has them scrubbed) and all texts are scrubbed
  Map<String, SentryAttribute> _attributes(
    Map<String, SentryAttribute> attributes,
  ) {
    final scrubbed = <String, SentryAttribute>{
      for (final entry in attributes.entries)
        if (!entry.key.startsWith('user.') &&
            !entry.key.startsWith('sentry.message.parameter.'))
          entry.key: switch (entry.value.value) {
            final String value => SentryAttribute.string(text(value)),
            final List<String> values => SentryAttribute.stringArray([
              for (final value in values) text(value),
            ]),
            _ => entry.value,
          },
    };
    final id = user.id;
    if (id != null) scrubbed['user.id'] = SentryAttribute.string(id);
    return scrubbed;
  }

  /// The trace data key marking a transaction that must be dropped.
  static const discardKey = 'carp_glitchtip.discard';
}
