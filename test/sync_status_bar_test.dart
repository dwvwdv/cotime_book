import 'package:cotime_book/models/page_info.dart';
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
      requestId: 'request-1',
      requestedByUserId: 'user-a',
      requestedByNickname: 'Alice',
      direction: PageTurnDirection.next,
      fromSeq: 3,
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

  testWidgets('a jump says where it goes, and is answered with Go',
      (tester) async {
    PageTurnRequest jump(PageInfo? label) => PageTurnRequest(
          requestId: 'request-1',
          requestedByUserId: 'user-a',
          requestedByNickname: 'Alice',
          direction: PageTurnDirection.jump,
          fromSeq: 3,
          targetCfi: 'epubcfi(/6/14!/4/2/1:0)',
          targetLabel: label,
          requestedAt: DateTime.now(),
          confirmedUserIds: const {'user-a'},
          requiredUserIds: const {'user-a', 'user-b'},
        );

    var confirmed = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SyncStatusBar(
          syncState: PageSyncState(
            status: SyncStatus.confirming,
            currentRequest: jump(
              const PageInfo(page: 5, pages: 12, progress: 0.45),
            ),
          ),
          onlineUsers: [readyUser('user-a'), readyUser('user-b')],
          onConfirm: () => confirmed++,
        ),
      ),
    ));
    expect(
      find.text('Alice wants to jump to page 5 / 12 (45%)'),
      findsOneWidget,
    );
    await tester.tap(find.text('Go'));
    expect(confirmed, 1);

    expect(
      describeRequest(jump(null)),
      'Alice wants to jump to another page',
    );
    expect(
      describeRequest(jump(const PageInfo(page: 2, pages: 3))),
      'Alice wants to jump to page 2 / 3',
    );
  });

  testWidgets('the bar keeps one height in every state', (tester) async {
    // The bar sits on top of the EPUB viewer. If it changes height, the
    // WebView resizes and epub.js re-paginates mid-turn, replacing this
    // reader's CFI with one no other reader has.
    PageTurnRequest request(Set<String> confirmed) => PageTurnRequest(
      requestId: 'request-1',
      requestedByUserId: 'user-a',
      requestedByNickname: 'Alice with a rather long nickname',
      direction: PageTurnDirection.next,
      fromSeq: 3,
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
      PageSyncState(
        status: SyncStatus.confirming,
        currentRequest: PageTurnRequest(
          requestId: 'request-2',
          requestedByUserId: 'user-a',
          requestedByNickname: 'Alice with a rather long nickname',
          direction: PageTurnDirection.jump,
          fromSeq: 3,
          targetCfi: 'cfi-far',
          targetLabel: const PageInfo(page: 1234, pages: 5678, progress: 0.5),
          requestedAt: DateTime.now(),
          confirmedUserIds: const {'user-a'},
          requiredUserIds: const {'user-a', 'user-b'},
        ),
      ),
      const PageSyncState.idle().withReadersReconnecting([
        'Reader user-b with a long name',
        'Reader user-c with a long name',
        'Reader user-d with a long name',
      ]),
      const PageSyncState.idle().withRoomHolds(
        reconnecting: [],
        inAd: [
          'Reader user-b with a long name',
          'Reader user-c with a long name',
          'Reader user-d with a long name',
        ],
        adBreak: true,
      ),
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

  testWidgets('a reader who dropped out is named while turns are held',
      (tester) async {
    // Regression: with the other reader briefly disconnected, the one left
    // could turn freely, and the bar still read "1 readers ready".
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SyncStatusBar(
          syncState: const PageSyncState.idle().withReadersReconnecting(
            ['Bob'],
          ),
          onlineUsers: [readyUser('user-a')],
        ),
      ),
    ));

    expect(find.text('Waiting for Bob to reconnect...'), findsOneWidget);
    expect(find.text('1 readers ready'), findsNothing);
  });

  testWidgets('an ad break names who the room is waiting for', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SyncStatusBar(
          syncState: const PageSyncState.idle().withRoomHolds(
            reconnecting: [],
            inAd: ['Alice'],
            adBreak: true,
          ),
          onlineUsers: [readyUser('user-a')],
        ),
      ),
    ));

    expect(find.text('Ad break: waiting for Alice...'), findsOneWidget);
    expect(find.text('Synced'), findsNothing);
  });

  testWidgets('the bar opens the member list', (tester) async {
    var opened = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SyncStatusBar(
          syncState: const PageSyncState.idle(),
          onlineUsers: [readyUser('user-a')],
          onShowMembers: () => opened++,
        ),
      ),
    ));

    await tester.tap(find.byIcon(Icons.people_outline));
    expect(opened, 1);
    await tester.tap(find.text('1 readers ready'));
    expect(opened, 2);
  });

  testWidgets('a request waiting on this reader is answered, not taken for '
      'the member list', (tester) async {
    var opened = 0;
    var confirmed = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SyncStatusBar(
          syncState: PageSyncState(
            status: SyncStatus.confirming,
            currentRequest: PageTurnRequest(
              requestId: 'request-1',
              requestedByUserId: 'user-a',
              requestedByNickname: 'Alice',
              direction: PageTurnDirection.next,
              fromSeq: 0,
              requestedAt: DateTime.utc(2026),
              confirmedUserIds: const {'user-a'},
              requiredUserIds: const {'user-a', 'user-b'},
            ),
          ),
          onlineUsers: [readyUser('user-a'), readyUser('user-b')],
          onConfirm: () => confirmed++,
          onShowMembers: () => opened++,
        ),
      ),
    ));

    await tester.tap(find.text('Alice wants to go to next page'));
    await tester.tap(find.text('Turn'));
    expect(confirmed, 1);
    expect(opened, 0);
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
              requestId: 'request-1',
              requestedByUserId: 'user-a',
              requestedByNickname: 'Alice',
              direction: PageTurnDirection.next,
              fromSeq: 3,
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
