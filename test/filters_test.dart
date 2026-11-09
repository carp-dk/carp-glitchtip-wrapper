// Tests for the filters: the ignore rules (IgnoreCandidate, IgnoreRule,
// IgnoreType, the offline rule), the network error classifier, NetworkHealth
// and the event throttle / rate limiter.

import 'dart:async';
import 'dart:io';

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:carp_glitchtip_wrapper/src/filters/ignore_rule.dart'
    show firstMatchingRule;
import 'package:carp_glitchtip_wrapper/src/filters/network_errors.dart';
import 'package:carp_glitchtip_wrapper/src/filters/network_health.dart';
import 'package:carp_glitchtip_wrapper/src/util/limits.dart';
import 'package:carp_glitchtip_wrapper/testing.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:sentry_flutter/sentry_flutter.dart' show SentryHttpClientError;

final _api = Uri.parse('https://cans.cachet.dk/api/studies');

// errno values of the host: Darwin on macOS / iOS, Linux / Android otherwise
final _darwin = Platform.isMacOS || Platform.isIOS;
final _errno = _darwin
    ? (netUnreach: 51, connReset: 54, timedOut: 60, connRefused: 61)
    : (netUnreach: 101, connReset: 104, timedOut: 110, connRefused: 111);
const _darwinTransient = {32, 50, 51, 53, 54, 60, 64, 65};
const _linuxTransient = {32, 100, 101, 103, 104, 110, 112, 113};
final _hostTransient = _darwin ? _darwinTransient : _linuxTransient;
final _otherTransient = (_darwin ? _linuxTransient : _darwinTransient)
    .difference(_hostTransient);

// the unambiguous offline messages, worded as the platforms word them
const _offlineMessages = [
  "Failed host lookup: 'cans.cachet.dk'",
  'No address associated with hostname',
  'nodename nor servname provided, or not known',
  'Temporary failure in name resolution',
  'Network is unreachable',
  'Network is down',
  'No route to host',
  'Host is down',
  'The Internet connection appears to be offline.',
  'The network connection was lost.',
  'A data connection is not currently allowed.',
  'International roaming is currently off.',
];

// generic connection messages, worded as dart:io and browsers word them
const _connectionMessages = [
  'Connection timed out',
  'Operation timed out',
  'HTTP connection timed out after 0:00:20.000000, host: x, port: 443',
  'Connection reset by peer',
  'Software caused connection abort',
  'Broken pipe',
  'Connection closed before full header was received',
  'Connection closed while receiving data',
  'Connection closed before response was received',
  'Failed to fetch',
  'NetworkError when attempting to fetch resource.',
  'XMLHttpRequest error.',
];

const _certificateError = HandshakeException(
  'Handshake error in client',
  OSError('CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate'),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // a clock the tests move by hand
  var now = DateTime.utc(2026, 10, 29, 12);
  DateTime clock() => now;
  void advance(Duration duration) => now = now.add(duration);

  setUp(() => now = DateTime.utc(2026, 10, 29, 12));
  tearDown(NetworkHealth.reset);

  // whether [rule] ignores [candidate], applied as the wrapper applies it
  bool ignores(IgnoreRule rule, IgnoreCandidate candidate) =>
      firstMatchingRule([rule], candidate) != null;

  const offline = IgnoreRule.offline();
  bool offlineIgnores(
    Object? error, {
    bool fromHttp = false,
    String? message,
    List<String> details = const [],
  }) => ignores(
    offline,
    IgnoreCandidate(
      error: error,
      message: message,
      url: fromHttp ? _api : null,
      details: details,
    ),
  );

  group('IgnoreCandidate', () {
    test('texts are error.toString(), the details and the message', () {
      final candidate = IgnoreCandidate(
        error: StateError('boom'),
        details: ['StateError: Bad state: boom', 'described'],
        message: 'reported',
      );
      expect(candidate.texts, [
        'Bad state: boom',
        'StateError: Bad state: boom',
        'described',
        'reported',
      ]);
    });

    test('texts of a message without an error', () {
      expect(IgnoreCandidate(message: 'Low battery').texts, ['Low battery']);
      expect(IgnoreCandidate().texts, isEmpty);
    });

    test('each text is cut at 2,000 characters', () {
      final long = 'x' * 2500;
      final candidate = IgnoreCandidate(
        error: long,
        details: [long, 'y' * 2000],
        message: long,
      );
      expect(candidate.texts, ['x' * 2000, 'x' * 2000, 'y' * 2000, 'x' * 2000]);
    });

    test('text after the cut is not matched', () {
      final candidate = IgnoreCandidate(
        error: StateError('${'x' * 2100} needle'),
      );
      expect(ignores(const IgnoreRule.message('needle'), candidate), isFalse);
      expect(ignores(const IgnoreRule.message('state: xx'), candidate), isTrue);
    });

    test('an error whose toString throws is skipped', () {
      final candidate = IgnoreCandidate(
        error: _Unprintable(),
        details: ['detail'],
        message: 'message',
      );
      expect(candidate.texts, ['detail', 'message']);
    });

    test('isHttp tells whether the candidate has a URL', () {
      expect(IgnoreCandidate(url: _api).isHttp, isTrue);
      final notHttp = IgnoreCandidate(
        error: StateError('x'),
        method: 'GET',
        statusCode: 503,
      );
      expect(notHttp.isHttp, isFalse);
    });
  });

  group('IgnoreRule.message', () {
    test('a String matches when a text contains it', () {
      const rule = IgnoreRule.message('Location services are disabled');
      final error = PlatformException(
        code: 'location',
        message: 'Location services are disabled.',
      );
      expect(ignores(rule, IgnoreCandidate(error: error)), isTrue);
      final details = IgnoreCandidate(
        error: StateError('opaque'),
        details: ['Location services are disabled'],
      );
      expect(ignores(rule, details), isTrue);
      final message = IgnoreCandidate(
        message: 'Location services are disabled',
      );
      expect(ignores(rule, message), isTrue);
      final other = IgnoreCandidate(message: 'Location permission denied');
      expect(ignores(rule, other), isFalse);
    });

    test('a String is matched literally and case-sensitively', () {
      const rule = IgnoreRule.message('a.c');
      expect(ignores(rule, IgnoreCandidate(message: 'xa.cx')), isTrue);
      expect(ignores(rule, IgnoreCandidate(message: 'abc')), isFalse);
      expect(ignores(rule, IgnoreCandidate(message: 'A.C')), isFalse);
    });

    test('a RegExp matches when a text has a match', () {
      final rule = IgnoreRule.message(RegExp(r'^Bad state: (boom|bang)$'));
      expect(ignores(rule, IgnoreCandidate(error: StateError('bang'))), isTrue);
      expect(
        ignores(rule, IgnoreCandidate(error: StateError('bangs'))),
        isFalse,
      );
      final anyCase = IgnoreRule.message(
        RegExp('service unavailable', caseSensitive: false),
      );
      final candidate = IgnoreCandidate(message: '503 Service Unavailable');
      expect(ignores(anyCase, candidate), isTrue);
    });
  });

  group('IgnoreRule.custom', () {
    test('ignores what the test returns true for', () {
      final rule = IgnoreRule.custom((c) => c.isHttp && c.statusCode == 503);
      final unavailable = IgnoreCandidate(url: _api, statusCode: 503);
      expect(ignores(rule, unavailable), isTrue);
      final serverError = IgnoreCandidate(url: _api, statusCode: 500);
      expect(ignores(rule, serverError), isFalse);
      expect(ignores(rule, IgnoreCandidate(statusCode: 503)), isFalse);
    });

    test('the test sees the candidate', () {
      final candidate = IgnoreCandidate(
        error: StateError('x'),
        message: 'm',
        url: _api,
        method: 'POST',
        statusCode: 502,
        details: ['d'],
      );
      final seen = <IgnoreCandidate>[];
      final rule = IgnoreRule.custom((c) {
        seen.add(c);
        return false;
      });
      expect(ignores(rule, candidate), isFalse);
      expect(seen.single, same(candidate));
    });
  });

  group('IgnoreType', () {
    test('matches errors of the type and its subtypes only', () {
      bool matches(IgnoreRule rule, Object error) =>
          ignores(rule, IgnoreCandidate(error: error));
      expect(matches(const IgnoreType<StateError>(), StateError('x')), isTrue);
      expect(matches(const IgnoreType<Error>(), StateError('x')), isTrue);
      const format = FormatException('x');
      expect(matches(const IgnoreType<Exception>(), format), isTrue);
      expect(matches(const IgnoreType<StateError>(), ArgumentError()), isFalse);
      expect(matches(const IgnoreType<Exception>(), StateError('x')), isFalse);
    });

    test('never matches a message without an error', () {
      const rule = IgnoreType<Object>();
      expect(ignores(rule, IgnoreCandidate(message: 'x')), isFalse);
      expect(ignores(rule, IgnoreCandidate(error: 'x')), isTrue);
    });

    test('message narrows by the texts', () {
      const rule = IgnoreType<StateError>(message: 'Service Unavailable');
      bool matches(Object error, {String? message, List<String>? details}) =>
          ignores(
            rule,
            IgnoreCandidate(
              error: error,
              message: message,
              details: details ?? const [],
            ),
          );
      expect(matches(StateError('503 Service Unavailable')), isTrue);
      expect(
        matches(StateError('x'), details: ['Service Unavailable']),
        isTrue,
      );
      expect(matches(StateError('x'), message: 'Service Unavailable'), isTrue);
      expect(matches(StateError('502 Bad Gateway')), isFalse);
      expect(matches(ArgumentError('Service Unavailable')), isFalse);

      final regExp = IgnoreType<StateError>(message: RegExp(r'code \d{3}$'));
      final code = IgnoreCandidate(error: StateError('code 503'));
      expect(ignores(regExp, code), isTrue);
      final longer = IgnoreCandidate(error: StateError('code 5030'));
      expect(ignores(regExp, longer), isFalse);
    });

    test('where gets the error typed', () {
      final rule = IgnoreType<PlatformException>(
        where: (e) => e.code == 'discovery_failed',
      );
      final discovery = PlatformException(code: 'discovery_failed');
      expect(ignores(rule, IgnoreCandidate(error: discovery)), isTrue);
      final other = PlatformException(code: 'other');
      expect(ignores(rule, IgnoreCandidate(error: other)), isFalse);
      final text = IgnoreCandidate(error: StateError('discovery_failed'));
      expect(ignores(rule, text), isFalse);
    });

    test('message and where must both match', () {
      final rule = IgnoreType<PlatformException>(
        message: 'timeout',
        where: (e) => e.code == 'ble',
      );
      bool matches(String code, String message) => ignores(
        rule,
        IgnoreCandidate(
          error: PlatformException(code: code, message: message),
        ),
      );
      expect(matches('ble', 'scan timeout'), isTrue);
      expect(matches('ble', 'scan failed'), isFalse);
      expect(matches('gps', 'fix timeout'), isFalse);
    });

    test('can be const, also in a const list of rules', () {
      const rules = <IgnoreRule>[
        IgnoreType<FormatException>(),
        IgnoreType<PlatformException>(where: _isDiscoveryFailure),
        IgnoreType<StateError>(message: 'Service Unavailable'),
        IgnoreRule.message('Location services are disabled'),
        IgnoreRule.custom(_isServiceUnavailable),
        IgnoreRule.offline(),
      ];
      const options = CarpGlitchTipOptions(ignoreErrors: rules);
      expect(options.ignoreErrors, same(rules));
      expect(rules.first, same(const IgnoreType<FormatException>()));

      IgnoreRule? match(IgnoreCandidate candidate) =>
          firstMatchingRule(rules, candidate);
      const format = FormatException('x');
      expect(match(IgnoreCandidate(error: format)), same(rules[0]));
      final discovery = PlatformException(code: 'discovery_failed');
      expect(match(IgnoreCandidate(error: discovery)), same(rules[1]));
      final unavailable = StateError('503 Service Unavailable');
      expect(match(IgnoreCandidate(error: unavailable)), same(rules[2]));
      final location = IgnoreCandidate(
        message: 'Location services are disabled',
      );
      expect(match(location), same(rules[3]));
      final status = IgnoreCandidate(url: _api, statusCode: 503);
      expect(match(status), same(rules[4]));
      const dns = SocketException("Failed host lookup: 'cans.cachet.dk'");
      expect(match(IgnoreCandidate(error: dns)), same(rules[5]));
      final other = PlatformException(code: 'other');
      expect(match(IgnoreCandidate(error: other)), isNull);
    });
  });

  group('when and whenOffline', () {
    test('when applies the rule only while the condition holds', () {
      var online = true;
      final rule = const IgnoreType<StateError>().when(() => !online);
      final candidate = IgnoreCandidate(error: StateError('x'));
      expect(ignores(rule, candidate), isFalse);
      online = false;
      expect(ignores(rule, candidate), isTrue);
      final other = IgnoreCandidate(error: ArgumentError('x'));
      expect(ignores(rule, other), isFalse, reason: 'never widens the rule');
    });

    test('a throwing condition counts as not matching', () {
      final rule = const IgnoreType<StateError>().when(
        () => throw StateError('no connectivity state'),
      );
      expect(ignores(rule, IgnoreCandidate(error: StateError('x'))), isFalse);
    });

    test('whenOffline applies the rule while the network looks offline', () {
      final health = NetworkHealth(clock: clock);
      NetworkHealth.reset(health);
      final rule = const IgnoreType<TimeoutException>().whenOffline();
      final candidate = IgnoreCandidate(error: TimeoutException('x'));
      expect(ignores(rule, candidate), isFalse);
      health.failed(Object(), connectivity: true);
      expect(ignores(rule, candidate), isTrue);
      advance(const Duration(seconds: 1));
      health.succeeded(Object());
      expect(ignores(rule, candidate), isFalse);
    });

    test('whenOffline reads the current NetworkHealth.instance', () {
      final rule = const IgnoreRule.message('boom').whenOffline();
      final candidate = IgnoreCandidate(message: 'boom');
      NetworkHealth.reset(
        NetworkHealth()..failed(Object(), connectivity: true),
      );
      expect(ignores(rule, candidate), isTrue);
      NetworkHealth.reset();
      expect(ignores(rule, candidate), isFalse);
    });
  });

  group('firstMatchingRule', () {
    test('returns the first rule that matches', () {
      final no = IgnoreRule.custom((_) => false, name: 'no');
      final first = IgnoreRule.custom((_) => true, name: 'first');
      final second = IgnoreRule.custom((_) => true, name: 'second');
      final candidate = IgnoreCandidate(error: StateError('x'));
      expect(firstMatchingRule([no, first, second], candidate), same(first));
      expect(firstMatchingRule([no], candidate), isNull);
      expect(firstMatchingRule(const [], candidate), isNull);
    });

    test('a throwing rule counts as not matching', () {
      final throws = IgnoreRule.custom((_) => throw StateError('rule bug'));
      final badCast = IgnoreRule.custom((c) => (c.error! as String).isEmpty);
      final badWhere = IgnoreType<StateError>(
        where: (_) => throw UnsupportedError('x'),
      );
      final matches = IgnoreRule.custom((_) => true);
      final candidate = IgnoreCandidate(error: StateError('x'));
      final buggy = [throws, badCast, badWhere];
      expect(firstMatchingRule(buggy, candidate), isNull);
      expect(firstMatchingRule([...buggy, matches], candidate), same(matches));
    });

    test('a rule is named by its name, else describes itself', () {
      expect(IgnoreRule.custom((_) => true, name: 'c').toString(), 'c');
      expect(const IgnoreType<StateError>(name: 't').toString(), 't');
      expect(const IgnoreRule.message('x', name: 'm').toString(), 'm');
      expect(const IgnoreRule.offline(name: 'o').toString(), 'o');
      expect(const IgnoreType<StateError>().toString(), contains('StateError'));
      expect(
        const IgnoreRule.message('Location services').toString(),
        contains('Location services'),
      );
      expect(const IgnoreRule.offline().toString(), contains('offline'));
    });

    test('when and whenOffline keep the name', () {
      const named = IgnoreType<StateError>(name: 'state');
      expect(named.when(() => true).toString(), 'state');
      expect(named.whenOffline().toString(), 'state');
      expect(
        const IgnoreType<StateError>().whenOffline().toString(),
        contains('StateError'),
      );
    });
  });

  group('IgnoreRule.offline()', () {
    test('is the const default of offlineErrors', () {
      expect(const CarpGlitchTipOptions().offlineErrors, same(offline));
      expect(const CarpGlitchTipOptions().ignoreErrors, isEmpty);
    });

    test('ignores a DNS failure, also outside an HTTP request', () {
      const darwin = SocketException(
        "Failed host lookup: 'cans.cachet.dk'",
        osError: OSError('nodename nor servname provided, or not known', 8),
      );
      const android = SocketException(
        "Failed host lookup: 'cans.cachet.dk'",
        osError: OSError('No address associated with hostname', 7),
      );
      expect(offlineIgnores(darwin), isTrue);
      expect(offlineIgnores(darwin, fromHttp: true), isTrue);
      expect(offlineIgnores(android), isTrue);
    });

    test('ignores an http ClientException with a transient message', () {
      for (final message in [
        'Connection closed before full header was received',
        'Connection closed while receiving data',
        'Connection reset by peer',
        'Failed to fetch',
        'XMLHttpRequest error.',
      ]) {
        final error = http.ClientException(message, _api);
        expect(offlineIgnores(error), isTrue, reason: message);
        expect(offlineIgnores(error, fromHttp: true), isTrue, reason: message);
      }
      final closed = http.ClientException(
        'HTTP request failed. Client is already closed.',
        _api,
      );
      expect(offlineIgnores(closed, fromHttp: true), isFalse);
    });

    test('ignores the DNS failure of a real request', () async {
      final error = await _requestError(
        Uri.parse('http://carp-glitchtip-test.invalid/'),
      );
      // package:http's _ClientSocketException
      expect(error, isA<http.ClientException>());
      expect(error, isA<SocketException>());
      expect(offlineIgnores(error), isTrue);
      expect(offlineIgnores(error, fromHttp: true), isTrue);
      final candidate = IgnoreCandidate(error: error);
      expect(ignores(const IgnoreType<SocketException>(), candidate), isTrue);
      expect(
        ignores(const IgnoreType<http.ClientException>(), candidate),
        isTrue,
      );
    });

    test('reports a refused connection of a real request', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      final error = await _requestError(Uri.parse('http://127.0.0.1:$port/'));
      expect(
        error,
        isA<SocketException>().having(
          (e) => e.osError?.errorCode,
          'errno',
          _errno.connRefused,
        ),
      );
      expect(error, isA<http.ClientException>());
      expect(offlineIgnores(error), isFalse);
      expect(offlineIgnores(error, fromHttp: true), isFalse);
    });

    test('ignores a TimeoutException of an HTTP request', () {
      final timeout = TimeoutException(
        'No response',
        const Duration(seconds: 5),
      );
      expect(offlineIgnores(timeout, fromHttp: true), isTrue);
    });

    test('ignores a bare TimeoutException only while offline', () {
      final health = NetworkHealth(clock: clock);
      NetworkHealth.reset(health);
      final timeout = TimeoutException('Future not completed');
      expect(offlineIgnores(timeout), isFalse);

      health.failed(Object(), connectivity: true);
      expect(offlineIgnores(timeout), isTrue);
      advance(const Duration(seconds: 1));
      health.succeeded(Object());
      expect(offlineIgnores(timeout), isFalse);

      // a request hanging since after the success
      advance(const Duration(seconds: 1));
      health.started(Object());
      advance(const Duration(seconds: 5));
      expect(offlineIgnores(timeout), isTrue);
    });

    test('ignores a HandshakeException only when the connection dropped', () {
      const dropped = HandshakeException(
        'Connection terminated during handshake',
      );
      expect(offlineIgnores(dropped), isTrue);
      expect(offlineIgnores(_certificateError), isFalse);
      expect(offlineIgnores(_certificateError, fromHttp: true), isFalse);
    });

    test('ignores generic connection messages of network errors', () {
      for (final message in _connectionMessages) {
        expect(
          offlineIgnores(SocketException(message)),
          isTrue,
          reason: message,
        );
        expect(offlineIgnores(HttpException(message)), isTrue, reason: message);
        expect(offlineIgnores(OSError(message)), isTrue, reason: message);
        final client = http.ClientException(message);
        expect(offlineIgnores(client), isTrue, reason: message);
      }
    });

    test('ignores generic connection messages of other errors only from '
        'an HTTP request', () {
      for (final message in _connectionMessages) {
        final platform = PlatformException(code: 'ble', message: message);
        expect(offlineIgnores(platform), isFalse, reason: message);
        expect(offlineIgnores(StateError(message)), isFalse, reason: message);
        expect(
          offlineIgnores(null, message: message),
          isFalse,
          reason: message,
        );
        expect(
          offlineIgnores(StateError(message), fromHttp: true),
          isTrue,
          reason: message,
        );
        expect(
          offlineIgnores(null, message: message, fromHttp: true),
          isTrue,
          reason: message,
        );
      }
    });

    test('ignores an unambiguous offline message in any text', () {
      for (final message in _offlineMessages) {
        final platform = PlatformException(code: 'error', message: message);
        expect(offlineIgnores(platform), isTrue, reason: message);
        expect(offlineIgnores(StateError(message)), isTrue, reason: message);
        // e.g. an error from another isolate, which arrives as text
        expect(offlineIgnores(null, message: message), isTrue, reason: message);
        expect(
          offlineIgnores(StateError('opaque'), details: [message]),
          isTrue,
          reason: message,
        );
        final upper = message.toUpperCase();
        expect(offlineIgnores(null, message: upper), isTrue, reason: upper);
      }
    });

    test('ignores NSURLErrorDomain -1009, not -1004', () {
      const offlineText =
          'Error Domain=NSURLErrorDomain Code=-1009 "(null)" '
          'UserInfo={_kCFStreamErrorCodeKey=50}';
      const refusedText =
          'Error Domain=NSURLErrorDomain Code=-1004 '
          '"Could not connect to the server."';
      PlatformException error(String text) =>
          PlatformException(code: 'auth', message: text);
      expect(offlineIgnores(error(offlineText)), isTrue);
      expect(offlineIgnores(null, message: offlineText), isTrue);
      expect(offlineIgnores(error(refusedText)), isFalse);
      expect(offlineIgnores(error(refusedText), fromHttp: true), isFalse);
    });

    test('reports errors unrelated to the network', () {
      expect(offlineIgnores(StateError('boom')), isFalse);
      expect(offlineIgnores(StateError('boom'), fromHttp: true), isFalse);
      final camera = PlatformException(code: 'camera_access_denied');
      expect(offlineIgnores(camera), isFalse);
      expect(offlineIgnores(null, message: 'Low battery'), isFalse);
    });

    test('reports HTTP error responses', () {
      final candidate = IgnoreCandidate(
        error: SentryHttpClientError(
          'HTTP 503: GET cans.cachet.dk/api/studies',
        ),
        url: _api,
        method: 'GET',
        statusCode: 503,
      );
      expect(ignores(offline, candidate), isFalse);
    });

    test('an error whose toString throws does not hide the other texts', () {
      final candidate = IgnoreCandidate(
        error: _Unprintable(),
        details: ["SocketException: Failed host lookup: 'cans.cachet.dk'"],
      );
      expect(ignores(offline, candidate), isTrue);
    });
  });

  group('isNetworkUnavailableError', () {
    test('is false for null and errors unrelated to the network', () {
      expect(isNetworkUnavailableError(null), isFalse);
      expect(
        isNetworkUnavailableError(StateError('boom'), fromHttpRequest: true),
        isFalse,
      );
      expect(
        isNetworkUnavailableError(
          const FormatException('Unexpected character'),
          fromHttpRequest: true,
        ),
        isFalse,
      );
    });

    test('a SocketException with a transient errno of the host', () {
      for (final code in _hostTransient) {
        final error = SocketException(
          'Socket error',
          osError: OSError('', code),
        );
        expect(isNetworkUnavailableError(error), isTrue, reason: 'errno $code');
      }
    });

    test('ENETUNREACH (${_errno.netUnreach}), ECONNRESET '
        '(${_errno.connReset}) and ETIMEDOUT (${_errno.timedOut}) count, '
        'ECONNREFUSED (${_errno.connRefused}) does not', () {
      SocketException error(int code) => SocketException(
        'Connection failed',
        osError: OSError('', code),
        address: InternetAddress.loopbackIPv4,
        port: 443,
      );
      expect(isNetworkUnavailableError(error(_errno.netUnreach)), isTrue);
      expect(isNetworkUnavailableError(error(_errno.connReset)), isTrue);
      expect(isNetworkUnavailableError(error(_errno.timedOut)), isTrue);
      final refused = error(_errno.connRefused);
      expect(isNetworkUnavailableError(refused), isFalse);
      expect(
        isNetworkUnavailableError(refused, fromHttpRequest: true),
        isFalse,
      );
    });

    test('errno values of the other platform family do not count', () {
      for (final code in _otherTransient) {
        final error = SocketException(
          'Socket error',
          osError: OSError('', code),
        );
        expect(
          isNetworkUnavailableError(error),
          isFalse,
          reason: 'errno $code',
        );
      }
    });

    test('a SocketException with an offline or connection message', () {
      for (final message in [..._offlineMessages, ..._connectionMessages]) {
        final error = SocketException(message);
        expect(isNetworkUnavailableError(error), isTrue, reason: message);
        final inOsError = SocketException('', osError: OSError(message));
        expect(isNetworkUnavailableError(inOsError), isTrue, reason: message);
      }
      const closed = SocketException('Socket has been closed');
      expect(isNetworkUnavailableError(closed), isFalse);
    });

    test('a raw OSError is classified like a SocketException', () {
      for (final code in _hostTransient) {
        final error = OSError('', code);
        expect(isNetworkUnavailableError(error), isTrue, reason: 'errno $code');
      }
      expect(
        isNetworkUnavailableError(const OSError('Network is down')),
        isTrue,
      );
      expect(isNetworkUnavailableError(const OSError('Broken pipe')), isTrue);
      final refused = OSError('Connection refused', _errno.connRefused);
      expect(isNetworkUnavailableError(refused), isFalse);
    });

    test('a TimeoutException only from an HTTP request', () {
      final timeout = TimeoutException('Future not completed');
      expect(isNetworkUnavailableError(timeout), isFalse);
      expect(isNetworkUnavailableError(timeout, fromHttpRequest: true), isTrue);
    });

    test('a HandshakeException only when the connection was terminated', () {
      const dropped = HandshakeException(
        'Connection terminated during handshake',
      );
      expect(isNetworkUnavailableError(dropped), isTrue);
      expect(
        isNetworkUnavailableError(_certificateError, fromHttpRequest: true),
        isFalse,
      );
    });

    test('HttpException and ClientException with connection messages', () {
      for (final message in _connectionMessages) {
        final httpException = HttpException(message);
        expect(
          isNetworkUnavailableError(httpException),
          isTrue,
          reason: message,
        );
        final client = http.ClientException(message, _api);
        expect(isNetworkUnavailableError(client), isTrue, reason: message);
      }
      const redirect = HttpException('Redirect limit exceeded');
      expect(isNetworkUnavailableError(redirect), isFalse);
      final closed = http.ClientException(
        'HTTP request failed. Client is already closed.',
        _api,
      );
      expect(isNetworkUnavailableError(closed, fromHttpRequest: true), isFalse);
    });

    test('NSURLErrorDomain offline codes, not others', () {
      for (final code in [-1001, -1003, -1005, -1006, -1009, -1018, -1020]) {
        final error = PlatformException(
          code: 'ios',
          message: 'Error Domain=NSURLErrorDomain Code=$code "(null)"',
        );
        expect(isNetworkUnavailableError(error), isTrue, reason: '$code');
      }
      for (final code in [-1004, -1011, -1200, -1202]) {
        final error = PlatformException(
          code: 'ios',
          message: 'Error Domain=NSURLErrorDomain Code=$code "(null)"',
        );
        expect(
          isNetworkUnavailableError(error, fromHttpRequest: true),
          isFalse,
          reason: '$code',
        );
      }
    });

    test('TLS certificate errors and HTTP error responses are not', () {
      for (final error in [
        _certificateError,
        const CertificateException('Bad certificate'),
        SentryHttpClientError('HTTP 503: GET cans.cachet.dk/api/studies'),
        SentryHttpClientError('HTTP 504: GET cans.cachet.dk/api/studies'),
      ]) {
        expect(
          isNetworkUnavailableError(error, fromHttpRequest: true),
          isFalse,
          reason: '$error',
        );
      }
    });

    test('generic messages of other errors count only from a request', () {
      final error = StateError('Connection timed out');
      expect(isNetworkUnavailableError(error), isFalse);
      expect(isNetworkUnavailableError(error, fromHttpRequest: true), isTrue);
      final unreachable = StateError('Network is unreachable');
      expect(isNetworkUnavailableError(unreachable), isTrue);
    });
  });

  group('hasTransientNetworkMessage', () {
    test('offline messages count in any text, in any case', () {
      for (final message in _offlineMessages) {
        expect(hasTransientNetworkMessage(message), isTrue, reason: message);
        final wrapped = 'PlatformException(error, ${message.toUpperCase()})';
        expect(hasTransientNetworkMessage(wrapped), isTrue, reason: wrapped);
      }
    });

    test('connection messages count only for a network error', () {
      for (final message in _connectionMessages) {
        expect(hasTransientNetworkMessage(message), isFalse, reason: message);
        expect(
          hasTransientNetworkMessage(message, networkError: true),
          isTrue,
          reason: message,
        );
      }
    });

    test('NSURLErrorDomain offline codes count in any text', () {
      for (final code in [-1001, -1003, -1005, -1006, -1009, -1018, -1020]) {
        final text = 'Error Domain=NSURLErrorDomain Code=$code "(null)"';
        expect(hasTransientNetworkMessage(text), isTrue, reason: text);
      }
      const other = 'Error Domain=NSURLErrorDomain Code=-1004 "(null)"';
      expect(hasTransientNetworkMessage(other, networkError: true), isFalse);
    });

    test('other texts do not count', () {
      for (final text in [
        '',
        'Bad state: boom',
        'Connection refused',
        'Could not connect to the server.',
        'HTTP 503: Service Unavailable',
        'CERTIFICATE_VERIFY_FAILED: certificate has expired',
      ]) {
        expect(
          hasTransientNetworkMessage(text, networkError: true),
          isFalse,
          reason: text,
        );
      }
    });
  });

  group('isNetworkError', () {
    test('is true for network errors of any kind', () {
      for (final error in <Object>[
        http.ClientException('HTTP request failed. Client is already closed.'),
        TimeoutException('Future not completed'),
        const SocketException('Connection refused'),
        const OSError('Connection refused', 61),
        const HttpException('Redirect limit exceeded'),
        _certificateError,
      ]) {
        expect(isNetworkError(error), isTrue, reason: '$error');
      }
    });

    test('is false for other errors, whatever their text', () {
      for (final error in <Object>[
        StateError("Failed host lookup: 'cans.cachet.dk'"),
        PlatformException(code: 'x', message: 'Network is unreachable'),
        const FormatException('Connection timed out'),
        "SocketException: Failed host lookup: 'cans.cachet.dk'",
      ]) {
        expect(isNetworkError(error), isFalse, reason: '$error');
      }
    });
  });

  group('networkErrorCode', () {
    test('is the errno of a SocketException or OSError', () {
      final socket = SocketException(
        'Connection reset by peer',
        osError: OSError('Connection reset by peer', _errno.connReset),
      );
      expect(networkErrorCode(socket), _errno.connReset);
      expect(networkErrorCode(OSError('', _errno.timedOut)), _errno.timedOut);
    });

    test('is null without an OS error and for other errors', () {
      expect(networkErrorCode(const SocketException('closed')), isNull);
      expect(networkErrorCode(http.ClientException('Failed to fetch')), isNull);
      expect(networkErrorCode(TimeoutException('x')), isNull);
      expect(networkErrorCode(StateError('x')), isNull);
    });

    test('is the errno of a real refused connection', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = server.port;
      await server.close();
      final error = await _requestError(Uri.parse('http://127.0.0.1:$port/'));
      expect(networkErrorCode(error), _errno.connRefused);
      expect(isNetworkError(error), isTrue);
      expect(isNetworkUnavailableError(error, fromHttpRequest: true), isFalse);
    });
  });

  group('NetworkHealth', () {
    late NetworkHealth health;
    setUp(() => health = NetworkHealth(clock: clock));

    test('defaults to 15 minutes of offline memory and a 5 s hang', () {
      final defaults = NetworkHealth();
      expect(defaults.offlineMemory, const Duration(minutes: 15));
      expect(defaults.hangThreshold, const Duration(seconds: 5));
    });

    test('does not look offline without traffic', () {
      expect(health.looksOffline, isFalse);
    });

    test('a connectivity failure looks offline until a success', () {
      health.failed(Object(), connectivity: true);
      expect(health.looksOffline, isTrue);
      advance(const Duration(minutes: 5));
      expect(health.looksOffline, isTrue);
      health.succeeded(Object());
      expect(health.looksOffline, isFalse);
    });

    test('a failure that is not a connectivity failure does not', () {
      final request = Object();
      health.started(request);
      health.failed(request, connectivity: false);
      advance(const Duration(minutes: 1));
      expect(health.looksOffline, isFalse);
    });

    test('a success before the failure does not count', () {
      health.succeeded(Object());
      advance(const Duration(seconds: 1));
      health.failed(Object(), connectivity: true);
      expect(health.looksOffline, isTrue);
    });

    test('a failure older than offlineMemory is forgotten', () {
      health.failed(Object(), connectivity: true);
      advance(const Duration(minutes: 14, seconds: 59));
      expect(health.looksOffline, isTrue);
      advance(const Duration(seconds: 2));
      expect(health.looksOffline, isFalse);

      final short = NetworkHealth(
        offlineMemory: const Duration(minutes: 1),
        clock: clock,
      )..failed(Object(), connectivity: true);
      advance(const Duration(seconds: 59));
      expect(short.looksOffline, isTrue);
      advance(const Duration(seconds: 2));
      expect(short.looksOffline, isFalse);
    });

    test('a request hanging for hangThreshold looks offline', () {
      health.started(Object());
      advance(const Duration(milliseconds: 4999));
      expect(health.looksOffline, isFalse);
      advance(const Duration(milliseconds: 1));
      expect(health.looksOffline, isTrue);

      final patient = NetworkHealth(
        hangThreshold: const Duration(seconds: 30),
        clock: clock,
      )..started(Object());
      advance(const Duration(seconds: 29));
      expect(patient.looksOffline, isFalse);
      advance(const Duration(seconds: 1));
      expect(patient.looksOffline, isTrue);
    });

    test('a success after a hanging request started clears it', () {
      health.started(Object());
      advance(const Duration(seconds: 1));
      health.succeeded(Object());
      advance(const Duration(seconds: 10));
      expect(health.looksOffline, isFalse);
    });

    test('a success before a hanging request started does not', () {
      health.succeeded(Object());
      advance(const Duration(seconds: 1));
      health.started(Object());
      advance(const Duration(seconds: 6));
      expect(health.looksOffline, isTrue);
    });

    test('a request that failed no longer hangs', () {
      final request = Object();
      health.started(request);
      advance(const Duration(seconds: 1));
      health.failed(request, connectivity: false);
      advance(const Duration(seconds: 10));
      expect(health.looksOffline, isFalse);
    });

    test('keeps at most 64 requests in flight, dropping the oldest', () {
      health.started(Object());
      advance(const Duration(seconds: 10));
      for (var i = 0; i < 63; i++) {
        health.started(Object());
      }
      expect(health.looksOffline, isTrue, reason: 'the oldest hangs');
      health.started(Object()); // the 65th drops the oldest
      expect(health.looksOffline, isFalse);
      advance(const Duration(seconds: 5));
      expect(health.looksOffline, isTrue, reason: 'the others hang now');
    });

    test('forgets requests in flight for more than 30 minutes', () {
      health.started(Object());
      advance(const Duration(minutes: 29));
      expect(health.looksOffline, isTrue);
      advance(const Duration(minutes: 2));
      expect(health.looksOffline, isFalse);
    });

    test('reset installs a fresh or the given tracker', () {
      NetworkHealth.reset(health);
      expect(NetworkHealth.instance, same(health));
      NetworkHealth.reset();
      expect(NetworkHealth.instance, isNot(same(health)));
      expect(NetworkHealth.instance.looksOffline, isFalse);
    });
  });

  group('EventThrottle', () {
    test('admits the first event per key, then counts the rest', () {
      final throttle = EventThrottle(const Duration(minutes: 10), clock: clock);
      expect(throttle.admit('a'), 0);
      expect(throttle.admit('a'), isNull);
      expect(throttle.admit('b'), 0, reason: 'keys are independent');
      advance(const Duration(minutes: 9, seconds: 59));
      expect(throttle.admit('a'), isNull);
      advance(const Duration(seconds: 2));
      expect(throttle.admit('a'), 2, reason: 'dropped since the last one');
      expect(throttle.admit('a'), isNull);
      advance(const Duration(minutes: 11));
      expect(throttle.admit('a'), 1);
      advance(const Duration(minutes: 11));
      expect(throttle.admit('a'), 0);
    });

    test('the window starts at the admitted event', () {
      final throttle = EventThrottle(const Duration(minutes: 10), clock: clock);
      expect(throttle.admit('a'), 0);
      for (var i = 0; i < 9; i++) {
        advance(const Duration(minutes: 1));
        expect(throttle.admit('a'), isNull);
      }
      advance(const Duration(minutes: 1, seconds: 1));
      expect(throttle.admit('a'), 9);
    });

    test('tracks at most 256 keys, forgetting the oldest', () {
      final throttle = EventThrottle(const Duration(minutes: 10), clock: clock);
      for (var i = 0; i <= 256; i++) {
        expect(throttle.admit('key $i'), 0);
      }
      for (var i = 1; i <= 256; i++) {
        expect(throttle.admit('key $i'), isNull, reason: 'key $i');
      }
      expect(throttle.admit('key 0'), 0, reason: 'evicted by the 257th');
    });
  });

  group('RateLimiter', () {
    test('allows perMinute actions at once, then none', () {
      final limiter = RateLimiter(3, clock: clock);
      final taken = [for (var i = 0; i < 4; i++) limiter.tryTake()];
      expect(taken, [true, true, true, false]);
    });

    test('refills tokens over time', () {
      final limiter = RateLimiter(60, clock: clock); // a token per second
      for (var i = 0; i < 60; i++) {
        expect(limiter.tryTake(), isTrue);
      }
      expect(limiter.tryTake(), isFalse);
      advance(const Duration(milliseconds: 500));
      expect(limiter.tryTake(), isFalse);
      advance(const Duration(milliseconds: 600));
      expect(limiter.tryTake(), isTrue);
      expect(limiter.tryTake(), isFalse);
    });

    test('never holds more than perMinute tokens', () {
      final limiter = RateLimiter(2, clock: clock);
      expect(limiter.tryTake(), isTrue);
      expect(limiter.tryTake(), isTrue);
      advance(const Duration(hours: 1));
      final taken = [for (var i = 0; i < 3; i++) limiter.tryTake()];
      expect(taken, [true, true, false]);
    });

    test('perMinute 0 allows nothing', () {
      final limiter = RateLimiter(0, clock: clock);
      expect(limiter.tryTake(), isFalse);
      advance(const Duration(hours: 1));
      expect(limiter.tryTake(), isFalse);
    });
  });

  group('ignore rules when reporting', () {
    const dsn = 'https://key@glitchtip.example.com/1';
    const dnsFailure = SocketException(
      "Failed host lookup: 'cans.cachet.dk'",
      osError: OSError('nodename nor servname provided, or not known', 8),
    );
    late GlitchTipTestTransport transport;

    setUp(() async {
      await CarpGlitchTip.resetForTest();
      transport = GlitchTipTestTransport();
    });
    tearDown(CarpGlitchTip.resetForTest);

    void sendTo(SentryFlutterOptions options) {
      options.transport = transport;
      options.autoInitializeNativeSdk = false;
    }

    // the exception types (or messages) sent, once a last message arrived
    Future<List<String?>> sent() async {
      await CarpGlitchTip.captureMessage('last');
      bool arrived() =>
          transport.events.any((event) => event.message?.formatted == 'last');
      for (var i = 0; i < 200 && !arrived(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(arrived(), isTrue, reason: 'the last message was not sent');
      return [
        for (final event in transport.events)
          if (event.message?.formatted != 'last')
            event.exceptions?.firstOrNull?.type ?? event.message?.formatted,
      ];
    }

    test('the default offline rule drops offline errors only', () async {
      await CarpGlitchTip.init(
        CarpGlitchTipOptions(enabled: true, dsn: dsn, configure: sendTo),
      );
      await CarpGlitchTip.captureException(dnsFailure);
      await CarpGlitchTip.captureException(StateError('bug'));
      expect(await sent(), ['StateError']);
    });

    test('offlineErrors: null reports offline errors', () async {
      await CarpGlitchTip.init(
        CarpGlitchTipOptions(
          enabled: true,
          dsn: dsn,
          offlineErrors: null,
          configure: sendTo,
        ),
      );
      await CarpGlitchTip.captureException(dnsFailure);
      expect(await sent(), ['SocketException']);
    });

    test('ignoreErrors apply in addition to the offline rule', () async {
      await CarpGlitchTip.init(
        CarpGlitchTipOptions(
          enabled: true,
          dsn: dsn,
          ignoreErrors: const [
            IgnoreType<StateError>(),
            IgnoreRule.message('Location services'),
          ],
          configure: sendTo,
        ),
      );
      await CarpGlitchTip.captureException(dnsFailure);
      await CarpGlitchTip.captureException(StateError('expected'));
      await CarpGlitchTip.captureMessage('Location services are disabled');
      await CarpGlitchTip.captureException(ArgumentError('bug'));
      expect(await sent(), ['ArgumentError']);
    });

    test('a throwing rule never hides an error', () async {
      await CarpGlitchTip.init(
        CarpGlitchTipOptions(
          enabled: true,
          dsn: dsn,
          ignoreErrors: [IgnoreRule.custom((_) => throw StateError('rule'))],
          configure: sendTo,
        ),
      );
      await CarpGlitchTip.captureException(ArgumentError('bug'));
      expect(await sent(), ['ArgumentError']);
    });

    test('whenOffline rules follow NetworkHealth.instance', () async {
      await CarpGlitchTip.init(
        CarpGlitchTipOptions(
          enabled: true,
          dsn: dsn,
          ignoreErrors: [const IgnoreRule.message('expected').whenOffline()],
          configure: sendTo,
        ),
      );
      await CarpGlitchTip.captureException(StateError('expected, online'));
      NetworkHealth.instance.failed(Object(), connectivity: true);
      await CarpGlitchTip.captureException(ArgumentError('expected, offline'));
      expect(await sent(), ['StateError']);
    });
  });
}

/// The error of a real request with package:http's IOClient. flutter_test
/// replaces dart:io's HttpClient with a fake answering 400, so the request
/// runs with the real one.
Future<Object> _requestError(Uri url) =>
    HttpOverrides.runWithHttpOverrides(() async {
      final client = IOClient();
      try {
        await client.get(url).timeout(const Duration(seconds: 10));
      } catch (error) {
        return error;
      } finally {
        client.close();
      }
      fail('the request to $url did not fail');
    }, _DartIoHttpOverrides());

// creates dart:io's real HttpClient
class _DartIoHttpOverrides extends HttpOverrides {}

class _Unprintable {
  @override
  String toString() => throw StateError('no text');
}

bool _isDiscoveryFailure(PlatformException error) =>
    error.code == 'discovery_failed';

bool _isServiceUnavailable(IgnoreCandidate candidate) =>
    candidate.statusCode == 503;
