import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_epub_viewer/flutter_epub_viewer.dart';

import '../config/theme.dart';
import '../models/page_info.dart';
import '../models/page_sync_state.dart';
import '../models/shared_page.dart';
import '../services/shared_page_renderer.dart';
import 'book_contents.dart';
import 'page_turn_input.dart';
import 'paper.dart';

/// Where the room should go, as picked in the [JumpPreview].
class JumpTarget {
  /// The page start of the page picked, on the room's shared page.
  final String cfi;

  /// The page as the counter shows it, for the others to read on their bar.
  final PageInfo? label;

  const JumpTarget({required this.cfi, this.label});
}

/// The page number typed into the preview, as a page of a chapter of [pages]
/// pages: clamped into it, so "999" goes to the last page rather than
/// nowhere. Null when nothing usable was typed.
int? parseJumpPage(String text, {required int pages}) {
  final value = int.tryParse(text.trim());
  if (value == null || pages < 1) return null;
  return value.clamp(1, pages);
}

/// Picks a page to take the room to, without moving anyone.
///
/// The book opens on a viewer of its own, laid out on the room's
/// [SharedPage] by the same `shared_page.js`, so its page starts are the
/// ones the room commits: the page seen here is the page everyone lands on.
/// The room's viewer underneath stays where the room is (it must: the room
/// has not agreed to go anywhere yet), and keeps its size, so nobody's
/// page is laid out again (issue #13).
///
/// The slider goes anywhere in the book; the page box goes to a page of the
/// chapter in view, numbered like the reader's page counter. The preview's
/// viewer has less height than the room's, so the bottom lines of a page
/// may be under the slider; the page itself is not cut.
class JumpPreview extends StatefulWidget {
  static const double headerHeight = 56;
  static const double footerHeight = 56;

  final File bookFile;
  final EpubDisplaySettings displaySettings;

  /// The page the room's viewer is laid out on.
  final SharedPage page;

  /// Where the preview opens: the page the room is on.
  final String? initialCfi;

  /// The page start the room's viewer shows now, so going "here" is not
  /// offered.
  final String? currentCfi;

  /// Whether a request can be sent right now (nothing else in flight).
  final bool canConfirm;
  final bool volumeKeysTurnPages;
  final Color ink;
  final Color paper;

  /// Where a share of the book is, and how far a page is into it. Asked of
  /// the room's viewer, whose book has long since worked out its locations;
  /// this viewer's own are still being worked out when it opens.
  final Future<String?> Function(double progress) cfiAtProgress;
  final Future<double?> Function(String cfi) progressAt;

  final VoidCallback onCancel;
  final ValueChanged<JumpTarget> onConfirm;

  const JumpPreview({
    super.key,
    required this.bookFile,
    required this.displaySettings,
    required this.page,
    required this.initialCfi,
    required this.currentCfi,
    required this.canConfirm,
    required this.volumeKeysTurnPages,
    required this.ink,
    required this.paper,
    required this.cfiAtProgress,
    required this.progressAt,
    required this.onCancel,
    required this.onConfirm,
  });

  @override
  State<JumpPreview> createState() => _JumpPreviewState();
}

class _JumpPreviewState extends State<JumpPreview> {
  static const _settleDelay = Duration(milliseconds: 400);
  static const _layoutCheckDelay = Duration(milliseconds: 600);
  static const _maxLayoutRepairs = 3;

  final EpubController _epubController = EpubController();
  final TextEditingController _pageField = TextEditingController();
  final FocusNode _pageFieldFocus = FocusNode();

  /// Takes the page keys from the reader underneath, which has the focus
  /// when the preview opens (so autofocus alone would not move it).
  final FocusNode _focus = FocusNode(debugLabel: 'jump preview');

  List<EpubChapter> _chapters = const [];
  bool _chaptersLoaded = false;

  Size? _viewerSize;
  SharedPage? _appliedPage;
  Size? _appliedViewerSize;
  bool _layoutInFlight = false;
  bool _layoutOwed = false;
  bool _layoutScheduled = false;
  int _layoutGeneration = 0;
  int _layoutRepairs = 0;
  Timer? _layoutCheckTimer;

  /// The page start in view, and what the counter would say about it. The
  /// page can only be picked once [_info] is about [_cfi]: a page still
  /// moving has no name yet.
  String? _cfi;
  PageInfo? _info;
  String? _infoCfi;
  Timer? _settleTimer;

  /// Where the slider is, while dragged and after.
  double _sliderValue = 0;
  bool _dragging = false;

  bool get _ready =>
      _chaptersLoaded && _appliedPage != null && !_layoutInFlight;

  bool get _settled => _ready && _cfi != null && _infoCfi == _cfi;

  bool get _isHere => _cfi != null && _cfi == widget.currentCfi;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(JumpPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The room laid its page out again (a new text size, a new reader):
    // so does the preview, or the page picked here is not the room's.
    if (widget.page != oldWidget.page) _scheduleLayout();
  }

  @override
  void dispose() {
    _layoutCheckTimer?.cancel();
    _settleTimer?.cancel();
    _pageField.dispose();
    _pageFieldFocus.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Layout: the room reader's, on the room's page

  void _updateViewerSize(Size size) {
    _viewerSize = size;
    if (widget.page != _appliedPage ||
        size != _appliedViewerSize ||
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
    final page = widget.page;
    final viewerSize = _viewerSize;
    if (!mounted ||
        !_chaptersLoaded ||
        _layoutInFlight ||
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
      // The check below asks again.
    }
    if (!mounted || generation != _layoutGeneration) return;
    setState(() {
      _layoutInFlight = false;
      _appliedPage = page;
      _appliedViewerSize = viewerSize;
      _layoutOwed = false;
    });
    // Every page break moved: back to the page in view, or where it opened.
    final cfi = _cfi ?? widget.initialCfi;
    if (cfi != null && cfi.isNotEmpty) {
      _display(cfi);
    } else {
      _settleSoon();
    }
    _checkLayoutSoon();
    if (widget.page != page || _viewerSize != viewerSize) _scheduleLayout();
  }

  /// The room reader's check (GH-49): a view laid out on the wrong box names
  /// its pages differently from the room's.
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
    // A layout's own relocations are not where the preview went.
    if (!mounted || _layoutInFlight) return;
    setState(() => _cfi = location.startCfi);
    _settleSoon();
    _checkLayoutSoon();
  }

  /// Reads the counter's numbers once the page has stopped moving.
  void _settleSoon() {
    _settleTimer?.cancel();
    _settleTimer = Timer(_settleDelay, () => unawaited(_readPage()));
  }

  Future<void> _readPage() async {
    final generation = _layoutGeneration;
    if (_cfi == null) {
      // Laid out without a relocation reaching here (a display onto the
      // page already shown): the page is still the one in view.
      final shown = (await SharedPageRenderer.diagnose(
        _epubController,
      ))?['cfi'];
      if (!mounted || generation != _layoutGeneration || _cfi != null) return;
      if (shown is String && shown.isNotEmpty) setState(() => _cfi = shown);
    }
    final cfi = _cfi;
    final info = await SharedPageRenderer.pageInfo(_epubController);
    final progress = cfi == null ? null : await widget.progressAt(cfi);
    if (!mounted || cfi != _cfi || generation != _layoutGeneration) return;
    final label = info == null
        ? null
        : PageInfo(
            page: info.page,
            pages: info.pages,
            progress: progress ?? info.progress,
          );
    setState(() {
      _info = label;
      _infoCfi = cfi;
      if (!_dragging && label?.progress != null) {
        _sliderValue = label!.progress!;
      }
    });
    if (!_pageFieldFocus.hasFocus && label != null) {
      _pageField.text = '${label.page}';
    }
  }

  // ---------------------------------------------------------------------------
  // Moving the preview

  void _display(String cfi) {
    try {
      _epubController.display(cfi: cfi);
    } catch (_) {
      // The viewer went away; nothing to show.
    }
  }

  void _turn(PageTurnDirection direction) {
    if (!_ready) return;
    try {
      if (direction == PageTurnDirection.next) {
        _epubController.next();
      } else if (direction == PageTurnDirection.previous) {
        _epubController.prev();
      }
    } catch (_) {
      // The viewer went away.
    }
  }

  Future<void> _goToProgress(double progress) async {
    if (!_ready) return;
    final cfi =
        await widget.cfiAtProgress(progress) ??
        await SharedPageRenderer.cfiAtProgress(_epubController, progress);
    if (!mounted || cfi == null || cfi.isEmpty) {
      if (mounted) {
        showPaperMessage(
          context,
          'Still working out the length of the book. Try again in a moment.',
        );
      }
      return;
    }
    _display(cfi);
  }

  Future<void> _goToTypedPage() async {
    final info = _info;
    if (!_ready || info == null) return;
    final page = parseJumpPage(_pageField.text, pages: info.pages);
    if (page == null) {
      _pageField.text = '${info.page}';
      return;
    }
    _pageField.text = '$page';
    if (page == info.page) return;
    final cfi = await SharedPageRenderer.pageStart(_epubController, page);
    if (!mounted || cfi == null) return;
    _display(cfi);
  }

  Future<void> _showContents() async {
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
    _display(href);
  }

  void _confirm() {
    final cfi = _cfi;
    if (!_settled || cfi == null || _isHere || !widget.canConfirm) return;
    widget.onConfirm(JumpTarget(cfi: cfi, label: _info));
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) widget.onCancel();
      return KeyEventResult.handled;
    }
    // Typing a page number: the arrows and digits are the field's.
    if (_pageFieldFocus.hasFocus) return KeyEventResult.ignored;
    final direction = pageTurnDirectionForKey(
      event.logicalKey,
      volumeKeysTurnPages: widget.volumeKeysTurnPages,
    );
    if (direction == null) return KeyEventResult.ignored;
    // Never on to the room's reader underneath: these keys turn its page.
    if (event is KeyDownEvent) _turn(direction);
    return KeyEventResult.handled;
  }

  // ---------------------------------------------------------------------------
  // UI

  @override
  Widget build(BuildContext context) {
    final ink = widget.ink;
    final paper = widget.paper;
    return Focus(
      focusNode: _focus,
      onKeyEvent: (_, event) => _handleKeyEvent(event),
      child: ColoredBox(
        color: paper,
        child: Column(
          children: [
            _buildHeader(ink, paper),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  _updateViewerSize(constraints.biggest);
                  return _buildViewer(constraints, ink, paper);
                },
              ),
            ),
            _buildFooter(ink),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(Color ink, Color paper) {
    final info = _info;
    final progress = info?.progressLabel;
    final canGo = _settled && !_isHere && widget.canConfirm;
    return Container(
      height: JumpPreview.headerHeight,
      padding: const EdgeInsets.only(right: 8),
      decoration: BoxDecoration(
        color: paper,
        border: Border(
          bottom: BorderSide(color: ink, width: AppTheme.ruleWidth),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Close',
            color: ink,
            onPressed: widget.onCancel,
            icon: const Icon(Icons.close),
          ),
          Text('Page', style: AppTheme.body.copyWith(color: ink)),
          const SizedBox(width: 6),
          SizedBox(
            width: 56,
            child: TextField(
              controller: _pageField,
              focusNode: _pageFieldFocus,
              enabled: _ready && info != null,
              keyboardType: TextInputType.number,
              textInputAction: TextInputAction.go,
              textAlign: TextAlign.center,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(5),
              ],
              style: AppTheme.body.copyWith(
                color: ink,
                fontWeight: FontWeight.w700,
              ),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 8,
                ),
                filled: true,
                fillColor: paper,
                enabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(color: ink, width: AppTheme.ruleWidth),
                ),
                focusedBorder: OutlineInputBorder(
                  borderSide: BorderSide(
                    color: ink,
                    width: AppTheme.heavyRuleWidth,
                  ),
                ),
                disabledBorder: OutlineInputBorder(
                  borderSide: BorderSide(
                    color: ink.withValues(alpha: 0.35),
                    width: AppTheme.ruleWidth,
                  ),
                ),
              ),
              onSubmitted: (_) {
                _focus.requestFocus();
                unawaited(_goToTypedPage());
              },
              // Back to the page keys.
              onTapOutside: (_) {
                if (_pageFieldFocus.hasFocus) _focus.requestFocus();
              },
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              // Words, not a spinner: e-ink.
              !_ready
                  ? 'Loading...'
                  : [
                      '/ ${info?.pages ?? '–'}',
                      // Where the slider will go, until it has gone there.
                      if (_dragging)
                        '${(_sliderValue * 100).floor()}%'
                      else if (progress != null)
                        progress,
                    ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.body.copyWith(color: ink),
            ),
          ),
          ElevatedButton(
            onPressed: canGo ? _confirm : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: ink,
              foregroundColor: paper,
              disabledBackgroundColor: paper,
              disabledForegroundColor: ink.withValues(alpha: 0.35),
              minimumSize: const Size(64, 44),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              side: BorderSide(
                color: canGo ? ink : ink.withValues(alpha: 0.35),
                width: AppTheme.ruleWidth,
              ),
            ),
            child: Text(_isHere && _settled ? 'Here' : 'Go'),
          ),
        ],
      ),
    );
  }

  Widget _buildViewer(BoxConstraints constraints, Color ink, Color paper) {
    return Stack(
      children: [
        AbsorbPointer(
          child: EpubViewer(
            epubController: _epubController,
            epubSource: EpubSource.fromFile(widget.bookFile),
            displaySettings: widget.displaySettings,
            initialCfi: widget.initialCfi,
            onChaptersLoaded: _onChaptersLoaded,
            onRelocated: _onRelocated,
          ),
        ),
        if (!_ready)
          Positioned.fill(
            child: ColoredBox(
              color: paper,
              child: Center(
                child: Text(
                  'Loading...',
                  style: AppTheme.body.copyWith(color: ink),
                ),
              ),
            ),
          )
        else
          // The reader's tap zones: back on the left third, on elsewhere.
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
  }

  Widget _buildFooter(Color ink) {
    final disabledInk = ink.withValues(alpha: 0.35);
    final iconStyle = IconButton.styleFrom(
      foregroundColor: ink,
      disabledForegroundColor: disabledInk,
    );
    return Container(
      height: JumpPreview.footerHeight,
      decoration: BoxDecoration(
        color: widget.paper,
        border: Border(
          top: BorderSide(color: ink, width: AppTheme.ruleWidth),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            style: iconStyle,
            tooltip: 'Contents',
            onPressed: _ready && _chapters.isNotEmpty
                ? () => unawaited(_showContents())
                : null,
            icon: const Icon(Icons.toc),
          ),
          IconButton(
            style: iconStyle,
            tooltip: 'Previous page',
            onPressed: _ready ? () => _turn(PageTurnDirection.previous) : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Expanded(
            child: SliderTheme(
              // Flat and still: e-ink.
              data: SliderThemeData(
                activeTrackColor: ink,
                inactiveTrackColor: disabledInk,
                thumbColor: ink,
                disabledActiveTrackColor: disabledInk,
                disabledInactiveTrackColor: disabledInk,
                disabledThumbColor: disabledInk,
                overlayShape: SliderComponentShape.noOverlay,
                trackHeight: 3,
              ),
              child: Semantics(
                label: 'Position in the book',
                child: Slider(
                  value: _sliderValue.clamp(0.0, 1.0),
                  onChanged: _ready
                      ? (value) => setState(() {
                          _dragging = true;
                          _sliderValue = value;
                        })
                      : null,
                  // Only where the drag ends: an e-ink screen cannot keep up
                  // with a page for every step of the thumb.
                  onChangeEnd: _ready
                      ? (value) {
                          setState(() => _dragging = false);
                          unawaited(_goToProgress(value));
                        }
                      : null,
                ),
              ),
            ),
          ),
          IconButton(
            style: iconStyle,
            tooltip: 'Next page',
            onPressed: _ready ? () => _turn(PageTurnDirection.next) : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}
