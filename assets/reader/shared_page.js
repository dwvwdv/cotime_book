// Lays the book out on the room's shared page instead of on this screen.
//
// epub.js paginates by whatever box and fonts it is given, so two devices
// showing "the same page" used to show different amounts of text, and the
// difference grew with every turn (issue #20). Every reader in a room calls
// cotimeSharedPage.apply() with the same page box and the same stylesheet;
// a bigger screen shows the same page with wider margins.
//
// The page is never scaled with CSS: epub.js finds the first visible
// character from getBoundingClientRect(), which a transform distorts, and a
// skewed page-start CFI would hand the other readers the wrong page.
//
// Injected by ReaderScreen after the viewer has loaded the book. Safe to
// inject twice.
(function () {
  if (window.cotimeSharedPage) return;

  function nextFrame() {
    return new Promise(function (resolve) {
      requestAnimationFrame(function () {
        requestAnimationFrame(resolve);
      });
    });
  }

  function fontsReady() {
    var pending = [];
    rendition.getContents().forEach(function (contents) {
      var doc = contents.document;
      if (doc && doc.fonts) pending.push(doc.fonts.ready);
    });
    return Promise.all(pending);
  }

  // The viewer reports "chapters loaded" when the table of contents is in,
  // which can be before the first section has rendered. Resizing then would
  // clear the views out from under that first display.
  function firstPageShown() {
    if (rendition.location && rendition.location.start) {
      return Promise.resolve();
    }
    return new Promise(function (resolve) {
      var done = false;
      function finish() {
        if (done) return;
        done = true;
        resolve();
      }
      rendition.once('relocated', finish);
      setTimeout(finish, 5000);
    });
  }

  // epub.js names a page by the first visible "word", and finds words by
  // splitting text on spaces. Chinese has no spaces, so a whole paragraph is
  // one word: a page that begins halfway through a paragraph is named by
  // where the paragraph starts — on the page before. The requester turned,
  // but the CFI it handed the room showed everyone else the page they were
  // already on (issue #21). It also gave every page inside one long
  // paragraph the same name, so the reader could not tell a turn from a
  // re-layout. Splitting into characters names each page by its first
  // visible character.
  function installCharacterPageStarts() {
    var manager = rendition.manager;
    if (!manager || !manager.mapping) return false;
    var proto = Object.getPrototypeOf(manager.mapping);
    if (proto.cotimeCharacterRanges) return true;
    proto.splitTextNodeIntoRanges = function (node) {
      var doc = node.ownerDocument;
      var range;
      if (node.nodeType !== Node.TEXT_NODE) {
        range = doc.createRange();
        range.selectNodeContents(node);
        return [range];
      }
      var text = node.textContent || '';
      var ranges = [];
      var offset = 0;
      // By code point, so a range never splits a surrogate pair.
      for (var ch of text) {
        if (!/\s/.test(ch)) {
          range = doc.createRange();
          range.setStart(node, offset);
          range.setEnd(node, offset + ch.length);
          ranges.push(range);
        }
        offset += ch.length;
      }
      if (ranges.length === 0) {
        range = doc.createRange();
        range.selectNodeContents(node);
        ranges.push(range);
      }
      return ranges;
    };
    proto.cotimeCharacterRanges = true;
    return true;
  }

  var stylesInstalled = false;

  window.cotimeSharedPage = {
    // page: {width, height, fontSize, left, top, rules}
    //   width, height, fontSize: the shared page, identical everywhere.
    //   left, top: where this screen centres that box.
    //   rules: epub.js theme rules (fonts and typography), identical
    //   everywhere. Only installed once per viewer.
    apply: async function (page) {
      if (typeof rendition === 'undefined' || !rendition) return false;
      await firstPageShown();
      installCharacterPageStarts();

      var body = document.body;
      body.style.margin = '0';
      body.style.padding = '0';
      body.style.overflow = 'hidden';
      body.style.display = 'block';
      body.style.minHeight = '0';

      var viewer = document.getElementById('viewer');
      viewer.style.position = 'absolute';
      viewer.style.margin = '0';
      // The Flutter side paints the theme colour behind the WebView.
      viewer.style.background = 'transparent';
      viewer.style.left = page.left + 'px';
      viewer.style.top = page.top + 'px';
      viewer.style.width = page.width + 'px';
      viewer.style.height = page.height + 'px';

      if (!stylesInstalled && page.rules) {
        // The "default" theme is the one epub.js injects into every section
        // it renders later, not only the ones on screen now.
        rendition.themes.default(page.rules);
        stylesInstalled = true;
      }

      rendition.themes.fontSize(page.fontSize + 'px');

      // Numbers, not "100vw": a window resize (keyboard, rotation) must not
      // put the book back on this screen's own box.
      rendition.resize(page.width, page.height);

      await fontsReady();
      await nextFrame();
      return true;
    }
  };
})();
