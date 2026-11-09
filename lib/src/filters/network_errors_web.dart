/// Web part of `isNetworkUnavailableError`: there are no dart:io errors, so
/// browser failures are recognised from their message only.
bool isNetworkUnavailable(Object error) => false;

/// Whether [error] is a dart:io network error. Never on the web.
bool isNetworkErrorType(Object error) => false;

/// The OS error code of a network [error]. None on the web.
int? networkErrorCode(Object error) => null;
