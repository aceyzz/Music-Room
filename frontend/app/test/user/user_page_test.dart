import 'package:flutter/material.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/mapping/user.mapping.dart';
import 'package:app/core/models/user/relationship.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/user/data/user_source.dart';
import 'package:app/gen/music_room/v1/services/user_service.pb.dart';
import 'package:app/pages/user_page.dart';
import 'package:fixnum/fixnum.dart';

import '../auth/fake_auth_api.dart';
import '../mocks/mock_flutter_secure_storage.dart';
import 'fake_social_api.dart';

void main() {
  late FakeSocialApi api;
  late SessionStore session;

  setUp(() async {
    FlutterSecureStoragePlatform.instance = FakeFlutterSecureStoragePlatform();
    final auth = FakeAuthApi()..emailVerified = true;
    final credentials = SessionCredentials();
    session = SessionStore(
      SessionRepository(
        api: auth,
        storage: TokenStorageService(),
        credentials: credentials,
        devSessionToken: '',
      ),
      credentials,
    );
    await session.start();
    await session.login(email: 'neo@example.test', password: 'password1234');
    api = FakeSocialApi();
  });

  // The page under a small router, so "Edit profile" has somewhere to go.
  Future<void> pumpPage(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(800, 1600)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: '/users/u-2',
      routes: [
        GoRoute(
          path: '/users/:id',
          builder: (context, state) => UserPage(publicId: state.pathParameters['id']!),
        ),
        GoRoute(path: '/profile', builder: (context, state) => const Text('own profile')),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<SessionStore>.value(value: session),
        Provider<SocialApi>.value(value: api),
      ],
      child: MaterialApp.router(routerConfig: router),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('a stranger: add as friend, then the request waits', (tester) async {
    api.profile = person(bio: 'Follow the white rabbit.', city: 'Zion');
    await pumpPage(tester);

    expect(find.text('Trinity'), findsWidgets); // app bar and header
    expect(find.text('Follow the white rabbit.'), findsOneWidget);
    expect(find.text('Zion'), findsOneWidget);
    expect(find.text('Trinity shares more with friends.'), findsOneWidget);
    expect(find.text('Block'), findsOneWidget);

    await tester.tap(find.text('Add as friend'));
    await tester.pumpAndSettle();

    expect(api.calls, ['send']);
    expect(find.text('Add as friend'), findsNothing);
    final sent = find.ancestor(of: find.text('Request sent'), matching: find.byType(FilledButton));
    expect(tester.widget<FilledButton>(sent).onPressed, isNull);
  });

  testWidgets('a request received: accept, then remove after a confirmation', (tester) async {
    api.current = const Relationship(status: FriendStatus.requestReceived, incomingRequestId: 7);
    await pumpPage(tester);

    expect(find.text('Wants to be your friend'), findsOneWidget);
    expect(find.text('Decline'), findsOneWidget);
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(api.calls, ['accept 7']);
    expect(find.text('Friends'), findsOneWidget);
    expect(find.text('Trinity shares more with friends.'), findsNothing);

    // Cancel first: nothing happens.
    await tester.tap(find.text('Remove friend'));
    await tester.pumpAndSettle();
    expect(find.text('Remove Trinity as a friend?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.calls, ['accept 7']);

    await tester.tap(find.text('Remove friend'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(api.calls, ['accept 7', 'remove']);
    expect(find.text('Add as friend'), findsOneWidget);
  });

  testWidgets('declining a request', (tester) async {
    api.current = const Relationship(status: FriendStatus.requestReceived, incomingRequestId: 7);
    await pumpPage(tester);

    await tester.tap(find.text('Decline'));
    await tester.pumpAndSettle();

    expect(api.calls, ['decline 7']);
    expect(find.text('Add as friend'), findsOneWidget);
  });

  testWidgets('block asks first, hides the profile, and turns into unblock', (tester) async {
    api.current = const Relationship(status: FriendStatus.friends);
    api.profile = person(bio: 'Follow the white rabbit.');
    await pumpPage(tester);

    await tester.tap(find.text('Block'));
    await tester.pumpAndSettle();
    expect(find.text('Block Trinity?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(api.calls, isEmpty);

    await tester.tap(find.text('Block'));
    await tester.pumpAndSettle();
    // The dialog's own button, not the page's.
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('Block')));
    await tester.pumpAndSettle();

    expect(api.calls, ['block']);
    expect(find.text('Trinity'), findsWidgets); // the name still shows
    expect(find.text('Blocked'), findsOneWidget);
    expect(find.text('Follow the white rabbit.'), findsNothing);
    expect(find.text('Remove friend'), findsNothing);
    expect(find.text('Add as friend'), findsNothing);

    await tester.tap(find.text('Unblock'));
    await tester.pumpAndSettle();

    expect(api.calls, ['block', 'unblock']);
    expect(find.text('Add as friend'), findsOneWidget);
    expect(find.text('Follow the white rabbit.'), findsOneWidget);
  });

  testWidgets('an unavailable profile still offers Block, and nothing else', (tester) async {
    api.profileFailure = const NotFoundError('user not found');
    await pumpPage(tester);

    expect(find.text('This profile isn\'t available'), findsOneWidget);
    expect(find.text('Add as friend'), findsNothing);
    expect(find.text('Block'), findsOneWidget);
  });

  testWidgets('a refused action says so and shows the state as it is now', (tester) async {
    api.actionFailure = const ConflictError('already exists');
    await pumpPage(tester);

    // Meanwhile they sent a request of their own.
    api.current = const Relationship(status: FriendStatus.requestReceived, incomingRequestId: 9);
    await tester.tap(find.text('Add as friend'));
    await tester.pumpAndSettle();

    expect(find.text('You are already friends, or a request is waiting.'), findsOneWidget);
    expect(find.text('Accept'), findsOneWidget);
  });

  testWidgets('your own profile: edit it, no friend or block buttons', (tester) async {
    api.current = const Relationship(status: FriendStatus.self);
    await pumpPage(tester);

    expect(find.text('This is you'), findsOneWidget);
    expect(find.text('Block'), findsNothing);
    expect(find.text('Add as friend'), findsNothing);

    await tester.tap(find.text('Edit profile'));
    await tester.pumpAndSettle();
    expect(find.text('own profile'), findsOneWidget);
  });

  group('GetUserRelationshipResponse.toRelationship', () {
    test('reads each status, and the request id only when set', () {
      expect(
        GetUserRelationshipResponse(status: 'request_received', incomingRequestId: Int64(4))
            .toRelationship(),
        const Relationship(status: FriendStatus.requestReceived, incomingRequestId: 4),
      );
      expect(
        GetUserRelationshipResponse(status: 'friends').toRelationship(),
        const Relationship(status: FriendStatus.friends),
      );
      expect(
        GetUserRelationshipResponse(status: 'self').toRelationship().status,
        FriendStatus.self,
      );
      expect(
        GetUserRelationshipResponse(status: 'request_sent').toRelationship().status,
        FriendStatus.requestSent,
      );
    });

    test('a block carries the name; an unknown status reads as none', () {
      expect(
        GetUserRelationshipResponse(status: 'none', blocked: true, displayName: 'Cypher')
            .toRelationship(),
        const Relationship(status: FriendStatus.none, blockedByMe: true, displayName: 'Cypher'),
      );
      expect(
        GetUserRelationshipResponse(status: 'enemies').toRelationship().status,
        FriendStatus.none,
      );
    });
  });
}
