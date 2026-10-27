import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../config/theme.dart';
import '../models/page_sync_state.dart';
import '../models/shared_page.dart';
import '../providers/reading_preferences_provider.dart';
import '../services/shared_page_renderer.dart';
import '../widgets/book_contents.dart';
import '../widgets/page_turn_input.dart';
import '../widgets/paper.dart';

/// Reads a book on this device alone, with no room and no one to agree with
/// on a turn: the TXT to EPUB tool's check of what it made.
///
/// The book is laid out the way a room of one would lay it out (the same
/// [SharedPage] rules and `shared_page.js`), so the chapters, the breaks and
/// the blank-page skipping seen here are the ones a room will see.
class BookPreviewScreen extends ConsumerStatefulWidget {
  final File file;
  final String title;

  const BookPreviewScreen({super.key, required this.file, required this.title});

  @override
  ConsumerState<BookPreviewScreen> createState() => _BookPreviewScreenState();
}

class _BookPreviewScreenState extends ConsumerState<BookPreviewScreen> {
  /// Fixed, like the room reader's chrome: anything that resizes the viewer
  /// makes epub.js lay the book out again (issue #13).
  static const _barHeight = 52.0;
  static const _layoutCheckDelay = Duration(milliseconds: 600);
  static const _maxLayoutRepairs = 3;

  final EpubController _epubController = EpubController();
  List<EpubChapter> _chapters = const [];
  bool _chaptersLoaded = false;

  Size? _viewerSize;
  SharedPage? _page;
  SharedPage? _appliedPage;
  Size? _appliedViewerSize;
  bool _layoutInFlight = false;
  bool _layoutOwed = false;
  bool _layoutScheduled = false;
  int _layoutGeneration = 0;
  int _layoutRepairs = 0;
  Timer? _layoutCheckTimer;

  /// Where the reader is, to come back to after a new layout moves every
  /// page break.
  String? _cfi;
  double _progress = 0;

  bool get _ready =>
      _chaptersLoaded && _appliedPage != null && !_layoutInFlight;

  @override
  void dispose() {
    _layoutCheckTimer?.cancel();
    super.dispose();
  }

  void _updatePage(Size viewerSize, ReadingPreferences prefs) {
    _viewerSize = viewerSize;
    _page = SharedPage.fromFit(
      PageFit.of(viewerSize, fontSize: prefs.fontSize),
    );
    if (_page != _appliedPage ||
        viewerSize != _appliedViewerSize ||
        _layoutOwed) {
      _scheduleLayout();
    }
  }

  void _scheduleLayout() {
    if (_layoutScheduled) return;
    _layoutScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _layoutScheduled = false;
      unawaited(_applyLayout());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _applyLayout() async {
    final page = _page;
    final viewerSize = _viewerSize;
    if (!mounted ||
        !_chaptersLoaded ||
        _layoutInFlight ||
        page == null ||
        viewerSize == null ||
        (page == _appliedPage &&
            viewerSize == _appliedViewerSize &&
            !_layoutOwed)) {
      return;
    }
    final generation = ++_layoutGeneration;
    _layoutCheckTimer?.cancel();
    setState(() => _layoutInFlight = true);
    try {
      await SharedPageRenderer.apply(_epubController, page, viewerSize);
    } catch (_) {
      // Reading goes on unchecked; the check below asks again.
    }
    if (!mounted || generation != _layoutGeneration) return;
    setState(() {
      _layoutInFlight = false;
      _appliedPage = page;
      _appliedViewerSize = viewerSize;
      _layoutOwed = false;
    });
    final cfi = _cfi;
    if (cfi != null && cfi.isNotEmpty) _epubController.display(cfi: cfi);
    _checkLayoutSoon();
    // The page or the screen may have changed while this one was applied.
    if (_page != page || _viewerSize != viewerSize) _scheduleLayout();
  }

  /// The room reader's check (GH-49): a view laid out on the wrong box cuts
  /// lines off every page, which here would read as a broken conversion.
  void _checkLayoutSoon() {
    _layoutCheckTimer?.cancel();
    _layoutCheckTimer = Timer(_layoutCheckDelay, () async {
      final generation = _layoutGeneration;
      final problems = await SharedPageRenderer.verify(_epubController);
      if (!mounted ||
          problems == null ||
          generation != _layoutGeneration ||
          _layoutInFlight) {
        return;
      }
      if (problems.isEmpty) {
        _layoutRepairs = 0;
      } else if (_layoutRepairs < _maxLayoutRepairs) {
        _layoutRepairs++;
        _layoutOwed = true;
        _scheduleLayout();
      }
    });
  }

  void _onChaptersLoaded(List<EpubChapter> chapters) {
    if (!mounted) return;
    setState(() {
      _chapters = chapters;
      _chaptersLoaded = true;
    });
    _scheduleLayout();
  }

  void _onRelocated(EpubLocation location) {
    // A layout's own relocations are not where the reader went.
    if (!mounted || _layoutInFlight) return;
    setState(() {
      _cfi = location.startCfi;
      _progress = location.progress;
    });
    _checkLayoutSoon();
  }

  void _turn(PageTurnDirection direction) {
    if (!_ready) return;
    if (direction == PageTurnDirection.next) {
      _epubController.next();
    } else {
      _epubController.prev();
    }
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    final direction = pageTurnDirectionForKey(
      event.logicalKey,
      volumeKeysTurnPages: ref
          .read(readingPreferencesProvider)
          .volumeKeysTurnPages,
    );
    if (direction == null) return KeyEventResult.ignored;
    if (event is KeyDownEvent) _turn(direction);
    return KeyEventResult.handled;
  }

  Future<void> _showContents(ReadingPreferences prefs) async {
    final href = await showPaperSheet<String>(
      context: context,
      builder: (sheetContext) => ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(sheetContext).size.height * 0.75,
        ),
        child: BookContents(
          chapters: _chapters,
          onOpen: (href) => Navigator.of(sheetContext).pop(href),
        ),
      ),
    );
    if (href == null || !mounted || !_ready) return;
    _epubController.display(cfi: href);
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(readingPreferencesProvider);
    final ink = prefs.textColor;
    final buttonStyle = TextButton.styleFrom(
      foregroundColor: ink,
      disabledForegroundColor: ink.withValues(alpha: 0.35),
      minimumSize: const Size(52, _barHeight),
    );
    return Scaffold(
      backgroundColor: prefs.backgroundColor,
      body: SafeArea(
        child: Focus(
          autofocus: true,
          onKeyEvent: (_, event) => _handleKeyEvent(event),
          child: Column(
            children: [
              SizedBox(
                height: _barHeight,
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Close',
                      color: ink,
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: const Icon(Icons.close),
                    ),
                    Expanded(
                      child: Text(
                        widget.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.body.copyWith(
                          color: ink,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    TextButton(
                      style: buttonStyle,
                      onPressed: _chaptersLoaded
                          ? () => _showContents(prefs)
                          : null,
                      child: const Text('Contents'),
                    ),
                  ],
                ),
              ),
              Divider(height: 1.5, thickness: 1.5, color: ink),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    _updatePage(constraints.biggest, prefs);
                    return Stack(
                      children: [
                        AbsorbPointer(
                          child: EpubViewer(
                            epubController: _epubController,
                            epubSource: EpubSource.fromFile(widget.file),
                            displaySettings: prefs.displaySettings,
                            onChaptersLoaded: _onChaptersLoaded,
                            onRelocated: _onRelocated,
                          ),
                        ),
                        if (!_ready)
                          Positioned.fill(
                            child: ColoredBox(
                              color: prefs.backgroundColor,
                              child: Center(
                                child: Text(
                                  'Loading...',
                                  style: AppTheme.body.copyWith(color: ink),
                                ),
                              ),
                            ),
                          )
                        else
                          Positioned.fill(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapUp: (details) => _turn(
                                pageTurnDirectionForTap(
                                  dx: details.localPosition.dx,
                                  width: constraints.maxWidth,
                                ),
                              ),
                              onHorizontalDragEnd: (details) {
                                final velocity = details.primaryVelocity;
                                if (velocity == null) return;
                                if (velocity < -200) {
                                  _turn(PageTurnDirection.next);
                                } else if (velocity > 200) {
                                  _turn(PageTurnDirection.previous);
                                }
                              },
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
              Divider(height: 1.5, thickness: 1.5, color: ink),
              SizedBox(
                height: _barHeight,
                child: Row(
                  children: [
                    TextButton(
                      style: buttonStyle,
                      onPressed: _ready
                          ? () => _turn(PageTurnDirection.previous)
                          : null,
                      child: const Text('Previous'),
                    ),
                    Expanded(
                      child: Text(
                        'Only you see this · ${(_progress * 100).round()}%',
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.caption.copyWith(color: ink),
                      ),
                    ),
                    TextButton(
                      style: buttonStyle,
                      onPressed: _ready
                          ? () => _turn(PageTurnDirection.next)
                          : null,
                      child: const Text('Next'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
