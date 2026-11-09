import 'dart:async';

import 'package:http/http.dart' as http;

import '../util/diagnostics.dart';
import 'network_errors_io.dart'
    if (dart.library.js_interop) 'network_errors_web.dart'
    as platform;

/// Whether [error] is a transient network failure, i.e. what CARP packages
/// throw while the phone is offline or the connection drops: a DNS failure
/// ("Failed host lookup", "nodename nor servname provided", "No address
/// associated with hostname"), an unreachable network, a reset or aborted
/// connection, or a timeout.
///
/// Set [fromHttpRequest] when the error is known to come from an HTTP
/// request. Only then are bare [TimeoutException]s and generic connection
/// messages counted, since sensors, Bluetooth and database code throw those
/// too.
///
/// Deliberately not counted, so they are still reported: a refused
/// connection (the server is down), TLS / certificate failures and HTTP
/// error responses.
bool isNetworkUnavailableError(Object? error, {bool fromHttpRequest = false}) {
  if (error == null) return false;
  if (error is TimeoutException) return fromHttpRequest;
  if (platform.isNetworkUnavailable(error)) return true;
  if (error is http.ClientException) {
    return hasTransientNetworkMessage(error.message, networkError: true);
  }
  // any other error, e.g. a PlatformException of a native plugin
  final text = guard('error.toString()', error.toString);
  if (text == null) return false;
  return hasTransientNetworkMessage(
    text.length <= 2000 ? text : text.substring(0, 2000),
    networkError: fromHttpRequest,
  );
}

/// Whether [text] contains a message of a transient network failure.
///
/// Messages that only the network stack produces (DNS failures, an
/// unreachable network, iOS "offline" errors) always count. Generic
/// connection messages such as "Connection timed out" only count when the
/// text is known to describe a [networkError].
bool hasTransientNetworkMessage(String text, {bool networkError = false}) {
  final lower = text.toLowerCase();
  if (_offlineMessages.any(lower.contains)) return true;
  if (_nsUrlOffline.hasMatch(text)) return true;
  return networkError && _connectionMessages.any(lower.contains);
}

// Lower case. Sources: getaddrinfo errors (Android bionic, Darwin), dart:io
// OS errors and iOS NSURLError descriptions (also surfaced by native plugins
// such as flutter_appauth).
const _offlineMessages = [
  'failed host lookup',
  'no address associated with hostname',
  'nodename nor servname provided',
  'temporary failure in name resolution',
  'network is unreachable',
  'network is down',
  'no route to host',
  'host is down',
  'the internet connection appears to be offline',
  'the network connection was lost',
  'a data connection is not currently allowed',
  'international roaming is currently off',
];

// Lower case. dart:io SocketException / HttpException messages and the
// browser's fetch errors; ambiguous outside of an HTTP request.
const _connectionMessages = [
  'connection timed out',
  'operation timed out',
  'http connection timed out',
  'connection reset by peer',
  'software caused connection abort',
  'broken pipe',
  'connection closed before full header was received',
  'connection closed while receiving data',
  'connection closed before response was received',
  'failed to fetch',
  'networkerror when attempting to fetch resource',
  'xmlhttprequest error',
];

// NSURLErrorDomain codes for timeouts (-1001), unknown host (-1003),
// connection lost (-1005), DNS failure (-1006), offline (-1009), roaming off
// (-1018) and data not allowed (-1020), e.g. from cupertino_http.
final _nsUrlOffline = RegExp(
  r'NSURLErrorDomain[^0-9-]{0,16}(-1001|-1003|-1005|-1006|-1009|-1018|-1020)\b',
);

/// Whether [error] is a network error of any kind, transient or not: an
/// HTTP client error, a dart:io socket / HTTP / TLS error or a timeout.
bool isNetworkError(Object error) =>
    error is http.ClientException ||
    error is TimeoutException ||
    platform.isNetworkErrorType(error);

/// The OS error code (errno) of a network [error], if any.
int? networkErrorCode(Object error) => platform.networkErrorCode(error);
