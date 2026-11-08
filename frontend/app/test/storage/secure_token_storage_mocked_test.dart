import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';

// Adjust these imports to match your project package structure
import 'package:app/core/storage/secure_token_storage.dart';
import 'package:app/features/auth/auth_repository.dart';

import '../mocks/mock_flutter_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeFlutterSecureStoragePlatform fakeStorage;
  late SecureTokenStorage secureTokenStorage;
  late TokenStorageService tokenStorageService;

  setUp(() {
    fakeStorage = FakeFlutterSecureStoragePlatform();
    FlutterSecureStoragePlatform.instance = fakeStorage;

    secureTokenStorage = SecureTokenStorage();
    tokenStorageService = TokenStorageService();
  });

  group('SecureTokenStorage Tests', () {
    test('saveSessionToken stores the token successfully', () async {
      const testToken = 'sess_live_1234567890abcdef';

      await secureTokenStorage.saveSessionToken(testToken);

      final storedToken = await secureTokenStorage.getSessionToken();
      expect(storedToken, equals(testToken));
    });

    test('getSessionToken returns null when no token is saved', () async {
      final storedToken = await secureTokenStorage.getSessionToken();
      expect(storedToken, isNull);
    });

    test('deleteSessionToken removes the stored token', () async {
      const testToken = 'sess_live_to_be_deleted';

      await secureTokenStorage.saveSessionToken(testToken);
      expect(await secureTokenStorage.getSessionToken(), equals(testToken));

      await secureTokenStorage.deleteSessionToken();
      expect(await secureTokenStorage.getSessionToken(), isNull);
    });
  });

  group('TokenStorageService Wrapper Tests', () {
    test('saveToken saves token via underlying storage', () async {
      const testToken = 'sess_live_service_token';

      await tokenStorageService.saveToken(testToken);

      final retrievedToken = await tokenStorageService.getToken();
      expect(retrievedToken, equals(testToken));
    });

    test('getToken returns null when empty', () async {
      final token = await tokenStorageService.getToken();
      expect(token, isNull);
    });

    test('clearToken removes token via underlying storage', () async {
      const testToken = 'sess_live_cleared';

      await tokenStorageService.saveToken(testToken);
      expect(await tokenStorageService.getToken(), equals(testToken));

      await tokenStorageService.clearToken();
      expect(await tokenStorageService.getToken(), isNull);
    });
  });
}