// Lays the book out on the room's shared page instead of on this screen.
//
// epub.js paginates by whatever box and fonts it is given, so two devices
// showing "the same page" used to show different amounts of text, and the
// difference grew with every turn (issue #20). Every reader in a room calls
// cotimeSharedPage.apply() with the same page box and the same stylesheet;
// a bigger screen shows the same page enlarged to fill it (GH-37).
//
// The page is never scaled with CSS: epub.js finds the first visible
// character from getBoundingClientRect(), which a transform distorts, and a
// skewed page-start CFI would hand the other readers the wrong page. It is
// enlarged by the WebView's own page scale (the viewport meta tag) instead,
// which works like pinch zoom: it changes how big a CSS pixel is drawn, and
// nothing the layout or getBoundingClientRect() measures.
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

  // What a page holds when it holds no text.
  var PICTURES = 'img, svg, video, canvas, object, embed';

  // Only the left-to-right horizontal pages the room shares are handled
  // below; anything else keeps epub.js's own behaviour.
  function horizontalLtr(mapping) {
    return mapping.horizontal && mapping.direction === 'ltr';
  }

  function startsOnPage(rect, start, end) {
    return rect.left >= start - 1 && rect.left < end;
  }

  function firstPictureOnPage(root, start, end) {
    var pictures = root.querySelectorAll(PICTURES);
    for (var i = 0; i < pictures.length; i++) {
      var rect = pictures[i].getBoundingClientRect();
      if (rect.width > 0 && rect.height > 0 && startsOnPage(rect, start, end)) {
        return pictures[i];
      }
    }
    return null;
  }

  // A page with no text on it has no character to be named by, and epub.js
  // then falls back to the last text before it — on an earlier page. A
  // follower shown that name stayed where it was while the requester was
  // looking at the picture (issue #22). Name such a page by its picture: an
  // element CFI, which display() places by the element's own box.
  function installPicturePageStarts() {
    var manager = rendition.manager;
    if (!manager || !manager.mapping || typeof ePub === 'undefined') return;
    var proto = Object.getPrototypeOf(manager.mapping);
    if (proto.cotimePicturePages) return;
    var findStart = proto.findStart;
    var rangePairToCfiPair = proto.rangePairToCfiPair;
    proto.findStart = function (root, start, end) {
      var range = findStart.call(this, root, start, end);
      if (!horizontalLtr(this)) return range;
      if (range && startsOnPage(range.getBoundingClientRect(), start, end)) {
        return range;
      }
      var picture = firstPictureOnPage(root, start, end);
      if (!picture) return range;
      var named = root.ownerDocument.createRange();
      named.selectNode(picture);
      named.cotimePicture = picture;
      return named;
    };
    // A range always becomes a CFI into a text node, which a picture has
    // none of; the element itself is the name.
    proto.rangePairToCfiPair = function (cfiBase, pair) {
      var picture = pair.start && pair.start.cotimePicture;
      var cfis = rangePairToCfiPair.call(this, cfiBase, pair);
      if (picture) cfis.start = new ePub.CFI(picture, cfiBase).toString();
      return cfis;
    };
    proto.cotimePicturePages = true;
  }

  function showsSomething(doc, start, end) {
    function onPage(rect) {
      return rect.width > 0 && rect.height > 0 &&
        rect.right > start + 1 && rect.left < end - 1;
    }
    var pictures = doc.body.querySelectorAll(PICTURES);
    for (var i = 0; i < pictures.length; i++) {
      if (onPage(pictures[i].getBoundingClientRect())) return true;
    }
    var walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
    var range = doc.createRange();
    var node;
    while ((node = walker.nextNode())) {
      if (!/\S/.test(node.data)) continue;
      range.selectNodeContents(node);
      var bounds = range.getBoundingClientRect();
      if (bounds.right <= start || bounds.left >= end) continue;
      // A paragraph across pages has a box on each; only its lines count.
      var lines = range.getClientRects();
      for (var j = 0; j < lines.length; j++) {
        if (onPage(lines[j])) return true;
      }
    }
    return false;
  }

  // The page in view, in each view's own coordinates, as epub.js maps it.
  function pagesInView(manager) {
    var container = manager.container.getBoundingClientRect();
    return manager.visible().map(function (view) {
      var position = view.position();
      var start = container.left - position.left;
      var width = Math.min(position.right - container.left, manager.layout.width);
      return { view: view, start: start, end: start + width };
    });
  }

  function pageIsBlank(manager) {
    var pages = pagesInView(manager);
    if (pages.length === 0) return false;
    return pages.every(function (page) {
      var doc = page.view.document;
      return doc && doc.body && !showsSomething(doc, page.start, page.end);
    });
  }

  function whereInBook(manager) {
    return pagesInView(manager).map(function (page) {
      return page.view.section.index + ':' + Math.round(page.start);
    }).join(' ');
  }

  async function step(manager, move) {
    var result = move.call(manager);
    if (result && typeof result.then === 'function') await result;
  }

  // Loads and shows the sections around the page in view. The manager reads
  // its scroll offset from the scroll event, so that has to arrive first.
  async function settle(manager) {
    await nextFrame();
    await manager.q.enqueue(function () {
      if (typeof manager.check === 'function') return manager.check();
    });
  }

  // One page in the direction of [move]. False when there is no page there.
  async function movePage(manager, move) {
    var before = whereInBook(manager);
    await step(manager, move);
    var after = whereInBook(manager);
    if (after !== '' && after !== before) return true;
    // Moved into a section still loading (nothing in view yet), or stopped
    // at the end of what is loaded so far.
    await settle(manager);
    if (whereInBook(manager) === before) {
      await step(manager, move);
      await settle(manager);
    }
    after = whereInBook(manager);
    return after !== '' && after !== before;
  }

  // Moves one page, then on past any page with nothing on it. Converted
  // books often end a chapter with empty paragraphs or a page break that
  // spill onto a page of their own. Its name is the last text before it, so
  // the requester was shown a white page while everyone else, shown that
  // name, stayed on the page before (issue #22). Nobody needs to stop on
  // such a page, and every reader skips the same ones: the page is shared.
  // Checked before the next frame is drawn, so the white page is never
  // painted unless a section has to load first.
  async function turnPastBlankPages(manager, forward, back) {
    if (!(await movePage(manager, forward))) return;
    var moved = 1;
    while (moved < 20 && pageIsBlank(manager)) {
      if (!(await movePage(manager, forward))) break;
      moved++;
    }
    if (pageIsBlank(manager)) {
      // Nothing but blank pages to the end of the book: stay where we were,
      // so the turn reads as the end of the book rather than a white page.
      for (; moved > 0; moved--) await movePage(manager, back);
    }
  }

  function installBlankPageSkipping() {
    var manager = rendition.manager;
    if (!manager || !manager.q || manager.cotimeSkipsBlankPages) return;
    var next = manager.next;
    var prev = manager.prev;
    manager.next = function () {
      if (!horizontalLtr(this.mapping)) return next.call(this);
      return turnPastBlankPages(this, next, prev);
    };
    manager.prev = function () {
      if (!horizontalLtr(this.mapping)) return prev.call(this);
      return turnPastBlankPages(this, prev, next);
    };
    manager.cotimeSkipsBlankPages = true;
  }

  var viewportMeta = null;
  var unscaledViewport = null;

  function viewportTag() {
    if (viewportMeta) return viewportMeta;
    viewportMeta = document.querySelector('meta[name="viewport"]');
    if (!viewportMeta) {
      viewportMeta = document.createElement('meta');
      viewportMeta.name = 'viewport';
      viewportMeta.content = 'width=device-width, initial-scale=1';
      document.head.appendChild(viewportMeta);
    }
    unscaledViewport = viewportMeta.content;
    return viewportMeta;
  }

  // The area in view, in CSS pixels. Page scale shrinks it.
  function visibleArea() {
    var vv = window.visualViewport;
    if (vv) return { width: vv.width, height: vv.height };
    return { width: window.innerWidth, height: window.innerHeight };
  }

  // A WebView takes a frame or several to apply a new viewport.
  async function viewportChanged(before) {
    for (var i = 0; i < 10; i++) {
      await nextFrame();
      var now = visibleArea();
      if (now.width !== before.width || now.height !== before.height) return;
    }
  }

  // Draws every CSS pixel [scale] times as large. No width: the layout
  // viewport then becomes the screen divided by the scale, exactly what is
  // in view, so nothing can be panned to.
  async function setPageScale(scale) {
    var tag = viewportTag();
    var content = scale > 1
      ? 'initial-scale=' + scale + ', minimum-scale=' + scale +
        ', maximum-scale=' + scale + ', user-scalable=no'
      : unscaledViewport;
    if (tag.content === content) return;
    var before = visibleArea();
    tag.content = content;
    await viewportChanged(before);
  }

  // Enlarges the page to [page.scale] and centres it in what is in view.
  // Where the WebView does not take the scale (or takes it only in part, so
  // the page would not fit), the page stays unscaled where the app centred
  // it: a page that does not fit would cut off its last line or its edge.
  async function placePage(viewer, page) {
    var scale = page.scale > 1 ? page.scale : 1;
    if (scale > 1) {
      await setPageScale(scale);
      var area = visibleArea();
      var screenWidth = page.screenWidth || window.innerWidth;
      var scaled = area.width < screenWidth - 1;
      if (scaled && area.width >= page.width && area.height >= page.height) {
        viewer.style.left = Math.floor((area.width - page.width) / 2) + 'px';
        viewer.style.top = Math.floor((area.height - page.height) / 2) + 'px';
        window.cotimeSharedPage.scale = window.visualViewport
          ? window.visualViewport.scale
          : screenWidth / area.width;
        return;
      }
    }
    await setPageScale(1);
    viewer.style.left = page.left + 'px';
    viewer.style.top = page.top + 'px';
    window.cotimeSharedPage.scale = 1;
  }

  var stylesInstalled = false;

  window.cotimeSharedPage = {
    // The page scale in effect after the last apply().
    scale: 1,

    // page: {width, height, fontSize, left, top, scale, screenWidth, rules}
    //   width, height, fontSize: the shared page, identical everywhere.
    //   left, top: where this screen centres that box unscaled.
    //   scale: how much larger this screen can draw it (1 for none).
    //   screenWidth: this viewer's width unscaled, in CSS pixels.
    //   rules: epub.js theme rules (fonts and typography), identical
    //   everywhere. Only installed once per viewer.
    apply: async function (page) {
      if (typeof rendition === 'undefined' || !rendition) return false;
      await firstPageShown();
      installCharacterPageStarts();
      installPicturePageStarts();
      installBlankPageSkipping();

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
      // Sized before the scale changes: the window resize that follows
      // would otherwise lay the book out once more on the box in between.
      viewer.style.width = page.width + 'px';
      viewer.style.height = page.height + 'px';
      await placePage(viewer, page);

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
