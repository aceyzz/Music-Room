import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:app/features/auth/auth_repository.dart';

void main() {
  // Ensures native platform channels (Keychain / KeyStore / DPAPI) are initialized
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final tokenService = TokenStorageService();
  const testToken = 'sess_live_real_device_test_12345';

  setUp(() async {
    // Clean up any stale state before running tests
    await tokenService.clearToken();
  });

  tearDown(() async {
    // Clean up after test completes
    await tokenService.clearToken();
  });

  // The test must be run from command line,because clicking directly on vscode make
  // the test run in a headless dart vm without a target device.
  //
  // # Target macOS Desktop host
  // flutter test -d macos integration_test/token_storage_integration_test.dart

  // # Target a running Android Emulator / Device
  // flutter test -d android integration_test/token_storage_integration_test.dart

  // # Target iOS Simulator
  // flutter test -d ios integration_test/token_storage_integration_test.dart
  testWidgets('Real storage write, read, and delete cycle', (tester) async {
    // 1. Verify storage starts empty
    final initialToken = await tokenService.getToken();
    expect(initialToken, isNull);

    // 2. Write token to real OS secure storage
    await tokenService.saveToken(testToken);

    // 3. Read token back from real OS secure storage
    final savedToken = await tokenService.getToken();
    expect(savedToken, equals(testToken));

    // 4. Delete token from real OS secure storage
    await tokenService.clearToken();

    // 5. Verify token is gone
    final finalToken = await tokenService.getToken();
    expect(finalToken, isNull);
  });
}
