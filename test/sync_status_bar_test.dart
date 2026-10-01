import 'package:cotime_book/models/page_sync_state.dart';
import 'package:cotime_book/widgets/sync_status_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows a synchronization error instead of a false synced state',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SyncStatusBar(
          syncState: PageSyncState.error('Realtime is unavailable'),
          onlineUsers: [],
        ),
      ),
    ));

    expect(find.text('Realtime is unavailable'), findsOneWidget);
    expect(find.text('Synced'), findsNothing);
    expect(find.byIcon(Icons.sync_problem), findsOneWidget);
  });

  testWidgets('counts unique ready readers only', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SyncStatusBar(
          syncState: const PageSyncState.idle(),
          onlineUsers: [
            readyUser('user-a'),
            readyUser('user-a'),
            readyUser('user-b'),
            {
              'user_id': 'lobby-user',
              'is_reading': false,
              'reader_ready': true,
            },
            {
              'user_id': 'loading-user',
              'is_reading': true,
              'reader_ready': false,
            },
          ],
        ),
      ),
    ));

    expect(find.text('2 readers ready'), findsOneWidget);
  });

  testWidgets('confirmation progress ignores spoofed non-quorum ids',
      (tester) async {
    final request = PageTurnRequest(
      sessionId: 'session-1',
      requestId: 'request-1',
      requestedByUserId: 'user-a',
      requestedByNickname: 'Alice',
      direction: PageTurnDirection.next,
      fromCfi: 'epubcfi(/6/4)',
      requestedAt: DateTime.now(),
      confirmedUserIds: const {'user-a', 'outsider'},
      requiredUserIds: const {'user-a', 'user-b'},
    );

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SyncStatusBar(
          syncState: PageSyncState(
            status: SyncStatus.requesting,
            currentRequest: request,
          ),
          onlineUsers: [readyUser('user-a'), readyUser('user-b')],
        ),
      ),
    ));

    expect(find.text('1/2'), findsOneWidget);
  });

  testWidgets('the bar keeps one height in every state', (tester) async {
    // The bar sits on top of the EPUB viewer. If it changes height, the
    // WebView resizes and epub.js re-paginates mid-turn, replacing this
    // reader's CFI with one no other reader has.
    PageTurnRequest request(Set<String> confirmed) => PageTurnRequest(
      sessionId: 'session-1',
      requestId: 'request-1',
      requestedByUserId: 'user-a',
      requestedByNickname: 'Alice with a rather long nickname',
      direction: PageTurnDirection.next,
      fromCfi: 'epubcfi(/6/4)',
      requestedAt: DateTime.now(),
      confirmedUserIds: confirmed,
      requiredUserIds: const {'user-a', 'user-b', 'user-c', 'user-d'},
    );
    final users = [
      for (final id in ['user-a', 'user-b', 'user-c', 'user-d'])
        {...readyUser(id), 'nickname': 'Reader $id with a long name'},
    ];

    final states = <PageSyncState>[
      const PageSyncState.idle(),
      PageSyncState(
        status: SyncStatus.requesting,
        currentRequest: request(const {'user-a'}),
      ),
      PageSyncState(
        status: SyncStatus.confirming,
        currentRequest: request(const {'user-a'}),
      ),
      PageSyncState(
        status: SyncStatus.waiting,
        currentRequest: request(const {'user-a', 'user-b'}),
      ),
      const PageSyncState(status: SyncStatus.turning),
      const PageSyncState.error(
        'Waiting for Reader user-b with a long name, Reader user-c with a '
        'long name and Reader user-d with a long name to become ready',
      ),
    ];

    for (final state in states) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SyncStatusBar(syncState: state, onlineUsers: users),
              const Expanded(child: SizedBox.expand(key: Key('viewer'))),
            ],
          ),
        ),
      ));

      expect(
        tester.getSize(find.byType(SyncStatusBar)).height,
        SyncStatusBar.height,
        reason: '${state.status} / ${state.errorMessage}',
      );
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('a request waiting on this reader can be answered from the bar',
      (tester) async {
    var confirmed = 0;
    var declined = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SyncStatusBar(
          syncState: PageSyncState(
            status: SyncStatus.confirming,
            currentRequest: PageTurnRequest(
              sessionId: 'session-1',
              requestId: 'request-1',
              requestedByUserId: 'user-a',
              requestedByNickname: 'Alice',
              direction: PageTurnDirection.next,
              fromCfi: 'epubcfi(/6/4)',
              requestedAt: DateTime.now(),
              confirmedUserIds: const {'user-a'},
              requiredUserIds: const {'user-a', 'user-b'},
            ),
          ),
          onlineUsers: [readyUser('user-a'), readyUser('user-b')],
          onConfirm: () => confirmed++,
          onDecline: () => declined++,
        ),
      ),
    ));

    expect(find.text('Alice wants to go to next page'), findsOneWidget);
    await tester.tap(find.text('Turn'));
    await tester.tap(find.text('Wait'));
    expect(confirmed, 1);
    expect(declined, 1);
  });
}

Map<String, dynamic> readyUser(String userId) => {
      'user_id': userId,
      'nickname': userId,
      'is_reading': true,
      'reader_ready': true,
    };
