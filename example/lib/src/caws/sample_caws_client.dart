// Contains the HTTP client that sends requests to the sample CAWS server.
//
// Parts:
// - `SampleCawsClient`, passed as `innerClient` to `CarpGlitchTip.runZoned`.

import 'package:http/http.dart' as http;

import 'sample_caws_server.dart';

/// An HTTP client that answers requests to the sample CAWS host with
/// [server] and sends all other requests with [other].
///
/// `CarpGlitchTip.runZoned(..., innerClient: () => SampleCawsClient(...))`
/// creates one for every `http.Client()` of the app, behind the wrapper's
/// instrumented client: requests are recorded first, then answered here.
/// Clients are cheap and independent: closing one never affects the server
/// or other clients.
class SampleCawsClient extends http.BaseClient {
  /// Creates a client for [server]. Requests to other hosts, such as the
  /// GlitchTip server in live mode, are sent with [other].
  SampleCawsClient(this.server, [this.other]);

  /// The sample CAWS server.
  final SampleCawsServer server;

  /// The client for every other host, if any.
  final http.Client? other;

  bool _closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (_closed) {
      throw http.ClientException(
        'HTTP request failed. Client is already closed.',
        request.url,
      );
    }
    if (server.handles(request.url)) return server.handle(request);
    final other = this.other;
    if (other == null) {
      throw http.ClientException(
        'No client for ${request.url.host}',
        request.url,
      );
    }
    return other.send(request);
  }

  @override
  void close() {
    _closed = true;
    other?.close();
  }
}
