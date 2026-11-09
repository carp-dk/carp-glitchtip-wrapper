import 'dart:io';

import 'network_errors.dart';

// errno values of transient connection failures: EPIPE, ENETDOWN,
// ENETUNREACH, ECONNABORTED, ECONNRESET, ETIMEDOUT, EHOSTDOWN, EHOSTUNREACH.
// ECONNREFUSED is left out on purpose: a refusing server should be reported.
const _linuxErrnos = {32, 100, 101, 103, 104, 110, 112, 113};
const _darwinErrnos = {32, 50, 51, 53, 54, 60, 64, 65};

final Set<int> _transientErrnos = Platform.isIOS || Platform.isMacOS
    ? _darwinErrnos
    : _linuxErrnos;

/// dart:io part of [isNetworkUnavailableError].
bool isNetworkUnavailable(Object error) {
  // includes package:http's private _ClientSocketException, which is both a
  // ClientException and a SocketException
  if (error is SocketException) {
    final code = error.osError?.errorCode;
    if (code != null && _transientErrnos.contains(code)) return true;
    return hasTransientNetworkMessage(error.message, networkError: true) ||
        hasTransientNetworkMessage(
          error.osError?.message ?? '',
          networkError: true,
        );
  }
  // a connect-phase failure can escape IOClient as a raw OSError
  if (error is OSError) {
    return _transientErrnos.contains(error.errorCode) ||
        hasTransientNetworkMessage(error.message, networkError: true);
  }
  if (error is HandshakeException) {
    return error.message.contains('Connection terminated during handshake');
  }
  if (error is HttpException) {
    return hasTransientNetworkMessage(error.message, networkError: true);
  }
  return false;
}

/// Whether [error] is a dart:io network error of any kind.
bool isNetworkErrorType(Object error) =>
    error is SocketException ||
    error is OSError ||
    error is HttpException ||
    error is HandshakeException;

/// The OS error code of a dart:io network [error], if any.
int? networkErrorCode(Object error) => switch (error) {
  SocketException(:final osError) => osError?.errorCode,
  OSError(:final errorCode) => errorCode,
  _ => null,
};
