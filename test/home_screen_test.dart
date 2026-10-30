import 'package:cotime_book/config/theme.dart';
import 'package:cotime_book/l10n/l10n.dart';
import 'package:cotime_book/models/layout_report_record.dart';
import 'package:cotime_book/models/recent_room.dart';
import 'package:cotime_book/providers/announcement_provider.dart';
import 'package:cotime_book/providers/app_locale_provider.dart';
import 'package:cotime_book/providers/auth_provider.dart';
import 'package:cotime_book/providers/external_link_provider.dart';
import 'package:cotime_book/providers/layout_report_history_provider.dart';
import 'package:cotime_book/providers/local_store_provider.dart';
import 'package:cotime_book/providers/room_provider.dart';
import 'package:cotime_book/screens/home_screen.dart';
import 'package:cotime_book/services/local_store.dart';
import 'package:cotime_book/services/room_service.dart';
import 'package:cotime_book/widgets/masthead.dart';
import 'package:cotime_book/widgets/recent_rooms_list.dart';
import 'package:cotime_book/widgets/room_code_input.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'announcement_test.dart' show FakeAnnouncements, announcement;
import 'layout_report_history_test.dart' show FakeReportHistory, reportRecord;
import 'room_provider_test.dart' show FakeRoomService, testRoom;

class _SignedInAuth extends AuthNotifier {
  _SignedInAuth(super.store) {
    state = state.copyWith(userId: 'alice');
  }
}

void main() {
  late LocalStore store;
  late FakeRoomService rooms;
  late FakeAnnouncements announcements;
  late FakeReportHistory reportHistory;
  late ProviderContainer container;
  late List<String> visitedLobbies;
  late List<Uri> openedLinks;
  late bool linksOpen;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = LocalStore(await SharedPreferences.getInstance());
    rooms = FakeRoomService();
    announcements = FakeAnnouncements();
    reportHistory = FakeReportHistory();
    visitedLobbies = [];
    openedLinks = [];
    linksOpen = true;
  });

  Future<void> pumpHome(WidgetTester tester) async {
    // Wired like the app, so the device's languages pick the interface's.
    // English unless a test sets tester.platformDispatcher.localesTestValue.
    container = ProviderContainer(
      overrides: [
        localStoreProvider.overrideWithValue(store),
        roomServiceProvider.overrideWithValue(rooms),
        authProvider.overrideWith((ref) => _SignedInAuth(store)),
        announcementServiceProvider.overrideWithValue(announcements),
        layoutReportHistoryServiceProvider.overrideWithValue(reportHistory),
        appVersionProvider.overrideWith((ref) async => '1.0.27+31'),
        externalLinkProvider.overrideWithValue((uri) async {
          openedLinks.add(uri);
          return linksOpen;
        }),
      ],
    );
    addTearDown(container.dispose);
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
        GoRoute(
          path: '/lobby/:roomCode',
          name: 'lobby',
          builder: (_, state) {
            visitedLobbies.add(state.pathParameters['roomCode']!);
            return const Scaffold(body: Text('Lobby'));
          },
        ),
        GoRoute(
          path: '/convert',
          name: 'convert',
          builder: (_, _) => const Scaffold(body: Text('Converter')),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) => MaterialApp.router(
            // The app's own buttons, whose padding decides what fits a row.
            theme: AppTheme.paperTheme,
            routerConfig: router,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: appLocales,
            locale: ref.watch(appLocaleProvider),
            builder: followAppLocale,
          ),
        ),
      ),
    );
  }

  /// Leaves the lobby's room so its heartbeat timer stops before the test ends.
  Future<void> leave(WidgetTester tester) async {
    await container.read(roomProvider.notifier).leaveRoom();
    await tester.pumpWidget(const SizedBox());
  }

  testWidgets('the home screen is titled with the app\'s Chinese name', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await pumpHome(tester);

    // The seal reads out as one word, not two characters.
    expect(find.bySemanticsLabel('頁間'), findsOneWidget);
    expect(find.text('CoTime Book'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('News on the home screen opens the announcements', (
    tester,
  ) async {
    announcements.results.add([
      announcement('v1.0.18', content: 'News on the home screen'),
    ]);
    await pumpHome(tester);
    // Nothing is fetched until it is opened.
    expect(announcements.calls, 0);

    await tester.tap(find.byTooltip('News'));
    await tester.pumpAndSettle();

    expect(announcements.calls, 1);
    expect(find.text('v1.0.18'), findsOneWidget);
    expect(find.text('News on the home screen'), findsOneWidget);
  });

  group('Report History', () {
    testWidgets('is not on Home for a reader who never sent a report', (
      tester,
    ) async {
      await pumpHome(tester);
      await tester.pumpAndSettle();

      expect(reportHistory.calls, 1);
      expect(find.text('Report History'), findsNothing);
      expect(find.textContaining('reports ha'), findsNothing);
    });

    testWidgets('a pending report puts it in the bar, with no news', (
      tester,
    ) async {
      reportHistory.results.add([reportRecord()]);
      await pumpHome(tester);
      await tester.pumpAndSettle();

      expect(find.text('Report History'), findsOneWidget);
      expect(find.textContaining('reports ha'), findsNothing);
    });

    testWidgets('an answer is announced on Home until it has been seen', (
      tester,
    ) async {
      reportHistory.results.add([
        reportRecord(status: LayoutReportStatus.resolved, fixedIn: '1.0.28'),
      ]);
      await pumpHome(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('One of your reports has an answer'));
      await tester.pumpAndSettle();
      expect(
        find.text('Fixed in 1.0.28. Update the app to get the fix.'),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('One of your reports has an answer'), findsNothing);
      expect(find.text('Report History'), findsOneWidget);
    });

    testWidgets('on a small phone the bar with it stays on one line', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      reportHistory.results.add([reportRecord()]);
      await pumpHome(tester);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final line = tester.getCenter(find.text('TXT to EPUB')).dy;
      expect(
        tester.getCenter(find.text('Report History')).dy,
        closeTo(line, 0.5),
      );
      expect(
        tester.getTopRight(find.byTooltip('News')).dx,
        lessThanOrEqualTo(320),
      );
    });
  });

  testWidgets('More Apps opens the Google Play page of 無感記帳', (tester) async {
    await pumpHome(tester);

    await tester.tap(find.text('More Apps'));
    await tester.pumpAndSettle();
    expect(find.text('無感記帳'), findsOneWidget);

    await tester.tap(find.text('Get it on Google Play'));
    await tester.pumpAndSettle();

    expect(openedLinks.single.host, 'play.google.com');
    expect(
      openedLinks.single.queryParameters['id'],
      'com.lazyrhythm.seamless_track',
    );
    expect(find.textContaining('could not be opened'), findsNothing);
  });

  testWidgets(
    'a device that cannot open Google Play is shown the link to copy',
    (tester) async {
      linksOpen = false;
      await pumpHome(tester);

      await tester.tap(find.text('More Apps'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Get it on Google Play'));
      await tester.pumpAndSettle();

      expect(find.textContaining('could not be opened'), findsOneWidget);
      expect(
        find.widgetWithText(SelectableText, openedLinks.single.toString()),
        findsOneWidget,
      );
      // The button still works: a second try is not blocked by the first.
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Get it on Google Play'),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('on a wide screen the bottom bar is one line, News at the end', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpHome(tester);

    final convert = tester.getCenter(find.text('TXT to EPUB'));
    final news = tester.getCenter(find.byTooltip('News'));
    expect(news.dy, convert.dy);
    expect(tester.getTopRight(find.byTooltip('News')).dx, greaterThan(700));
    expect(convert.dx, lessThan(400));
  });

  testWidgets('on a small phone the bottom bar stays on one line', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpHome(tester);

    expect(tester.takeException(), isNull);
    final line = tester.getCenter(find.text('TXT to EPUB')).dy;
    // closeTo: the shrunk buttons sit a rounding error off the line.
    expect(tester.getCenter(find.text('More Apps')).dy, closeTo(line, 0.5));
    expect(tester.getCenter(find.byTooltip('News')).dy, closeTo(line, 0.5));
    expect(
      tester.getTopRight(find.byTooltip('News')).dx,
      lessThanOrEqualTo(320),
    );
  });

  group('the language toggle', () {
    // appStrings is global: later tests in this file read English again.
    tearDown(() => useAppStringsOf(const Locale('en')));

    testWidgets('switches the interface at once, both ways', (tester) async {
      await pumpHome(tester);
      expect(find.text('Create Room'), findsOneWidget);

      await tester.tap(find.text('中文'));
      await tester.pumpAndSettle();
      expect(find.text('建立房間'), findsOneWidget);
      expect(find.text('Create Room'), findsNothing);
      // Messages made outside the widget tree follow it too.
      expect(appStrings.createRoom, '建立房間');

      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();
      expect(find.text('Create Room'), findsOneWidget);
      expect(appStrings.createRoom, 'Create Room');
    });

    testWidgets('is remembered the next time the app opens', (tester) async {
      await pumpHome(tester);
      await tester.tap(find.text('中文'));
      await tester.pumpAndSettle();
      expect(store.appLanguage, 'zh');

      // A new app on the same preferences, on the same English device.
      await tester.pumpWidget(const SizedBox());
      store = LocalStore(await SharedPreferences.getInstance());
      await pumpHome(tester);
      expect(find.text('建立房間'), findsOneWidget);
    });

    testWidgets('sits clear of the masthead in either language', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpHome(tester);

      for (final label in ['中文', 'English']) {
        final toggle = tester.getRect(
          find.ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate((widget) => widget is TextButton),
          ),
        );
        final masthead = tester.getRect(find.byType(Masthead));
        expect(toggle.bottom, lessThanOrEqualTo(masthead.top), reason: label);
        expect(toggle.right, lessThanOrEqualTo(320), reason: label);
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }
    });
  });

  group('on a Chinese device', () {
    setUp(() {
      final dispatcher =
          TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher;
      dispatcher.localesTestValue = const [Locale('zh', 'TW')];
      addTearDown(() {
        dispatcher.clearLocalesTestValue();
        // appStrings is global: later tests in this file read English again.
        useAppStringsOf(const Locale('en'));
      });
    });

    testWidgets('the interface is in Traditional Chinese', (tester) async {
      await pumpHome(tester);

      expect(find.text('建立房間'), findsOneWidget);
      expect(find.text('加入房間'), findsOneWidget);
      expect(find.text('TXT 轉 EPUB'), findsOneWidget);
      expect(find.byTooltip('公告'), findsOneWidget);
      expect(find.text('Create Room'), findsNothing);
      // Text made outside the widget tree (provider state, page sync
      // messages) follows the same language.
      expect(appStrings.createRoom, '建立房間');
    });

    testWidgets('the toggle switches to English', (tester) async {
      await pumpHome(tester);
      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();
      expect(find.text('Create Room'), findsOneWidget);
      expect(store.appLanguage, 'en');
    });

    testWidgets('on a small phone the bottom bar stays on one line', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpHome(tester);

      expect(tester.takeException(), isNull);
      final line = tester.getCenter(find.text('TXT 轉 EPUB')).dy;
      expect(tester.getCenter(find.text('更多 App')).dy, closeTo(line, 0.5));
      expect(tester.getCenter(find.byTooltip('公告')).dy, closeTo(line, 0.5));
      expect(
        tester.getTopRight(find.byTooltip('公告')).dx,
        lessThanOrEqualTo(320),
      );
    });
  });

  testWidgets('the nickname from last time is already filled in', (
    tester,
  ) async {
    await store.saveNickname('Alice');
    await pumpHome(tester);

    expect(find.widgetWithText(TextField, 'Alice'), findsOneWidget);
  });

  testWidgets('the room code field asks for an English keyboard', (
    tester,
  ) async {
    await pumpHome(tester);
    await tester.tap(find.text('Join Room'));
    await tester.pump();

    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byType(RoomCodeInput),
        matching: find.byType(TextField),
      ),
    );
    expect(field.keyboardType, TextInputType.visiblePassword);
    expect(field.autocorrect, isFalse);
  });

  testWidgets('a room you joined shows up under recent rooms', (tester) async {
    rooms.nextRoom = testRoom(
      code: 'ABC234',
    ).copyWith(currentBookTitle: 'Moby-Dick');
    await store.saveNickname('Alice');
    await pumpHome(tester);

    await tester.tap(find.text('Join Room'));
    await tester.pump();
    await tester.enterText(find.byType(RoomCodeInput), 'abc234');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Join Room'));
    await tester.pumpAndSettle();
    await leave(tester);

    final saved = (LocalStore(
      await SharedPreferences.getInstance(),
    )).recentRooms.single;
    expect(saved.code, 'ABC234');
    expect(saved.bookTitle, 'Moby-Dick');
  });

  testWidgets('tapping a recent room goes straight back in', (tester) async {
    rooms.nextRoom = testRoom(code: 'ABC234');
    await store.saveNickname('Alice');
    await store.saveRecentRooms([
      RecentRoom(
        code: 'ABC234',
        bookTitle: 'Moby-Dick',
        lastVisitedAt: DateTime.now(),
      ),
    ]);
    await pumpHome(tester);

    expect(find.text('Moby-Dick · Today'), findsOneWidget);
    await tester.tap(find.text('ABC234'));
    await tester.pumpAndSettle();

    expect(rooms.joinedCodes, ['ABC234']);
    expect(visitedLobbies, ['ABC234']);
    await leave(tester);
  });

  testWidgets('a recent room that is gone says so and leaves the list', (
    tester,
  ) async {
    rooms.joinError = const RoomNotFoundException('ABC234');
    await store.saveNickname('Alice');
    await store.saveRecentRooms([
      RecentRoom(code: 'ABC234', lastVisitedAt: DateTime.now()),
    ]);
    await pumpHome(tester);

    await tester.tap(find.text('ABC234'));
    await tester.pumpAndSettle();

    expect(visitedLobbies, isEmpty);
    expect(rooms.createCalls, 0);
    expect(find.text('Room ABC234 is no longer available.'), findsOneWidget);
    expect(find.byType(RecentRoomsList), findsNothing);
    expect(store.recentRooms, isEmpty);
  });

  testWidgets('rooms deleted while the app was closed are not listed', (
    tester,
  ) async {
    // Closed rooms are deleted 30 days after closing; the server is the only
    // one who knows when that happened.
    rooms.availableCodes = {'BBBBBB'};
    await store.saveRecentRooms([
      RecentRoom(code: 'AAAAAA', lastVisitedAt: DateTime.now()),
      RecentRoom(code: 'BBBBBB', lastVisitedAt: DateTime.now()),
    ]);
    await pumpHome(tester);
    await tester.pump();

    expect(find.text('AAAAAA'), findsNothing);
    expect(find.text('BBBBBB'), findsOneWidget);
    expect(store.recentRooms.map((r) => r.code), ['BBBBBB']);
  });

  testWidgets('being offline does not empty the recent list', (tester) async {
    rooms.availabilityError = StateError('no network');
    await store.saveRecentRooms([
      RecentRoom(code: 'AAAAAA', lastVisitedAt: DateTime.now()),
    ]);
    await pumpHome(tester);
    await tester.pump();

    expect(find.text('AAAAAA'), findsOneWidget);
  });

  testWidgets('a recent room can be forgotten', (tester) async {
    await store.saveRecentRooms([
      RecentRoom(code: 'ABC234', lastVisitedAt: DateTime.now()),
    ]);
    await pumpHome(tester);

    await tester.tap(find.byTooltip('Remove ABC234 from recent rooms'));
    await tester.pump();

    expect(find.byType(RecentRoomsList), findsNothing);
    expect(store.recentRooms, isEmpty);
  });

  testWidgets('TXT to EPUB is a tool of its own on the home screen, '
      'outside any room', (tester) async {
    await pumpHome(tester);

    await tester.tap(find.text('TXT to EPUB'));
    await tester.pumpAndSettle();

    expect(find.text('Converter'), findsOneWidget);
    expect(visitedLobbies, isEmpty);
  });

  testWidgets('TXT to EPUB stays reachable while in a room', (tester) async {
    await pumpHome(tester);
    await container.read(roomProvider.notifier).createRoom('Alice');
    await tester.pump();

    expect(find.text('Continue'), findsOneWidget);
    expect(find.text('TXT to EPUB'), findsOneWidget);
    await leave(tester);
  });

  test('visit dates read as words', () {
    final now = DateTime(2026, 10, 1, 9);
    expect(describeVisit(DateTime(2026, 10, 1, 0, 5), now), 'Today');
    expect(describeVisit(DateTime(2026, 9, 30, 23, 50), now), 'Yesterday');
    expect(describeVisit(DateTime(2026, 9, 27, 12), now), '4 days ago');
    expect(describeVisit(DateTime(2026, 8, 3), now), '2026-08-03');
  });
}
