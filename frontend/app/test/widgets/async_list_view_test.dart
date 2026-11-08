import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/core/errors/app_error.dart';
import 'package:app/core/sources/source_state.dart';
import 'package:app/core/widgets/async_list_view.dart';

void main() {
  testWidgets('shows loading placeholder when items is null and no error', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AsyncListView<String>(
            state: const SourceListState(),
            items: null,
            emptyMessage: 'Empty list',
            onRefresh: () async {},
            itemBuilder: (context, item, index) => Text(item),
          ),
        ),
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Empty list'), findsNothing);
  });

  testWidgets('shows initial error placeholder when items is null and has error', (tester) async {
    var retried = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AsyncListView<String>(
            state: const SourceListState(error: NetworkError('Failed')),
            items: null,
            emptyMessage: 'Empty list',
            onRefresh: () async {},
            onRetry: () async => retried = true,
            itemBuilder: (context, item, index) => Text(item),
          ),
        ),
      ),
    );

    expect(find.text('Cannot reach the server. Check your connection.'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    expect(retried, isTrue);
  });

  testWidgets('shows empty message when items is empty and no error', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AsyncListView<String>(
            state: SourceListState.success(const []),
            items: const [],
            emptyMessage: 'No items here',
            onRefresh: () async {},
            itemBuilder: (context, item, index) => Text(item),
          ),
        ),
      ),
    );

    expect(find.text('No items here'), findsOneWidget);
  });

  testWidgets('renders items and supports pull-to-refresh', (tester) async {
    var refreshed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AsyncListView<String>(
            state: SourceListState.success(const ['Item A', 'Item B', 'Item C']),
            items: const ['Item A', 'Item B', 'Item C'],
            emptyMessage: 'No items',
            onRefresh: () async => refreshed = true,
            itemBuilder: (context, item, index) => ListTile(title: Text(item)),
          ),
        ),
      ),
    );

    expect(find.text('Item A'), findsOneWidget);
    expect(find.text('Item B'), findsOneWidget);
    expect(find.text('Item C'), findsOneWidget);

    // Trigger pull-to-refresh
    await tester.fling(find.text('Item A'), const Offset(0, 300), 1000);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(refreshed, isTrue);
  });

  testWidgets('triggers onNearEnd when near end of list', (tester) async {
    var nearEndCalled = false;
    final items = List.generate(20, (i) => 'Item $i');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AsyncListView<String>(
            state: SourceListState.success(items),
            items: items,
            emptyMessage: 'No items',
            onRefresh: () async {},
            onNearEnd: () async => nearEndCalled = true,
            itemBuilder: (context, item, index) => SizedBox(height: 50, child: Text(item)),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();
    expect(nearEndCalled, isTrue);
  });

  testWidgets('asks for more once per build, not once per row near the end', (tester) async {
    var calls = 0;
    const items = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H'];
    Widget list(SourceListState<String> state) => MaterialApp(
          home: Scaffold(
            body: AsyncListView<String>(
              state: state,
              items: items,
              emptyMessage: 'No items',
              onRefresh: () async {},
              onNearEnd: () async => calls++,
              itemBuilder: (context, item, index) => SizedBox(height: 50, child: Text(item)),
            ),
          ),
        );

    // All eight rows on screen: the last five used to ask five times.
    await tester.pumpWidget(list(SourceListState.success(items)));
    await tester.pump();
    expect(calls, 1);

    // A page already loading: no more asking.
    calls = 0;
    await tester.pumpWidget(list(SourceListState.fetchingMore(currentData: items)));
    await tester.pump();
    expect(calls, 0);
  });

  testWidgets('shows footer loader when isFetchingMore is true', (tester) async {
    const items = ['Item 1', 'Item 2'];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AsyncListView<String>(
            state: SourceListState.fetchingMore(currentData: items),
            items: items,
            emptyMessage: 'No items',
            onRefresh: () async {},
            itemBuilder: (context, item, index) => ListTile(title: Text(item)),
          ),
        ),
      ),
    );

    expect(find.text('Item 1'), findsOneWidget);
    expect(find.text('Item 2'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('shows footer error when items exist and error occurs', (tester) async {
    var retried = false;
    const items = ['Item 1'];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AsyncListView<String>(
            state: const SourceListState(
              data: items,
              error: NetworkError('More failed'),
            ),
            items: items,
            emptyMessage: 'No items',
            onRefresh: () async {},
            onRetry: () async => retried = true,
            itemBuilder: (context, item, index) => ListTile(title: Text(item)),
          ),
        ),
      ),
    );

    expect(find.text('Item 1'), findsOneWidget);
    expect(find.text('Cannot reach the server. Check your connection.'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    expect(retried, isTrue);
  });
}
