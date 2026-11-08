import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureTokenStorage {

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock,
    ),
    mOptions: MacOsOptions(
      accessibility: KeychainAccessibility.first_unlock,
    ),
    wOptions: WindowsOptions(),
    lOptions: LinuxOptions(),
  );

  static const _sessionTokenKey = 'session_token';

  /// JSON of the signed-in AuthUser. Not a secret, but it lives and dies with
  /// the token, so it is kept in the same place and cleared with it.
  static const _sessionUserKey = 'session_user';

  /// This install's stable id (core/device/device_info.dart). Not part of the
  /// session: it survives logout, so the same phone keeps one devices row and
  /// the control licences granted on it.
  static const _deviceIdentifierKey = 'device_identifier';

  Future<void> saveSessionToken(String token) async {
    await _storage.write(key: _sessionTokenKey, value: token);
  }

  Future<String?> getSessionToken() async {
    return await _storage.read(key: _sessionTokenKey);
  }

  Future<void> deleteSessionToken() async {
    await _storage.delete(key: _sessionTokenKey);
  }

  Future<void> saveSessionUser(String json) async {
    await _storage.write(key: _sessionUserKey, value: json);
  }

  Future<String?> getSessionUser() async {
    return await _storage.read(key: _sessionUserKey);
  }

  Future<void> deleteSessionUser() async {
    await _storage.delete(key: _sessionUserKey);
  }

  Future<void> saveDeviceIdentifier(String identifier) async {
    await _storage.write(key: _deviceIdentifierKey, value: identifier);
  }

  Future<String?> getDeviceIdentifier() async {
    return await _storage.read(key: _deviceIdentifierKey);
  }
}
