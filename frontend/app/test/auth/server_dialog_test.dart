import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:app/core/network/backend_address.dart';
import 'package:app/features/auth/presentation/widgets/server_dialog.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    BackendAddress.current = BackendAddress.fromBuild;
  });
  tearDown(() => BackendAddress.current = BackendAddress.fromBuild);

  group('BackendAddress', () {
    test("the build's address until one is saved", () async {
      await BackendAddress.load();
      expect(BackendAddress.current, BackendAddress.fromBuild);
    });

    test('a saved address wins over the build, from the next load', () async {
      const lan = BackendAddress(host: '192.168.1.20', port: 50051, httpPort: 8081);
      await BackendAddress.save(lan);
      expect(BackendAddress.current, BackendAddress.fromBuild); // not before a start

      await BackendAddress.load();
      expect(BackendAddress.current, lan);
    });

    test("saving the build's own forgets the saved one", () async {
      await BackendAddress.save(const BackendAddress(host: '10.0.0.5', port: 1, httpPort: 2));
      await BackendAddress.save(BackendAddress.fromBuild);

      await BackendAddress.load();
      expect(BackendAddress.current, BackendAddress.fromBuild);
    });
  });

  group('the Server form', () {
    var restarts = 0;
    setUp(() {
      restarts = 0;
      restartApp = () => restarts++;
    });

    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Center(child: ServerButton()))));
      expect(find.text('Server: ${BackendAddress.fromBuild}'), findsOneWidget);
      await tester.tap(find.byType(ServerButton));
      await tester.pumpAndSettle();
    }

    Finder field(String label) => find.widgetWithText(TextFormField, label);

    testWidgets('saves the address and restarts the app to use it', (tester) async {
      await open(tester);
      await tester.enterText(field('Host'), ' 192.168.1.20 ');
      await tester.tap(find.text('Save and restart'));
      await tester.pumpAndSettle();

      expect(restarts, 1);
      await BackendAddress.load();
      expect(BackendAddress.current.host, '192.168.1.20');
    });

    testWidgets('refuses a URL for a host, and a port out of range', (tester) async {
      await open(tester);
      await tester.enterText(field('Host'), 'http://192.168.1.20:50051');
      await tester.enterText(field('gRPC port'), '70000');
      await tester.tap(find.text('Save and restart'));
      await tester.pumpAndSettle();

      expect(find.text('A host name or an IP address, without http:// or a port.'), findsOneWidget);
      expect(find.text('A port, 1 to 65535.'), findsOneWidget);
      expect(restarts, 0);
    });

    testWidgets("Default fills in the build's address", (tester) async {
      await open(tester);
      await tester.enterText(field('Host'), 'somewhere-else');
      await tester.tap(find.text('Default'));
      await tester.pump();

      expect(find.text(BackendAddress.fromBuild.host), findsOneWidget);
    });

    testWidgets('where the app does not restart itself, it says to reopen it', (tester) async {
      restartApp = null;
      await open(tester);
      await tester.enterText(field('Host'), '192.168.1.20');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.textContaining('close and reopen the app'), findsOneWidget);
    });
  });
}
