import 'package:flutter/material.dart';
import '../config/theme.dart';
import '../models/library_book.dart';
import '../services/library_service.dart';
import 'paper.dart';

/// Where the book to share comes from.
sealed class ShareBookChoice {
  const ShareBookChoice();
}

class ShareFromDevice extends ShareBookChoice {
  const ShareFromDevice();
}

class ShareFromLibrary extends ShareBookChoice {
  final LibraryBook book;

  const ShareFromLibrary(this.book);
}

/// Picks the book to share: a file on this device, or one from the public
/// library. Pops with a [ShareBookChoice], or nothing when dismissed.
class ShareBookSheet extends StatefulWidget {
  final LibraryService library;

  const ShareBookSheet({super.key, required this.library});

  @override
  State<ShareBookSheet> createState() => _ShareBookSheetState();
}

class _ShareBookSheetState extends State<ShareBookSheet> {
  List<LibraryBook>? _books;
  String? _error;

  /// A retry must not be overwritten by the slower attempt it replaced.
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _load();
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

  @override
  Widget build(BuildContext context) {
    final books = _books;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Share a Book', style: AppTheme.title),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).pop(const ShareFromDevice()),
          icon: const Icon(Icons.upload_file),
          label: const Text('Choose a File on This Device'),
        ),
        const SizedBox(height: 24),
        SectionHeader(
          label: 'Public Library',
          trailing: books == null
              ? null
              : Text(
                  '${books.length} ${books.length == 1 ? 'book' : 'books'}',
                  style: AppTheme.caption,
                ),
        ),
        // Bounded so a long library scrolls inside the sheet instead of
        // pushing the device-file button off the screen.
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.5,
          ),
          child: _buildLibrary(books),
        ),
      ],
    );
  }

  Widget _buildLibrary(List<LibraryBook>? books) {
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PaperNotice(message: _error!, icon: Icons.wifi_off),
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: const Text('Try Again')),
          ],
        ),
      );
    }
    if (books == null) {
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
    return ListView.separated(
      shrinkWrap: true,
      itemCount: books.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final book = books[index];
        return InkWell(
          onTap: () => Navigator.of(context).pop(ShareFromLibrary(book)),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Row(
              children: [
                const Icon(Icons.menu_book_outlined, size: 22),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
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
                ),
                if (book.sizeFormatted != null) ...[
                  const SizedBox(width: 12),
                  Text(book.sizeFormatted!, style: AppTheme.caption),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
