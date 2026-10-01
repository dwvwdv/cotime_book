// Checks that two different devices lay the book out on identical pages once
// they share a page (issue #20). Runs the real epub.js page from
// flutter_epub_viewer in Chromium, with the app's own shared_page.js and
// stylesheet, on two "devices" that differ in screen size, pixel density and
// system fonts, turns through the whole book on both and compares where every
// page starts.
//
//   flutter pub get
//   node tool/shared_page_check/check.js        (from the repo root)
//
// Needs Playwright with a Chromium (NODE_PATH pointing at its node_modules if
// it is installed globally), python3 and fonts-dejavu / fonts-liberation /
// fonts-wqy-zenhei / fonts-ipafont-gothic for the two devices' system fonts.
// Exits non-zero when the pages differ.
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

const rules = JSON.parse(fs.readFileSync(path.join(work, 'rules.json'), 'utf8'));
const book = [...fs.readFileSync(path.join(work, 'book.epub'))];
const script = path.join(root, 'assets/reader/shared_page.js');

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
};
const page = { width: 360, height: 640, fontSize: 22 };

function rulesFor(device) {
  const text = { ...rules['body, body *'] };
  text['font-family'] = text['font-family'].replace(' serif ', ` ${device.cjk} `);
  return { ...rules, 'body, body *': text };
}

async function pageStarts(browser, device, shared, turns) {
  const context = await browser.newContext({
    viewport: device.viewport,
    deviceScaleFactor: device.deviceScaleFactor,
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
        await cotimeSharedPage.apply(p);
        await rendition.display();
      },
      {
        ...page,
        left: Math.floor((device.viewport.width - page.width) / 2),
        top: Math.floor((device.viewport.height - page.height) / 2),
        rules: rulesFor(device),
      },
    );
  }
  const starts = [];
  for (let i = 0; i < turns; i++) {
    await tab.waitForTimeout(60);
    starts.push(await tab.evaluate(() => rendition.location.start.cfi));
    await tab.evaluate(
      () => new Promise((resolve) => {
        rendition.once('relocated', resolve);
        rendition.next();
      }),
    );
  }
  await context.close();
  return starts;
}

(async () => {
  const browser = await chromium.launch();
  const turns = 120;
  let failed = false;
  for (const shared of [false, true]) {
    const a = await pageStarts(browser, devices.phone, shared, turns);
    const b = await pageStarts(browser, devices.tablet, shared, turns);
    const same = a.filter((cfi, i) => cfi === b[i]).length;
    const label = shared ? 'shared page ' : 'own screens ';
    console.log(`${label}: ${same}/${turns} pages start at the same place`);
    if (shared && same !== turns) {
      const i = a.findIndex((cfi, j) => cfi !== b[j]);
      console.log(`  first difference at page ${i}: ${a[i]} vs ${b[i]}`);
      failed = true;
    }
  }
  await browser.close();
  process.exit(failed ? 1 : 0);
})();
