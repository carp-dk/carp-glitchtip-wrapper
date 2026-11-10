// Contains the error the app's CAWS client throws for error responses.
//
// Parts:
// - `CawsException`, modelled on carp_webservices' `CarpServiceException`.

import 'dart:convert';

/// An error response of CARP Web Services (CAWS), thrown by the app's
/// `CawsRepository` for every status that is not 2xx.
///
/// Like carp_webservices' `CarpServiceException` it has no `toString()`, so
/// on its own it would reach GlitchTip as "Instance of 'CawsException'". The
/// app's `describeError` gives GlitchTip its [description] instead.
class CawsException implements Exception {
  /// Creates an exception for a response with [statusCode] and [message].
  const CawsException(
    this.statusCode,
    this.message, {
    this.exception,
    this.path,
  });

  /// Reads a CAWS error response, e.g.
  /// `{"statusCode": 500, "exception": "...", "message": "...", "path": "..."}`.
  /// Bodies that are not CAWS errors keep the status code only.
  factory CawsException.fromResponse(int statusCode, String body) {
    Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      json = null;
    }
    if (json case {'message': final String message}) {
      return CawsException(
        statusCode,
        message,
        exception: json['exception'] is String
            ? json['exception'] as String
            : null,
        path: json['path'] is String ? json['path'] as String : null,
      );
    }
    return CawsException(statusCode, 'Unexpected response');
  }

  /// The HTTP status code of the response.
  final int statusCode;

  /// The message of the server.
  final String message;

  /// The Java exception CAWS reported, if any.
  final String? exception;

  /// The request that failed, e.g. `POST /api/deployment-service`.
  final String? path;

  /// A readable description, e.g. `HTTP 404: Deployment not found`.
  String get description => 'HTTP $statusCode: $message';
}
