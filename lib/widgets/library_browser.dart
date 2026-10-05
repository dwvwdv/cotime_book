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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Public Library', style: AppTheme.title),
        const SizedBox(height: 16),
        TextField(
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
        if (categories.isNotEmpty) ...[
          const SizedBox(height: 12),
          _FilterRow(
            label: 'Category',
            options: categories,
            selected: _filter.category,
            onChanged: _setCategory,
          ),
        ],
        if (languages.isNotEmpty) ...[
          const SizedBox(height: 8),
          _FilterRow(
            label: 'Language',
            options: languages,
            selected: _filter.language,
            onChanged: _setLanguage,
          ),
        ],
        const SizedBox(height: 16),
        SectionHeader(
          label: 'Books',
          trailing: books == null || shown == null
              ? null
              : Text(
                  _filter.isEmpty
                      ? _countLabel(books.length)
                      : '${shown.length} of ${_countLabel(books.length)}',
                  style: AppTheme.caption,
                ),
        ),
        Expanded(child: _buildBooks(books, shown)),
      ],
    );
  }

  static String _countLabel(int count) =>
      '$count ${count == 1 ? 'book' : 'books'}';

  Widget _buildBooks(List<LibraryBook>? books, List<LibraryBook>? shown) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PaperNotice(message: _error!, icon: Icons.wifi_off),
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: const Text('Try Again')),
          ],
        ),
      );
    }
    if (books == null || shown == null) {
      // Text, not a spinner: e-ink.
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Text('Loading the library...', style: AppTheme.body),
      );
    }
    if (books.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Text('The library is empty for now.', style: AppTheme.body),
      );
    }
    if (shown.isEmpty) {
      // A dead end otherwise: the filter that hid everything may be scrolled
      // out of view in its row.
      return Padding(
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
      );
    }
    return ListView.separated(
      itemCount: shown.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final book = shown[index];
        return _BookRow(book: book, onTap: () => widget.onSelected(book));
      },
    );
  }
}

/// One line of mutually exclusive choices, "All" first. Scrolls sideways so
/// a long list of categories never wraps and pushes the books down.
class _FilterRow extends StatelessWidget {
  final String label;
  final List<String> options;
  final String? selected;
  final ValueChanged<String?> onChanged;

  const _FilterRow({
    required this.label,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 84,
          child: Text(label.toUpperCase(), style: AppTheme.overline),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _FilterChoice(
                  label: 'All',
                  selected: selected == null,
                  onTap: () => onChanged(null),
                ),
                for (final option in options) ...[
                  const SizedBox(width: 8),
                  _FilterChoice(
                    label: option,
                    selected: option == selected,
                    // Tapping the chosen one again lets go of it.
                    onTap: () => onChanged(option == selected ? null : option),
                  ),
                ],
              ],
            ),
          ),
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
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? AppTheme.ink : AppTheme.paper,
            border: const Border.fromBorderSide(AppTheme.rule),
            borderRadius: BorderRadius.circular(AppTheme.radius),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 15,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? AppTheme.paper : AppTheme.ink,
            ),
          ),
        ),
      ),
    );
  }
}

class _BookRow extends StatelessWidget {
  final LibraryBook book;
  final VoidCallback onTap;

  const _BookRow({required this.book, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final details = [
      book.author,
      book.category,
      book.languageName,
      book.sizeFormatted,
    ].whereType<String>().join(' · ');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.menu_book_outlined, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    book.title,
                    style: const TextStyle(
                      fontFamily: AppTheme.serif,
                      fontWeight: FontWeight.w700,
                      fontSize: 17,
                      color: AppTheme.ink,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (details.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      details,
                      style: AppTheme.caption,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
