import 'package:flutter/material.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/mapping/user.mapping.dart';
import 'package:app/core/models/user/friend_request.dart';
import 'package:app/core/models/user/friend_summary.dart';
import 'package:app/core/models/user/user_summary.dart';
import 'package:app/core/network/auth/session_credentials.dart';
import 'package:app/core/theme/app_theme.dart';
import 'package:app/features/auth/auth_repository.dart';
import 'package:app/features/auth/data/session_repository.dart';
import 'package:app/features/auth/presentation/stores/session_store.dart';
import 'package:app/features/user/data/user_source.dart';
import 'package:app/gen/music_room/v1/dto/user.pb.dart';
import 'package:app/pages/friends_page.dart';
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

  // The page under a small router, so a person has a profile to open.
  Future<void> pumpPage(WidgetTester tester, {Size size = const Size(800, 1600)}) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final router = GoRouter(
      initialLocation: '/friends',
      routes: [
        GoRoute(path: '/friends', builder: (context, state) => const FriendsPage()),
        GoRoute(
          path: '/users/:id',
          builder: (context, state) => Text('profile ${state.pathParameters['id']}'),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<SessionStore>.value(value: session),
        Provider<SocialApi>.value(value: api),
      ],
      // The app's own theme: its full-width filled buttons are what broke
      // the request row on the phone, and the default theme hides that.
      child: MaterialApp.router(theme: AppTheme.lightTheme(), routerConfig: router),
    ));
    await tester.pumpAndSettle();
  }

  FriendRequest request(int id, String name, {bool incoming = true}) =>
      FriendRequest(id: id, user: someone(name), incoming: incoming);

  testWidgets('no friends: the empty state, and no empty sections', (tester) async {
    await pumpPage(tester);

    expect(find.text('Friends (0)'), findsOneWidget);
    expect(find.text('No friends yet. Search for someone above.'), findsOneWidget);
    expect(find.textContaining('Requests'), findsNothing);
    expect(find.textContaining('Sent'), findsNothing);
    expect(find.textContaining('Blocked'), findsNothing);
  });

  testWidgets('searches once typing pauses for 300 ms', (tester) async {
    api.directory = [someone('Morpheus'), someone('Mouse'), someone('Trinity')];
    api.friendList = [const FriendSummary(publicId: 'id-Tank', displayName: 'Tank')];
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField), 'm');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.enterText(find.byType(TextField), 'mo');
    await tester.pump(const Duration(milliseconds: 299));
    expect(api.searches, isEmpty, reason: 'typing has not paused for 300 ms yet');

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(api.searches, ['mo'], reason: 'two quick edits are one search');

    // The results replace the sections.
    expect(find.text('Morpheus'), findsOneWidget);
    expect(find.text('Mouse'), findsOneWidget);
    expect(find.text('Trinity'), findsNothing);
    expect(find.text('Tank'), findsNothing);

    // Clearing brings the sections back, with no request.
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(api.searches, ['mo']);
    expect(find.text('Tank'), findsOneWidget);
    expect(find.text('Morpheus'), findsNothing);
  });

  testWidgets('a search with no match says so', (tester) async {
    api.directory = [someone('Morpheus')];
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField), 'smith');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(find.text('No one matches "smith".'), findsOneWidget);
  });

  testWidgets('a full page of results asks to keep typing', (tester) async {
    api.directory = [for (var i = 0; i < 25; i++) someone('Agent $i')];
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField), 'agent');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.textContaining('Keep typing'),
      200,
      // The list's, not the text field's.
      scrollable: find.descendant(of: find.byType(ListView), matching: find.byType(Scrollable)),
    );
    expect(find.text('Showing the first 20. Keep typing to narrow it down.'), findsOneWidget);
  });

  testWidgets('accepting a request moves them into Friends', (tester) async {
    api.incomingList = [request(7, 'Trinity')];
    api.outgoingList = [request(8, 'Switch', incoming: false)];
    await pumpPage(tester);

    expect(find.text('Requests (1)'), findsOneWidget);
    expect(find.text('Sent (1)'), findsOneWidget);
    expect(find.text('Request sent'), findsOneWidget);
    expect(find.text('Friends (0)'), findsOneWidget);

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(api.calls, ['accept 7']);
    expect(find.textContaining('Requests'), findsNothing);
    expect(find.text('Friends (1)'), findsOneWidget);
    expect(find.text('Trinity'), findsOneWidget);
  });

  testWidgets('declining a request removes it', (tester) async {
    api.incomingList = [request(7, 'Trinity')];
    await pumpPage(tester);

    await tester.tap(find.text('Decline'));
    await tester.pumpAndSettle();

    expect(api.calls, ['decline 7']);
    expect(find.text('Trinity'), findsNothing);
    expect(find.text('Friends (0)'), findsOneWidget);
  });

  testWidgets('a request already answered says so and leaves the list', (tester) async {
    api.incomingList = [request(7, 'Trinity')];
    api.actionFailure = const NotFoundError('request not found');
    await pumpPage(tester);

    // Meanwhile it was answered elsewhere.
    api.incomingList = [];
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(find.text('That request was already answered.'), findsOneWidget);
    expect(find.textContaining('Requests'), findsNothing);
  });

  testWidgets('blocked people sit collapsed, and Unblock removes them', (tester) async {
    api.blockedList = [someone('Cypher')];
    await pumpPage(tester);

    expect(find.text('Blocked (1)'), findsOneWidget);
    expect(find.text('Cypher'), findsNothing, reason: 'collapsed');

    await tester.tap(find.text('Blocked (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unblock'));
    await tester.pumpAndSettle();

    expect(api.calls, ['unblock']);
    expect(find.textContaining('Blocked'), findsNothing);
  });

  testWidgets('a person opens their profile, and coming back reloads', (tester) async {
    api.friendList = [const FriendSummary(publicId: 'id-Tank', displayName: 'Tank')];
    await pumpPage(tester);

    await tester.tap(find.text('Tank'));
    await tester.pumpAndSettle();
    expect(find.text('profile id-Tank'), findsOneWidget);

    // Removed from their profile.
    api.friendList = [];
    final router = GoRouter.of(tester.element(find.text('profile id-Tank')));
    router.pop();
    await tester.pumpAndSettle();

    expect(find.text('Tank'), findsNothing);
    expect(find.text('Friends (0)'), findsOneWidget);
  });

  testWidgets('a list that fails shows a retry, the others still show', (tester) async {
    api.friendList = [const FriendSummary(publicId: 'id-Tank', displayName: 'Tank')];
    api.listFailure = const NetworkError('offline');
    await pumpPage(tester);

    // Which of the four reads failed is the order they run in: friends first.
    expect(find.text('Cannot reach the server. Check your connection.'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Tank'), findsOneWidget);
  });

  group('mapping', () {
    test('a request names the other person, with their avatar', () {
      final dto = FriendRequestDTO(
        id: Int64(7),
        otherUser: UserSummaryDTO(
          publicId: 'u-2',
          displayName: 'Trinity',
          avatarStorageKey: 'avatars/t.webp',
        ),
      );
      expect(
        dto.toFriendRequest(incoming: true, mediaUrl: (key) => 'https://media/$key'),
        const FriendRequest(
          id: 7,
          incoming: true,
          user: UserSummary(
            publicId: 'u-2',
            displayName: 'Trinity',
            avatarUrl: 'https://media/avatars/t.webp',
          ),
        ),
      );
    });

    test('no avatar key means no avatar', () {
      expect(
        UserSummaryDTO(publicId: 'u-3', displayName: 'Cypher').toSummary().avatarUrl,
        isNull,
      );
      expect(
        BlockedUserDTO(publicId: 'u-3', displayName: 'Cypher').toSummary(),
        const UserSummary(publicId: 'u-3', displayName: 'Cypher'),
      );
    });
  });

  testWidgets('on a phone, a request keeps its name and line readable', (tester) async {
    api.incomingList = [request(7, 'Trinity')];
    // The demo phone's screen (frontend/phone: 412x915).
    await pumpPage(tester, size: const Size(412, 915));

    // The buttons sit under the name: the text keeps the row's width
    // instead of wrapping a letter per line beside them. (The test font is
    // wide: two lines here, one on the phone.)
    final line = tester.getSize(find.text('Wants to be your friend'));
    expect(line.width, greaterThan(150));
    expect(line.height, lessThan(60));

    // The buttons are under the name and the line, not painted over them,
    // and they work.
    final name = tester.getRect(find.text('Trinity'));
    final below = tester.getRect(find.text('Wants to be your friend')).bottom;
    for (final label in ['Accept', 'Decline']) {
      final button = tester.getRect(find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ));
      expect(button.top, greaterThanOrEqualTo(below), reason: '$label under the text');
      expect(button.left, greaterThanOrEqualTo(name.left), reason: '$label not over the avatar');
      expect(button.right, lessThanOrEqualTo(412), reason: '$label on screen');
    }
    await tester.tap(find.text('Accept').hitTestable());
    await tester.pumpAndSettle();
    expect(api.calls, ['accept 7']);
  });
}
