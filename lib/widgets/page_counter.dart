import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../models/page_info.dart';

/// The page in its chapter, and how far into the book: "3 / 12" over "45%".
///
/// One width whatever it says, so the buttons beside it never move as the
/// numbers grow. No wider than the members button it replaced: the bottom
/// bar has to fit a 320dp screen. Long numbers shrink to fit instead.
///
/// Also the way to the jump preview: with [onTap] it is a button, framed
/// like the other outlined buttons on the bar, since a page number is where
/// a reader looks for "go to page".
class PageCounter extends StatelessWidget {
  static const double width = 52;

  final PageInfo? info;
  final Color ink;

  /// Opens the jump preview; null while it cannot be opened.
  final VoidCallback? onTap;

  const PageCounter({
    super.key,
    required this.info,
    required this.ink,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final info = this.info;
    final progress = info?.progressLabel;
    final onTap = this.onTap;
    final numbers = info == null
        ? null
        : Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  info.pageLabel,
                  style: TextStyle(
                    color: ink,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (progress != null)
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    progress,
                    style: TextStyle(color: ink, fontSize: 13),
                  ),
                ),
            ],
          );
    final label = info == null
        ? 'Go to page'
        : 'Page ${info.page} of ${info.pages} in this chapter'
              '${progress == null ? '' : ', $progress of the book'}'
              '${onTap == null ? '' : '. Go to page'}';
    return SizedBox(
      width: width,
      child: onTap == null
          ? (numbers == null
                ? null
                : Semantics(
                    label: label,
                    excludeSemantics: true,
                    child: numbers,
                  ))
          : Semantics(
              button: true,
              label: label,
              excludeSemantics: true,
              // No ripple: e-ink.
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onTap,
                child: Container(
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: ink, width: AppTheme.ruleWidth),
                    borderRadius: BorderRadius.circular(AppTheme.radius),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  alignment: Alignment.center,
                  // Before the first count there are no numbers to show, but
                  // the button is there all the same.
                  child: numbers ?? Icon(Icons.menu_book_outlined, color: ink),
                ),
              ),
            ),
    );
  }
}
