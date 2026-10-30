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

  // Text in a box taken out of the flow (position: absolute or fixed) is
  // drawn where its containing block puts it, not where it stands in the
  // document, and in columns that block is the whole section. Project
  // Gutenberg marks the printed book's page numbers with `.pagenum {
  // position: absolute; left: 92% }`: every one of a chapter's numbers lands
  // on one page near its end, while each stands in the document between the
  // paragraphs of a page long before (GH-80). Per element, and cleared by
  // layOut() with everything else that hangs on the layout.
  var outOfFlowCache = new WeakMap();

  function outOfFlow(element) {
    var body = element.ownerDocument.body;
    var win = element.ownerDocument.defaultView;
    var walked = [];
    var result = false;
    for (var el = element; el && el.nodeType === 1 && el !== body;
         el = el.parentElement) {
      if (outOfFlowCache.has(el)) {
        result = outOfFlowCache.get(el);
        break;
      }
      walked.push(el);
      var position = win.getComputedStyle(el).position;
      if (position === 'absolute' || position === 'fixed') {
        result = true;
        break;
      }
    }
    for (var i = 0; i < walked.length; i++) outOfFlowCache.set(walked[i], result);
    return result;
  }

  // The first character of the first line that begins on this page. epub.js
  // takes the first character, in document order, that lies in the page's
  // strip; but a line that cannot break (a long URL) runs out of its column
  // into the next page's strip, so the next page was named by a character
  // of the page before. display() places a name by the whole line, which is
  // still on the page before: every reader shown that name went back a page,
  // and turning from there committed the same name again, so the room could
  // not get past the page (GH-52). Characters of a line that began on an
  // earlier page never name this one. Null when no line begins here.
  //
  // Only text in the flow counts (outOfFlow()). The walk stops at the first
  // text past the page, which holds only for text drawn in document order:
  // a Gutenberg page number standing before the page and drawn chapters
  // later stopped it before it got to the page, and epub.js then named the
  // page by that number. Every page after it got the same name, so a turn
  // never landed and a follower shown it went to the page with the numbers
  // on it (GH-80).
  function firstLineStart(mapping, root, start, end) {
    var doc = root.ownerDocument;
    var walker = doc.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    var range = doc.createRange();
    var node;
    while ((node = walker.nextNode())) {
      if (!/\S/.test(node.data)) continue;
      if (node.parentElement && outOfFlow(node.parentElement)) continue;
      range.selectNodeContents(node);
      var bounds = range.getBoundingClientRect();
      if (bounds.width === 0 && bounds.height === 0) continue;
      // Text after the page: nothing later in the flow is on it either.
      if (bounds.left >= end) break;
      if (bounds.right <= start) continue;
      var lines = range.getClientRects();
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i];
        if (line.width === 0 || !startsOnPage(line, start, end)) continue;
        var characters = mapping.splitTextNodeIntoRanges(node);
        for (var j = 0; j < characters.length; j++) {
          var box = characters[j].getBoundingClientRect();
          if (box.width > 0 && startsOnPage(box, start, end) &&
              box.top < line.bottom && box.bottom > line.top) {
            return characters[j];
          }
        }
      }
    }
    return null;
  }

  // How findStart() named the last page it was asked about — `by` 'line',
  // 'picture', or 'epub.js' for epub.js's own guess — what it named it by,
  // and where that is drawn. For the diagnostics. The place is read here:
  // epub.js collapses the range to its start right after, and a collapsed
  // range at the start of a line reports the end of the line before, which
  // can be on the page before.
  var lastNaming = null;

  function noteNaming(by, range) {
    lastNaming = { by: by, node: null, left: null };
    if (!range || typeof range.getBoundingClientRect !== 'function') return;
    lastNaming.node = range.cotimePicture || range.startContainer;
    lastNaming.left = range.getBoundingClientRect().left;
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
      if (!horizontalLtr(this)) {
        lastNaming = null;
        return findStart.call(this, root, start, end);
      }
      var line = firstLineStart(this, root, start, end);
      if (line) {
        noteNaming('line', line);
        return line;
      }
      var picture = firstPictureOnPage(root, start, end);
      if (picture) {
        var named = root.ownerDocument.createRange();
        named.selectNode(picture);
        named.cotimePicture = picture;
        noteNaming('picture', named);
        return named;
      }
      // Nothing begins on this page: it holds at most the end of a line that
      // ran over from the page before, which epub.js would name it by. Such
      // a page counts as blank (showsSomething), so a turn never stops on it
      // and that name is never committed.
      var guessed = findStart.call(this, root, start, end);
      noteNaming('epub.js', guessed);
      return guessed;
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
      // Not what makes a page worth stopping on: a page that holds nothing
      // else has nothing to be named by but epub.js's guess (GH-80).
      if (node.parentElement && outOfFlow(node.parentElement)) continue;
      range.selectNodeContents(node);
      var bounds = range.getBoundingClientRect();
      if (bounds.right <= start || bounds.left >= end) continue;
      // A paragraph across pages has a box on each; only its lines count,
      // and only those that begin here: the end of a line too long for the
      // page before is that page's text (GH-52).
      var lines = range.getClientRects();
      for (var j = 0; j < lines.length; j++) {
        if (onPage(lines[j]) && lines[j].left >= start - 1) return true;
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

  // Which of a section's [count] pages show something, by the same test as
  // showsSomething(), in one pass over the section instead of one per page:
  // a long chapter has thousands of text nodes, and an e-ink reader feels
  // every pass.
  function pagesShown(doc, count, delta, width) {
    var shown = [];
    for (var p = 0; p < count; p++) shown.push(false);
    function mark(rect, lineStartsHere) {
      if (rect.width <= 0 || rect.height <= 0) return;
      var first = Math.max(0, Math.floor(rect.left / delta) - 1);
      var last = Math.min(count - 1, Math.floor(rect.right / delta) + 1);
      for (var i = first; i <= last; i++) {
        var start = i * delta;
        var end = start + width;
        if (rect.right > start + 1 && rect.left < end - 1 &&
            (!lineStartsHere || rect.left >= start - 1)) {
          shown[i] = true;
        }
      }
    }
    var pictures = doc.body.querySelectorAll(PICTURES);
    for (var i = 0; i < pictures.length; i++) {
      mark(pictures[i].getBoundingClientRect(), false);
    }
    var walker = doc.createTreeWalker(doc.body, NodeFilter.SHOW_TEXT);
    var range = doc.createRange();
    var node;
    while ((node = walker.nextNode())) {
      if (!/\S/.test(node.data)) continue;
      if (node.parentElement && outOfFlow(node.parentElement)) continue;
      range.selectNodeContents(node);
      var lines = range.getClientRects();
      for (var j = 0; j < lines.length; j++) mark(lines[j], true);
    }
    return shown;
  }

  // The last section counted by pageInfo(), and on what layout.
  var countedKey = null;
  var counted = null;

  // "section:page/pages" for each view in sight, for the diagnostics.
  function pageNumber(manager) {
    var delta = manager.layout && manager.layout.delta;
    if (!delta) return '';
    return pagesInView(manager).map(function (page) {
      return page.view.section.index + ':' + Math.round(page.start / delta) +
        '/' + Math.round(page.view.width() / delta);
    }).join(' ');
  }

  // The last turn this viewer made: where from, where to and how many pages
  // it moved. A turn that moves more than one page is the blank-page skip
  // above at work, or a sign that it took a page with text for a blank one.
  var lastTurn = null;

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
    var turn = { from: pageNumber(manager), moved: 0, backedOff: false };
    lastTurn = turn;
    if (!(await movePage(manager, forward))) return;
    var moved = 1;
    while (moved < 20 && pageIsBlank(manager)) {
      if (!(await movePage(manager, forward))) break;
      moved++;
    }
    turn.moved = moved;
    if (pageIsBlank(manager)) {
      // Nothing but blank pages to the end of the book: stay where we were,
      // so the turn reads as the end of the book rather than a white page.
      turn.backedOff = true;
      for (; moved > 0; moved--) await movePage(manager, back);
    }
    turn.to = pageNumber(manager);
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

  // Draws every CSS pixel [scale] times as large, on a layout viewport of
  // the screen divided by the scale: exactly what is in view, so nothing can
  // be panned to. The width has to be spelled out. Android's WebView runs
  // with useWideViewport, and a viewport tag with a scale but no width then
  // gets a 980px "desktop" layout viewport instead (GH-48), which is not what
  // anything here was measured against.
  async function setPageScale(scale, screenWidth) {
    var tag = viewportTag();
    var content = scale > 1
      ? 'width=' + Math.floor(screenWidth / scale) +
        ', initial-scale=' + scale + ', minimum-scale=' + scale +
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
      var screenWidth = page.screenWidth || window.innerWidth;
      await setPageScale(scale, screenWidth);
      var area = visibleArea();
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

  function differs(a, b) {
    return Math.abs(a - b) > 1;
  }

  // Where the book is not laid out on the page it is shown in. epub.js
  // keeps its own record of the stage size and skips a resize to a size it
  // believes it already has, so a view laid out on another box can stay that
  // way: the frame then cuts off the last lines of every page, and a turn
  // moves past text nobody saw (GH-49). Each entry names what disagrees.
  function layoutProblems(page) {
    var problems = [];
    var manager = rendition && rendition.manager;
    if (!page || !manager || !manager.container) return problems;
    var container = manager.container;
    if (differs(container.clientWidth, page.width) ||
        differs(container.clientHeight, page.height)) {
      problems.push('container ' + container.clientWidth + 'x' +
        container.clientHeight);
    }
    var layout = manager.layout;
    if (layout && (differs(layout.width, page.width) ||
        differs(layout.height, page.height))) {
      problems.push('layout ' + layout.width + 'x' + layout.height);
    }
    // Fixed-layout and vertical books size their frames by other rules.
    if (!layout || layout.name !== 'reflowable' || !manager.mapping ||
        !horizontalLtr(manager.mapping)) {
      return problems;
    }
    manager.views.displayed().forEach(function (view) {
      var name = 'section ' + view.section.index;
      if (view.iframe && differs(view.iframe.offsetHeight, page.height)) {
        problems.push(name + ' frame ' + view.iframe.offsetHeight + ' high');
      }
      var doc = view.document;
      if (doc && doc.body) {
        var height = doc.body.getBoundingClientRect().height;
        if (differs(height, page.height)) {
          problems.push(name + ' columns ' + Math.round(height) + ' high');
        }
      }
    });
    return problems;
  }

  // Whether the page runs off what the WebView shows. Not something a new
  // layout can fix (the page is the room's), so only reported.
  function fitProblems() {
    var viewer = document.getElementById('viewer');
    if (!viewer) return [];
    var box = viewer.getBoundingClientRect();
    var vv = window.visualViewport;
    var left = vv ? vv.offsetLeft : 0;
    var top = vv ? vv.offsetTop : 0;
    var area = visibleArea();
    var problems = [];
    if (box.left < left - 1 || box.right > left + area.width + 1) {
      problems.push('page ' + Math.round(box.left) + '..' +
        Math.round(box.right) + ' wide, screen ' + Math.round(area.width));
    }
    if (box.top < top - 1 || box.bottom > top + area.height + 1) {
      problems.push('page ' + Math.round(box.top) + '..' +
        Math.round(box.bottom) + ' high, screen ' + Math.round(area.height));
    }
    return problems;
  }

  // Lays the book out on [page] even when epub.js thinks it already is.
  async function layOut(page) {
    // Every page break may move: a new text size, a new frame, a repair.
    countedKey = null;
    outOfFlowCache = new WeakMap();
    var manager = rendition.manager;
    if (manager) manager._stageSize = undefined;
    // Numbers, not "100vw": a window resize (keyboard, rotation) must not
    // put the book back on this screen's own box.
    rendition.resize(page.width, page.height);
    await displayQueued();
    await fontsReady();
    await nextFrame();
  }

  // The resize above clears the views and queues a display() of the page
  // the book was on. A display() called before that one is done cuts it
  // short — epub.js resolves the display in flight to start the next — and
  // the next one then measures where its target is on a view still being
  // laid out: the reader landed pages before the room's page (GH-65). Each
  // no-op below runs once everything queued before it is done. The second
  // runs after the location report the display queues when it ends — that
  // task only asks for a frame, and rendition.location changes in that
  // frame, so layOut()'s nextFrame() after this is what waits for it.
  // Bounded, so a section that never loads cannot hold apply() forever, but
  // well past the reader's own 8 s for a display: an e-reader can take
  // seconds to lay out a long chapter, and giving up early brings GH-65
  // back.
  function displayQueued() {
    var queue = rendition.q;
    if (!queue || typeof queue.enqueue !== 'function') return Promise.resolve();
    var drained = queue.enqueue(function () {}).then(function () {
      return queue.enqueue(function () {});
    });
    return Promise.race([
      drained,
      new Promise(function (resolve) { setTimeout(resolve, 20000); }),
    ]);
  }

  function round(value) {
    return typeof value === 'number' ? Math.round(value * 10) / 10 : value;
  }

  function boxOf(element) {
    if (!element) return null;
    var r = element.getBoundingClientRect();
    return [round(r.left), round(r.top), round(r.width), round(r.height)];
  }

  // "span.ralign > span.pagenum > a#Page_ii": where a name or a box is in the
  // book, without any of its text.
  function elementPath(element, depth, withIds) {
    var parts = [];
    var body = element.ownerDocument.body;
    for (var el = element; el && el.nodeType === 1 && el !== body &&
         parts.length < depth; el = el.parentElement) {
      var part = el.localName;
      if (withIds && el.id) part += '#' + el.id;
      for (var i = 0; i < el.classList.length && i < 3; i++) {
        part += '.' + el.classList[i];
      }
      parts.unshift(part.slice(0, 60));
    }
    return parts.join(' > ');
  }

  function pageOf(left, delta) {
    return Math.floor((left + 1) / delta);
  }

  // How the pages around the one in view are named: the name a turn onto
  // each would commit, how findStart() came by it, what it was named by,
  // and which page that is drawn on. Two pages with one name, a name drawn
  // on another page, or a page epub.js had to guess for is what kept a room
  // from turning (GH-52, GH-80), and none of it needs the book's text.
  function pageNames(manager) {
    var layout = manager.layout;
    var inView = pagesInView(manager)[0];
    if (!layout || !layout.delta || !inView || !inView.view.contents) return [];
    var delta = layout.delta;
    var here = Math.round(inView.start / delta);
    var count = Math.max(1, Math.round(inView.view.width() / delta));
    var names = [];
    for (var i = Math.max(0, here - 2); i <= Math.min(count - 1, here + 2); i++) {
      lastNaming = null;
      var start = i * delta;
      var range = manager.mapping.page(inView.view.contents,
        inView.view.section.cfiBase, start, start + layout.width);
      var entry = {
        page: i,
        cfi: range && range.start ? range.start : null,
        by: lastNaming ? lastNaming.by : null,
      };
      var node = lastNaming && lastNaming.node;
      var element = node && (node.nodeType === 1 ? node : node.parentElement);
      if (element) {
        entry.element = elementPath(element, 4, true);
        entry.outOfFlow = outOfFlow(element);
        entry.drawnOn = pageOf(lastNaming.left, delta);
      }
      names.push(entry);
    }
    lastNaming = null;
    return names;
  }

  // The boxes out of the flow in the section in view (see outOfFlow()), by
  // kind: how many and which pages they are drawn on. Gutenberg's page
  // numbers show up as one kind, all on one page.
  function outOfFlowBoxes(manager) {
    var layout = manager.layout;
    var inView = pagesInView(manager)[0];
    var doc = inView && inView.view.document;
    if (!layout || !layout.delta || !doc || !doc.body) return [];
    var win = doc.defaultView;
    var kinds = [];
    var byKind = {};
    var all = doc.body.querySelectorAll('*');
    for (var i = 0; i < all.length; i++) {
      var el = all[i];
      var position = win.getComputedStyle(el).position;
      if (position !== 'absolute' && position !== 'fixed') continue;
      // Counted once, as the outermost box taken out.
      if (el.parentElement && outOfFlow(el.parentElement)) continue;
      var box = elementPath(el, 1, false);
      var key = box + ' ' + position;
      var kind = byKind[key];
      if (!kind) {
        if (kinds.length >= 5) continue;
        kind = byKind[key] = { box: box, position: position, count: 0, pages: [] };
        kinds.push(kind);
      }
      kind.count++;
      var rect = el.getBoundingClientRect();
      var drawnOn = rect.width > 0 || rect.height > 0
        ? pageOf(rect.left, layout.delta)
        : null;
      if (kind.pages.indexOf(drawnOn) < 0 && kind.pages.length < 5) {
        kind.pages.push(drawnOn);
      }
    }
    return kinds;
  }

  // Diagnostics that must never cost the report the rest of it.
  function attempt(read, fallback) {
    try {
      return read();
    } catch (e) {
      return fallback;
    }
  }

  // The last few script errors in this WebView, for the diagnostics.
  var errors = [];
  function remember(message) {
    errors.push(String(message).slice(0, 200));
    if (errors.length > 5) errors.shift();
  }
  window.addEventListener('error', function (e) {
    remember(e.message || e);
  });
  window.addEventListener('unhandledrejection', function (e) {
    remember('unhandled: ' + (e.reason && e.reason.message || e.reason));
  });

  function bookHasLocations() {
    return typeof book !== 'undefined' && book && book.locations &&
      book.locations.length() > 0;
  }

  var appliedPage = null;
  var applies = 0;
  var repairs = 0;
  var lastRepair = null;
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

      await layOut(page);
      applies++;
      appliedPage = {
        width: page.width, height: page.height, fontSize: page.fontSize,
        left: page.left, top: page.top, scale: page.scale,
        screenWidth: page.screenWidth,
      };
      var problems = layoutProblems(appliedPage);
      if (problems.length > 0) {
        repairs++;
        lastRepair = problems;
        await layOut(appliedPage);
      }
      return true;
    },

    // What layoutProblems() finds now on the last applied page; empty when
    // the book is laid out on it. The app re-applies the page when not.
    verify: function () {
      if (typeof rendition === 'undefined' || !rendition) return [];
      return layoutProblems(appliedPage);
    },

    // Where the page in view is: its number in its chapter and the chapter's
    // page count, both without the blank pages that turns skip (issue #22),
    // and how far into the book it is (null until epub.js has worked out
    // the book's locations). The page is shared, so every reader in the room
    // gets the same numbers.
    pageInfo: function () {
      var manager = typeof rendition !== 'undefined' && rendition &&
        rendition.manager;
      var layout = manager && manager.layout;
      if (!layout || !layout.delta) return null;
      var inView = pagesInView(manager)[0];
      var doc = inView && inView.view.document;
      if (!doc || !doc.body) return null;
      if (!doc.cotimeRecountsOnLoad) {
        // A picture that finishes loading reflows the section and can move
        // its page breaks without changing how many there are.
        doc.addEventListener('load', function () { countedKey = null; }, true);
        doc.cotimeRecountsOnLoad = true;
      }
      var delta = layout.delta;
      var count = Math.max(1, Math.round(inView.view.width() / delta));
      // The counts change with the layout. layOut() and a picture loading
      // drop them; the key also catches a section that reflowed otherwise
      // into a different number of pages.
      var key = [inView.view.section.index, applies,
        appliedPage && appliedPage.fontSize, delta, layout.width, count]
        .join(':');
      if (key !== countedKey) {
        counted = pagesShown(doc, count, delta, layout.width);
        countedKey = key;
      }
      var here = Math.round(inView.start / delta);
      var page = 0;
      var pages = 0;
      for (var i = 0; i < counted.length; i++) {
        if (!counted[i]) continue;
        pages++;
        if (i <= here) page = pages;
      }
      var percent = null;
      var location = rendition.location;
      if (bookHasLocations() && location && location.start) {
        percent = book.locations.percentageFromCfi(location.start.cfi);
      }
      return {
        section: inView.view.section.index,
        page: Math.max(page, 1),
        pages: Math.max(pages, 1),
        percent: percent,
      };
    },

    // The name of the [n]th page of the chapter in view, counted the way
    // pageInfo() counts it (blank pages skipped): the page start a turn onto
    // that page would commit, so the jump preview can show it and the room
    // can go to it. Null when there is no such page or the viewer cannot
    // say.
    pageStart: function (n) {
      var info = window.cotimeSharedPage.pageInfo();
      if (!info || !counted || n < 1 || n > info.pages) return null;
      var manager = rendition.manager;
      var layout = manager.layout;
      var inView = pagesInView(manager)[0];
      var index = -1;
      for (var i = 0, seen = 0; i < counted.length; i++) {
        if (counted[i] && ++seen === n) {
          index = i;
          break;
        }
      }
      if (index < 0 || !inView.view.contents) return null;
      var start = index * layout.delta;
      var range = manager.mapping.page(inView.view.contents,
        inView.view.section.cfiBase, start, start + layout.width);
      return range && range.start ? range.start : null;
    },

    // Where [progress] (0 to 1) of the way into the book is, and how far
    // into the book [cfi] is. Both null until epub.js has worked out the
    // book's locations. Locations count characters, not pages, so they are
    // the same on every layout.
    cfiAtProgress: function (progress) {
      if (!bookHasLocations()) return null;
      return book.locations.cfiFromPercentage(
        Math.min(1, Math.max(0, progress))) || null;
    },

    progressAt: function (cfi) {
      if (!bookHasLocations() || !cfi) return null;
      var value = book.locations.percentageFromCfi(cfi);
      return typeof value === 'number' && isFinite(value) ? value : null;
    },

    // Everything that decides what is on screen, for a reader to copy into
    // a bug report from a real device: the regressions in GH-49 showed up
    // only in an Android WebView, never in the Chromium check.
    diagnose: function () {
      var manager = typeof rendition !== 'undefined' && rendition &&
        rendition.manager;
      var vv = window.visualViewport;
      var tag = document.querySelector('meta[name="viewport"]');
      var layout = manager && manager.layout;
      var container = manager && manager.container;
      var location = rendition && rendition.location;
      return {
        userAgent: navigator.userAgent,
        devicePixelRatio: window.devicePixelRatio,
        window: [window.innerWidth, window.innerHeight],
        layoutViewport: [document.documentElement.clientWidth,
          document.documentElement.clientHeight],
        visualViewport: vv ? [round(vv.width), round(vv.height),
          round(vv.scale), round(vv.offsetLeft), round(vv.offsetTop)] : null,
        viewportTag: tag ? tag.content : null,
        page: appliedPage,
        scale: round(window.cotimeSharedPage.scale),
        viewer: boxOf(document.getElementById('viewer')),
        container: container ? [container.clientWidth, container.clientHeight,
          round(container.scrollLeft), container.scrollWidth] : null,
        layout: layout ? [layout.width, layout.height, layout.delta,
          layout.columnWidth, layout.gap] : null,
        views: manager ? manager.views.displayed().map(function (view) {
          var body = view.document && view.document.body;
          return {
            section: view.section.index,
            href: view.section.href,
            frame: boxOf(view.iframe),
            columns: body ? round(body.getBoundingClientRect().height) : null,
          };
        }) : [],
        at: manager ? pageNumber(manager) : '',
        cfi: location && location.start ? location.start.cfi : null,
        problems: layoutProblems(appliedPage),
        fit: fitProblems(),
        applies: applies,
        repairs: repairs,
        lastRepair: lastRepair,
        lastTurn: lastTurn,
        pageNames: manager ? attempt(function () {
          return pageNames(manager);
        }, null) : [],
        outOfFlow: manager ? attempt(function () {
          return outOfFlowBoxes(manager);
        }, null) : [],
        errors: errors,
      };
    }
  };
})();
