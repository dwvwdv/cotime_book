import 'package:cotime_book/models/shared_page.dart';
import 'package:cotime_book/providers/presence_provider.dart';
import 'package:cotime_book/services/shared_page_renderer.dart';
import 'package:cotime_book/services/shared_page_style.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The two phones from the bug report: a narrow one at a larger text size,
  // and a wider one at the default.
  const narrow = PageFit(width: 360, height: 640, fontSize: 20);
  const wide = PageFit(width: 412, height: 700, fontSize: 18);

  Map<String, dynamic> reader(
    String userId,
    PageFit? fit, {
    bool isReading = true,
  }) => {
    'user_id': userId,
    'nickname': userId,
    'is_reading': isReading,
    'reader_ready': isReading,
    'page_fit': fit?.toWire(),
    'online_at': '2026-10-01T10:00:00Z',
  };

  group('every reader lays the book out on the same page', () {
    test('readers on different screens agree on one page', () {
      final room = [reader('alice', narrow), reader('bob', wide)];

      final alicePage = SharedPage.forRoom(own: narrow, onlineUsers: room);
      final bobPage = SharedPage.forRoom(own: wide, onlineUsers: room);

      expect(alicePage, bobPage);
      // Fits the smaller screen, at the larger text size anyone picked.
      expect(
        alicePage,
        const SharedPage(width: 360, height: 640, fontSize: 20),
      );
    });

    test('the page is the reader\'s own screen until anyone else reads', () {
      final page = SharedPage.forRoom(
        own: wide,
        onlineUsers: [reader('bob', wide)],
      );
      expect(page, SharedPage.fromFit(wide));
    });

    test('someone in the lobby does not shrink the page', () {
      final page = SharedPage.forRoom(
        own: wide,
        onlineUsers: [
          reader('bob', wide),
          reader('carol', narrow, isReading: false),
        ],
      );
      expect(page, SharedPage.fromFit(wide));
    });

    test('a fit that is missing or malformed is left out', () {
      final page = SharedPage.forRoom(
        own: wide,
        onlineUsers: [
          reader('bob', wide),
          {
            ...reader('carol', null),
            'page_fit': {'w': 'tiny', 'h': 10},
          },
          {...reader('dave', null), 'page_fit': 'not a fit'},
          reader('erin', null),
        ],
      );
      expect(page, SharedPage.fromFit(wide));
    });

    test('a half-measured screen cannot squeeze the page to nothing', () {
      final page = SharedPage.forRoom(
        own: wide,
        onlineUsers: [
          {
            ...reader('carol', null),
            'page_fit': {'w': 0, 'h': 3, 'font': 18},
          },
        ],
      );
      expect(page.width, PageFit.minWidth);
      expect(page.height, PageFit.minHeight);
    });

    test('one person reading on two devices gets a page that fits both', () {
      final merged = mergePresenceUsers([
        {...reader('alice', wide), 'online_at': '2026-10-01T10:00:00Z'},
        {...reader('alice', narrow), 'online_at': '2026-10-01T09:00:00Z'},
      ]);

      final page = SharedPage.forRoom(own: wide, onlineUsers: merged);

      expect(page, const SharedPage(width: 360, height: 640, fontSize: 20));
    });
  });

  group('while Presence is reconnecting', () {
    test('the page does not grow because people seem to have left', () {
      final page = SharedPage.resolve(
        own: wide,
        onlineUsers: const [],
        presenceIsCurrent: false,
        previous: SharedPage.fromFit(narrow),
      );
      expect(page, const SharedPage(width: 360, height: 640, fontSize: 20));
    });

    test('this reader\'s own larger text still applies', () {
      final page = SharedPage.resolve(
        own: const PageFit(width: 412, height: 700, fontSize: 26),
        onlineUsers: const [],
        presenceIsCurrent: false,
        previous: SharedPage.fromFit(narrow),
      );
      expect(page, const SharedPage(width: 360, height: 640, fontSize: 26));
    });
  });

  test('a bigger screen shows the shared page centred, not stretched', () {
    final origin = SharedPageRenderer.originFor(
      const SharedPage(width: 360, height: 640, fontSize: 20),
      const Size(412.7, 700),
    );
    expect(origin, const Offset(26, 30));
  });

  group('a bigger screen enlarges the shared page (GH-37)', () {
    const phonePage = SharedPage(width: 360, height: 640, fontSize: 20);

    test('a tablet reading with a phone fills its screen', () {
      final scale = SharedPageRenderer.scaleFor(
        phonePage,
        const Size(800, 1200),
      );
      // Limited by the height: 1196 / 640.
      expect(scale, 1.86);
      expect(phonePage.width * scale, lessThanOrEqualTo(800));
      expect(phonePage.height * scale, lessThanOrEqualTo(1200 - 4));
    });

    test('the screen the page was made for is not enlarged', () {
      expect(SharedPageRenderer.scaleFor(phonePage, const Size(360, 640)), 1);
      expect(SharedPageRenderer.scaleFor(phonePage, const Size(361.5, 641)), 1);
    });

    test('a page is never shrunk', () {
      expect(SharedPageRenderer.scaleFor(phonePage, const Size(300, 500)), 1);
    });

    test('a very large screen stops at the cap', () {
      expect(
        SharedPageRenderer.scaleFor(phonePage, const Size(2560, 2560)),
        SharedPageRenderer.maxScale,
      );
    });
  });

  group('the layout check reads what the viewer reports (GH-49)', () {
    test('a layout on the page it is shown in has nothing wrong', () {
      expect(SharedPageRenderer.layoutProblemsFrom('[]'), isEmpty);
      expect(SharedPageRenderer.layoutProblemsFrom(<Object?>[]), isEmpty);
    });

    test('what disagrees is passed on, from a string or a decoded list', () {
      expect(SharedPageRenderer.layoutProblemsFrom('["container 384x600"]'), [
        'container 384x600',
      ]);
      expect(
        SharedPageRenderer.layoutProblemsFrom(['section 3 columns 689 high']),
        ['section 3 columns 689 high'],
      );
    });

    test('a viewer that could not be asked is not read as a good layout', () {
      // The script not injected yet answers "null": not the same as "fine",
      // and not a reason to lay the book out again either.
      expect(SharedPageRenderer.layoutProblemsFrom('null'), isNull);
      expect(SharedPageRenderer.layoutProblemsFrom(null), isNull);
      expect(SharedPageRenderer.layoutProblemsFrom('not json'), isNull);
      expect(SharedPageRenderer.layoutProblemsFrom('{"a":1}'), isNull);
    });
  });

  group('the book is set in the bundled font on every device', () {
    late Map<String, dynamic> rules;

    setUpAll(() async {
      rules = await SharedPageStyle.load(rootBundle);
    });

    test('every face of the font ships with the app', () {
      final faces = rules['@font-face'] as List;
      expect(
        faces,
        hasLength(
          SharedPageStyle.subsets.length *
              SharedPageStyle.weights.length *
              SharedPageStyle.styles.length,
        ),
      );
      for (final face in faces.cast<Map<String, dynamic>>()) {
        expect(face['src'], startsWith('url(data:font/woff2;base64,'));
        expect(face['font-family'], '"${SharedPageStyle.fontFamily}"');
      }
    });

    test('the device\'s own fonts and line heights cannot take over', () {
      final text = rules['body, body *'] as Map<String, dynamic>;
      expect(
        text['font-family'],
        startsWith('"${SharedPageStyle.fontFamily}"'),
      );
      expect(text['font-family'], endsWith('!important'));
      expect(text['line-height'], '${SharedPageStyle.lineHeight} !important');
      expect(text['hyphens'], 'manual !important');
      // A URL or a code line wider than the page wraps instead of running
      // past its edge, where it was cut off (GH-52).
      expect(text['overflow-wrap'], 'break-word !important');
      expect(
        (rules['pre, pre *'] as Map<String, dynamic>)['white-space'],
        'pre-wrap !important',
      );
    });
  });
}
