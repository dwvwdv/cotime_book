import 'dart:async';

import 'package:cotime_book/config/ad_config.dart';
import 'package:cotime_book/config/app_constants.dart';
import 'package:cotime_book/models/page_info.dart';
import 'package:cotime_book/models/page_sync_state.dart';
import 'package:cotime_book/services/page_sync_service.dart';
import 'package:cotime_book/services/presence_merge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PageSyncService', () {
    test('readers on different screens keep turning pages together', () async {
      // Regression: the old protocol required every reader's CFI string to be
      // identical. Two different screens paginate differently, so their CFIs
      // for the same page never matched and every turn was rejected — the
      // room stayed on page one.
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice', layout: 'phone');
      final bob = room.join('bob', 'Bob', layout: 'tablet');
      addTearDown(room.dispose);
      await flush();

      for (var turn = 1; turn <= 4; turn++) {
        final requester = turn.isOdd ? alice : bob;
        final follower = turn.isOdd ? bob : alice;

        expect(
          await requester.service.requestPageTurn(
            direction: PageTurnDirection.next,
          ),
          isTrue,
          reason: 'turn $turn request',
        );
        await flush();
        expect(follower.service.currentState.status, SyncStatus.confirming);
        await follower.service.confirmPageTurn();
        await flush();

        expect(alice.service.position.seq, turn, reason: 'alice turn $turn');
        expect(bob.service.position.seq, turn, reason: 'bob turn $turn');
        expect(alice.service.position, bob.service.position);
        expect(alice.service.currentState.status, SyncStatus.idle);
        expect(bob.service.currentState.status, SyncStatus.idle);
        expect(alice.service.currentState.errorMessage, isNull);
        expect(bob.service.currentState.errorMessage, isNull);
      }
      // The follower was told to display each page the requester landed on.
      expect(bob.displayed.length, 2);
      expect(alice.displayed.length, 2);
    });

    test('a reader reading alone turns without asking anyone', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      room.join('carol', 'Carol', isReading: false); // still in the lobby
      addTearDown(room.dispose);
      await flush();

      expect(
        await alice.service.requestPageTurn(direction: PageTurnDirection.next),
        isTrue,
      );
      await flush();

      expect(alice.service.position.seq, 1);
      expect(
        room.sent.where((e) => e.event == PageSyncService.requestEvent),
        isEmpty,
      );
    });

    test('someone in the lobby or still loading never blocks a turn', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      final bob = room.join('bob', 'Bob');
      room.join('carol', 'Carol', isReading: false);
      room.join('dave', 'Dave', readerReady: false);
      addTearDown(room.dispose);
      await flush();

      await alice.service.requestPageTurn(direction: PageTurnDirection.next);
      await flush();
      expect(alice.service.currentState.currentRequest!.requiredUserIds, {
        'alice',
        'bob',
      });
      await bob.service.confirmPageTurn();
      await flush();

      expect(alice.service.position.seq, 1);
      expect(bob.service.position.seq, 1);
    });

    test(
      'a reader who opens the book late lands on the room\'s page',
      () async {
        final room = FakeRoom();
        final alice = room.join('alice', 'Alice');
        addTearDown(room.dispose);
        await flush();
        for (var i = 0; i < 3; i++) {
          await alice.service.requestPageTurn(
            direction: PageTurnDirection.next,
          );
          await flush();
        }
        expect(alice.service.position.seq, 3);

        // Bob starts from the database, which may be behind.
        final bob = room.join(
          'bob',
          'Bob',
          initialPosition: const SharedPosition(seq: 0, cfi: 'db-cfi'),
        );
        await flush();

        expect(bob.service.position, alice.service.position);
        expect(bob.displayed, [alice.service.position]);
      },
    );

    test('a lost commit still reaches the follower', () async {
      final room = FakeRoom();
      final alice = room.join(
        'alice',
        'Alice',
        positionAnnounceInterval: const Duration(milliseconds: 20),
      );
      final bob = room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();

      room.dropEvents.add(PageSyncService.commitEvent);
      await alice.service.requestPageTurn(direction: PageTurnDirection.next);
      await flush();
      await bob.service.confirmPageTurn();
      await flush();
      expect(alice.service.position.seq, 1);

      // Alice repeats where she is; Bob follows.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await flush();
      expect(bob.service.position, alice.service.position);
      expect(bob.service.currentState.status, SyncStatus.idle);
    });

    test(
      'a follower that missed a commit catches up from the next request',
      () async {
        final room = FakeRoom();
        final alice = room.join('alice', 'Alice');
        final bob = room.join('bob', 'Bob');
        addTearDown(room.dispose);
        await flush();

        room.dropEvents.add(PageSyncService.commitEvent);
        await alice.service.requestPageTurn(direction: PageTurnDirection.next);
        await flush();
        await bob.service.confirmPageTurn();
        await flush();
        room.dropEvents.clear();
        expect(bob.service.position.seq, 0);

        await alice.service.requestPageTurn(direction: PageTurnDirection.next);
        await flush();

        // Bob was moved to Alice's page before being asked about the next.
        expect(bob.displayed.single, alice.service.position);
        expect(bob.service.currentState.status, SyncStatus.confirming);
        await bob.service.confirmPageTurn();
        await flush();
        expect(bob.service.position.seq, 2);
      },
    );

    test('a lost vote is sent again when the requester nudges', () async {
      final room = FakeRoom();
      final alice = room.join(
        'alice',
        'Alice',
        nudgeInterval: const Duration(milliseconds: 20),
      );
      final bob = room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();

      await alice.service.requestPageTurn(direction: PageTurnDirection.next);
      await flush();
      room.dropEvents.add(PageSyncService.voteEvent);
      await bob.service.confirmPageTurn();
      await flush();
      expect(alice.service.position.seq, 0);

      room.dropEvents.clear();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await flush();

      expect(alice.service.position.seq, 1);
      expect(bob.service.position.seq, 1);
    });

    test(
      'a follower that missed the request picks it up from a nudge',
      () async {
        final room = FakeRoom();
        final alice = room.join(
          'alice',
          'Alice',
          nudgeInterval: const Duration(milliseconds: 20),
        );
        final bob = room.join('bob', 'Bob');
        addTearDown(room.dispose);
        await flush();

        room.dropEvents.add(PageSyncService.requestEvent);
        await alice.service.requestPageTurn(direction: PageTurnDirection.next);
        await flush();
        expect(bob.service.currentState.status, SyncStatus.idle);

        room.dropEvents.clear();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await flush();
        expect(bob.service.currentState.status, SyncStatus.confirming);
      },
    );

    test('declining names the reader and releases everyone', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      final bob = room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();

      await alice.service.requestPageTurn(direction: PageTurnDirection.next);
      await flush();
      await bob.service.declinePageTurn();
      await flush();

      expect(alice.service.currentState.status, SyncStatus.idle);
      expect(alice.service.currentState.currentRequest, isNull);
      expect(
        alice.service.currentState.errorMessage,
        'Bob asked to wait on this page',
      );
      expect(bob.service.currentState.status, SyncStatus.idle);
      expect(alice.service.position.seq, 0);
    });

    test('a reader who leaves the book stops blocking the turn', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      final bob = room.join('bob', 'Bob');
      room.join('carol', 'Carol');
      addTearDown(room.dispose);
      await flush();

      await alice.service.requestPageTurn(direction: PageTurnDirection.next);
      await flush();
      await bob.service.confirmPageTurn();
      await flush();
      expect(alice.service.position.seq, 0, reason: 'still waiting for Carol');

      room.setPresence('carol', isReading: false);
      await flush();

      expect(alice.service.position.seq, 1);
      expect(bob.service.position.seq, 1);
    });

    test('a requester who leaves releases the readers it asked', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      final bob = room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();

      await alice.service.requestPageTurn(direction: PageTurnDirection.next);
      await flush();
      expect(bob.service.currentState.status, SyncStatus.confirming);

      room.setPresence('alice', isReading: false);
      await flush();

      expect(bob.service.currentState.status, SyncStatus.idle);
      expect(bob.service.currentState.errorMessage, 'Alice left the book');
    });

    test('a request whose requester went silent expires', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      final bob = room.join(
        'bob',
        'Bob',
        followerLiveness: const Duration(milliseconds: 40),
      );
      addTearDown(room.dispose);
      await flush();

      await alice.service.requestPageTurn(direction: PageTurnDirection.next);
      await flush();
      // Alice's app freezes: Presence still shows her, but nothing more is
      // sent.
      await alice.service.dispose();
      expect(bob.service.currentState.status, SyncStatus.confirming);

      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(bob.service.currentState.status, SyncStatus.idle);
      expect(bob.service.currentState.currentRequest, isNull);
    });

    test('two readers pressing next together turn exactly one page', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      final bob = room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();

      await Future.wait([
        alice.service.requestPageTurn(direction: PageTurnDirection.next),
        bob.service.requestPageTurn(direction: PageTurnDirection.next),
      ]);
      await flush();
      await flush();

      expect(alice.service.position.seq, 1);
      expect(bob.service.position, alice.service.position);
      expect(alice.service.currentState.status, SyncStatus.idle);
      expect(bob.service.currentState.status, SyncStatus.idle);
      expect(room.turnsExecuted, 1);
    });

    test('a request from a page the room has left is refused', () async {
      final room = FakeRoom();
      final alice = room.join(
        'alice',
        'Alice',
        initialPosition: const SharedPosition(seq: 4, cfi: 'p4'),
      );
      addTearDown(room.dispose);
      await flush();

      room.inject(PageSyncService.requestEvent, {
        'request_id': 'old',
        'user_id': 'bob',
        'nickname': 'Bob',
        'direction': 'next',
        'from_epoch': 0,
        'from_seq': 2,
        'from_cfi': 'p2',
        'requested_at': DateTime.now().toUtc().toIso8601String(),
        'required_users': ['alice', 'bob'],
      });
      await flush();

      expect(alice.service.currentState.status, SyncStatus.idle);
      final vote = room.sent.singleWhere(
        (e) => e.event == PageSyncService.voteEvent,
      );
      expect(vote.payload['accept'], isFalse);
      expect(vote.payload['reason'], 'out_of_sync');
    });

    test('a requester that is behind is told so in plain words', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();
      room.dropEvents.add(PageSyncService.requestEvent);

      await alice.service.requestPageTurn(direction: PageTurnDirection.next);
      final requestId = alice.service.currentState.currentRequest!.requestId;
      room.inject(PageSyncService.voteEvent, {
        'request_id': requestId,
        'user_id': 'bob',
        'accept': false,
        'reason': 'out_of_sync',
      });
      await flush();

      expect(alice.service.currentState.status, SyncStatus.idle);
      expect(alice.service.currentState.errorMessage, isNot(contains('_')));
      expect(
        alice.service.currentState.errorMessage,
        contains('different pages'),
      );
    });

    test('a turn that cannot move releases everyone', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice', canTurn: false);
      final bob = room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();

      await alice.service.requestPageTurn(
        direction: PageTurnDirection.previous,
      );
      await flush();
      await bob.service.confirmPageTurn();
      await flush();

      expect(alice.service.position.seq, 0);
      expect(alice.service.currentState.status, SyncStatus.idle);
      expect(alice.service.currentState.errorMessage, contains('did not move'));
      expect(bob.service.currentState.status, SyncStatus.idle);
      expect(bob.service.currentState.currentRequest, isNull);
    });

    test('a turn the viewer never finishes times out', () async {
      final room = FakeRoom();
      final alice = room.join(
        'alice',
        'Alice',
        neverRelocates: true,
        turnTimeout: const Duration(milliseconds: 30),
      );
      addTearDown(room.dispose);
      await flush();

      await alice.service.requestPageTurn(direction: PageTurnDirection.next);
      expect(alice.service.currentState.status, SyncStatus.turning);
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(alice.service.currentState.status, SyncStatus.idle);
      expect(alice.abandoned, hasLength(1));
    });

    test(
      'an unanswered request times out and names who it waited for',
      () async {
        final room = FakeRoom();
        final alice = room.join(
          'alice',
          'Alice',
          requestTimeout: const Duration(milliseconds: 40),
        );
        room.join('bob', 'Bob');
        addTearDown(room.dispose);
        await flush();

        await alice.service.requestPageTurn(direction: PageTurnDirection.next);
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(alice.service.currentState.status, SyncStatus.idle);
        expect(
          alice.service.currentState.errorMessage,
          'Page turn timed out waiting for Bob',
        );
      },
    );

    test('a reader whose app dropped this version is named (GH-33)', () async {
      // Their app listens for other events, so it never answers; "timed
      // out" alone reads as a bad connection.
      final room = FakeRoom();
      final alice = room.join(
        'alice',
        'Alice',
        requestTimeout: const Duration(milliseconds: 40),
      );
      room.join('bob', 'Bob');
      room.setProtocol('bob', 99, oldest: 99);
      addTearDown(room.dispose);
      await flush();

      await alice.service.requestPageTurn(direction: PageTurnDirection.next);
      await Future<void>.delayed(const Duration(milliseconds: 80));

      expect(
        alice.service.currentState.errorMessage,
        'Page turn timed out waiting for Bob. '
        'Update the app to read with Bob',
      );
    });

    test(
      'a reader on an app that breaks pages the old way is asked to update',
      () async {
        // v1.0.5 sends no version. It speaks the same wire, but it lays some
        // books out on other page breaks than this app (GH-49): the timeout
        // is worth an update, not only a better connection.
        final room = FakeRoom();
        final alice = room.join(
          'alice',
          'Alice',
          requestTimeout: const Duration(milliseconds: 40),
        );
        room.join('bob', 'Bob');
        room.setProtocol('bob', null);
        addTearDown(room.dispose);
        await flush();

        await alice.service.requestPageTurn(direction: PageTurnDirection.next);
        await Future<void>.delayed(const Duration(milliseconds: 80));

        expect(
          alice.service.currentState.errorMessage,
          'Page turn timed out waiting for Bob. '
          'Bob needs to update the app to read together',
        );
      },
    );

    test(
      'a transient failure clears itself instead of pinning the bar',
      () async {
        final room = FakeRoom();
        final alice = room.join(
          'alice',
          'Alice',
          errorAutoClearDelay: const Duration(milliseconds: 20),
        );
        final bob = room.join('bob', 'Bob');
        addTearDown(room.dispose);
        await flush();

        await alice.service.requestPageTurn(direction: PageTurnDirection.next);
        await flush();
        await bob.service.declinePageTurn();
        await flush();
        expect(alice.service.currentState.errorMessage, isNotNull);

        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(alice.service.currentState.errorMessage, isNull);
        expect(alice.service.currentState.status, SyncStatus.idle);
      },
    );

    test('fails closed until Presence includes this reader', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice', trackPresence: false);
      addTearDown(room.dispose);
      await flush();

      expect(
        await alice.service.requestPageTurn(direction: PageTurnDirection.next),
        isFalse,
      );
      expect(alice.service.currentState.errorMessage, contains('connecting'));
      expect(alice.service.position.seq, 0);
    });

    test(
      'a dropped connection does not let the requester turn alone',
      () async {
        final room = FakeRoom();
        final alice = room.join('alice', 'Alice');
        room.join('bob', 'Bob');
        addTearDown(room.dispose);
        await flush();

        await alice.service.requestPageTurn(direction: PageTurnDirection.next);
        await flush();
        // A reconnect empties the Presence view for a moment.
        room.blackout('alice');
        await flush();

        expect(alice.service.position.seq, 0);
        expect(alice.service.currentState.status, SyncStatus.requesting);
        expect(alice.service.currentState.currentRequest!.requiredUserIds, {
          'alice',
          'bob',
        });
      },
    );

    test('a reader whose connection dropped does not turn alone', () async {
      // Regression: with the channel down, Presence read empty, so the
      // quorum was this reader alone and the turn went through unasked — or
      // the request was sent and failed with "Could not reach the other
      // readers".
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();

      room.offline.add('alice');
      room.blackout('alice');
      await flush();

      expect(
        await alice.service.requestPageTurn(direction: PageTurnDirection.next),
        isFalse,
      );
      expect(alice.service.position.seq, 0);
      expect(alice.service.currentState.errorMessage, contains('Reconnecting'));
      expect(
        room.sent.where((e) => e.event == PageSyncService.requestEvent),
        isEmpty,
      );
    });

    test(
      'right after a reconnect it waits for Presence before turning',
      () async {
        final room = FakeRoom();
        final alice = room.join('alice', 'Alice');
        room.join('bob', 'Bob');
        addTearDown(room.dispose);
        await flush();

        // Connected again, but the new channel has not synced Presence yet.
        room.blackout('alice');
        await flush();

        expect(
          await alice.service.requestPageTurn(
            direction: PageTurnDirection.next,
          ),
          isFalse,
        );
        expect(alice.service.position.seq, 0);
        expect(alice.service.currentState.errorMessage, contains('connecting'));
      },
    );

    test('a loading reader cannot start a turn', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice', viewerReady: false);
      addTearDown(room.dispose);
      await flush();

      expect(
        await alice.service.requestPageTurn(direction: PageTurnDirection.next),
        isFalse,
      );
      expect(alice.service.currentState.errorMessage, contains('loading'));
    });

    test(
      'a reader waking from an older stretch does not pull the room back',
      () async {
        // Regression: seq restarted at 0 for every reader who opened the book
        // alone, so a reader who slept through a session with a higher seq
        // dragged everyone back to their stale page when they woke.
        final room = FakeRoom();
        final bob = room.join(
          'bob',
          'Bob',
          initialPosition: const SharedPosition(epoch: 5, seq: 10, cfi: 'p10'),
        );
        await flush();
        room.setOnline('bob', false); // asleep
        await flush();
        final alice = room.join('alice', 'Alice', mintEpoch: () => 100);
        addTearDown(room.dispose);
        await flush();

        for (var i = 0; i < 2; i++) {
          await alice.service.requestPageTurn(
            direction: PageTurnDirection.next,
          );
          await flush();
        }
        expect(alice.service.position.epoch, 100);
        expect(alice.service.position.seq, 2);

        room.setOnline('bob', true);
        await flush();

        expect(alice.service.position.seq, 2, reason: 'Alice stays put');
        expect(alice.displayed, isEmpty);
        expect(bob.service.position, alice.service.position);
      },
    );

    test('a reader who drops out holds the room until they are back', () async {
      // Turning on without them would leave them on another page when they
      // reconnect. Not silent: the bar names who it is waiting for.
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();

      room.setOnline('bob', false);
      await flush();

      expect(alice.service.currentState.readersReconnecting, ['Bob']);
      expect(
        await alice.service.requestPageTurn(direction: PageTurnDirection.next),
        isFalse,
      );
      expect(
        alice.service.currentState.errorMessage,
        'Waiting for Bob to reconnect',
      );
      expect(alice.service.position.seq, 0);

      room.setOnline('bob', true);
      await flush();
      expect(alice.service.currentState.readersReconnecting, isEmpty);
    });

    test('the hold ends once the reconnect grace has passed', () async {
      final room = FakeRoom();
      final alice = room.join(
        'alice',
        'Alice',
        reconnectGrace: const Duration(milliseconds: 40),
      );
      room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();

      room.setOnline('bob', false);
      await flush();
      expect(alice.service.currentState.readersReconnecting, ['Bob']);

      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(alice.service.currentState.readersReconnecting, isEmpty);
      expect(
        await alice.service.requestPageTurn(direction: PageTurnDirection.next),
        isTrue,
      );
    });

    test('leaving on purpose never holds anyone up', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      final bob = room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();

      await bob.service.leave();
      await flush();
      room.setOnline('bob', false);
      await flush();

      expect(alice.service.currentState.readersReconnecting, isEmpty);
      expect(
        await alice.service.requestPageTurn(direction: PageTurnDirection.next),
        isTrue,
      );
    });

    test('a reader dropping out mid-request pauses the turn', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();

      await alice.service.requestPageTurn(direction: PageTurnDirection.next);
      await flush();
      room.setOnline('bob', false);
      await flush();

      expect(alice.service.position.seq, 0, reason: 'not turned without Bob');
      expect(alice.service.currentState.currentRequest, isNull);
      expect(
        alice.service.currentState.errorMessage,
        'Waiting for Bob to reconnect',
      );
    });

    test('readers converge on one page after conflicting commits', () async {
      final room = FakeRoom();
      final alice = room.join(
        'alice',
        'Alice',
        initialPosition: const SharedPosition(seq: 2, cfi: 'aaa'),
      );
      final bob = room.join(
        'bob',
        'Bob',
        initialPosition: const SharedPosition(seq: 2, cfi: 'bbb'),
      );
      addTearDown(room.dispose);
      await flush();

      expect(alice.service.position, const SharedPosition(seq: 2, cfi: 'bbb'));
      expect(bob.service.position, const SharedPosition(seq: 2, cfi: 'bbb'));
    });
  });

  group('jumping to a page', () {
    const label = PageInfo(page: 5, pages: 12, progress: 0.45);

    test('the room goes to the page picked once everyone agrees', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      final bob = room.join('bob', 'Bob', layout: 'tablet');
      addTearDown(room.dispose);
      await flush();

      expect(
        await alice.service.requestJump(
          targetCfi: 'epubcfi(/6/14!/4/2/1:0)',
          label: label,
        ),
        isTrue,
      );
      await flush();

      // Nobody moves on a request: Bob is asked, and told where to.
      expect(bob.displayed, isEmpty);
      final asked = bob.service.currentState;
      expect(asked.status, SyncStatus.confirming);
      expect(asked.currentRequest!.isJump, isTrue);
      expect(asked.currentRequest!.targetCfi, 'epubcfi(/6/14!/4/2/1:0)');
      expect(asked.currentRequest!.targetLabel, label);

      await bob.service.confirmPageTurn();
      await flush();

      const landed = SharedPosition(
        epoch: 1,
        seq: 1,
        cfi: 'epubcfi(/6/14!/4/2/1:0)',
      );
      expect(alice.service.position, landed);
      expect(bob.service.position, landed);
      expect(bob.displayed, [landed]);
      expect(alice.service.currentState.status, SyncStatus.idle);
      expect(bob.service.currentState.status, SyncStatus.idle);
    });

    test('a reader reading alone jumps without asking anyone', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      addTearDown(room.dispose);
      await flush();

      expect(await alice.service.requestJump(targetCfi: 'cfi-far'), isTrue);
      await flush();

      expect(alice.service.position.cfi, 'cfi-far');
      expect(alice.service.position.seq, 1);
    });

    test('a jump is not put to a reader whose app cannot answer it', () async {
      // An app on version 3 drops a jump without a word: the room would
      // wait out the whole timeout for it.
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      room.join('bob', 'Bob');
      room.setProtocol('bob', 3, oldest: 2);
      addTearDown(room.dispose);
      await flush();

      expect(await alice.service.requestJump(targetCfi: 'cfi-far'), isFalse);
      expect(
        alice.service.currentState.errorMessage,
        'Bob needs to update the app to jump to a page',
      );
      expect(
        room.sent.where((e) => e.event == PageSyncService.requestEvent),
        isEmpty,
      );

      // Turning a page together still works with them.
      expect(
        await alice.service.requestPageTurn(direction: PageTurnDirection.next),
        isTrue,
      );
    });

    test('a reader in the lobby on an old app does not stop a jump', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      room.join('bob', 'Bob', isReading: false);
      room.setProtocol('bob', 3, oldest: 2);
      addTearDown(room.dispose);
      await flush();

      expect(await alice.service.requestJump(targetCfi: 'cfi-far'), isTrue);
      await flush();
      expect(alice.service.position.cfi, 'cfi-far');
    });

    test('two jumps to different pages are not taken as one', () async {
      // Pressing "next" together is the same wish; picking two different
      // pages is not, and the loser of the tie-break is asked like anyone.
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      final bob = room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();

      await Future.wait([
        alice.service.requestJump(targetCfi: 'cfi-alice'),
        bob.service.requestJump(targetCfi: 'cfi-bob'),
      ]);
      await flush();

      final states = [alice.service.currentState, bob.service.currentState];
      expect(states.map((state) => state.status).toSet(), {
        SyncStatus.requesting,
        SyncStatus.confirming,
      });
      expect(alice.service.position.seq, 0);
      final asked = states.firstWhere(
        (state) => state.status == SyncStatus.confirming,
      );
      final requester = states.firstWhere(
        (state) => state.status == SyncStatus.requesting,
      );
      expect(
        asked.currentRequest!.requestId,
        requester.currentRequest!.requestId,
      );
    });

    test('two jumps to the same page turn exactly once', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      final bob = room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();

      await Future.wait([
        alice.service.requestJump(targetCfi: 'cfi-same'),
        bob.service.requestJump(targetCfi: 'cfi-same'),
      ]);
      await flush();

      expect(alice.service.position.seq, 1);
      expect(bob.service.position, alice.service.position);
      expect(alice.service.position.cfi, 'cfi-same');
    });

    test('a jump the viewer cannot show releases everyone', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice', canTurn: false);
      final bob = room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();

      await alice.service.requestJump(targetCfi: 'cfi-far');
      await flush();
      await bob.service.confirmPageTurn();
      await flush();

      expect(alice.service.position.seq, 0);
      expect(
        alice.service.currentState.errorMessage,
        'Could not go to that page — try again',
      );
      expect(bob.service.currentState.currentRequest, isNull);
    });

    test('a jump gets longer to land than a turn', () async {
      // The page may be in a chapter the viewer has not loaded yet.
      final room = FakeRoom();
      final alice = room.join(
        'alice',
        'Alice',
        neverRelocates: true,
        turnTimeout: const Duration(milliseconds: 20),
        jumpTimeout: const Duration(milliseconds: 120),
      );
      addTearDown(room.dispose);
      await flush();

      await alice.service.requestJump(targetCfi: 'cfi-far');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(alice.service.currentState.status, SyncStatus.turning);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(alice.service.currentState.status, SyncStatus.idle);
      expect(alice.abandoned, hasLength(1));
      expect(alice.service.currentState.errorMessage, contains('that page'));
    });

    test('a jump without a target is never put to the room', () async {
      // Everyone would drop it, and the room would wait out the timeout.
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();

      expect(
        await alice.service.requestPageTurn(direction: PageTurnDirection.jump),
        isFalse,
      );
      expect(await alice.service.requestJump(targetCfi: ''), isFalse);
      expect(
        room.sent.where((e) => e.event == PageSyncService.requestEvent),
        isEmpty,
      );
      expect(alice.service.currentState.status, SyncStatus.idle);
    });

    test('turning the page does not answer a jump', () async {
      // Agreeing by turning the same way only makes sense for next/previous.
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice');
      final bob = room.join('bob', 'Bob');
      addTearDown(room.dispose);
      await flush();

      await alice.service.requestJump(targetCfi: 'cfi-far');
      await flush();
      expect(
        await bob.service.requestPageTurn(direction: PageTurnDirection.next),
        isFalse,
      );
      expect(bob.service.currentState.status, SyncStatus.confirming);
    });
  });

  group('jump requests on the wire', () {
    PageTurnRequest jump({PageInfo? label}) => PageTurnRequest(
      requestId: 'r1',
      requestedByUserId: 'alice',
      requestedByNickname: 'Alice',
      direction: PageTurnDirection.jump,
      fromEpoch: 7,
      fromSeq: 3,
      fromCfi: 'cfi-here',
      targetCfi: 'cfi-there',
      targetLabel: label,
      requestedAt: DateTime.utc(2026, 10, 27),
      confirmedUserIds: const {'alice'},
      requiredUserIds: const {'alice', 'bob'},
    );

    test('carry where they go and how to name it', () {
      final read = PageTurnRequest.fromJson(
        jump(
          label: const PageInfo(page: 5, pages: 12, progress: 0.45),
        ).toJson(),
      );
      expect(read.direction, PageTurnDirection.jump);
      expect(read.targetCfi, 'cfi-there');
      expect(
        read.targetLabel,
        const PageInfo(page: 5, pages: 12, progress: 0.45),
      );
    });

    test('name no page when the label is missing or wrong', () {
      expect(PageTurnRequest.fromJson(jump().toJson()).targetLabel, isNull);
      final json = jump().toJson()
        ..['target_page'] = 13
        ..['target_pages'] = 12;
      expect(PageTurnRequest.fromJson(json).targetLabel, isNull);
    });

    test('without a target are refused', () {
      final json = jump().toJson()..remove('target_cfi');
      expect(() => PageTurnRequest.fromJson(json), throwsFormatException);
      json['target_cfi'] = '';
      expect(() => PageTurnRequest.fromJson(json), throwsFormatException);
    });

    test('leave turns as they were', () {
      final turn = PageTurnRequest(
        requestId: 'r2',
        requestedByUserId: 'alice',
        requestedByNickname: 'Alice',
        direction: PageTurnDirection.next,
        fromSeq: 1,
        requestedAt: DateTime.utc(2026, 10, 27),
        confirmedUserIds: const {'alice'},
        requiredUserIds: const {'alice', 'bob'},
      ).toJson();
      expect(turn.keys.where((key) => key.startsWith('target')), isEmpty);
      final read = PageTurnRequest.fromJson(turn);
      expect(read.isJump, isFalse);
      expect(read.targetCfi, isEmpty);
    });

    test('only an app that knows jumps is asked for one', () {
      expect(
        presenceSpeaksProtocol({
          'protocols': [
            [3, 2],
            [AppConstants.pageJumpProtocol, 2],
          ],
        }, AppConstants.pageJumpProtocol),
        isTrue,
      );
      expect(
        presenceSpeaksProtocol({
          'protocols': [
            [3, 2],
          ],
        }, AppConstants.pageJumpProtocol),
        isFalse,
      );
      expect(
        presenceSpeaksProtocol({
          'protocol': AppConstants.roomProtocolVersion,
        }, AppConstants.pageJumpProtocol),
        isTrue,
      );
      // Apps from before the field existed.
      expect(presenceSpeaksProtocol({}, AppConstants.pageJumpProtocol), isFalse);

      // The old device is the one in the book; the new one in the lobby is
      // never asked, so nobody would answer.
      Map<String, dynamic> meta(int protocol, {required bool reading}) => {
        'user_id': 'bob',
        'protocol': protocol,
        'protocol_min': 2,
        'is_reading': reading,
        'reader_ready': reading,
      };
      final oldInBook = mergePresenceUsers([
        meta(3, reading: true),
        meta(AppConstants.pageJumpProtocol, reading: false),
      ]).single;
      expect(
        presenceSpeaksProtocol(oldInBook, AppConstants.pageJumpProtocol),
        isFalse,
      );
      // Readiness is merged across connections: a stale flag on the new
      // app in the lobby must not stand in for the old one in the book.
      final oldInBookNotReady = mergePresenceUsers([
        {...meta(3, reading: true), 'reader_ready': false},
        {...meta(AppConstants.pageJumpProtocol, reading: false),
          'reader_ready': true},
      ]).single;
      expect(oldInBookNotReady['reader_ready'], isTrue);
      expect(
        presenceSpeaksProtocol(oldInBookNotReady, AppConstants.pageJumpProtocol),
        isFalse,
      );
      final newInBook = mergePresenceUsers([
        meta(3, reading: false),
        meta(AppConstants.pageJumpProtocol, reading: true),
      ]).single;
      expect(
        presenceSpeaksProtocol(newInBook, AppConstants.pageJumpProtocol),
        isTrue,
      );
    });
  });

  group('ad breaks', () {
    /// Turns [pages] pages, each asked by [requester] and agreed to by
    /// everyone else in [room].
    Future<void> turnPages(
      FakeRoom room,
      FakeReader requester,
      int pages,
    ) async {
      for (var i = 0; i < pages; i++) {
        expect(
          await requester.service.requestPageTurn(
            direction: PageTurnDirection.next,
          ),
          isTrue,
          reason: requester.service.currentState.errorMessage,
        );
        await flush();
        for (final reader in room.readers.values) {
          if (reader != requester &&
              reader.service.currentState.status == SyncStatus.confirming) {
            await reader.service.confirmPageTurn();
          }
        }
        await flush();
      }
    }

    test('every reader reaches the ad break on the same shared page', () async {
      // Regression: each device counted the moves it had seen since the app
      // started, so a reader who opened the book later, or whose ad had not
      // loaded once, got theirs on another page — or not at all while the
      // others watched one.
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice', adBreakEvery: 3, showsAd: true);
      final bob = room.join('bob', 'Bob', adBreakEvery: 3, showsAd: true);
      addTearDown(room.dispose);
      await flush();

      await turnPages(room, alice, 2);
      expect(alice.adBreaks, isEmpty);
      expect(bob.adBreaks, isEmpty);

      // Carol opens the book two pages in.
      final carol = room.join('carol', 'Carol', adBreakEvery: 3, showsAd: true);
      await flush();
      await turnPages(room, bob, 1);

      expect(alice.service.position.seq, 3);
      for (final reader in [alice, bob, carol]) {
        expect(reader.adBreaks.map((position) => position.seq), [
          3,
        ], reason: reader.nickname);
      }
    });

    test('nobody turns until every ad is closed, a reader whose ad never '
        'loaded included', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice', adBreakEvery: 2, showsAd: true);
      // An ad blocker: no ad ever loads.
      final bob = room.join('bob', 'Bob', adBreakEvery: 2);
      addTearDown(room.dispose);
      await flush();

      await turnPages(room, bob, 2);
      expect(bob.adBreaks.single.seq, 2);

      // Bob's new page stays covered while Alice watches her ad.
      expect(bob.service.currentState.adBreak, isTrue);
      expect(bob.service.currentState.readersInAd, ['Alice']);
      expect(
        await bob.service.requestPageTurn(direction: PageTurnDirection.next),
        isFalse,
      );
      expect(
        bob.service.currentState.errorMessage,
        'Waiting for Alice to finish an ad',
      );
      expect(alice.service.currentState.adBreak, isTrue);
      expect(
        await alice.service.requestPageTurn(direction: PageTurnDirection.next),
        isFalse,
      );
      await flush();
      expect(alice.service.position.seq, 2);

      alice.service.endAdBreak();
      await flush();
      expect(alice.service.currentState.adBreak, isFalse);
      expect(bob.service.currentState.adBreak, isFalse);
      expect(bob.service.currentState.readersInAd, isEmpty);

      await turnPages(room, bob, 1);
      expect(alice.service.position.seq, 3);
      expect(bob.service.position.seq, 3);
    });

    test('a reader under an ad turns down a request that reached it', () async {
      // Bob never heard that Alice's ad is up (or runs an app that knows
      // nothing of ad breaks): Alice's app answers for her.
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice', adBreakEvery: 2, showsAd: true);
      final bob = room.join('bob', 'Bob', adBreakEvery: 2);
      addTearDown(room.dispose);
      await flush();
      await turnPages(room, bob, 1);
      room.dropEvents.add(PageSyncService.adBreakEvent);
      await turnPages(room, bob, 1);
      expect(bob.service.currentState.adBreak, isFalse);
      expect(alice.service.currentState.adBreak, isTrue);

      expect(
        await bob.service.requestPageTurn(direction: PageTurnDirection.next),
        isTrue,
      );
      await flush();

      expect(alice.service.currentState.status, SyncStatus.idle);
      expect(bob.service.currentState.status, SyncStatus.idle);
      expect(
        bob.service.currentState.errorMessage,
        describeCancelReason('ad_break'),
      );
      expect(alice.service.position.seq, 2);
      expect(bob.service.position.seq, 2);
    });

    test('a reader without an ad keeps the page covered for a moment to hear '
        'about the others\' ads', () async {
      final room = FakeRoom();
      final alice = room.join(
        'alice',
        'Alice',
        adBreakEvery: 1,
        adBreakSettle: const Duration(milliseconds: 40),
      );
      room.join(
        'bob',
        'Bob',
        adBreakEvery: 1,
        adBreakSettle: const Duration(milliseconds: 40),
      );
      addTearDown(room.dispose);
      await flush();

      await turnPages(room, alice, 1);
      // Nobody has an ad, but Alice cannot know that yet.
      expect(alice.service.currentState.adBreak, isTrue);
      expect(alice.service.currentState.readersInAd, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 60));
      await flush();
      expect(alice.service.currentState.adBreak, isFalse);
      await turnPages(room, alice, 1);
      expect(alice.service.position.seq, 2);
    });

    test('a reader reading alone without an ad is not held up', () async {
      final room = FakeRoom();
      final alice = room.join(
        'alice',
        'Alice',
        adBreakEvery: 1,
        adBreakSettle: const Duration(minutes: 5),
      );
      addTearDown(room.dispose);
      await flush();

      await turnPages(room, alice, 2);
      expect(alice.adBreaks.length, 2);
      expect(alice.service.currentState.adBreak, isFalse);
      expect(alice.service.position.seq, 2);
    });

    test('a request whose answer was lost is turned down again when it is '
        'repeated', () async {
      // Bob never hears of Alice's ad, and her first "no" is lost: his
      // repeat must still get one, not wait out the whole request timeout.
      final room = FakeRoom();
      room.join('alice', 'Alice', adBreakEvery: 2, showsAd: true);
      final bob = room.join(
        'bob',
        'Bob',
        adBreakEvery: 2,
        nudgeInterval: const Duration(milliseconds: 20),
      );
      addTearDown(room.dispose);
      await flush();
      await turnPages(room, bob, 1);
      room.dropEvents.add(PageSyncService.adBreakEvent);
      await turnPages(room, bob, 1);

      room.dropEvents.add(PageSyncService.voteEvent);
      await bob.service.requestPageTurn(direction: PageTurnDirection.next);
      await flush();
      expect(bob.service.currentState.status, SyncStatus.requesting);

      room.dropEvents.remove(PageSyncService.voteEvent);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await flush();
      expect(bob.service.currentState.status, SyncStatus.idle);
      expect(
        bob.service.currentState.errorMessage,
        describeCancelReason('ad_break'),
      );
    });

    test(
      'an ad outlasting the settle does not keep waking the reader',
      () async {
        // Regression: the settle deadline, once past, stayed among the
        // wake-ups while an ad was up, and the timer fired back to back.
        var clockReads = 0;
        DateTime countingClock() {
          clockReads++;
          return DateTime.now();
        }

        final room = FakeRoom();
        room.join('alice', 'Alice', adBreakEvery: 1, showsAd: true);
        final bob = room.join(
          'bob',
          'Bob',
          adBreakEvery: 1,
          adBreakSettle: const Duration(milliseconds: 10),
          clock: countingClock,
        );
        addTearDown(room.dispose);
        await flush();
        await turnPages(room, bob, 1);
        expect(bob.service.currentState.readersInAd, ['Alice']);

        clockReads = 0;
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(clockReads, lessThan(50));
        expect(bob.service.currentState.adBreak, isTrue);
      },
    );

    test('a hold that stops being announced expires', () async {
      // The end of Alice's ad was lost: Bob lets go once he stops hearing it.
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice', adBreakEvery: 1, showsAd: true);
      final bob = room.join(
        'bob',
        'Bob',
        adBreakEvery: 1,
        followerLiveness: const Duration(milliseconds: 40),
      );
      addTearDown(room.dispose);
      await flush();
      await turnPages(room, bob, 1);
      expect(bob.service.currentState.readersInAd, ['Alice']);

      room.dropEvents.add(PageSyncService.adBreakEvent);
      alice.service.endAdBreak();
      await flush();
      expect(bob.service.currentState.readersInAd, ['Alice']);

      await Future<void>.delayed(const Duration(milliseconds: 60));
      await flush();
      expect(bob.service.currentState.adBreak, isFalse);
    });

    test('a hold is announced again while the ad is up', () async {
      final room = FakeRoom();
      room.join(
        'alice',
        'Alice',
        adBreakEvery: 1,
        showsAd: true,
        nudgeInterval: const Duration(milliseconds: 20),
      );
      final bob = room.join(
        'bob',
        'Bob',
        adBreakEvery: 1,
        followerLiveness: const Duration(milliseconds: 50),
      );
      addTearDown(room.dispose);
      await flush();
      await turnPages(room, bob, 1);

      await Future<void>.delayed(const Duration(milliseconds: 120));
      await flush();
      expect(bob.service.currentState.readersInAd, ['Alice']);
    });

    test('an ad that never reports back stops holding the room', () async {
      final room = FakeRoom();
      final alice = room.join(
        'alice',
        'Alice',
        adBreakEvery: 1,
        showsAd: true,
        adBreakLimit: const Duration(milliseconds: 40),
      );
      final bob = room.join('bob', 'Bob', adBreakEvery: 1);
      addTearDown(room.dispose);
      await flush();
      await turnPages(room, bob, 1);
      expect(bob.service.currentState.adBreak, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 60));
      await flush();
      expect(alice.service.currentState.adBreak, isFalse);
      expect(bob.service.currentState.adBreak, isFalse);
      // Told, so the reader stops answering for an ad that may still be up,
      // and does not show one later outside any break.
      expect(alice.service.isHoldingForAd, isFalse);
      expect(alice.holdsExpired, 1);
    });

    test('a closed ad is not an expired hold', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice', adBreakEvery: 1, showsAd: true);
      room.join('bob', 'Bob', adBreakEvery: 1);
      addTearDown(room.dispose);
      await flush();
      await turnPages(room, alice, 1);
      expect(alice.service.isHoldingForAd, isTrue);

      alice.service.endAdBreak();
      expect(alice.service.isHoldingForAd, isFalse);
      expect(alice.holdsExpired, 0);
    });

    test('catching up on a page from an announcement starts no break', () async {
      // Regression: a reader back after missing the commit reached the break
      // page late, showed an ad, and covered the page everyone else had been
      // reading since their own break ended.
      final room = FakeRoom();
      final alice = room.join(
        'alice',
        'Alice',
        adBreakEvery: 2,
        positionAnnounceInterval: const Duration(milliseconds: 20),
      );
      final bob = room.join('bob', 'Bob', adBreakEvery: 2, showsAd: true);
      addTearDown(room.dispose);
      await flush();
      await turnPages(room, alice, 1);

      room.dropEvents.add(PageSyncService.commitEvent);
      await turnPages(room, alice, 1);
      expect(alice.service.position.seq, 2);
      expect(bob.service.position.seq, 1);
      room.dropEvents.clear();

      await Future<void>.delayed(const Duration(milliseconds: 60));
      await flush();
      expect(bob.service.position, alice.service.position);
      expect(bob.adBreaks, isEmpty);
      expect(alice.service.currentState.adBreak, isFalse);
    });

    test('leaving the book under an ad releases the room', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice', adBreakEvery: 1, showsAd: true);
      final bob = room.join('bob', 'Bob', adBreakEvery: 1);
      addTearDown(room.dispose);
      await flush();
      await turnPages(room, bob, 1);
      expect(bob.service.currentState.adBreak, isTrue);

      await alice.service.leave();
      room.leave('alice');
      await flush();
      expect(bob.service.currentState.adBreak, isFalse);
      await turnPages(room, bob, 1);
      expect(bob.service.position.seq, 2);
    });

    test('the same page arriving twice is one ad break', () async {
      final room = FakeRoom();
      final alice = room.join('alice', 'Alice', adBreakEvery: 2);
      addTearDown(room.dispose);
      await flush();
      await turnPages(room, alice, 2);
      final page = alice.service.position;

      // A second commit for the same page, from a race between two quorums.
      room.inject(PageSyncService.commitEvent, {
        'request_id': 'other',
        'user_id': 'zed',
        'epoch': page.epoch,
        'seq': page.seq,
        'cfi': '${page.cfi}~',
      });
      await flush();
      expect(alice.service.position.cfi, '${page.cfi}~');
      expect(alice.adBreaks.length, 1);
    });

    test('ad breaks fall on every twentieth shared page', () {
      bool isBreak(int seq) => PageSyncService.isAdBreakPage(
        SharedPosition(epoch: 1, seq: seq, cfi: 'c'),
        every: AdConfig.pageTurnsPerAd,
      );
      expect(AdConfig.pageTurnsPerAd, 20);
      expect(isBreak(0), isFalse);
      expect(isBreak(19), isFalse);
      expect(isBreak(20), isTrue);
      expect(isBreak(21), isFalse);
      expect(isBreak(40), isTrue);
      expect(
        PageSyncService.isAdBreakPage(
          const SharedPosition(seq: 20, cfi: 'c'),
          every: 0,
        ),
        isFalse,
      );
    });
  });

  test('cancel reasons are never shown as protocol codes', () {
    for (final reason in [
      'timeout',
      'out_of_sync',
      'requester_left',
      'superseded',
      'turn_failed',
      'requester_busy',
      'reader_disconnected',
      'ad_break',
      'jump_failed',
      'declined_by_Bob',
      'something_new',
    ]) {
      expect(
        describeCancelReason(reason),
        isNot(contains('_')),
        reason: reason,
      );
    }
    expect(
      describeCancelReason('declined_by_Bob'),
      'Bob asked to wait on this page',
    );
  });
}

Future<void> flush() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class SentEvent {
  final String sender;
  final String event;
  final Map<String, dynamic> payload;

  const SentEvent(this.sender, this.event, this.payload);
}

/// A room of readers wired through one fake Realtime channel: broadcasts reach
/// everyone (sender included, as with `self: true`), and every client sees the
/// same Presence.
class FakeRoom {
  final Map<String, FakeReader> readers = {};
  final Map<String, Map<String, dynamic>> _presence = {};
  final Set<String> _blackedOut = {};
  final Set<String> offline = {};
  final List<SentEvent> sent = [];
  final Set<String> dropEvents = {};
  int turnsExecuted = 0;

  FakeReader join(
    String userId,
    String nickname, {
    bool isReading = true,
    bool readerReady = true,
    bool viewerReady = true,
    bool trackPresence = true,
    bool canTurn = true,
    bool neverRelocates = false,
    String layout = 'phone',
    SharedPosition initialPosition = const SharedPosition.start(),
    Duration requestTimeout = const Duration(minutes: 5),
    Duration nudgeInterval = const Duration(minutes: 5),
    Duration followerLiveness = const Duration(minutes: 5),
    Duration turnTimeout = const Duration(minutes: 5),
    Duration jumpTimeout = const Duration(minutes: 5),
    Duration errorAutoClearDelay = const Duration(hours: 1),
    Duration positionAnnounceInterval = const Duration(minutes: 5),
    Duration reconnectGrace = const Duration(minutes: 1),
    int Function()? mintEpoch,
    int adBreakEvery = 0,
    bool showsAd = false,
    Duration adBreakSettle = Duration.zero,
    Duration adBreakLimit = const Duration(minutes: 5),
    DateTime Function()? clock,
  }) {
    if (trackPresence) {
      _presence[userId] = {
        'protocol': AppConstants.roomProtocolVersion,
        'user_id': userId,
        'nickname': nickname,
        'is_reading': isReading,
        'reader_ready': readerReady,
      };
    }
    final transport = FakeTransport(this, userId);
    final service = PageSyncService(
      transport: transport,
      currentUserId: userId,
      currentNickname: nickname,
      initialPosition: initialPosition,
      requestTimeout: requestTimeout,
      nudgeInterval: nudgeInterval,
      followerLiveness: followerLiveness,
      turnTimeout: turnTimeout,
      jumpTimeout: jumpTimeout,
      errorAutoClearDelay: errorAutoClearDelay,
      mintEpoch: mintEpoch ?? () => 1,
      positionAnnounceInterval: positionAnnounceInterval,
      reconnectGrace: reconnectGrace,
      adBreakEvery: adBreakEvery,
      adBreakSettle: adBreakSettle,
      adBreakLimit: adBreakLimit,
      clock: clock,
    );
    final reader = FakeReader(userId, nickname, service, transport);
    var localPage = 0;
    service.onExecuteTurn = (command) {
      turnsExecuted++;
      if (neverRelocates) return;
      scheduleMicrotask(() {
        if (!canTurn) {
          service.abandonTurn(command.requestId);
          return;
        }
        if (command.direction == PageTurnDirection.jump) {
          // Laid out on the shared page, so it lands on the page picked.
          service.completeTurn(command.requestId, command.targetCfi);
          return;
        }
        localPage += command.direction == PageTurnDirection.next ? 1 : -1;
        // Each device paginates its own way: the CFI it lands on is its own.
        service.completeTurn(command.requestId, 'cfi-$layout-$localPage');
      });
    };
    service.onPositionChanged = reader.displayed.add;
    service.onTurnAbandoned = reader.abandoned.add;
    service.onAdBreak = (position) {
      reader.adBreaks.add(position);
      return showsAd;
    };
    service.onAdHoldExpired = () => reader.holdsExpired++;
    service.setViewerReady(viewerReady && isReading);
    readers[userId] = reader;
    service.initialize();
    if (trackPresence) _emitPresence();
    return reader;
  }

  /// The app version [userId] announces; null is an app from before the
  /// field existed.
  void setProtocol(String userId, int? protocol, {int? oldest}) {
    final meta = _presence[userId]!;
    meta.remove('protocol_min');
    if (protocol == null) {
      meta.remove('protocol');
    } else {
      meta['protocol'] = protocol;
      if (oldest != null) meta['protocol_min'] = oldest;
    }
    _emitPresence();
  }

  void setPresence(String userId, {bool? isReading, bool? readerReady}) {
    final meta = _presence[userId]!;
    if (isReading != null) meta['is_reading'] = isReading;
    if (readerReady != null) meta['reader_ready'] = readerReady;
    _emitPresence();
  }

  /// The device drops off the channel (or comes back): its Presence goes and
  /// nothing reaches it or leaves it.
  void setOnline(String userId, bool online, {bool isReading = true}) {
    if (online) {
      offline.remove(userId);
      _presence[userId] = {
        'protocol': AppConstants.roomProtocolVersion,
        'user_id': userId,
        'nickname': readers[userId]!.nickname,
        'is_reading': isReading,
        'reader_ready': isReading,
      };
    } else {
      offline.add(userId);
      _presence.remove(userId);
    }
    _emitPresence();
  }

  void leave(String userId) {
    _presence.remove(userId);
    _emitPresence();
  }

  /// This client's view of Presence goes empty, as during a reconnect.
  void blackout(String userId) {
    _blackedOut.add(userId);
    readers[userId]!.transport.presence.add({'event': 'sync'});
  }

  List<Map<String, dynamic>> presenceFor(String userId) {
    if (_blackedOut.contains(userId) || offline.contains(userId)) {
      return const [];
    }
    return [for (final meta in _presence.values) Map.of(meta)];
  }

  void deliver(String sender, String event, Map<String, dynamic> payload) {
    sent.add(SentEvent(sender, event, Map.of(payload)));
    if (dropEvents.contains(event) || offline.contains(sender)) return;
    for (final reader in readers.values.toList()) {
      if (offline.contains(reader.userId)) continue;
      final copy = Map<String, dynamic>.from(payload);
      scheduleMicrotask(() => reader.transport.receive(event, copy));
    }
  }

  /// A message from a client that is not modelled here.
  void inject(String event, Map<String, dynamic> payload) {
    for (final reader in readers.values) {
      reader.transport.receive(event, Map.of(payload));
    }
  }

  void _emitPresence() {
    for (final reader in readers.values.toList()) {
      scheduleMicrotask(() {
        if (!reader.transport.presence.isClosed) {
          reader.transport.presence.add({'event': 'sync'});
        }
      });
    }
  }

  Future<void> dispose() async {
    for (final reader in readers.values) {
      await reader.service.dispose();
      await reader.transport.close();
    }
  }
}

class FakeReader {
  final String userId;
  final String nickname;
  final PageSyncService service;
  final FakeTransport transport;
  final List<SharedPosition> displayed = [];
  final List<String> abandoned = [];

  /// Ad breaks this reader reached, whether or not it had an ad to show.
  final List<SharedPosition> adBreaks = [];
  int holdsExpired = 0;

  FakeReader(this.userId, this.nickname, this.service, this.transport);
}

class FakeTransport implements PageSyncTransport {
  final FakeRoom room;
  final String userId;
  final Map<String, StreamController<Map<String, dynamic>>> _controllers = {};
  final presence = StreamController<Map<String, dynamic>>.broadcast();

  FakeTransport(this.room, this.userId);

  @override
  Stream<Map<String, dynamic>> broadcastStream(String event) {
    return (_controllers[event] ??=
            StreamController<Map<String, dynamic>>.broadcast())
        .stream;
  }

  @override
  Stream<Map<String, dynamic>> get presenceStream => presence.stream;

  @override
  List<Map<String, dynamic>> getOnlineUsers() => room.presenceFor(userId);

  @override
  bool get isConnected => !room.offline.contains(userId);

  @override
  Future<void> broadcast({
    required String event,
    required Map<String, dynamic> payload,
  }) async {
    room.deliver(userId, event, payload);
  }

  void receive(String event, Map<String, dynamic> payload) {
    final controller = _controllers[event];
    if (controller != null && !controller.isClosed) controller.add(payload);
  }

  Future<void> close() async {
    await presence.close();
    for (final controller in _controllers.values) {
      await controller.close();
    }
  }
}
