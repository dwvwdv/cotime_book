import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../l10n/l10n.dart';

/// Covers the page the room just reached while its ad break is on.
///
/// Every reader gets the next page at the same moment: a reader whose ad was
/// shorter, or never loaded, does not read ahead while the others watch
/// theirs. Solid paper and words, no spinner: e-ink.
class AdBreakCover extends StatelessWidget {
  /// Other readers whose ad is still up. Empty while this reader's own ad is
  /// coming up, or while it waits to hear whether anyone has one.
  final List<String> readersInAd;
  final Color ink;
  final Color paper;

  const AdBreakCover({
    super.key,
    required this.readersInAd,
    this.ink = AppTheme.ink,
    this.paper = AppTheme.paper,
  });

  @override
  Widget build(BuildContext context) {
    final detail = readersInAd.isEmpty
        ? context.l10n.adBreakPageOpensWhenBack
        : context.l10n.adBreakWaitingForAd(
            readersInAd.join(context.l10n.listSeparator),
          );
    // Taps on the cover are not page turns: nobody turns during the break.
    return AbsorbPointer(
      child: ColoredBox(
        color: paper,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.l10n.adBreak,
                  style: AppTheme.title.copyWith(color: ink),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  detail,
                  style: AppTheme.body.copyWith(color: ink),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
