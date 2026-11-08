/// The session token every outgoing call carries, held in memory.
///
/// Lives in the network layer, not in the auth feature, because [AppNetwork]
/// is built before any store and the interceptor needs something to read on
/// every call. Reading secure storage per call would put a keychain round trip
/// on the hot path; the auth feature writes here once at login/restore and
/// clears it at logout, and secure storage stays the persistent copy.
class SessionCredentials {
  String? _token;

  /// Called when the server rejects [rejectedToken] as `UNAUTHENTICATED`
  /// (expired, idle, revoked). Set by the auth feature, which signs the user out.
  void Function(String rejectedToken)? onRejected;

  String? get token => _token;

  void set(String token) => _token = token;

  void clear() => _token = null;

  /// Reports a rejection, unless the token has changed since the call left.
  ///
  /// A call sent with an old token can come back after the user logged in
  /// again; signing out the new session because of it would be wrong.
  void reject(String rejectedToken) {
    if (rejectedToken != _token) {
      return;
    }
    onRejected?.call(rejectedToken);
  }
}
