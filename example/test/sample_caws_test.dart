// Unit tests of the in-process sample CAWS: its endpoints, the network
// conditions, the per-`http.Client()` clients and the app's CAWS client.

import 'dart:convert';

import 'package:carp_glitchtip_wrapper_example/src/caws/caws_api.dart';
import 'package:carp_glitchtip_wrapper_example/src/caws/caws_exception.dart';
import 'package:carp_glitchtip_wrapper_example/src/caws/caws_repository.dart';
import 'package:carp_glitchtip_wrapper_example/src/caws/network_condition.dart';
import 'package:carp_glitchtip_wrapper_example/src/caws/sample_caws_client.dart';
import 'package:carp_glitchtip_wrapper_example/src/caws/sample_caws_server.dart';
import 'package:carp_glitchtip_wrapper_example/src/reporting/example_reporting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _cams = 'bf19ced6-7ede-47a9-ad87-c83a6ac8c600';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SampleCawsData data;
  late SampleCawsServer server;

  setUpAll(() async => data = await SampleCawsData.load(rootBundle));
  setUp(() {
    server = SampleCawsServer(
      data: () async => data,
      latency: Duration.zero,
      slowLatency: const Duration(milliseconds: 300),
    );
  });

  Uri url(String path) => SampleCawsServer.baseUri.replace(path: path);

  Future<http.Response> post(
    String path, {
    Object? body,
    String? token,
    http.Client? client,
  }) async {
    final caws = client ?? SampleCawsClient(server);
    return caws.post(
      url(path),
      headers: {'Authorization': ?(token == null ? null : 'Bearer $token')},
      body: body is Map<String, Object?> ? jsonEncode(body) : body,
    );
  }

  Future<String> signIn() async {
    final response = await post(
      CawsApi.tokenPath,
      body: 'grant_type=password&client_id=test',
    );
    return (jsonDecode(response.body) as Map<String, Object?>)['access_token']
        as String;
  }

  group('sample CAWS endpoints', () {
    test('the token endpoint issues a bearer token', () async {
      final response = await post(
        CawsApi.tokenPath,
        body: 'grant_type=password&client_id=test',
      );
      expect(response.statusCode, 200);
      expect(jsonDecode(response.body), {
        'access_token': isA<String>(),
        'token_type': 'bearer',
        'expires_in': 300,
      });
    });

    test('the token endpoint needs a grant type', () async {
      final response = await post(CawsApi.tokenPath, body: 'client_id=x');
      expect(response.statusCode, 400);
    });

    test('services need a token', () async {
      final response = await post(
        CawsApi.participationService,
        body: {'__type': CawsApi.getActiveParticipationInvitations},
      );
      expect(response.statusCode, 401);
      expect(jsonDecode(response.body), containsPair('statusCode', 401));
    });

    test('GetActiveParticipationInvitations returns the invitations', () async {
      final response = await post(
        CawsApi.participationService,
        token: await signIn(),
        body: {
          '__type': CawsApi.getActiveParticipationInvitations,
          'accountId': SampleCawsServer.demoAccountId,
        },
      );
      expect(response.statusCode, 200);
      expect(response.body, data.invitations);
    });

    test(
      'GetDeviceDeploymentFor returns the protocol of a deployment',
      () async {
        final token = await signIn();
        final response = await post(
          CawsApi.deploymentService,
          token: token,
          body: {
            '__type': CawsApi.getDeviceDeploymentFor,
            'studyDeploymentId': _cams,
            'primaryDeviceRoleName': 'Primary Phone',
          },
        );
        expect(response.statusCode, 200);
        expect(response.body, data.protocols[_cams]);

        final unknownRole = await post(
          CawsApi.deploymentService,
          token: token,
          body: {
            '__type': CawsApi.getDeviceDeploymentFor,
            'studyDeploymentId': _cams,
            'primaryDeviceRoleName': 'Smartwatch',
          },
        );
        expect(unknownRole.statusCode, 400);

        final unknownDeployment = await post(
          CawsApi.deploymentService,
          token: token,
          body: {
            '__type': CawsApi.getDeviceDeploymentFor,
            'studyDeploymentId': 'unknown',
            'primaryDeviceRoleName': 'Primary Phone',
          },
        );
        expect(unknownDeployment.statusCode, 404);
      },
    );

    test('AppendToDataStreams accepts data of a deployment', () async {
      final response = await post(
        CawsApi.dataStreamService,
        token: await signIn(),
        body: {
          '__type': CawsApi.appendToDataStreams,
          'studyDeploymentId': _cams,
          'batch': <Object?>[],
        },
      );
      expect(response.statusCode, 200);
    });

    test('other requests are bad requests or not found', () async {
      final token = await signIn();
      final unknown = await post(
        CawsApi.deploymentService,
        token: token,
        body: {'__type': 'dk.cachet.carp.Unknown'},
      );
      expect(unknown.statusCode, 400);
      final notJson = await post(
        CawsApi.deploymentService,
        token: token,
        body: 'not json',
      );
      expect(notJson.statusCode, 400);
      final missing = await post(
        '/api/missing-service',
        token: token,
        body: {'__type': CawsApi.getDeviceDeploymentFor},
      );
      expect(missing.statusCode, 400);
      expect(missing.body, contains('Unsupported request'));
      final get = await SampleCawsClient(server).get(url('/'));
      expect(get.statusCode, 404);
    });
  });

  group('network conditions', () {
    test('offline throws the ClientException of IOClient', () async {
      server.network.value = NetworkCondition.offline;
      await expectLater(
        signIn(),
        throwsA(
          isA<http.ClientException>()
              .having(
                (e) => e.message,
                'message',
                "Failed host lookup: '${SampleCawsServer.host}'",
              )
              .having((e) => e.uri?.host, 'uri', SampleCawsServer.host),
        ),
      );
    });

    test('a server error answers 500 with a CAWS error body', () async {
      server.network.value = NetworkCondition.serverError;
      final response = await post(
        CawsApi.dataStreamService,
        body: {'__type': CawsApi.appendToDataStreams},
      );
      expect(response.statusCode, 500);
      final error = CawsException.fromResponse(500, response.body);
      expect(error.message, 'The service is temporarily unavailable.');
      expect(error.exception, 'java.lang.IllegalStateException');
      expect(error.path, 'POST ${CawsApi.dataStreamService}');
    });

    test('slow answers after the slow latency', () async {
      server.network.value = NetworkCondition.slow;
      final watch = Stopwatch()..start();
      await signIn();
      expect(watch.elapsed, greaterThanOrEqualTo(server.slowLatency));
    });
  });

  group('SampleCawsClient', () {
    test('closing one client does not affect the others', () async {
      final first = SampleCawsClient(server)..close();
      await expectLater(
        first.get(url('/')),
        throwsA(isA<http.ClientException>()),
      );
      final second = SampleCawsClient(server);
      expect((await second.get(url('/'))).statusCode, 404);
    });

    test('sends other hosts to the other client', () async {
      final other = MockClient((request) async => http.Response('other', 200));
      final client = SampleCawsClient(server, other);
      final response = await client.get(Uri.https('example.com', '/'));
      expect(response.body, 'other');
      expect(
        () => SampleCawsClient(server).get(Uri.https('example.com', '/')),
        throwsA(isA<http.ClientException>()),
      );
    });
  });

  group('CawsRepository', () {
    late CawsRepository caws;

    setUp(() => caws = CawsRepository(client: () => SampleCawsClient(server)));

    test('signs in and reads the account from the token', () async {
      final session = await caws.signIn();
      expect(session.accountId, SampleCawsServer.demoAccountId);
      expect(session.userName, SampleCawsServer.demoUserName);
      expect(caws.session, same(session));
    });

    test('loads the invitations and a deployment', () async {
      await caws.signIn();
      final invitations = await caws.getActiveParticipationInvitations();
      expect(invitations, hasLength(2));
      final protocol = await caws.getDeviceDeployment(
        invitations.first.studyDeploymentId,
        invitations.first.deviceRoleName!,
      );
      expect(protocol.name, 'CAMS App - Demo Study Protocol');
      await caws.appendToDataStreams(_cams, 'Primary Phone');
    });

    test('throws a CawsException for error responses', () async {
      await expectLater(
        caws.getActiveParticipationInvitations(),
        throwsA(
          isA<CawsException>().having((e) => e.statusCode, 'status', 401),
        ),
      );
      await caws.signIn();
      server.network.value = NetworkCondition.serverError;
      await expectLater(
        caws.appendToDataStreams(_cams, 'Primary Phone'),
        throwsA(
          isA<CawsException>().having((e) => e.statusCode, 'status', 500),
        ),
      );
    });

    test('a CAWS error is described for GlitchTip', () {
      const error = CawsException(404, 'Not found');
      expect(ExampleReporting.describeError(error), 'HTTP 404: Not found');
      expect(ExampleReporting.describeError(StateError('x')), isNull);
      expect(
        CawsException.fromResponse(502, '<html>').message,
        'Unexpected response',
      );
    });
  });
}
