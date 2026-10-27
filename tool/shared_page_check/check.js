// Checks that two different devices lay the book out on identical pages once
// they share a page (issue #20). Runs the real epub.js page from
// flutter_epub_viewer in Chromium, with the app's own shared_page.js and
// stylesheet, on two "devices" that differ in screen size, pixel density and
// system fonts, turns through the whole book on both and compares where every
// page starts. Then it plays the page-turn protocol: the tablet display()s
// each page start the phone reports, as a follower does with a commit, and
// checks it lands on that page rather than the one before (issue #21).
// Pages with nothing on them — where a chapter's empty tail spills onto a
// page of its own — must never be turned to, and a page with only a picture
// on it must be named by that picture (issue #22). The tablet shows the
// phone's page enlarged to fill its screen, by the WebView's page scale
// (GH-37); its pages must still be the phone's. Chromium runs with the
// viewport settings of Android's WebView, where a page scale without a width
// used to put the book on a 980px layout viewport (GH-48). A layout the
// frame no longer matches must be found and laid out again (GH-49). The
// jump preview's "go to page n of this chapter" must name exactly the page
// the counter numbers n, and the preview — a viewer shorter than the page,
// whose bottom lines are under its slider — must name every page as the
// room does.
//
//   flutter pub get
//   node tool/shared_page_check/check.js        (from the repo root)
//
// Needs Playwright with a Chromium (NODE_PATH pointing at its node_modules if
// it is installed globally), python3 and fonts-dejavu / fonts-liberation /
// fonts-wqy-zenhei / fonts-ipafont-gothic for the two devices' system fonts.
// Runs on two books: a mixed English and Chinese EPUB, and one the TXT
// import built. Exits non-zero when the pages differ.
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const root = path.resolve(__dirname, '../..');
const work = path.join(root, 'build/shared_page_check');
fs.mkdirSync(work, { recursive: true });

function viewerPage() {
  const config = JSON.parse(
    fs.readFileSync(path.join(root, '.dart_tool/package_config.json'), 'utf8'),
  );
  const pkg = config.packages.find((p) => p.name === 'flutter_epub_viewer');
  const pkgRoot = new URL(pkg.rootUri, 'file://' + path.join(root, '.dart_tool/')).pathname;
  return path.join(pkgRoot, 'lib/assets/webpage/html/swipe.html');
}

execFileSync('flutter', ['test', 'tool/shared_page_check/dump_rules_test.dart'], {
  cwd: root,
  stdio: 'inherit',
});
execFileSync('python3', [path.join(__dirname, 'make_epub.py'), path.join(work, 'book.epub')]);
// The same check on a book the TXT import made: what a Chinese novel shared
// as TXT turns into.
execFileSync('flutter', ['test', 'tool/shared_page_check/make_txt_book_test.dart'], {
  cwd: root,
  stdio: 'inherit',
});

const rules = JSON.parse(fs.readFileSync(path.join(work, 'rules.json'), 'utf8'));
// `pictures`: the book has a picture-only page, which must be found.
const books = {
  'mixed EPUB': {
    bytes: [...fs.readFileSync(path.join(work, 'book.epub'))], pictures: true, ends: 3,
  },
  'TXT import': {
    bytes: [...fs.readFileSync(path.join(work, 'txt_book.epub'))], pictures: false, ends: 0,
  },
};
let book;
// SHARED_PAGE_SCRIPT runs another copy, e.g. the one before a change.
const script =
  process.env.SHARED_PAGE_SCRIPT || path.join(root, 'assets/reader/shared_page.js');

// `sysFont` is what the device would draw unstyled text in. The app's rules
// fall back to the generic `serif` for CJK; Chromium maps that to the same
// font for both pages here, so each device's CJK fallback is named instead.
const devices = {
  phone: {
    viewport: { width: 360, height: 640 },
    deviceScaleFactor: 3,
    sysFont: '"DejaVu Sans", "WenQuanYi Zen Hei"',
    cjk: '"WenQuanYi Zen Hei"',
    loadFontSize: 18,
  },
  tablet: {
    viewport: { width: 600, height: 900 },
    deviceScaleFactor: 2,
    sysFont: '"Liberation Sans", "IPAGothic"',
    cjk: '"IPAGothic"',
    loadFontSize: 22,
  },
  // The phone's jump preview: the same device, with less height than the
  // page (JumpPreview's header and footer take more than the bottom bar).
  preview: {
    viewport: { width: 360, height: 592 },
    deviceScaleFactor: 3,
    sysFont: '"DejaVu Sans", "WenQuanYi Zen Hei"',
    cjk: '"WenQuanYi Zen Hei"',
    loadFontSize: 18,
  },
};
const page = { width: 360, height: 640, fontSize: 22 };

// SharedPageRenderer.scaleFor.
function scaleFor(viewport) {
  const fit = Math.min((viewport.width - 4) / page.width, (viewport.height - 4) / page.height);
  const scale = Math.floor(Math.min(fit, 3) * 100) / 100;
  return scale > 1 ? scale : 1;
}

function rulesFor(device) {
  const text = { ...rules['body, body *'] };
  text['font-family'] = text['font-family'].replace(' serif ', ` ${device.cjk} `);
  return { ...rules, 'body, body *': text };
}

async function openBook(browser, device, shared, fontSize = page.fontSize) {
  const context = await browser.newContext({
    viewport: device.viewport,
    deviceScaleFactor: device.deviceScaleFactor,
    // Honours the viewport meta tag, as a phone's WebView does.
    isMobile: true,
    hasTouch: true,
  });
  const tab = await context.newPage();
  tab.on('pageerror', (e) => console.error('page error:', e.message));
  await tab.addInitScript(() => {
    window.flutter_inappwebview = { callHandler: () => Promise.resolve() };
  });
  await tab.goto('file://' + viewerPage());
  await tab.evaluate(
    ({ book, sysFont, fontSize }) => {
      // The arguments ReaderScreen's display settings produce.
      loadBook(book, '', null, 'continuous', 'paginated', 'none', false, false,
        'ltr', false, 'null', '#000000', String(fontSize), true, false, null);
      rendition.hooks.content.register((contents) => {
        const style = contents.document.createElement('style');
        style.textContent = `html{font-family:${sysFont}}`;
        contents.document.head.prepend(style);
      });
    },
    { book, sysFont: device.sysFont, fontSize: device.loadFontSize },
  );
  await tab.waitForFunction(() => rendition.location && rendition.location.start);
  if (shared) {
    await tab.addScriptTag({ path: script });
    await tab.evaluate(
      async (p) => {
        window.sharedPage = p;
        await cotimeSharedPage.apply(p);
        await rendition.display();
      },
      {
        ...page,
        fontSize,
        // SharedPageRenderer.originFor.
        left: Math.max(0, Math.floor((device.viewport.width - page.width) / 2)),
        top: Math.max(0, Math.floor((device.viewport.height - page.height) / 2)),
        scale: scaleFor(device.viewport),
        screenWidth: device.viewport.width,
        rules: rulesFor(device),
      },
    );
  }
  return { context, tab };
}

/// How large the page is drawn, and whether all of it is in view.
function pageScale(tab) {
  return tab.evaluate(() => {
    const box = document.getElementById('viewer').getBoundingClientRect();
    const vv = window.visualViewport;
    return {
      scale: vv.scale,
      // The layout viewport: what is in view, never Android's 980px default.
      layoutWidth: document.documentElement.clientWidth,
      viewWidth: vv.width,
      fits: box.left >= vv.offsetLeft && box.top >= vv.offsetTop &&
        box.right <= vv.offsetLeft + vv.width + 0.5 &&
        box.bottom <= vv.offsetTop + vv.height + 0.5,
    };
  });
}

/// What is on the page in view: 'text', 'picture' (and no text) or ''.
/// Measured on screen, independently of how epub.js names the page.
function pageShows() {
  const box = document.getElementById('viewer').getBoundingClientRect();
  const onPage = (frame, r) =>
    r.width > 0 && r.height > 0 &&
    frame.left + r.right > box.left + 1 && frame.left + r.left < box.right - 1 &&
    frame.top + r.bottom > box.top + 1 && frame.top + r.top < box.bottom - 1;
  let shows = '';
  for (const iframe of document.querySelectorAll('#viewer iframe')) {
    const frame = iframe.getBoundingClientRect();
    const doc = iframe.contentDocument;
    if (!doc || !doc.body) continue;
    for (const el of doc.body.querySelectorAll('img, svg, video, canvas')) {
      if (onPage(frame, el.getBoundingClientRect())) shows = 'picture';
    }
    const walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
      const text = node.textContent;
      for (let i = 0; i < text.length; i++) {
        if (/\s/.test(text[i])) continue;
        const range = doc.createRange();
        range.setStart(node, i);
        range.setEnd(node, i + 1);
        for (const r of range.getClientRects()) {
          if (onPage(frame, r)) return 'text';
        }
      }
    }
  }
  return shows;
}

/// The marked last paragraphs of chapters ("end-c0", ...) wholly on the page
/// in view. A chapter squeezed into one clipped page never shows its end
/// (GH-49).
function endsShown() {
  const box = document.getElementById('viewer').getBoundingClientRect();
  const seen = [];
  for (const iframe of document.querySelectorAll('#viewer iframe')) {
    const frame = iframe.getBoundingClientRect();
    const doc = iframe.contentDocument;
    if (!doc) continue;
    for (const el of doc.querySelectorAll('[id^="end-c"]')) {
      const rects = [...el.getClientRects()].filter((r) => r.width > 0 && r.height > 0);
      const inView = rects.length > 0 && rects.every((r) =>
        frame.left + r.left >= box.left - 1 && frame.left + r.right <= box.right + 1 &&
        frame.top + r.top >= box.top - 1 && frame.top + r.bottom <= box.bottom + 1);
      if (inView) seen.push(el.id);
    }
  }
  return seen;
}

/// Turns one page; resolves once the viewer has reported where it is.
/// A turn that cannot move (the end of the book) never reports.
function turn(tab, direction) {
  return tab.evaluate(
    (direction) => new Promise((resolve) => {
      const timer = setTimeout(() => resolve(false), 3000);
      rendition.once('relocated', () => {
        clearTimeout(timer);
        resolve(true);
      });
      direction === 'next' ? rendition.next() : rendition.prev();
    }),
    direction,
  );
}

/// What is wrong with a run of "section:page/pages" page numbers read on
/// every page from the first to the last, or null when nothing is.
function pageNumbersProblem(numbers) {
  let previous = null;
  for (let i = 0; i < numbers.length; i++) {
    const match = /^(\d+):(\d+)\/(\d+)$/.exec(numbers[i]);
    if (!match) return `no page number on page ${i}`;
    const [section, page, pages] = match.slice(1).map(Number);
    if (page < 1 || page > pages) return `page ${i} is ${numbers[i]}`;
    if (previous === null || section !== previous.section) {
      if (page !== 1) return `page ${i} opens a chapter as ${numbers[i]}`;
      if (previous && previous.page !== previous.pages) {
        return `page ${i - 1} leaves its chapter as ${numbers[i - 1]}`;
      }
    } else if (page !== previous.page + 1 || pages !== previous.pages) {
      return `page ${i} follows ${numbers[i - 1]} as ${numbers[i]}`;
    }
    previous = { section, page, pages };
  }
  if (previous && previous.page !== previous.pages) {
    return `the book ends on ${numbers[numbers.length - 1]}`;
  }
  return null;
}

/// Every page from the first to the last and back: where each starts, which
/// show nothing at all, and which only a picture.
async function pageStarts(browser, device, shared, turns) {
  const { context, tab } = await openBook(browser, device, shared);
  const scale = await pageScale(tab);
  const starts = [];
  const blank = [];
  const pictures = [];
  const ends = new Set();
  const back = [];
  const numbers = [];
  const misnamed = [];
  for (const direction of ['next', 'prev']) {
    const seen = direction === 'next' ? starts : back;
    for (let i = 0; i < turns; i++) {
      await tab.waitForTimeout(60);
      const here = await tab.evaluate(() => rendition.location);
      const cfi = here.start.cfi;
      // A turn that did not move: the end of the book (or its start). Only
      // on the shared page are page names distinct (issue #21); on its own
      // screen a reader goes by epub.js's own idea of the end.
      if (shared && seen.length > 0 && cfi === seen[seen.length - 1]) break;
      seen.push(cfi);
      const shows = await tab.evaluate(pageShows);
      if (shows === '') blank.push(`${direction} ${i}`);
      if (shows === 'picture' && direction === 'next') pictures.push(i);
      if (direction === 'next') (await tab.evaluate(endsShown)).forEach((id) => ends.add(id));
      if (shared && direction === 'next') {
        const info = await tab.evaluate(() => cotimeSharedPage.pageInfo());
        numbers.push(info ? `${info.section}:${info.page}/${info.pages}` : 'none');
        // The page a jump to "page n" of this chapter goes to is this one.
        const named = info &&
          (await tab.evaluate((n) => cotimeSharedPage.pageStart(n), info.page));
        if (named !== cfi) misnamed.push(`${i}: ${named} for ${cfi}`);
      }
      if (!shared && (direction === 'next' ? here.atEnd : here.atStart)) break;
      if (!(await turn(tab, direction))) break;
    }
  }
  back.reverse();
  await context.close();
  return { starts, blank, pictures, ends, back, scale, numbers, misnamed };
}

/// Whether a frame that no longer matches the book's layout is noticed and
/// laid out again: the frame shrinks under epub.js, the way a real WebView
/// was seen to leave it, cutting the last lines off every page (GH-49).
async function repairsLayout(browser, device) {
  const { context, tab } = await openBook(browser, device, true);
  const result = await tab.evaluate(async () => {
    const before = cotimeSharedPage.verify();
    const p = window.sharedPage;
    rendition.manager.stage.size(p.width, p.height - 40);
    const broken = cotimeSharedPage.verify();
    await cotimeSharedPage.apply(p);
    return { before, broken, after: cotimeSharedPage.verify() };
  });
  await context.close();
  return result;
}

/// The page counter after the room's text size changes: the chapter's page
/// count has to be worked out again, not kept from the old size. Compared
/// with a reader who opened the book at the new size.
async function recountsOnNewSize(browser, device, turns) {
  const larger = Math.round(page.fontSize * 1.5);
  const { context, tab } = await openBook(browser, device, true);
  // Into the body of the book, past a cover or a title page.
  for (let i = 0; i < turns; i++) await turn(tab, 'next');
  await tab.waitForTimeout(60);
  const before = await tab.evaluate(() => cotimeSharedPage.pageInfo());
  const cfi = await tab.evaluate(() => rendition.location.start.cfi);
  const after = await tab.evaluate(async ({ size, cfi }) => {
    await cotimeSharedPage.apply({ ...window.sharedPage, fontSize: size });
    // epub.js shows the page again by itself after the resize; a display()
    // straight after lands on the wrong page here (GH-65). The
    // app displays the room's page a platform round trip later.
    await new Promise((resolve) => setTimeout(resolve, 800));
    await rendition.display(cfi);
    return cotimeSharedPage.pageInfo();
  }, { size: larger, cfi });
  await context.close();

  const fresh = await openBook(browser, device, true, larger);
  const opened = await fresh.tab.evaluate(async (cfi) => {
    await rendition.display(cfi);
    return cotimeSharedPage.pageInfo();
  }, cfi);
  await fresh.context.close();
  return { before, after, opened };
}

/// How many of [starts] a follower on [device] does not land on.
async function missedCommits(browser, device, starts) {
  const { context, tab } = await openBook(browser, device, true);
  // Let the opening display report before listening for the next one.
  await tab.waitForTimeout(300);
  let missed = 0;
  for (const cfi of new Set(starts)) {
    const landed = await tab.evaluate(
      (cfi) => new Promise((resolve) => {
        rendition.once('relocated', () => {
          setTimeout(() => resolve(rendition.location.start.cfi), 60);
        });
        toCfi(cfi);
      }),
      cfi,
    );
    if (landed !== cfi) {
      if (missed === 0) console.log(`  first miss: ${cfi} showed ${landed}`);
      missed++;
    }
  }
  await context.close();
  return { missed, of: new Set(starts).size };
}

(async () => {
  // Android's WebView: useWideViewport and loadWithOverviewMode are on, as
  // flutter_inappwebview leaves them.
  const browser = await chromium.launch({
    args: ['--blink-settings=wideViewportQuirkEnabled=true,useWideViewport=true,' +
      'loadWithOverviewMode=true'],
  });
  const turns = 400;
  let failed = false;
  for (const [name, { bytes, pictures, ends }] of Object.entries(books)) {
    book = bytes;
    console.log(`${name}:`);
    for (const shared of [false, true]) {
      const phone = await pageStarts(browser, devices.phone, shared, turns);
      const tablet = await pageStarts(browser, devices.tablet, shared, turns);
      const a = phone.starts;
      const b = tablet.starts;
      const pages = Math.max(a.length, b.length);
      const same = a.filter((cfi, i) => cfi === b[i]).length;
      const label = shared ? 'shared page ' : 'own screens ';
      console.log(`${label}: ${same}/${pages} pages start at the same place`);
      if (shared && same !== pages) {
        const i = a.findIndex((cfi, j) => cfi !== b[j]);
        console.log(`  first difference at page ${i}: ${a[i]} vs ${b[i]}`);
        failed = true;
      }
      if (shared) {
        const blank = [...phone.blank, ...tablet.blank];
        console.log(`blank pages : ${blank.length} turned to`);
        if (blank.length > 0) {
          console.log(`  at ${blank.join(', ')}`);
          failed = true;
        }
        // Without one the picture case would pass by not being there.
        console.log(`pictures    : on page ${phone.pictures.join(', ') || 'none'}`);
        if (pictures && phone.pictures.length === 0) failed = true;
        if (ends > 0) {
          // Every chapter's last paragraph is on some page: no chapter was
          // cut short and skipped past.
          console.log(`chapter ends: ${phone.ends.size}/${ends} shown`);
          if (phone.ends.size !== ends) failed = true;
        }
        // The page numbers the reader shows: the same on both screens, and
        // counting each chapter's pages one by one from 1 to its last — a
        // skipped blank page counted, or a page turned to and not counted,
        // would show as a jump or a repeat.
        const sameNumbers = phone.numbers.length === tablet.numbers.length &&
          phone.numbers.every((n, i) => n === tablet.numbers[i]);
        const counting = pageNumbersProblem(phone.numbers);
        console.log(`page numbers: ${sameNumbers ? 'the same on both' : 'different'}, ` +
          `${counting || 'counted one by one'}`);
        if (!sameNumbers || counting) failed = true;
        const misnamed = [...phone.misnamed, ...tablet.misnamed];
        console.log(`jump names  : ${misnamed.length === 0 ? 'every page' :
          `${misnamed.length} pages misnamed, first ${misnamed[0]}`}`);
        if (misnamed.length > 0) failed = true;
        const preview = await pageStarts(browser, devices.preview, true, turns);
        const previewSame = preview.starts.length === a.length &&
          preview.starts.every((cfi, i) => cfi === a[i]);
        console.log(`jump preview: ${preview.starts.filter((cfi, i) => cfi === a[i]).length}` +
          `/${a.length} pages start at the same place`);
        if (!previewSame) failed = true;
        const named = new Set(a).size;
        console.log(`page names  : ${named}/${a.length} distinct`);
        if (named !== a.length) failed = true;
        const backSame = phone.back.length === a.length &&
          phone.back.every((cfi, i) => cfi === a[i]);
        console.log(`backwards   : ${backSame ? 'the same pages' : 'different pages'}`);
        if (!backSame) failed = true;
        const expected = scaleFor(devices.tablet.viewport);
        const enlarged = Math.abs(tablet.scale.scale - expected) < 0.02 &&
          tablet.scale.fits && phone.scale.scale === 1 && phone.scale.fits;
        console.log(`tablet page : drawn x${tablet.scale.scale.toFixed(2)} ` +
          `(expected x${expected}), ${tablet.scale.fits ? 'all in view' : 'cut off'}`);
        if (!enlarged) failed = true;
        const narrow = tablet.scale.layoutWidth <= Math.ceil(tablet.scale.viewWidth) + 1;
        console.log(`tablet view : ${tablet.scale.layoutWidth}px layout viewport, ` +
          `${Math.round(tablet.scale.viewWidth)}px in view`);
        if (!narrow) failed = true;
        const repair = await repairsLayout(browser, devices.phone);
        const repaired = repair.before.length === 0 && repair.broken.length > 0 &&
          repair.after.length === 0;
        console.log(`frame check : ${repair.broken.join(', ') || 'nothing found'} ` +
          `-> ${repair.after.join(', ') || 'laid out again'}`);
        if (!repaired) failed = true;
        const resized = await recountsOnNewSize(browser, devices.phone, 3);
        const numbered = (info) => (info ? `${info.page}/${info.pages}` : 'none');
        const recounted = resized.before && resized.after && resized.opened &&
          resized.after.section === resized.opened.section &&
          resized.after.page === resized.opened.page &&
          resized.after.pages === resized.opened.pages;
        console.log(`text size   : ${numbered(resized.before)} -> ` +
          `${numbered(resized.after)}, opened at that size ${numbered(resized.opened)}`);
        if (!recounted) failed = true;
        const { missed, of } = await missedCommits(browser, devices.tablet, a);
        console.log(`follower    : landed on ${of - missed}/${of} reported pages`);
        if (missed > 0) failed = true;
      }
    }
  }
  await browser.close();
  process.exit(failed ? 1 : 0);
})();
