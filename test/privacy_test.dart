// Tests for the CARP privacy policy: URL normalisation, CAWS secrets and the
// scrubbing of events, breadcrumbs and transactions before they are sent.

import 'dart:convert';

import 'package:carp_glitchtip_wrapper/carp_glitchtip_wrapper.dart';
import 'package:carp_glitchtip_wrapper/src/network/caws.dart';
import 'package:carp_glitchtip_wrapper/src/network/url_normalizer.dart';
import 'package:carp_glitchtip_wrapper/src/pipeline/privacy.dart';
import 'package:carp_glitchtip_wrapper/testing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sentry_flutter/sentry_flutter.dart';

const _uuid = '123e4567-e89b-12d3-a456-426614174000';
const _jwt =
    'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.'
    'dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U';
const _getStatus =
    'dk.cachet.carp.deployments.infrastructure.'
    'DeploymentServiceRequest.GetStudyDeploymentStatus';
const _deploymentService = 'https://cans.cachet.dk/api/deployment-service';
const _droppedCategories = [
  'device.event',
  'device.connectivity',
  'device.orientation',
  'network.event',
  'touch',
  'ui.lifecycle',
];

String _route(String url, [List<PathTemplate> templates = const []]) =>
    normalizeUrl(Uri.parse(url), templates: templates);

http.Request _rpc(String method, String url, List<int> body) =>
    http.Request(method, Uri.parse(url))..bodyBytes = body;

List<int> _json(Object body) => utf8.encode(jsonEncode(body));

/// A finished transaction, as the Sentry SDK passes it to
/// `beforeSendTransaction`.
Future<SentryTransaction> _transaction(
  String name,
  String operation, {
  Map<String, Object> data = const {},
}) async {
  SentryTransaction? sent;
  final hub = Hub(
    SentryOptions(dsn: 'https://key@glitchtip.example.com/1')
      ..tracesSampleRate = 1
      // as set by the wrapper
      ..traceLifecycle = SentryTraceLifecycle.static
      ..transport = GlitchTipTestTransport()
      ..beforeSendTransaction = (transaction, hint) {
        sent = transaction;
        return null;
      },
  );
  final span = hub.startTransaction(name, operation);
  data.forEach(span.setData);
  await span.finish();
  await hub.close();
  return sent!;
}

/// Waits until [done] holds, for at most two seconds.
Future<void> _waitFor(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final launchUser = SentryUser(id: 'launch-user');
  final privacy = Privacy(user: launchUser);

  group('normalizeUrl', () {
    test('replaces UUIDs in any case with {uuid}', () {
      expect(
        _route('https://cans.cachet.dk/api/studies/$_uuid/participants'),
        'cans.cachet.dk/api/studies/{uuid}/participants',
      );
      expect(_route('https://h/a/${_uuid.toUpperCase()}'), 'h/a/{uuid}');
      expect(
        _route('https://h/a/aBcDeF01-2345-6789-AbCd-eF0123456789'),
        'h/a/{uuid}',
      );
    });

    test('replaces digit-only segments with {id}', () {
      expect(
        _route('https://h/api/v2/users/42/data/0'),
        'h/api/v2/users/{id}/data/{id}',
      );
    });

    test('replaces 16+ hex characters with a digit with {hash}', () {
      expect(_route('https://h/files/0123456789abcdef'), 'h/files/{hash}');
      expect(_route('https://h/files/DEADBEEF00112233'), 'h/files/{hash}');
      final hex = _uuid.replaceAll('-', '');
      expect(_route('https://h/files/$hex'), 'h/files/{hash}');
      // pure letters are words, and 15 characters are too short
      expect(
        _route('https://h/files/deadbeefdeadbeef'),
        'h/files/deadbeefdeadbeef',
      );
      expect(
        _route('https://h/files/0123456789abcde'),
        'h/files/0123456789abcde',
      );
    });

    test('replaces e-mail addresses, also percent-encoded, with {email}', () {
      expect(
        _route('https://h/users/john.doe@example.com/profile'),
        'h/users/{email}/profile',
      );
      expect(
        _route('https://h/users/john.doe%40example.com'),
        'h/users/{email}',
      );
    });

    test('replaces JWTs and long letter+digit tokens with {token}', () {
      expect(_route('https://h/reset/$_jwt'), 'h/reset/{token}');
      expect(
        _route('https://h/invite/a1B2c3D4e5F6g7H8i9J0k1L2'),
        'h/invite/{token}',
      );
      expect(
        _route('https://h/invite/Ab12_cd34-ef56.gh78~ij90'),
        'h/invite/{token}',
      );
    });

    test('keeps long plain words and short mixed segments', () {
      for (final segment in [
        'internationalization',
        'pneumonoultramicroscopicsilicovolcanoconiosis',
        'study-deployment-status-overview',
        'a1B2c3D4e5F6g7H8i9J0k1L', // 23 characters
        'abc123',
        'v1',
      ]) {
        expect(_route('https://h/$segment'), 'h/$segment');
      }
    });

    test('replaces segments longer than 64 characters with {long}', () {
      expect(_route('https://h/${'a' * 65}'), 'h/{long}');
      expect(_route('https://h/${'a' * 64}'), 'h/${'a' * 64}');
    });

    test('applies templates to the raw path first and keeps them', () {
      final participant = PathTemplate(
        RegExp('/participants/[^/]+'),
        '/participants/{participant}',
      );
      expect(
        _route('https://h/api/participants/12345/data', [participant]),
        'h/api/participants/{participant}/data',
      );
      // templates see the percent-encoded path
      expect(
        _route('https://h/my%20files/12', [
          const PathTemplate('/my%20files', '/files'),
        ]),
        'h/files/{id}',
      );
    });

    test('keeps literal and percent-encoded placeholders', () {
      expect(
        _route('https://h/api/{uuid}/files/%7Bid%7D/%7bname%7d'),
        'h/api/{uuid}/files/{id}/{name}',
      );
    });

    test('does not trust arbitrary content in braces', () {
      expect(
        _route('https://h/users/{john.doe@example.com}'),
        'h/users/{email}',
      );
      expect(
        _route('https://h/invite/{a1B2c3D4e5F6g7H8i9J0k1L2}'),
        'h/invite/{token}',
      );
      expect(_route('https://h/notes/{$_uuid}'), isNot(contains('4266')));
      // nor in the output of a template
      final careless = PathTemplate(
        RegExp('/users/[^/]+'),
        '/users/{john.doe@example.com}',
      );
      expect(_route('https://h/users/42', [careless]), 'h/users/{email}');
    });

    test('lower-cases the host and keeps the case of the path', () {
      expect(
        _route('https://CANS.Cachet.DK/API/Studies'),
        'cans.cachet.dk/API/Studies',
      );
    });

    test('drops default ports and keeps other ports', () {
      expect(_route('https://h:443/a'), 'h/a');
      expect(_route('http://h:80/a'), 'h/a');
      expect(_route('https://h:8443/a'), 'h:8443/a');
      expect(_route('http://h:8080/a'), 'h:8080/a');
      expect(_route('https://h:80/a'), 'h:80/a');
    });

    test('drops the default ports of WebSocket URLs', () {
      expect(_route('wss://h:443/socket'), 'h/socket');
      expect(_route('ws://h:80/socket'), 'h/socket');
    });

    test('drops the query, fragment and user info', () {
      expect(
        _route(
          'https://john:secret@cans.cachet.dk/api/files'
          '?token=abc&mail=john@example.com#top',
        ),
        'cans.cachet.dk/api/files',
      );
    });

    test('removes a trailing slash but keeps the root', () {
      expect(_route('https://h/api/studies/'), 'h/api/studies');
      expect(_route('https://h/'), 'h/');
      expect(_route('https://h'), 'h/');
    });

    test('replaces paths longer than 4096 characters with /{long}', () {
      expect(_route('https://h${'/abc' * 1025}'), 'h/{long}');
      // 4096 characters are still normalised segment by segment
      expect(_route('https://h${'/abc' * 1024}'), startsWith('h/abc/abc/'));
    });

    test('caps the route at 200 characters between segments', () {
      final route = 'h${'/abc' * 100}';
      final capped = _route('https://$route');
      expect(capped.length, lessThanOrEqualTo(200));
      expect(capped, 'h${'/abc' * 49}');
    });

    test('never throws on malformed percent-encoding', () {
      for (final url in [
        'https://h/a%zz/b',
        'https://h/%E0%A4%A/c',
        'https://h/%',
        'https://h/%FF%FE/x%40',
      ]) {
        expect(() => _route(url), returnsNormally, reason: url);
        expect(() => normalizeUrlText(url), returnsNormally, reason: url);
      }
    });
  });

  group('normalizeUrlText', () {
    test('keeps the scheme of the URL', () {
      expect(
        normalizeUrlText('https://cans.cachet.dk/api/studies/42?x=1'),
        'https://cans.cachet.dk/api/studies/{id}',
      );
      expect(
        normalizeUrlText('wss://h:8443/socket/$_uuid'),
        'wss://h:8443/socket/{uuid}',
      );
    });

    test('returns {url} for text that is not an absolute URL', () {
      for (final text in [
        '',
        'not a url',
        '/api/studies/42',
        'mailto:john@example.com',
        'file:///etc/passwd',
        'https://',
        'http://:80/x',
        'https://h:abc/x',
      ]) {
        expect(normalizeUrlText(text), '{url}', reason: text);
      }
    });

    test('is idempotent', () {
      for (final url in [
        'https://john:pw@CANS.cachet.dk:443/api/studies/$_uuid/x?y=1#z',
        'https://h/users/john.doe%40example.com/data/42',
        'https://h/api/{uuid}/files/%7Bid%7D',
        'https://h/reset/$_jwt',
        'https://h:8443/a%zz/${'x' * 70}',
        'https://h${'/abc' * 1025}',
        'https://h${'/abc' * 100}',
        'not a url',
      ]) {
        final once = normalizeUrlText(url);
        expect(normalizeUrlText(once), once, reason: url);
      }
      const signup = 'https://cans.cachet.dk/api/self-signup/AbC123';
      final once = normalizeUrlText(signup, templates: cawsPathTemplates);
      expect(normalizeUrlText(once, templates: cawsPathTemplates), once);
    });

    test('is idempotent when the length cap cuts a placeholder', () {
      // the route is cut at 200 characters, inside {uuid}
      final url = 'https://host${'/abcd' * 38}/$_uuid/files';
      final once = normalizeUrlText(url);
      expect(normalizeUrlText(once), once);
    });

    test('keeps the brackets of an IPv6 host', () {
      expect(
        normalizeUrlText('http://[::1]:8080/api/users/42'),
        'http://[::1]:8080/api/users/{id}',
      );
    });
  });

  group('CAWS', () {
    test('cawsPathTemplates hide the self-signup code', () {
      expect(
        _route(
          'https://cans.cachet.dk/api/self-signup/welcome',
          cawsPathTemplates,
        ),
        'cans.cachet.dk/api/self-signup/{code}',
      );
      expect(
        _route(
          'https://cans.cachet.dk/api/self-signup/AbC123/accept',
          cawsPathTemplates,
        ),
        'cans.cachet.dk/api/self-signup/{code}/accept',
      );
    });

    test('redactCawsPaths hides codes in bare paths', () {
      expect(
        redactCawsPaths('POST /api/self-signup/AbC123xyz failed'),
        'POST /api/self-signup/{code} failed',
      );
      expect(
        redactCawsPaths('{"path":"/api/self-signup/AbC123xyz","status":404}'),
        '{"path":"/api/self-signup/{code}","status":404}',
      );
      expect(
        redactCawsPaths('GET /api/studies failed'),
        'GET /api/studies failed',
      );
    });

    test('redactCawsPaths stops at trailing punctuation', () {
      expect(
        redactCawsPaths(
          "codes '/api/self-signup/a1', (/api/self-signup/b2); "
          '/api/self-signup/c3?lang=da',
        ),
        "codes '/api/self-signup/{code}', (/api/self-signup/{code}); "
        '/api/self-signup/{code}?lang=da',
      );
      // a full stop may belong to the code, which is hidden either way
      expect(
        redactCawsPaths('Opened /api/self-signup/AbC123xyz.'),
        allOf(contains('/api/self-signup/{code}'), isNot(contains('AbC123'))),
      );
    });

    test('cawsOperation reads the RPC operation of a CAWS POST', () {
      final body = _json({
        '__type': _getStatus,
        'apiVersion': '1.1',
        'studyDeploymentId': _uuid,
      });
      expect(
        cawsOperation(_rpc('POST', _deploymentService, body)),
        'GetStudyDeploymentStatus',
      );
      final spaced = utf8.encode('{ "__type" : "$_getStatus" }');
      expect(
        cawsOperation(_rpc('POST', '$_deploymentService?x=1', spaced)),
        'GetStudyDeploymentStatus',
      );
    });

    test('cawsOperation is null for other requests', () {
      final body = _json({'__type': _getStatus});
      expect(cawsOperation(_rpc('GET', _deploymentService, body)), isNull);
      expect(
        cawsOperation(_rpc('POST', 'https://cans.cachet.dk/api/studies', body)),
        isNull,
      );
      expect(
        cawsOperation(
          _rpc('POST', _deploymentService, _json({'apiVersion': '1.1'})),
        ),
        isNull,
      );
      expect(
        cawsOperation(_rpc('POST', _deploymentService, utf8.encode('{oops'))),
        isNull,
      );
    });

    test('cawsOperation reads only the first 4 KB of the body', () {
      final padding = 'x' * 5000;
      final early = utf8.encode('{"__type":"$_getStatus","pad":"$padding"}');
      final late = utf8.encode('{"pad":"$padding","__type":"$_getStatus"}');
      expect(
        cawsOperation(_rpc('POST', _deploymentService, early)),
        'GetStudyDeploymentStatus',
      );
      expect(cawsOperation(_rpc('POST', _deploymentService, late)), isNull);
    });

    test('cawsOperation tolerates malformed UTF-8', () {
      final head = utf8.encode('{"__type":"$_getStatus","note":"');
      final malformed = [...head, 0xFF, 0xFE, 0xC3, ...utf8.encode('"}')];
      expect(
        cawsOperation(_rpc('POST', _deploymentService, malformed)),
        'GetStudyDeploymentStatus',
      );
      // a two-byte character cut by the 4 KB limit
      final cut = [...head, ...utf8.encode('${'x' * (4095 - head.length)}æ"}')];
      expect(
        cawsOperation(_rpc('POST', _deploymentService, cut)),
        'GetStudyDeploymentStatus',
      );
    });

    test('cawsOperation rejects invalid operation names', () {
      String? operation(String type) => cawsOperation(
        _rpc('POST', _deploymentService, _json({'__type': type})),
      );
      for (final type in [
        'a.b.Get Status',
        'a.b.1GetStatus',
        'a.b.Get-Status',
        'a.b.GetStätus',
        'a.b.',
        'a.b.${'A' * 65}',
      ]) {
        expect(operation(type), isNull, reason: type);
      }
      expect(operation('a.b.${'A' * 64}'), 'A' * 64);
    });
  });

  group('Privacy.text', () {
    test('normalises URLs and drops their query', () {
      expect(
        privacy.text(
          'GET https://cans.cachet.dk/api/studies/$_uuid/files?token=s failed',
        ),
        'GET https://cans.cachet.dk/api/studies/{uuid}/files failed',
      );
      expect(
        privacy.text('socket wss://h/socket/12345?ticket=abc closed'),
        'socket wss://h/socket/{id} closed',
      );
    });

    test('normalises the uri of an http ClientException', () {
      final error = http.ClientException(
        'Connection closed before full header was received',
        Uri.parse(
          'https://cans.cachet.dk/api/users/42/data'
          '?access_token=s3cr3t&email=john%40example.com',
        ),
      );
      expect(
        privacy.text(error.toString()),
        'ClientException: Connection closed before full header was received, '
        'uri=https://cans.cachet.dk/api/users/{id}/data',
      );
    });

    test('replaces URLs that cannot be parsed with {url}', () {
      expect(privacy.text('retry http://:80/x later'), 'retry {url} later');
      expect(privacy.text('retry https://h:abc/x later'), 'retry {url} later');
    });

    test('normalises URLs followed by punctuation', () {
      const url = 'https://cans.cachet.dk/api/users/42';
      const route = 'https://cans.cachet.dk/api/users/{id}';
      for (final (text, scrubbed) in [
        (
          'Failed to load $url, giving up.',
          'Failed to load $route, giving up.',
        ),
        ('Request to $url.', 'Request to $route.'),
        ('GET $url: not found', 'GET $route: not found'),
        ('{url: $url, status: 500}', '{url: $route, status: 500}'),
        ('{status: 500, url: $url}', '{status: 500, url: $route}'),
        ('Opened https://h/api/{uuid}.', 'Opened https://h/api/{uuid}.'),
      ]) {
        expect(privacy.text(text), scrubbed, reason: text);
      }
    });

    test('normalises URLs whatever the case of their scheme', () {
      final text = privacy.text('see HTTPS://h/api/users/42?token=secret');
      expect(text, isNot(contains('token=secret')));
      expect(text, isNot(contains('/42')));
    });

    test('normalises URLs with an IPv6 host', () {
      final text = privacy.text(
        'GET http://[::1]:8080/api/users/42?token=secret failed',
      );
      expect(text, isNot(contains('token=secret')));
      expect(text, isNot(contains('/42')));
    });

    test('replaces JWTs with {jwt}', () {
      expect(privacy.text('token $_jwt expired'), 'token {jwt} expired');
    });

    test('replaces bearer tokens with {token}', () {
      expect(
        privacy.text('Authorization: Bearer abcdefgh12345678'),
        'Authorization: Bearer {token}',
      );
      expect(
        privacy.text('authorization: bearer abc.DEF-ghi_123~456'),
        'authorization: bearer {token}',
      );
      final jwt = privacy.text('Authorization: Bearer $_jwt');
      expect(jwt, startsWith('Authorization: Bearer {'));
      expect(jwt, isNot(contains('eyJ')));
    });

    test('replaces e-mail addresses with {email}', () {
      expect(
        privacy.text('no account for John.Doe+test@Example.co.uk, sorry'),
        'no account for {email}, sorry',
      );
    });

    test('hides CAWS self-signup codes in bare paths and URLs', () {
      expect(
        privacy.text('POST /api/self-signup/AbC123xyz failed'),
        'POST /api/self-signup/{code} failed',
      );
      expect(
        privacy.text(
          'GET https://cans.cachet.dk/api/self-signup/AbC123xyz?lang=da',
        ),
        'GET https://cans.cachet.dk/api/self-signup/{code}',
      );
    });

    test('leaves text without URLs or secrets unchanged', () {
      const text = 'Bad state: No element (study 3 of 4, 100% done)';
      expect(privacy.text(text), text);
    });

    test('cuts text at 8192 characters', () {
      expect(privacy.text('a' * 10000), '${'a' * 8192} …');
      expect(privacy.text('a' * 8192), 'a' * 8192);
    });

    test('cuts long text at a white space, never inside a URL', () {
      final words = 'word ' * 1630; // 8150 characters
      final text = '${words}https://cans.cachet.dk/api/users/42 tail';
      final scrubbed = privacy.text(text * 2);
      expect(scrubbed.length, lessThanOrEqualTo(8194));
      expect(scrubbed, endsWith(' …'));
      expect(scrubbed, isNot(contains('/42')));
      expect(privacy.text(scrubbed), scrubbed);
    });

    test('is idempotent', () {
      for (final text in [
        'GET https://cans.cachet.dk/api/studies/$_uuid/files?token=s failed',
        http.ClientException(
          'Connection reset by peer',
          Uri.parse('https://cans.cachet.dk/api/users/42?x=1'),
        ).toString(),
        'Authorization: Bearer abcdefgh12345678',
        'Authorization: Bearer $_jwt',
        'token $_jwt expired',
        'no account for John.Doe+test@Example.co.uk, sorry',
        'POST /api/self-signup/AbC123xyz failed',
        'see https://h/api/{uuid}/files/%7Bid%7D now',
        'retry http://:80/x later',
        'socket wss://h:8443/socket/12345?ticket=abc closed',
        'a' * 10000,
      ]) {
        final once = privacy.text(text);
        expect(privacy.text(once), once, reason: text);
      }
    });

    test('is idempotent at the length cap', () {
      // {email} is longer than the address it replaces
      final once = privacy.text('${'x' * 8185} a@b.co');
      final twice = privacy.text(once);
      // compare the ends first, for a readable failure
      expect(twice.substring(8180), once.substring(8180));
      expect(twice, once);
    });
  });

  group('Privacy.url', () {
    test('drops user info, query and fragment and replaces ids', () {
      expect(
        privacy.url(
          'https://john:pw@CANS.cachet.dk:443/api/studies/$_uuid/participants'
          '?token=x#top',
        ),
        'https://cans.cachet.dk/api/studies/{uuid}/participants',
      );
    });

    test('applies the path templates', () {
      final withTemplates = Privacy(
        user: launchUser,
        templates: [
          ...cawsPathTemplates,
          PathTemplate(RegExp('/consent/[^/]+'), '/consent/{document}'),
        ],
      );
      expect(
        withTemplates.url('https://h/api/consent/signed-form?x=1'),
        'https://h/api/consent/{document}',
      );
      expect(
        withTemplates.url('https://h/api/self-signup/welcome'),
        'https://h/api/self-signup/{code}',
      );
    });

    test('returns {url} for text that is not an absolute URL', () {
      expect(privacy.url('/api/studies/42?token=x'), '{url}');
    });
  });

  group('Privacy.breadcrumb', () {
    test('scrubs the message', () {
      final crumb = privacy.breadcrumb(
        Breadcrumb(
          message: 'signed in as john@example.com at https://h/u/42?t=x',
        ),
      )!;
      expect(crumb.message, 'signed in as {email} at https://h/u/{id}');
    });

    test('removes route arguments, query and fragment from the data', () {
      final crumb = privacy.breadcrumb(
        Breadcrumb(
          category: 'navigation',
          data: {
            'state': 'didPush',
            'from': '/home',
            'to': '/study',
            'from_arguments': {'studyId': 's1'},
            'to_arguments': {'email': 'john@example.com'},
            'route_settings_arguments': 'code=AbC123',
            'http.query': 'token=secret',
            'http.fragment': 'top',
          },
        ),
      )!;
      expect(crumb.data, {'state': 'didPush', 'from': '/home', 'to': '/study'});
    });

    test('normalises the url and scrubs other strings in the data', () {
      final crumb = privacy.breadcrumb(
        Breadcrumb(
          type: 'http',
          category: 'http',
          data: {
            'url': 'https://h/api/users/42?token=secret',
            'method': 'GET',
            'reason': 'no account for john@example.com',
            'status_code': 404,
            'duration': '12ms',
          },
        ),
      )!;
      expect(crumb.data, {
        'url': 'https://h/api/users/{id}',
        'method': 'GET',
        'reason': 'no account for {email}',
        'status_code': 404,
        'duration': '12ms',
      });
    });

    test('normalises a url given as a Uri', () {
      final crumb = privacy.breadcrumb(
        Breadcrumb(
          data: {'url': Uri.parse('https://h/api/users/42?token=secret')},
        ),
      )!;
      // Sentry serialises values that are not JSON with toString()
      expect('${crumb.data!['url']}', 'https://h/api/users/{id}');
    });

    test('is idempotent', () {
      final once = privacy.breadcrumb(
        Breadcrumb(
          category: 'http',
          message: 'GET https://h/users/$_uuid?x=1 for john@example.com',
          data: {
            'url': 'https://h/users/42?token=x',
            'to_arguments': {'id': '42'},
            'reason': 'Bearer abcdefgh12345678',
          },
        ),
      )!;
      final json = jsonEncode(once.toJson());
      expect(jsonEncode(privacy.breadcrumb(once)!.toJson()), json);
    });
  });

  group('Privacy.event', () {
    SentryEvent dirtyEvent() {
      final event = SentryEvent(
        user: SentryUser(id: 'account-1', email: 'john@example.com'),
        serverName: 'Johns-iPhone',
        level: SentryLevel.fatal,
        tags: {'study_id': 's1'},
        request: SentryRequest(
          url: 'https://cans.cachet.dk/api/users/42?token=secret',
          method: 'GET',
          cookies: 'session=abc',
        ),
        message: SentryMessage(
          'no study for john@example.com',
          template: 'no study for %s',
          params: ['john@example.com'],
        ),
        exceptions: [
          SentryException(
            type: 'StateError',
            value: 'Bad state: https://h/users/$_uuid?x=1 (john@example.com)',
            mechanism: Mechanism(type: 'FlutterError', handled: false),
          ),
        ],
        breadcrumbs: [
          Breadcrumb(category: 'touch', message: 'tap'),
          Breadcrumb(
            category: 'http',
            data: {'url': 'https://h/users/42?t=x', 'http.query': 't=x'},
          ),
        ],
      );
      event.contexts['accessibility'] = {'screen_reader': true};
      event.contexts['flutter_context'] = {
        'default_route_name': '/signup?code=AbC123',
        'has_render_view': 'true',
      };
      event.contexts.device = SentryDevice.fromJson({
        'id': 'installation-id',
        'boot_time': '2026-10-29T08:00:00.000Z',
        'model': 'Pixel 8',
      });
      event.contexts.response = SentryResponse(
        statusCode: 404,
        bodySize: 12,
        headers: {'Set-Cookie': 'session=abc'},
      );
      return event;
    }

    test('replaces the user, also one with an e-mail and a username', () {
      final event = SentryEvent(
        user: SentryUser(
          id: 'account-1',
          email: 'john@example.com',
          username: 'john',
          ipAddress: '10.0.0.7',
          name: 'John Doe',
        ),
      );
      expect(privacy.event(event)!.user!.toJson(), {'id': 'launch-user'});
    });

    test('removes the server name', () {
      final event = SentryEvent(serverName: 'Johns-iPhone');
      expect(privacy.event(event)!.serverName, isNull);
    });

    test('reduces the request to its normalised url and method', () {
      final event = SentryEvent(
        request: SentryRequest(
          url: 'https://john:pw@cans.cachet.dk/api/studies/42?token=s#top',
          method: 'POST',
          queryString: 'token=s',
          cookies: 'session=abc',
          headers: {'Authorization': 'Bearer abcdefgh12345678'},
          data: {'password': 'hunter2'},
          fragment: 'top',
        ),
      );
      expect(privacy.event(event)!.request!.toJson(), {
        'url': 'https://cans.cachet.dk/api/studies/{id}',
        'method': 'POST',
      });
    });

    test('removes accessibility and the default route name', () {
      final event = SentryEvent();
      event.contexts['accessibility'] = {'screen_reader': true};
      event.contexts['flutter_context'] = {
        'default_route_name': '/signup?code=AbC123',
        'has_render_view': 'true',
      };
      final contexts = privacy.event(event)!.contexts;
      expect(contexts['accessibility'], isNull);
      expect(contexts['flutter_context'], {'has_render_view': 'true'});
    });

    test('removes the device id and boot time', () {
      final event = SentryEvent();
      // the Android SDK reports its installation id as device id
      event.contexts.device = SentryDevice.fromJson({
        'id': 'installation-id',
        'boot_time': '2026-10-29T08:00:00.000Z',
        'model': 'Pixel 8',
        'family': 'Pixel',
        'simulator': false,
      });
      expect(privacy.event(event)!.contexts.device!.toJson(), {
        'model': 'Pixel 8',
        'family': 'Pixel',
        'simulator': false,
      });
    });

    test('reduces the response to its status code and body size', () {
      final event = SentryEvent();
      event.contexts.response = SentryResponse(
        statusCode: 503,
        bodySize: 42,
        headers: {'Set-Cookie': 'session=abc'},
        cookies: 'session=abc',
        data: {'email': 'john@example.com'},
      );
      expect(privacy.event(event)!.contexts.response!.toJson(), {
        'status_code': 503,
        'body_size': 42,
      });
    });

    test('describes and scrubs exception values', () {
      final describing = Privacy(
        user: launchUser,
        describeError: (error) => error is _ServiceError ? error.message : null,
      );
      final event = SentryEvent(
        exceptions: [
          SentryException(
            type: '_ServiceError',
            value: "Instance of '_ServiceError'",
            throwable: _ServiceError(
              'Not found: https://h/api/users/42?x=1 (john@example.com)',
            ),
          ),
          SentryException(
            type: 'StateError',
            value: 'Bad state: no study for john@example.com',
            throwable: StateError('no study for john@example.com'),
          ),
        ],
      );
      expect(describing.event(event)!.exceptions!.map((e) => e.value), [
        'Not found: https://h/api/users/{id} ({email})',
        'Bad state: no study for {email}',
      ]);
    });

    test('ignores a describeError that throws', () {
      final failing = Privacy(
        user: launchUser,
        describeError: (error) => throw StateError('bug in the app'),
      );
      final event = SentryEvent(
        exceptions: [
          SentryException(
            type: 'StateError',
            value: 'Bad state: no study for john@example.com',
            throwable: StateError('no study for john@example.com'),
          ),
        ],
      );
      expect(
        failing.event(event)!.exceptions!.single.value,
        'Bad state: no study for {email}',
      );
    });

    test('scrubs the message and drops its parameters', () {
      final event = SentryEvent(
        message: SentryMessage(
          'login failed for john@example.com',
          template: 'login failed for %s at https://h/users/42?x=1',
          params: ['john@example.com'],
        ),
      );
      final message = privacy.event(event)!.message!;
      expect(message.formatted, 'login failed for {email}');
      expect(message.template, 'login failed for %s at https://h/users/{id}');
      expect(message.params, isNull);
    });

    test('scrubs breadcrumbs and removes dropped categories', () {
      final event = SentryEvent(
        breadcrumbs: [
          for (final category in _droppedCategories)
            Breadcrumb(category: category, message: 'screen on'),
          Breadcrumb(
            category: 'navigation',
            data: {
              'from': '/home',
              'to': '/study',
              'to_arguments': {'id': '42'},
            },
          ),
          Breadcrumb(
            category: 'http',
            data: {
              'url': 'https://h/users/42?token=x',
              'http.query': 'token=x',
            },
          ),
          Breadcrumb(category: 'app', message: 'mail john@example.com'),
        ],
      );
      final crumbs = privacy.event(event)!.breadcrumbs!;
      expect(crumbs.map((crumb) => crumb.category), [
        'navigation',
        'http',
        'app',
      ]);
      expect(crumbs[0].data, {'from': '/home', 'to': '/study'});
      expect(crumbs[1].data, {'url': 'https://h/users/{id}'});
      expect(crumbs[2].message, 'mail {email}');
    });

    test('reports fatal events as errors', () {
      expect(
        privacy.event(SentryEvent(level: SentryLevel.fatal))!.level,
        SentryLevel.error,
      );
      expect(
        privacy.event(SentryEvent(level: SentryLevel.warning))!.level,
        SentryLevel.warning,
      );
    });

    test('tags whether the first mechanism was handled, and its type', () {
      final unhandled = SentryEvent(
        tags: {'study_id': 's1'},
        exceptions: [
          SentryException(
            type: 'StateError',
            value: 'a',
            mechanism: Mechanism(type: 'FlutterError', handled: false),
          ),
          SentryException(
            type: 'ArgumentError',
            value: 'b',
            mechanism: Mechanism(type: 'generic', handled: true),
          ),
        ],
      );
      expect(privacy.event(unhandled)!.tags, {
        'study_id': 's1',
        'handled': 'no',
        'mechanism': 'FlutterError',
      });
      final handled = SentryEvent(
        exceptions: [
          SentryException(
            type: 'SentryHttpClientError',
            value: 'HTTP 503',
            mechanism: Mechanism(
              type: 'CarpGlitchTipHttpClient',
              handled: true,
            ),
          ),
        ],
      );
      expect(privacy.event(handled)!.tags, {
        'handled': 'yes',
        'mechanism': 'CarpGlitchTipHttpClient',
      });
    });

    test('is idempotent', () {
      final once = privacy.event(dirtyEvent())!;
      final json = jsonEncode(once.toJson());
      expect(json, isNot(contains('john@example.com')));
      expect(jsonEncode(privacy.event(once)!.toJson()), json);
    });

    test('falls back to a coarse scrub when the full scrub fails', () {
      final event = SentryEvent(
        user: SentryUser(id: 'account-1', email: 'john@example.com'),
        serverName: 'Johns-iPhone',
        request: _UnreadableRequest(),
        breadcrumbs: [Breadcrumb(message: 'signed in as john@example.com')],
        message: SentryMessage(
          'see https://h/users/42?token=secret or john@example.com',
          template: 'see %s',
          params: ['john@example.com'],
        ),
        exceptions: [
          SentryException(
            type: 'StateError',
            value:
                'upload to https://h/users/42?token=secret failed for '
                'john@example.com',
          ),
        ],
      );
      event.contexts['accessibility'] = {'screen_reader': true};
      event.contexts['flutter_context'] = {
        'default_route_name': '/signup?code=AbC123',
      };
      event.contexts.device = SentryDevice.fromJson({'id': 'installation-id'});
      event.contexts.app = SentryApp(name: 'CARP Study');

      final scrubbed = privacy.event(event);
      expect(scrubbed, isNotNull);
      expect(scrubbed!.user!.toJson(), {'id': 'launch-user'});
      expect(scrubbed.serverName, isNull);
      expect(scrubbed.request, isNull);
      expect(scrubbed.breadcrumbs ?? const <Breadcrumb>[], isEmpty);
      for (final key in ['accessibility', 'flutter_context', 'device', 'app']) {
        expect(scrubbed.contexts[key], isNull, reason: key);
      }
      expect(scrubbed.exceptions!.single.value, contains('{url}'));
      expect(scrubbed.message!.formatted, contains('{url}'));
      final json = jsonEncode(scrubbed.toJson());
      for (final secret in ['https://', 'token=secret', '@', 'AbC123']) {
        expect(json, isNot(contains(secret)), reason: secret);
      }
    });

    test('drops the event when even the coarse scrub fails', () {
      final event = SentryEvent(exceptions: [_UnreadableException()]);
      expect(privacy.event(event), isNull);
    });
  });

  group('Privacy.transaction', () {
    test('drops transactions marked for discarding', () async {
      final discarded = await _transaction(
        'GET h/api',
        'http.client',
        data: {Privacy.discardKey: true},
      );
      expect(privacy.transaction(discarded), isNull);
      final kept = await _transaction(
        'GET h/api',
        'http.client',
        data: {Privacy.discardKey: false},
      );
      expect(privacy.transaction(kept), isNotNull);
    });

    test('keeps only the trace context', () async {
      final transaction = await _transaction(
        'sync',
        'task',
        data: {'note': 'kept'},
      );
      transaction
        ..user = SentryUser(id: 'account-1', email: 'john@example.com')
        ..tags = {'study_id': 's1'}
        ..breadcrumbs = [Breadcrumb(message: 'crumb')]
        ..serverName = 'Johns-iPhone';
      transaction.contexts['study'] = {'study_id': 's1'};
      transaction.contexts.device = SentryDevice(model: 'Pixel 8');
      expect(transaction.toJson(), contains('extra'));

      final scrubbed = privacy.transaction(transaction)!;
      final json = scrubbed.toJson();
      for (final key in [
        'user',
        'tags',
        'breadcrumbs',
        'server_name',
        'extra',
      ]) {
        expect(json, isNot(contains(key)), reason: key);
      }
      expect(scrubbed.contexts.keys, ['trace']);
      expect(scrubbed.contexts.trace!.data!['note'], 'kept');
    });

    test('removes route arguments and normalises the url', () async {
      final transaction = await _transaction(
        '/study',
        'navigation',
        data: {
          'route_settings_arguments': {'email': 'john@example.com'},
          'url': 'https://h/api/users/42?token=secret',
        },
      );
      final data = privacy.transaction(transaction)!.contexts.trace!.data!;
      expect(data, isNot(contains('route_settings_arguments')));
      expect(data['url'], 'https://h/api/users/{id}');
    });

    test('sets the request of HTTP transactions from the trace data', () async {
      const name =
          'POST cans.cachet.dk/api/deployment-service GetStudyDeploymentStatus';
      final transaction = await _transaction(
        name,
        'http.client',
        data: {'http.request.method': 'POST', 'url': '$_deploymentService?x=1'},
      );
      transaction.request = SentryRequest(
        url: '$_deploymentService?x=1',
        method: 'POST',
        cookies: 'session=abc',
        headers: {'Authorization': 'Bearer abcdefgh12345678'},
      );
      final scrubbed = privacy.transaction(transaction)!;
      expect(scrubbed.request!.toJson(), {
        'method': 'POST',
        'url': _deploymentService,
      });
      expect(scrubbed.transaction, name);
    });

    test('scrubs the name and removes the request of others', () async {
      final transaction = await _transaction(
        'sync john@example.com https://h/users/42?token=secret',
        'task',
      );
      transaction.request = SentryRequest(url: 'https://h/x', method: 'GET');
      final scrubbed = privacy.transaction(transaction)!;
      expect(scrubbed.request, isNull);
      expect(scrubbed.transaction, 'sync {email} https://h/users/{id}');
    });

    test('drops a transaction that cannot be scrubbed', () async {
      final transaction = await _transaction('sync', 'task');
      transaction.contexts.trace = _UnreadableTraceContext();
      expect(privacy.transaction(transaction), isNull);
    });

    test('is idempotent', () async {
      for (final transaction in [
        await _transaction(
          'GET h/api/users/{id}',
          'http.client',
          data: {
            'http.request.method': 'GET',
            'url': 'https://h/api/users/42?x=1',
          },
        ),
        await _transaction(
          'sync john@example.com',
          'task',
          data: {'route_settings_arguments': 'x'},
        ),
      ]) {
        final once = jsonEncode(privacy.transaction(transaction)!.toJson());
        expect(jsonEncode(privacy.transaction(transaction)!.toJson()), once);
      }
    });
  });

  group('in the reporting pipeline', () {
    late GlitchTipTestTransport transport;

    setUp(() async {
      await CarpGlitchTip.resetForTest();
      transport = GlitchTipTestTransport();
    });
    tearDown(CarpGlitchTip.resetForTest);

    Future<void> init({
      BeforeSendCallback? beforeSend,
      void Function(SentryFlutterOptions options)? configure,
    }) => CarpGlitchTip.init(
      CarpGlitchTipOptions(
        enabled: true,
        dsn: 'https://key@glitchtip.example.com/1',
        tracesSampleRate: 1,
        beforeSend: beforeSend,
        configure: (o) {
          o.transport = transport;
          o.autoInitializeNativeSdk = false;
          configure?.call(o);
        },
      ),
    );

    test('scrubs events after the app hooks', () async {
      await init(
        beforeSend: (event, hint) => event
          ..user = SentryUser(id: 'account-1', email: 'john@example.com')
          ..request = SentryRequest(
            url: 'https://cans.cachet.dk/api/users/42?token=secret',
            method: 'GET',
          ),
      );
      await CarpGlitchTip.captureException(
        StateError('no study for john@example.com'),
      );
      await CarpGlitchTip.captureMessage('second report');
      await _waitFor(() => transport.events.length == 2);

      final [first, second] = transport.events;
      expect(first.user!.toJson().keys, ['id']);
      expect(first.user!.id, isNot('account-1'));
      // one random user per app launch
      expect(second.user!.id, first.user!.id);
      expect(first.request!.toJson(), {
        'url': 'https://cans.cachet.dk/api/users/{id}',
        'method': 'GET',
      });
      expect(first.exceptions!.single.value, 'Bad state: no study for {email}');
    });

    test('drops device breadcrumbs and scrubs others before storing', () async {
      await init();
      for (final category in _droppedCategories) {
        await Sentry.addBreadcrumb(
          Breadcrumb(category: category, message: 'screen on'),
        );
      }
      await Sentry.addBreadcrumb(
        Breadcrumb(
          category: 'app',
          data: {
            'url': 'https://h/users/42?token=x',
            'to_arguments': {'id': '42'},
            'http.query': 'token=x',
          },
        ),
      );
      // the scope is synced to the native SDKs, i.e. to native crash reports
      final stored = <Breadcrumb>[];
      await Sentry.configureScope((scope) => stored.addAll(scope.breadcrumbs));
      await CarpGlitchTip.captureException(StateError('boom'));
      await _waitFor(() => transport.events.isNotEmpty);

      final sent = transport.events.single.breadcrumbs ?? const [];
      for (final crumbs in [stored, sent]) {
        for (final crumb in crumbs) {
          expect(_droppedCategories, isNot(contains(crumb.category)));
        }
        expect(crumbs.singleWhere((crumb) => crumb.category == 'app').data, {
          'url': 'https://h/users/{id}',
        });
      }
    });

    test('reduces transactions after the app hook', () async {
      await init(
        configure: (o) {
          o.beforeSendTransaction = (transaction, hint) {
            transaction
              ..transaction = 'sync for john@example.com'
              ..user = SentryUser(id: 'account-1', email: 'john@example.com')
              ..tags = {'study_id': 's1'};
            final trace = transaction.contexts.trace!;
            trace.data = {
              ...?trace.data,
              'route_settings_arguments': {'id': '42'},
            };
            return transaction;
          };
        },
      );
      await CarpGlitchTip.trace('sync', () async {});
      await _waitFor(() => transport.transactions.isNotEmpty);

      final transaction = transport.transactions.single;
      expect(transaction.transaction, 'sync for {email}');
      expect(transaction.user, isNull);
      expect(transaction.tags, isNull);
      expect(transaction.contexts.keys, ['trace']);
      expect(
        transaction.contexts.trace!.data,
        isNot(contains('route_settings_arguments')),
      );
    });
  });
}

/// An error whose `toString()` says nothing, like CARP service exceptions.
class _ServiceError implements Exception {
  _ServiceError(this.message);

  final String message;
}

/// A request whose url cannot be read, so the full scrub fails.
class _UnreadableRequest extends SentryRequest {
  _UnreadableRequest() : super(method: 'GET');

  @override
  String? get url => throw StateError('unreadable');
}

/// An exception whose value cannot be read, so even the coarse scrub fails.
class _UnreadableException extends SentryException {
  _UnreadableException() : super(type: 'StateError', value: null);

  @override
  String? get value => throw StateError('unreadable');
}

/// A trace context whose data cannot be read.
class _UnreadableTraceContext extends SentryTraceContext {
  _UnreadableTraceContext() : super(operation: 'task');

  @override
  Map<String, dynamic>? get data => throw StateError('unreadable');
}
