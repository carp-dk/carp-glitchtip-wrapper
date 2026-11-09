import 'dart:convert';

import 'package:http/http.dart' as http;

import 'url_normalizer.dart';

/// Templates for CARP Web Services (CAWS) paths that carry secrets. They are
/// applied before the app's own `HttpOptions.pathTemplates`.
final cawsPathTemplates = [
  // the self-signup code is exchanged for a magic login link
  PathTemplate(RegExp('/api/self-signup/[^/]+'), '/api/self-signup/{code}'),
];

final _barePaths = RegExp('/api/self-signup/[^/\\s\'"?#,;)]+');

/// Applies [cawsPathTemplates] to CAWS paths that appear in free [text]
/// without a host, e.g. the `path` a CAWS error response reports.
String redactCawsPaths(String text) => text.contains('/api/self-signup/')
    ? text.replaceAll(_barePaths, '/api/self-signup/{code}')
    : text;

final _rpcType = RegExp(r'"__type"\s*:\s*"([^"]{1,300})"');
final _operationName = RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$');

/// The CAWS RPC operation of [request], e.g. `GetStudyDeploymentStatus`.
///
/// All CAWS RPC calls are POSTs to `/api/<name>-service`; the operation is
/// the last part of the `__type` of the JSON body, e.g.
/// `dk.cachet.carp.deployments.infrastructure.DeploymentServiceRequest.GetStudyDeploymentStatus`.
/// Without it, all calls to a service would share one GlitchTip transaction
/// group. Only the first 4 KB of the body are read.
String? cawsOperation(http.BaseRequest request) {
  if (request is! http.Request || request.method != 'POST') return null;
  if (!request.url.path.endsWith('-service')) return null;
  final bytes = request.bodyBytes;
  final head = utf8.decode(
    bytes.length > 4096 ? bytes.sublist(0, 4096) : bytes,
    allowMalformed: true,
  );
  final type = _rpcType.firstMatch(head)?.group(1);
  if (type == null) return null;
  final operation = type.split('.').last;
  return _operationName.hasMatch(operation) ? operation : null;
}
