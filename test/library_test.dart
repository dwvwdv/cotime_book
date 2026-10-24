import 'dart:convert';
import 'dart:typed_data';

import 'package:cotime_book/config/app_constants.dart';
import 'package:cotime_book/models/book_metadata.dart';
import 'package:cotime_book/models/library_book.dart';
import 'package:cotime_book/providers/book_provider.dart';
import 'package:cotime_book/services/library_service.dart';
import 'package:cotime_book/widgets/library_browser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Map<String, dynamic> row(
  String path, {
  String? title,
  String? originalTitle,
  String? author,
  String? originalAuthor,
  String? language,
  List<Object?>? tags,
  String? cover,
}) => {
  'path': path,
  'title': title,
  'original_title': originalTitle,
  'author': author,
  'original_author': originalAuthor,
  'language': language,
  'tags': tags,
  'cover_path': cover,
};

/// A pCloud public folder page, trimmed to what the app reads.
String folderPage(List<Map<String, Object?>> content) =>
    '''<!doctype html><html><body><table></table>
<script>
  var directLinkData=${const JsonEncoder.withIndent('\t').convert({'code': 'abc', 'dirpath': '/books/', 'content': content})};
</script>
</body></html>''';

class FakeLibrary implements LibraryService {
  final List<Future<List<LibraryBook>> Function()> answers;
  final List<Future<String> Function()> notices;
  int listCalls = 0;
  int noticeCalls = 0;

  FakeLibrary(this.answers, {this.notices = const []});

  @override
  Future<List<LibraryBook>> listBooks() => answers[listCalls++]();

  @override
  Future<Uint8List> download(String path) async => Uint8List(0);

  @override
  String coverUrl(String path) => 'https://library.test/$path';

  @override
  Future<String> readNotice() => notices[noticeCalls++]();
}

void main() {
  group('the library shows', () {
    test('catalogued books by their catalog title, the rest by file name', () {
      final books = libraryBooksFrom(
        const [
          LibraryFile('the_time_machine.epub', sizeBytes: 300 * 1024),
          LibraryFile('classics/hongloumeng.epub', sizeBytes: 2 * 1024 * 1024),
          LibraryFile('Alice in Wonderland.EPUB'),
        ],
        [
          row(
            'classics/hongloumeng.epub',
            title: '紅樓夢',
            originalTitle: 'Dream of the Red Chamber',
            author: '曹雪芹',
            language: 'zh-Hant',
            tags: ['Classics', ' ', null, 'Classics', 'Chinese'],
            cover: 'covers/hongloumeng.jpg',
          ),
          row('Alice in Wonderland.EPUB', title: '  ', author: '', cover: ' '),
          // Catalogued, but the file is not in the folder.
          row('missing.epub', title: 'Missing'),
        ],
      );

      expect(books.map((book) => book.title), [
        'Alice in Wonderland',
        'the time machine',
        '紅樓夢',
      ]);
      // A blank catalog field is no field, not an empty label.
      expect(books.first.author, isNull);
      expect(books.first.coverPath, isNull);
      expect(books.last.coverPath, 'covers/hongloumeng.jpg');
      expect(books.last.author, '曹雪芹');
      expect(books.last.languageName, 'Chinese (Traditional)');
      expect(books.last.fileName, 'hongloumeng.epub');
      expect(books.last.sizeFormatted, '2.0 MB');
      expect(books.last.originalTitle, 'Dream of the Red Chamber');
      // Blank and repeated tags are dropped.
      expect(books.last.tags, ['Classics', 'Chinese']);
      expect(books.first.tags, isEmpty);
      expect(books[1].sizeFormatted, '300 KB');
    });

    test('no book larger than every device accepts', () {
      final books = libraryBooksFrom(const [
        LibraryFile('fits.epub', sizeBytes: AppConstants.maxFileSize),
        LibraryFile('too-big.epub', sizeBytes: AppConstants.maxFileSize + 1),
      ], const []);

      expect(books.map((book) => book.fileName), ['fits.epub']);
    });
  });

  group('searching the library', () {
    const dream = LibraryBook(
      path: 'hongloumeng.epub',
      title: '紅樓夢',
      author: '曹雪芹',
      language: 'zh-Hant',
      tags: ['Classics'],
    );
    const alice = LibraryBook(
      path: 'alice.epub',
      title: '愛麗絲夢遊仙境',
      originalTitle: "Alice's Adventures in Wonderland",
      author: '路易斯·卡羅',
      originalAuthor: 'Lewis Carroll',
      language: 'en',
      tags: ['Children', 'Classics'],
    );
    const machine = LibraryBook(
      path: 'The_Time_Machine.epub',
      language: 'en-GB',
      tags: ['Science Fiction'],
    );
    const books = [dream, alice, machine];

    test('by title, author or file name, in any order and case', () {
      expect(const LibraryFilter(query: '樓夢').apply(books), [dream]);
      // A translated book is found by its own title and author too.
      expect(const LibraryFilter(query: '愛麗絲').apply(books), [alice]);
      expect(const LibraryFilter(query: '卡羅').apply(books), [alice]);
      expect(const LibraryFilter(query: 'carroll').apply(books), [alice]);
      expect(const LibraryFilter(query: 'wonderland LEWIS').apply(books), [
        alice,
      ]);
      expect(const LibraryFilter(query: 'time machine').apply(books), [
        machine,
      ]);
      expect(const LibraryFilter(query: 'hongloumeng').apply(books), [dream]);
      expect(const LibraryFilter(query: 'alice dickens').apply(books), isEmpty);
      expect(const LibraryFilter(query: '   ').apply(books), books);
    });

    test('by tag and language together with the words', () {
      // A book is under every tag it carries.
      expect(const LibraryFilter(tags: {'Classics'}).apply(books), [
        dream,
        alice,
      ]);
      expect(const LibraryFilter(tags: {'Children'}).apply(books), [alice]);
      // Several tags narrow to the books that carry all of them.
      expect(const LibraryFilter(tags: {'Classics', 'Children'}).apply(books), [
        alice,
      ]);
      expect(
        const LibraryFilter(tags: {'Classics', 'Science Fiction'}).apply(books),
        isEmpty,
      );
      expect(const LibraryFilter(language: 'English').apply(books), [
        alice,
        machine,
      ]);
      expect(
        const LibraryFilter(
          query: 'time',
          tags: {'Children'},
          language: 'English',
        ).apply(books),
        isEmpty,
      );
    });

    test('offers each tag and language once, the most used tag first', () {
      expect(libraryTags(books), ['Classics', 'Children', 'Science Fiction']);
      // en and en-GB are one language to a reader.
      expect(libraryLanguages(books), ['Chinese (Traditional)', 'English']);
      expect(libraryTags(const [LibraryBook(path: 'x.epub')]), isEmpty);
    });

    test('badges a book with its language, briefly', () {
      expect(alice.languageBadge, 'En');
      expect(dream.languageBadge, 'Zh');
      expect(
        const LibraryBook(path: 'x.epub', language: 'pt_BR').languageBadge,
        'Pt',
      );
      expect(const LibraryBook(path: 'x.epub').languageBadge, isNull);
    });

    test('names the language tags the catalog is likely to use', () {
      expect(describeLanguage('zh-TW'), 'Chinese (Traditional)');
      expect(describeLanguage('zh_Hant_HK'), 'Chinese (Traditional)');
      expect(describeLanguage('zh-CN'), 'Chinese (Simplified)');
      expect(describeLanguage('zh'), 'Chinese');
      expect(describeLanguage('JA'), 'Japanese');
      expect(describeLanguage('tlh'), 'tlh');
    });
  });

  test('a shared book says where it is in the library', () {
    const metadata = BookMetadata(
      id: 'h',
      title: 'Alice',
      author: 'Unknown',
      fileName: 'Alice.epub',
      fileSizeBytes: 1,
      fileHash: 'h',
      libraryPath: 'Alice.epub',
    );

    expect(BookMetadata.fromJson(metadata.toJson()).libraryPath, 'Alice.epub');
    expect(
      const BookMetadata(
        id: 'h',
        title: 'Mine',
        author: 'Unknown',
        fileName: 'Mine.epub',
        fileSizeBytes: 1,
        fileHash: 'h',
      ).toJson().containsKey('library_path'),
      isFalse,
    );
  });

  test('a library path from the room must be a plain object name', () {
    expect(isPlainLibraryPath('Alice.epub'), isTrue);
    expect(isPlainLibraryPath('classics/Alice.epub'), isTrue);
    expect(isPlainLibraryPath(''), isFalse);
    expect(isPlainLibraryPath('/Alice.epub'), isFalse);
    expect(isPlainLibraryPath('../other-bucket/x.epub'), isFalse);
    expect(isPlainLibraryPath('classics//Alice.epub'), isFalse);
    expect(isPlainLibraryPath(r'..\x.epub'), isFalse);
  });

  group('the library folder', () {
    test('lists the EPUB files on its page, not folders or notes', () {
      final files = parseLibraryListing(
        folderPage([
          {'name': 'pg1342-images-3.epub', 'size': 2048, 'icon': 0},
          {'name': 'Upper.EPUB', 'size': 10, 'icon': 0},
          {'name': 'covers', 'icon': 20},
          {'name': '書籍來源聲明.txt', 'size': 305, 'icon': 4},
        ]),
      );

      expect(files.map((file) => file.path), [
        'pg1342-images-3.epub',
        'Upper.EPUB',
      ]);
      expect(files.first.sizeBytes, 2048);
    });

    test('a page without a listing is an error, not an empty library', () {
      expect(
        () => parseLibraryListing('<html>Service unavailable</html>'),
        throwsFormatException,
      );
    });

    PublicFolderLibraryService service(
      Future<http.Response> Function(http.Request request) handler, {
      List<Map<String, dynamic>> catalog = const [],
    }) => PublicFolderLibraryService(
      baseUrl: 'https://folder.test/books/',
      client: () => MockClient(handler),
      readCatalog: () async => catalog,
    );

    test('joins the files with the catalog', () async {
      final library = service(
        (request) async => http.Response.bytes(
          utf8.encode(
            folderPage([
              {'name': 'pg1342-images-3.epub', 'size': 2048, 'icon': 0},
              {'name': 'new_book.epub', 'size': 1024, 'icon': 0},
            ]),
          ),
          200,
        ),
        catalog: [
          row(
            'pg1342-images-3.epub',
            title: '傲慢與偏見',
            language: 'en',
            tags: ['愛情'],
          ),
        ],
      );

      final books = await library.listBooks();

      expect(books.map((book) => book.title), ['new book', '傲慢與偏見']);
      expect(books.last.languageName, 'English');
      expect(books.last.tags, ['愛情']);
    });

    test('a folder that cannot be read fails the listing', () async {
      final library = service((request) async => http.Response('', 503));

      await expectLater(library.listBooks(), throwsA(anything));
    });

    test('downloads a book and finds a cover inside the folder', () async {
      Uri? requested;
      final library = service((request) async {
        requested = request.url;
        return http.Response.bytes([1, 2, 3], 200);
      });

      expect(await library.download('classics/A Book.epub'), [1, 2, 3]);
      expect(
        requested.toString(),
        'https://folder.test/books/classics/A%20Book.epub',
      );
      expect(
        library.coverUrl('covers/a.jpg'),
        'https://folder.test/books/covers/a.jpg',
      );
      expect(
        library.coverUrl('https://img.test/a.jpg'),
        'https://img.test/a.jpg',
      );
    });

    test('reads the note on where the books come from', () async {
      Uri? requested;
      final library = service((request) async {
        requested = request.url;
        return http.Response.bytes(
          utf8.encode('\uFEFF來源：Project Gutenberg\r\n公有領域\r\n'),
          200,
        );
      });

      expect(await library.readNotice(), '來源：Project Gutenberg\n公有領域');
      expect(
        requested.toString(),
        'https://folder.test/books/'
        '${Uri.encodeComponent(AppConstants.libraryNoticeFile)}',
      );
    });

    test('a missing book is an error, not an empty book', () async {
      final library = service((request) async => http.Response('gone', 404));

      await expectLater(library.download('gone.epub'), throwsA(anything));
    });

    test('stops downloading a book larger than every device accepts', () async {
      final library = PublicFolderLibraryService(
        baseUrl: 'https://folder.test/books/',
        client: () => MockClient.streaming(
          (request, body) async => http.StreamedResponse(
            Stream.fromIterable([
              Uint8List(AppConstants.maxFileSize),
              Uint8List(1),
            ]),
            200,
          ),
        ),
        readCatalog: () async => const [],
      );

      await expectLater(library.download('huge.epub'), throwsA(anything));
    });
  });

  group('the library browser', () {
    /// Opens the browser; the returned getter reads the book it resolved with.
    Future<LibraryBook? Function()> openBrowser(
      WidgetTester tester,
      LibraryService library,
    ) async {
      LibraryBook? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  picked = await showLibraryBrowser(
                    context: context,
                    library: library,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return () => picked;
    }

    /// A book on the shelf by the title under its cover, not the title set
    /// on a plain jacket.
    Finder shelved(String title) => find.byElementPredicate(
      (element) =>
          element.widget is Text &&
          (element.widget as Text).data == title &&
          element.findAncestorWidgetOfExactType<LibraryCover>() == null,
    );

    Finder choice(String label) => find.descendant(
      of: find.byKey(const Key('library-filters')),
      matching: find.text(label),
    );

    Future<void> openFilters(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Filters'));
      await tester.pump();
    }

    Future<void> tapChoice(WidgetTester tester, String label) async {
      await tester.tap(choice(label));
      await tester.pump();
    }

    const catalog = [
      LibraryBook(
        path: 'hongloumeng.epub',
        title: '紅樓夢',
        author: '曹雪芹',
        language: 'zh-Hant',
        tags: ['Classics'],
      ),
      LibraryBook(
        path: 'alice.epub',
        sizeBytes: 1024,
        title: "Alice's Adventures in Wonderland",
        author: 'Lewis Carroll',
        language: 'en',
        tags: ['Children'],
      ),
      LibraryBook(path: 'The_Time_Machine.epub', language: 'en'),
    ];

    testWidgets('picks the book that is tapped', (tester) async {
      final picked = await openBrowser(
        tester,
        FakeLibrary([() async => catalog]),
      );

      expect(find.text('3 books'), findsOneWidget);
      // Only titles: the shelf is for finding a book, not reading its record.
      expect(find.textContaining('Lewis Carroll'), findsNothing);
      await tester.tap(shelved('The Time Machine'));
      await tester.pumpAndSettle();

      expect(picked()?.path, 'The_Time_Machine.epub');
    });

    testWidgets('shows a cover where the catalog has one', (tester) async {
      await openBrowser(
        tester,
        FakeLibrary([
          () async => const [
            LibraryBook(path: 'alice.epub', coverPath: 'covers/alice.jpg'),
            LibraryBook(path: 'bare.epub'),
          ],
        ]),
      );

      final images = tester.widgetList<Image>(find.byType(Image)).toList();
      expect(images, hasLength(1));
      final provider = images.single.image as ResizeImage;
      expect(
        (provider.imageProvider as NetworkImage).url,
        'https://library.test/covers/alice.jpg',
      );
      // Until a cover loads, and when it cannot (as in tests), the book wears
      // a plain jacket with its title rather than an empty or broken box.
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(LibraryCover),
          matching: find.text('alice'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(LibraryCover),
          matching: find.text('bare'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('finds a book by its name', (tester) async {
      await openBrowser(tester, FakeLibrary([() async => catalog]));

      await tester.enterText(find.byType(TextField), '紅樓');
      await tester.pump();

      expect(shelved('紅樓夢'), findsOneWidget);
      expect(shelved('The Time Machine'), findsNothing);
      expect(find.text('1 of 3 books'), findsOneWidget);
    });

    testWidgets('filters wait behind a button next to the search', (
      tester,
    ) async {
      await openBrowser(tester, FakeLibrary([() async => catalog]));

      expect(find.text('TAGS'), findsNothing);
      expect(choice('English'), findsNothing);

      await openFilters(tester);
      expect(find.text('TAGS'), findsOneWidget);
      expect(find.text('LANGUAGE'), findsOneWidget);

      await openFilters(tester);
      expect(find.text('TAGS'), findsNothing);
    });

    testWidgets('narrows by tag and by language', (tester) async {
      await openBrowser(tester, FakeLibrary([() async => catalog]));
      await openFilters(tester);

      await tapChoice(tester, 'English');
      expect(shelved('紅樓夢'), findsNothing);
      expect(shelved('The Time Machine'), findsOneWidget);
      expect(shelved("Alice's Adventures in Wonderland"), findsOneWidget);

      await tapChoice(tester, 'Children');
      expect(shelved('The Time Machine'), findsNothing);
      expect(shelved("Alice's Adventures in Wonderland"), findsOneWidget);

      // Tapping the chosen tag again lets go of it.
      await tapChoice(tester, 'Children');
      expect(shelved('The Time Machine'), findsOneWidget);

      // Closing the panel keeps the filter, and the list says it is narrowed.
      await openFilters(tester);
      expect(shelved('紅樓夢'), findsNothing);
      expect(find.text('2 of 3 books'), findsOneWidget);
    });

    testWidgets('several tags can be chosen at once', (tester) async {
      await openBrowser(
        tester,
        FakeLibrary([
          () async => const [
            LibraryBook(path: 'a.epub', title: 'Alpha', tags: ['冒險', '科幻']),
            LibraryBook(path: 'b.epub', title: 'Beta', tags: ['冒險']),
            LibraryBook(path: 'c.epub', title: 'Gamma', tags: ['科幻']),
          ],
        ]),
      );
      await openFilters(tester);

      await tapChoice(tester, '冒險');
      await tapChoice(tester, '科幻');
      expect(shelved('Alpha'), findsOneWidget);
      expect(shelved('Beta'), findsNothing);
      expect(shelved('Gamma'), findsNothing);
      expect(find.text('Books with all of them'), findsOneWidget);

      // Tapping a chosen tag again lets go of only that one.
      await tapChoice(tester, '冒險');
      expect(shelved('Alpha'), findsOneWidget);
      expect(shelved('Gamma'), findsOneWidget);
      expect(shelved('Beta'), findsNothing);

      await tapChoice(tester, '冒險');
      await tapChoice(tester, 'All');
      expect(find.text('3 books'), findsOneWidget);
    });

    testWidgets('each cover says what language the book is in', (tester) async {
      await openBrowser(tester, FakeLibrary([() async => catalog]));

      expect(find.text('Zh'), findsOneWidget);
      expect(find.text('En'), findsNWidgets(2));
    });

    testWidgets('the help button shows where the books come from', (
      tester,
    ) async {
      final library = FakeLibrary(
        [() async => catalog],
        notices: [
          () async => throw Exception('offline'),
          () async => '來源：https://www.gutenberg.org',
        ],
      );
      await openBrowser(tester, library);
      expect(library.noticeCalls, 0);

      await tester.tap(find.byTooltip('About these books'));
      await tester.pumpAndSettle();
      expect(find.text('The note could not be loaded.'), findsOneWidget);

      await tester.tap(
        find.descendant(
          of: find.byKey(const Key('library-notice')),
          matching: find.text('Try Again'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('來源：https://www.gutenberg.org'), findsOneWidget);

      // Closed and opened again, it is not fetched again.
      await tester.tap(find.byTooltip('About these books'));
      await tester.pump();
      expect(find.byKey(const Key('library-notice')), findsNothing);
      await tester.tap(find.byTooltip('About these books'));
      await tester.pump();
      expect(find.text('來源：https://www.gutenberg.org'), findsOneWidget);
      expect(library.noticeCalls, 2);
    });

    testWidgets('a search with no result can be cleared in one tap', (
      tester,
    ) async {
      await openBrowser(tester, FakeLibrary([() async => catalog]));

      await openFilters(tester);
      await tapChoice(tester, 'Classics');
      await openFilters(tester);
      await tester.enterText(find.byType(TextField), 'carroll');
      await tester.pump();
      expect(find.text('No books match.'), findsOneWidget);

      await tester.tap(find.text('Clear Search and Filters'));
      await tester.pump();
      expect(find.text('3 books'), findsOneWidget);
      expect(shelved('紅樓夢'), findsOneWidget);
    });

    testWidgets('an uncatalogued library offers no empty filters', (
      tester,
    ) async {
      await openBrowser(
        tester,
        FakeLibrary([
          () async => const [LibraryBook(path: 'Alice.epub')],
        ]),
      );

      expect(shelved('Alice'), findsOneWidget);
      expect(find.byTooltip('Filters'), findsNothing);
    });

    testWidgets('says when the library is empty', (tester) async {
      await openBrowser(tester, FakeLibrary([() async => const []]));

      expect(find.text('The library is empty for now.'), findsOneWidget);
    });

    testWidgets('a library that cannot be reached can be tried again', (
      tester,
    ) async {
      final library = FakeLibrary([
        () async => throw Exception('offline'),
        () async => const [LibraryBook(path: 'Alice.epub')],
      ]);
      await openBrowser(tester, library);

      expect(find.text('The library could not be opened.'), findsOneWidget);
      await tester.tap(find.text('Try Again'));
      await tester.pumpAndSettle();

      expect(shelved('Alice'), findsOneWidget);
      expect(library.listCalls, 2);
    });
  });
}
