import 'package:flutter/material.dart';
import '../config/theme.dart';
import '../models/library_book.dart';
import '../services/library_service.dart';
import 'paper.dart';

/// Opens the public library in a sheet. Resolves with the book the reader
/// picked, or null when they closed it.
Future<LibraryBook?> showLibraryBrowser({
  required BuildContext context,
  required LibraryService library,
}) {
  return showPaperSheet<LibraryBook>(
    context: context,
    builder: (sheetContext) {
      final media = MediaQuery.of(sheetContext);
      // A fixed height, so filtering a long list down to a few books does not
      // collapse the sheet under the reader's finger; it only gives way to
      // the keyboard while searching.
      final height = (media.size.height * 0.85 - media.viewInsets.bottom).clamp(
        240.0,
        double.infinity,
      );
      return Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: SizedBox(
          height: height,
          child: LibraryBrowser(
            library: library,
            onSelected: (book) => Navigator.of(sheetContext).pop(book),
          ),
        ),
      );
    },
  );
}

/// Browses the public library: search by title or author, and narrow by
/// category and language.
///
/// The whole catalog is loaded once and filtered on the device, so typing
/// never waits on the network and never flashes a loading state on e-ink.
/// Expands to the height it is given.
class LibraryBrowser extends StatefulWidget {
  final LibraryService library;
  final ValueChanged<LibraryBook> onSelected;

  const LibraryBrowser({
    super.key,
    required this.library,
    required this.onSelected,
  });

  @override
  State<LibraryBrowser> createState() => _LibraryBrowserState();
}

class _LibraryBrowserState extends State<LibraryBrowser> {
  final _searchController = TextEditingController();
  List<LibraryBook>? _books;
  String? _error;
  LibraryFilter _filter = const LibraryFilter();

  /// Category and language are advanced: hidden behind the filter button so
  /// the books get the room, and so the search box is the obvious way in.
  bool _showFilters = false;

  /// A retry must not be overwritten by the slower attempt it replaced.
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    setState(() {
      _books = null;
      _error = null;
    });
    try {
      final books = await widget.library.listBooks();
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _books = books);
    } catch (error) {
      debugPrint('Unable to list the library: $error');
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _error = 'The library could not be opened.');
    }
  }

  void _setQuery(String query) {
    setState(() {
      _filter = LibraryFilter(
        query: query,
        category: _filter.category,
        language: _filter.language,
      );
    });
  }

  void _setCategory(String? category) {
    setState(() {
      _filter = LibraryFilter(
        query: _filter.query,
        category: category,
        language: _filter.language,
      );
    });
  }

  void _setLanguage(String? language) {
    setState(() {
      _filter = LibraryFilter(
        query: _filter.query,
        category: _filter.category,
        language: language,
      );
    });
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() => _filter = const LibraryFilter());
  }

  @override
  Widget build(BuildContext context) {
    final books = _books;
    final shown = books == null ? null : _filter.apply(books);
    final categories = books == null
        ? const <String>[]
        : libraryCategories(books);
    final languages = books == null
        ? const <String>[]
        : libraryLanguages(books);
    final canFilter = categories.isNotEmpty || languages.isNotEmpty;
    final filtersActive = _filter.category != null || _filter.language != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Public Library', style: AppTheme.title),
        const SizedBox(height: 16),
        // Stretched so the filter button is exactly as tall as the field,
        // whatever the theme and text size make that.
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  onChanged: _setQuery,
                  enabled: books != null,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: 'Search by title or author',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: _filter.query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _searchController.clear();
                              _setQuery('');
                            },
                          ),
                  ),
                ),
              ),
              // No button when there is nothing to filter by: an uncatalogued
              // library would open an empty panel.
              if (canFilter) ...[
                const SizedBox(width: 8),
                _FilterButton(
                  open: _showFilters,
                  active: filtersActive,
                  onPressed: () => setState(() => _showFilters = !_showFilters),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        // The panel scrolls with the books instead of sitting above them: with
        // the keyboard up on a phone, a fixed panel would leave no room.
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) => CustomScrollView(
              slivers: [
                if (canFilter && _showFilters)
                  SliverPadding(
                    padding: const EdgeInsets.only(bottom: 16),
                    sliver: SliverToBoxAdapter(
                      child: _FilterPanel(
                        categories: categories,
                        languages: languages,
                        category: _filter.category,
                        language: _filter.language,
                        onCategory: _setCategory,
                        onLanguage: _setLanguage,
                      ),
                    ),
                  ),
                SliverToBoxAdapter(
                  child: SectionHeader(
                    label: 'Books',
                    trailing: books == null || shown == null
                        ? null
                        : Text(
                            _filter.isEmpty
                                ? _countLabel(books.length)
                                : '${shown.length} of '
                                      '${_countLabel(books.length)}',
                            style: AppTheme.caption,
                          ),
                  ),
                ),
                _buildBooks(context, books, shown, constraints.maxWidth),
              ],
            ),
          ),
        ),
      ],
    );
  }

  static String _countLabel(int count) =>
      '$count ${count == 1 ? 'book' : 'books'}';

  Widget _buildBooks(
    BuildContext context,
    List<LibraryBook>? books,
    List<LibraryBook>? shown,
    double width,
  ) {
    if (_error != null) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PaperNotice(message: _error!, icon: Icons.wifi_off),
              const SizedBox(height: 8),
              TextButton(onPressed: _load, child: const Text('Try Again')),
            ],
          ),
        ),
      );
    }
    if (books == null || shown == null) {
      // Text, not a spinner: e-ink.
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Text('Loading the library...', style: AppTheme.body),
        ),
      );
    }
    if (books.isEmpty) {
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 20),
          child: Text('The library is empty for now.', style: AppTheme.body),
        ),
      );
    }
    if (shown.isEmpty) {
      // A dead end otherwise: the filter that hid everything may be in a
      // closed panel.
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.only(top: 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('No books match.', style: AppTheme.body),
              const SizedBox(height: 8),
              TextButton(
                onPressed: _clearFilters,
                child: const Text('Clear Search and Filters'),
              ),
            ],
          ),
        ),
      );
    }
    const spacing = 16.0;
    // At least three across, as a shelf reads on a phone; wider screens
    // (e-ink tablets) get more columns rather than bigger covers.
    final columns = ((width + spacing) / (120 + spacing)).floor().clamp(3, 8);
    final tileWidth = (width - spacing * (columns - 1)) / columns;
    final titleLines =
        MediaQuery.textScalerOf(context).scale(_BookTile.titleSize) *
        _BookTile.titleHeight *
        _BookTile.titleMaxLines;
    return SliverPadding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      sliver: SliverGrid.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: columns,
          crossAxisSpacing: spacing,
          mainAxisSpacing: 20,
          // Every tile is as tall as a cover plus two lines of title, so a
          // short title does not pull its row out of line.
          mainAxisExtent:
              tileWidth / LibraryCover.aspectRatio +
              _BookTile.gap +
              titleLines +
              2,
        ),
        itemCount: shown.length,
        itemBuilder: (context, index) {
          final book = shown[index];
          final coverPath = book.coverPath;
          return _BookTile(
            book: book,
            coverUrl: coverPath == null
                ? null
                : widget.library.coverUrl(coverPath),
            onTap: () => widget.onSelected(book),
          );
        },
      ),
    );
  }
}

/// Opens and closes the category and language filters. Inverted while a
/// filter is applied, so a narrowed list is never mistaken for the whole
/// library when the panel is closed; a heavier rule while the panel is open.
class _FilterButton extends StatelessWidget {
  final bool open;
  final bool active;
  final VoidCallback onPressed;

  const _FilterButton({
    required this.open,
    required this.active,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      toggled: open,
      child: Tooltip(
        message: 'Filters',
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(AppTheme.radius),
          child: Container(
            width: AppTheme.controlHeight,
            decoration: BoxDecoration(
              color: active ? AppTheme.ink : AppTheme.paper,
              border: Border.fromBorderSide(
                open
                    ? const BorderSide(
                        color: AppTheme.ink,
                        width: AppTheme.heavyRuleWidth,
                      )
                    : AppTheme.rule,
              ),
              borderRadius: BorderRadius.circular(AppTheme.radius),
            ),
            // The same icon open or closed: a cross here would read as
            // "clear the filters".
            child: Icon(
              Icons.tune,
              color: active ? AppTheme.paper : AppTheme.ink,
            ),
          ),
        ),
      ),
    );
  }
}

class _FilterPanel extends StatelessWidget {
  final List<String> categories;
  final List<String> languages;
  final String? category;
  final String? language;
  final ValueChanged<String?> onCategory;
  final ValueChanged<String?> onLanguage;

  const _FilterPanel({
    required this.categories,
    required this.languages,
    required this.category,
    required this.language,
    required this.onCategory,
    required this.onLanguage,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const Key('library-filters'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: const Border.fromBorderSide(AppTheme.rule),
        borderRadius: BorderRadius.circular(AppTheme.radius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (categories.isNotEmpty)
            _FilterGroup(
              label: 'Category',
              options: categories,
              selected: category,
              onChanged: onCategory,
            ),
          if (categories.isNotEmpty && languages.isNotEmpty)
            const SizedBox(height: 12),
          if (languages.isNotEmpty)
            _FilterGroup(
              label: 'Language',
              options: languages,
              selected: language,
              onChanged: onLanguage,
            ),
        ],
      ),
    );
  }
}

/// One set of mutually exclusive choices, "All" first. The label sits above
/// and the choices wrap, so neither is cut off on a narrow screen.
class _FilterGroup extends StatelessWidget {
  final String label;
  final List<String> options;
  final String? selected;
  final ValueChanged<String?> onChanged;

  const _FilterGroup({
    required this.label,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label.toUpperCase(), style: AppTheme.overline),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _FilterChoice(
              label: 'All',
              selected: selected == null,
              onTap: () => onChanged(null),
            ),
            for (final option in options)
              _FilterChoice(
                label: option,
                selected: option == selected,
                // Tapping the chosen one again lets go of it.
                onTap: () => onChanged(option == selected ? null : option),
              ),
          ],
        ),
      ],
    );
  }
}

/// Chosen is ink on paper reversed, not a tint: the panel is grayscale.
class _FilterChoice extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _FilterChoice({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppTheme.radius),
        child: Container(
          constraints: const BoxConstraints(minHeight: 40),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: selected ? AppTheme.ink : AppTheme.paper,
            border: const Border.fromBorderSide(AppTheme.rule),
            borderRadius: BorderRadius.circular(AppTheme.radius),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? AppTheme.paper : AppTheme.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A cover with the title under it, as books face out on a shelf.
class _BookTile extends StatelessWidget {
  static const titleSize = 14.0;
  static const titleHeight = 1.3;
  static const titleMaxLines = 2;
  static const gap = 8.0;

  final LibraryBook book;
  final String? coverUrl;
  final VoidCallback onTap;

  const _BookTile({
    required this.book,
    required this.coverUrl,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: LibraryCover.aspectRatio,
            child: LibraryCover(url: coverUrl, title: book.title),
          ),
          const SizedBox(height: gap),
          Text(
            book.title,
            style: const TextStyle(
              fontSize: titleSize,
              height: titleHeight,
              fontWeight: FontWeight.w600,
              color: AppTheme.ink,
            ),
            maxLines: titleMaxLines,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// A book's cover, filling the space it is given. Without a cover, or until
/// one loads, it is a plain jacket with the title set on it, so a shelf of
/// uncovered books still tells them apart at a glance.
///
/// A cover appears in one step rather than fading in: a fade is a dozen
/// partial refreshes on e-ink.
class LibraryCover extends StatelessWidget {
  /// Width over height; most EPUB covers are 2:3.
  static const aspectRatio = 2 / 3;

  final String? url;
  final String title;

  const LibraryCover({super.key, required this.url, required this.title});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final jacket = _PlainJacket(title: title);
        final url = this.url;
        return Container(
          decoration: const BoxDecoration(
            color: AppTheme.paper,
            border: Border.fromBorderSide(AppTheme.rule),
          ),
          child: url == null
              ? jacket
              : Image.network(
                  url,
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  // Decoded at the size it is shown, not the 400px it is
                  // stored at: a long shelf of covers stays small in memory.
                  cacheWidth:
                      (constraints.maxWidth *
                              MediaQuery.devicePixelRatioOf(context))
                          .ceil()
                          .clamp(1, 400),
                  excludeFromSemantics: true,
                  frameBuilder:
                      (context, child, frame, wasSynchronouslyLoaded) =>
                          frame == null ? jacket : child,
                  errorBuilder: (context, error, stackTrace) => jacket,
                ),
        );
      },
    );
  }
}

class _PlainJacket extends StatelessWidget {
  final String title;

  const _PlainJacket({required this.title});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        children: [
          const Divider(height: 1, thickness: AppTheme.ruleWidth),
          Expanded(
            child: Center(
              child: Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 5,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: AppTheme.serif,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  height: 1.25,
                  color: AppTheme.ink,
                ),
              ),
            ),
          ),
          const Divider(height: 1, thickness: AppTheme.ruleWidth),
        ],
      ),
    );
  }
}
